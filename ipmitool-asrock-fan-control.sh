#!/usr/bin/env bash
#
# Fan control for ASRock Rack boards with an ASPEED AST2500 BMC.
#
# Developed against: ROMED8-2T (rev 1.02A), BMC firmware 2.02, ASPEED AST2500.
# Command reference: ASRock Rack TSDQA-72 (JUL/2025)
#   https://download.asrock.com/Rack/TSD/FAQ/TSDQA-72.pdf
#
# THIS SCRIPT IS AST2500-ONLY. On AST2600 boards every command differs and the
# manual-mode value is 0x02 rather than 0x01:
#
#            AST2500 (here)          AST2600
#   set mode  0x3a 0xd8 <16 bytes>   0x3a 0xd0 0x11 <16 bytes>
#   set duty  0x3a 0xd6 <16 bytes>   0x3a 0xd0 0x0e <16 bytes>
#   get mode  0x3a 0xd9 (observed)   0x3a 0xd0 0x12
#   get duty  0x3a 0xda              0x3a 0xd0 0x0f
#   manual    0x01                   0x02
#
# `ipmitool mc info` does not distinguish the two, so this is not auto-detected.
#
# Do NOT probe neighbouring OEM command bytes to discover capabilities: 0x3a 0xdc
# is reported to factory-reset all fan settings, and other neighbours of 0xda are
# undocumented writes.

set -uo pipefail

# Associative arrays and namerefs are used throughout; both need bash 4.3+.
# macOS ships bash 3.2, where `declare -A` fails with a confusing usage error
# rather than stopping, so check explicitly.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  printf '%s: requires bash 4.3 or newer, found %s\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 1
fi

FAN='0x3a'

FAN_SET_MODE='0xd8'
FAN_GET_MODE='0xd9'
FAN_MODE_AUTO_VALUE='00'
FAN_MODE_MANUAL_VALUE='01'
FAN_MODE_CUSTOM_VALUE='02'

FAN_SET_DUTY_PERCENTAGE='0xd6'
FAN_GET_CURRENT_DUTY_PERCENTAGE='0xda'

# 0xd7 is the SAVED duty setpoint; 0xda is the live current duty. Settled by
# observation on 2026-09-04: with slot 6 switched from manual to auto, 0xd7 kept its
# 0x64 (100%) setpoint while 0xda followed the BMC curve down to 0x23 (35%). Before
# that, every slot was either in manual or in auto at a coincidentally equal value, so
# the two arrays were byte-identical in every sample and looked like aliases.
#
# This is why the write-back baseline must be 0xd7: rebuilding the array from 0xda
# would overwrite every other fan's stored setpoint with a live sample of the curve.
#
# TSDQA-72 calls 0x3a 0xd7 "see fan setting mode", which is wrong for this board --
# 0xd9 is get-mode, and the doc never mentions it. The ServeTheHome thread says 0xd7
# returns one byte, also wrong here. set_duty still shape-checks the array at runtime,
# since another board could genuinely differ.
FAN_GET_SAVED_DUTY_PERCENTAGE='0xd7'

# Community-sourced only; absent from TSDQA-72; never verified on this board.
FAN_RESET_FACTORY='0xdc'

# Minimum duty this BMC will accept. Established by testing slot 5 (an empty header)
# on firmware 2.02: 20% is accepted, 19% and everything below is REJECTED outright with
#   rsp=0xcc: Invalid data field in request
# and the whole 16-byte write is discarded, so nothing partially applies. It is a hard
# rejection, not a silent clamp. The ServeTheHome thread's 20% floor is correct;
# TSDQA-72's implied 0-100 range is not. Override if another board differs.
FAN_MIN_DUTY=${FAN_MIN_DUTY:-20}

# Pause between the two writes set_duty makes. This BMC intermittently desynchronises
# IPMI message IDs when raw commands are issued back to back ("Received a response
# with unexpected ID 0 vs. 1"), after which it reports rsp=0xff for a command it has
# actually carried out. Set to 0 to disable.
FAN_WRITE_DELAY=${FAN_WRITE_DELAY:-0.25}

# Number of controllable fan slots. Auto-detected from the SDR; override if the BMC
# under-reports. The raw arrays are always 16 bytes regardless.
FAN_SLOT_COUNT=16
: "${FAN_SLOTS:=}"
: "${FAN_LABELS_FILE:=$(dirname "$0")/fan-labels.conf}"

SCRIPT_NAME=$(basename "$0")

# Replaced with the tag by the release workflow. An unstamped copy reports `git describe`
# instead, since the host runs this from a checkout where 'dev' alone says nothing.
VERSION='dev'

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

# ---------------------------------------------------------------------------
# Reads. Every raw read goes through read_fan_array so that a failed or
# malformed read can never reach a write path (see F5 in the plan: the previous
# version turned an empty read into a one-byte Set Fan Mode).
# ---------------------------------------------------------------------------

RAW_ARRAY=()

# read_fan_array <cmd> -- validates and populates RAW_ARRAY. Returns non-zero on
# any failure, having explained it on stderr.
read_fan_array() {
  local cmd=$1 out err rc errfile

  errfile=$(mktemp) || { warn "mktemp failed"; return 1; }
  out=$(ipmitool raw "$FAN" "$cmd" 2>"$errfile"); rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"

  if (( rc != 0 )); then
    warn "ipmitool raw $FAN $cmd failed (exit $rc)${err:+: $err}"
    return 1
  fi
  if [[ -z ${out//[[:space:]]/} ]]; then
    warn "ipmitool raw $FAN $cmd returned no data${err:+: $err}"
    return 1
  fi

  # Unquoted expansion flattens both spaces and any line wrapping.
  local -a toks=()
  local t
  for t in $out; do
    if [[ ! $t =~ ^[0-9a-fA-F]{2}$ ]]; then
      warn "ipmitool raw $FAN $cmd returned unexpected token '$t'"
      return 1
    fi
    toks+=( "${t,,}" )
  done

  RAW_ARRAY=( "${toks[@]}" )
  return 0
}

# Cached lazy loaders -- a narrow action must not pay for reads it does not use.
# DUTY_ARRAY and SET_ARRAY are read through namerefs in cell_dec, which static
# analysis cannot follow -- hence the disable below.
# shellcheck disable=SC2034
MODE_ARRAY=(); DUTY_ARRAY=(); SET_ARRAY=()
_loaded_mode=0; _loaded_duty=0; _loaded_set=0

load_mode() {
  (( _loaded_mode )) && return 0
  read_fan_array "$FAN_GET_MODE" || return 1
  MODE_ARRAY=( "${RAW_ARRAY[@]}" ); _loaded_mode=1
}
load_duty() {
  (( _loaded_duty )) && return 0
  read_fan_array "$FAN_GET_CURRENT_DUTY_PERCENTAGE" || return 1
  # shellcheck disable=SC2034  # read via nameref in cell_dec
  DUTY_ARRAY=( "${RAW_ARRAY[@]}" ); _loaded_duty=1
}
load_set() {
  (( _loaded_set )) && return 0
  read_fan_array "$FAN_GET_SAVED_DUTY_PERCENTAGE" || return 1
  SET_ARRAY=( "${RAW_ARRAY[@]}" ); _loaded_set=1
}

# A mode array is all 00/01/02; a duty array is not. Used to catch the case where
# 0xd7 turns out to mean what TSDQA-72 says it means (F18).
is_mode_shaped() {
  local -n _arr=$1
  local b
  (( ${#_arr[@]} == 0 )) && return 1
  for b in "${_arr[@]}"; do
    [[ $b == 00 || $b == 01 || $b == 02 ]] || return 1
  done
  return 0
}

declare -A SDR_NAME=() SDR_RPM=() SDR_RPM2=()
SDR_MAX_SLOT=0
_loaded_sdr=0

load_sdr() {
  (( _loaded_sdr )) && return 0
  local out err rc errfile
  errfile=$(mktemp) || { warn "mktemp failed"; return 1; }
  out=$(ipmitool sdr type fan 2>"$errfile"); rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"

  if (( rc != 0 )); then
    warn "ipmitool sdr type fan failed (exit $rc)${err:+: $err}"
    return 1
  fi
  if [[ -z ${out//[[:space:]]/} ]]; then
    warn "ipmitool sdr type fan returned no fan sensors${err:+: $err}"
    return 1
  fi

  # FANn is a header's first tachometer; FANn_2 is the second tach on that same
  # 6-pin header (pins 3 and 5), sharing one speed control on pin 4. So FANn_2 is
  # a second reading for slot n, never a slot of its own.
  local line name reading slot suffix rpm
  while IFS= read -r line; do
    [[ -z ${line//[[:space:]]/} ]] && continue
    name=${line%%|*}; name=${name//[[:space:]]/}
    reading=${line##*|}
    [[ $name =~ ^FAN([0-9]+)(_([0-9]+))?$ ]] || continue
    slot=${BASH_REMATCH[1]}; suffix=${BASH_REMATCH[3]:-}
    if [[ $reading =~ ([0-9]+)[[:space:]]*RPM ]]; then rpm=${BASH_REMATCH[1]}; else rpm='-'; fi
    if [[ -z $suffix ]]; then
      SDR_NAME[$slot]=$name
      SDR_RPM[$slot]=$rpm
      (( slot > SDR_MAX_SLOT )) && SDR_MAX_SLOT=$slot
    else
      SDR_RPM2[$slot]=$rpm
    fi
  done <<< "$out"

  if (( SDR_MAX_SLOT == 0 )); then
    warn "no FANn sensors found in the SDR"
    return 1
  fi
  _loaded_sdr=1
}

# Slot count comes from the BMC's own SDR declaration, not from guessing at byte
# values -- 0x1e is a legitimate 30% duty, not an absence marker.
resolve_fan_slots() {
  if [[ -n $FAN_SLOTS ]]; then
    [[ $FAN_SLOTS =~ ^[0-9]+$ ]] || die "FAN_SLOTS must be a positive integer, got '$FAN_SLOTS'"
    (( FAN_SLOTS >= 1 && FAN_SLOTS <= FAN_SLOT_COUNT )) \
      || die "FAN_SLOTS must be between 1 and $FAN_SLOT_COUNT, got $FAN_SLOTS"
    return 0
  fi
  load_sdr || die "cannot determine the fan slot count from the SDR (set FAN_SLOTS to override)"
  FAN_SLOTS=$SDR_MAX_SLOT
}

declare -A FAN_LABEL=()
HAVE_LABELS=0

load_labels() {
  [[ -r $FAN_LABELS_FILE ]] || return 0
  local line slot label lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$(( lineno + 1 ))
    line=${line%%#*}
    [[ -z ${line//[[:space:]]/} ]] && continue
    if [[ ! $line =~ ^[[:space:]]*([0-9]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
      warn "$FAN_LABELS_FILE line $lineno: expected 'slot = label', ignoring"
      continue
    fi
    slot=${BASH_REMATCH[1]}; label=${BASH_REMATCH[2]}
    if (( slot < 1 || slot > FAN_SLOTS )); then
      warn "$FAN_LABELS_FILE line $lineno: slot $slot is outside 1..$FAN_SLOTS, ignoring"
      continue
    fi
    FAN_LABEL[$slot]=$label
    HAVE_LABELS=1
  done < "$FAN_LABELS_FILE"
}

# ---------------------------------------------------------------------------
# Display. One table, projected by each read action, so every action shares the
# same SLOT index -- the whole point of the rewrite.
# ---------------------------------------------------------------------------

mode_name() {
  case $1 in
    "$FAN_MODE_AUTO_VALUE")   printf 'auto' ;;
    "$FAN_MODE_MANUAL_VALUE") printf 'manual' ;;
    "$FAN_MODE_CUSTOM_VALUE") printf 'custom' ;;
    *)                        printf '0x%s' "$1" ;;
  esac
}

cell_dec() {
  local -n _a=$1
  local idx=$(( $2 - 1 ))
  if (( idx >= 0 && idx < ${#_a[@]} )); then printf '%d' "0x${_a[$idx]}"; else printf '%s' '-'; fi
}

cell_mode() {
  local idx=$(( $1 - 1 ))
  if (( idx >= 0 && idx < ${#MODE_ARRAY[@]} )); then mode_name "${MODE_ARRAY[$idx]}"; else printf '%s' '-'; fi
}

# fan_table <show_all> <column>...
# Columns: NAME LABEL RPM RPM2 MODE DUTY SET. Only the sources actually needed
# are fetched.
fan_table() {
  local all=$1; shift
  local -a want=( "$@" )
  local col slot
  local need_sdr=0 need_mode=0 need_duty=0 need_set=0

  for col in "${want[@]}"; do
    case $col in
      NAME|RPM|RPM2) need_sdr=1 ;;
      MODE)          need_mode=1 ;;
      DUTY)          need_duty=1 ;;
      SET)           need_set=1 ;;
    esac
  done
  (( need_sdr ))  && { load_sdr  || return 1; }
  (( need_mode )) && { load_mode || return 1; }
  (( need_duty )) && { load_duty || return 1; }
  (( need_set ))  && { load_set  || return 1; }

  local last=$FAN_SLOTS
  (( all )) && last=$FAN_SLOT_COUNT

  # Drop columns that would be entirely empty on this board.
  local have_rpm2=0
  for (( slot = 1; slot <= last; slot++ )); do
    [[ ${SDR_RPM2[$slot]:--} != '-' ]] && have_rpm2=1
  done

  local -a cols=()
  for col in "${want[@]}"; do
    case $col in
      RPM2)  (( have_rpm2 ))  && cols+=( "$col" ) ;;
      LABEL) (( HAVE_LABELS )) && cols+=( "$col" ) ;;
      *)     cols+=( "$col" ) ;;
    esac
  done

  {
    local hdr='SLOT'
    for col in "${cols[@]}"; do
      case $col in
        DUTY) hdr+='|DUTY%' ;;
        SET)  hdr+='|SAVED%' ;;
        *)    hdr+="|$col" ;;
      esac
    done
    printf '%s\n' "$hdr"

    local row v
    for (( slot = 1; slot <= last; slot++ )); do
      row=$slot
      for col in "${cols[@]}"; do
        case $col in
          NAME)  v=${SDR_NAME[$slot]:--} ;;
          LABEL) v=${FAN_LABEL[$slot]:--} ;;
          RPM)   v=${SDR_RPM[$slot]:--} ;;
          RPM2)  v=${SDR_RPM2[$slot]:--} ;;
          MODE)  v=$(cell_mode "$slot") ;;
          DUTY)  v=$(cell_dec DUTY_ARRAY "$slot") ;;
          SET)   v=$(cell_dec SET_ARRAY "$slot") ;;
        esac
        row+="|$v"
      done
      printf '%s\n' "$row"
    done
  } | column -t -s '|'   # short flags: util-linux and BSD column both accept these
}

# ---------------------------------------------------------------------------
# Writes. Every write path validates its arguments with a regex before any
# arithmetic, and aborts before writing if any read failed or looks wrong.
# ---------------------------------------------------------------------------

# Runs a write and returns its exit status without acting on it. Callers MUST
# verify by reading the value back instead: this BMC returns
#   Unable to send RAW command (... cmd=0xd6 rsp=0xff): Unspecified error
# intermittently for writes it has in fact applied. Trusting the exit code reports
# a spurious failure; ignoring it (as the original script did) misses real ones.
# Only a read-back can tell the two apart.
WRITE_ERR=''
ipmitool_write() {
  local cmd=$1; shift
  local errfile rc
  errfile=$(mktemp) || { WRITE_ERR='mktemp failed'; return 1; }
  ipmitool raw "$FAN" "$cmd" "$@" >/dev/null 2>"$errfile"
  rc=$?
  WRITE_ERR=$(cat "$errfile"); rm -f "$errfile"
  return $rc
}

# "slot 4" or "slots 1-7", so messages read the same for both forms.
target_desc() {
  if [[ $1 == all ]]; then printf 'slots 1-%s' "$FAN_SLOTS"; else printf 'slot %s' "$1"; fi
}

prefix_hex() {
  local b; local -a out=()
  for b in "$@"; do out+=( "0x$b" ); done
  printf '%s' "${out[*]}"
}

# Regex first: `[ "$x" -lt 1 ]` exits 2 on non-numeric input, which reads as
# "test passed" through an || chain and then indexes the array with -1.
validate_slot() {
  local v=$1
  [[ $v =~ ^[0-9]+$ ]] || die "fan slot must be a whole number, got '$v'"
  (( v >= 1 && v <= FAN_SLOTS )) \
    || die "fan slot must be between 1 and $FAN_SLOTS (this board has $FAN_SLOTS controllable headers), got $v"
}

check_arrays_usable() {
  is_mode_shaped MODE_ARRAY \
    || die "aborting: $FAN_GET_MODE did not return a mode array (${MODE_ARRAY[*]}); refusing to write"
  if is_mode_shaped SET_ARRAY; then
    die "aborting: $FAN_GET_SAVED_DUTY_PERCENTAGE returned a mode-shaped array (${SET_ARRAY[*]}), not duties.
This board may differ from the one this script was written against -- see the note on
FAN_GET_SAVED_DUTY_PERCENTAGE at the top. Refusing to write a duty array built from mode bytes."
  fi
  (( ${#MODE_ARRAY[@]} == ${#SET_ARRAY[@]} )) \
    || die "aborting: mode array has ${#MODE_ARRAY[@]} bytes but duty array has ${#SET_ARRAY[@]}"
}

set_duty_percentage() {
  local slot='' duty='' dry=0 a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      -*)        die "unknown option '$a'" ;;
      *)
        if   [[ -z $slot ]]; then slot=$a
        elif [[ -z $duty ]]; then duty=$a
        else die "too many arguments to set_duty"; fi ;;
    esac
  done

  [[ -n $slot && -n $duty ]] \
    || die "usage: $SCRIPT_NAME set_duty <slot 1-$FAN_SLOTS|all> <duty $FAN_MIN_DUTY-100> [--dry-run]"
  [[ $slot == all ]] || validate_slot "$slot"
  [[ $duty =~ ^[0-9]+$ ]] || die "duty must be a whole number, got '$duty'"
  (( duty <= 100 )) || die "duty must be between $FAN_MIN_DUTY and 100, got $duty"
  (( duty >= FAN_MIN_DUTY )) \
    || die "duty must be at least ${FAN_MIN_DUTY}%: this BMC rejects anything lower with
'Invalid data field in request' (rsp=0xcc) and discards the whole write. Got $duty.
Set FAN_MIN_DUTY to override if your board accepts less."

  load_mode || die "aborting: could not read the current fan modes; nothing was written"
  load_set  || die "aborting: could not read the current duty baseline; nothing was written"
  check_arrays_usable

  local -a targets=()
  if [[ $slot == all ]]; then
    local t
    for (( t = 1; t <= FAN_SLOTS; t++ )); do targets+=( "$t" ); done
  else
    targets=( "$slot" )
  fi

  local idx
  for idx in "${targets[@]}"; do
    (( idx - 1 < ${#MODE_ARRAY[@]} )) \
      || die "aborting: the BMC returned only ${#MODE_ARRAY[@]} bytes, so slot $idx does not exist"
  done

  local -a modes=( "${MODE_ARRAY[@]}" ) duties=( "${SET_ARRAY[@]}" )
  local hexduty; hexduty=$(printf '%02x' "$duty")
  for idx in "${targets[@]}"; do
    modes[idx-1]=$FAN_MODE_MANUAL_VALUE
    duties[idx-1]=$hexduty
  done

  local mode_args duty_args
  mode_args=$(prefix_hex "${modes[@]}")
  duty_args=$(prefix_hex "${duties[@]}")

  if (( dry )); then
    local shown=0
    if [[ ${modes[*]} != "${MODE_ARRAY[*]}" ]]; then
      printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_MODE" "$mode_args"; shown=1
    else
      printf '# mode already correct for slot %s -- 0x%s not sent\n' "$slot" "${FAN_SET_MODE#0x}"
    fi
    if [[ ${duties[*]} != "${SET_ARRAY[*]}" ]]; then
      printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_DUTY_PERCENTAGE" "$duty_args"; shown=1
    else
      printf '# duty already %s%% for slot %s -- 0x%s not sent\n' "$duty" "$slot" "${FAN_SET_DUTY_PERCENTAGE#0x}"
    fi
    (( shown )) || printf '# nothing to do\n'
    return 0
  fi

  local attempt rc_mode=0 rc_duty=0 err_mode='' err_duty=''
  for attempt in 1 2; do
    rc_mode=0; rc_duty=0; err_mode=''; err_duty=''
    local wrote=0

    # Both OEM commands take the whole 16-byte array -- there is no per-slot form --
    # so every write re-applies a value to every fan on the board. Sending one that
    # would change nothing therefore disturbs seven fans to no purpose, so don't.
    if [[ ${modes[*]} != "${MODE_ARRAY[*]}" ]]; then
      ipmitool_write "$FAN_SET_MODE" $mode_args || rc_mode=$?
      err_mode=$WRITE_ERR
      wrote=1
      [[ $FAN_WRITE_DELAY != 0 ]] && sleep "$FAN_WRITE_DELAY"
    fi
    if [[ ${duties[*]} != "${SET_ARRAY[*]}" ]]; then
      ipmitool_write "$FAN_SET_DUTY_PERCENTAGE" $duty_args || rc_duty=$?
      err_duty=$WRITE_ERR
      wrote=1
    fi

    if (( ! wrote )); then
      printf '%s: manual, %s%% already -- nothing written\n' "$(target_desc "$slot")" "$duty"
      return 0
    fi

    _loaded_mode=0; _loaded_set=0
    load_mode || die "wrote, but could not read back to confirm; run 'show' to check the state"
    load_set  || die "wrote, but could not read back to confirm; run 'show' to check the state"

    local all_ok=1 any_clamped=0 got_mode='' got_duty='' t2
    for t2 in "${targets[@]}"; do
      local m=${MODE_ARRAY[t2-1]:-} d; d=$(cell_dec SET_ARRAY "$t2")
      got_mode=$m; got_duty=$d
      [[ $m == "$FAN_MODE_MANUAL_VALUE" ]] || all_ok=0
      if [[ $d != "$duty" ]]; then
        if (( rc_duty == 0 )); then any_clamped=1; else all_ok=0; fi
      fi
    done

    if (( all_ok && ! any_clamped )); then
      if (( rc_mode || rc_duty )); then
        warn "the BMC reported an error but the change did land -- this board does that
intermittently. Verified by reading the value back.${err_duty:+
  $err_duty}"
      fi
      printf '%s: manual, %s%%\n' "$(target_desc "$slot")" "$duty"
      return 0
    fi

    # Landed, but not on the requested value: a clamp, not a transport glitch, so
    # retrying would just repeat it.
    if (( all_ok && any_clamped )); then
      if (( ${#targets[@]} == 1 )); then
        warn "requested ${duty}% for slot ${targets[0]} but the BMC stored $(cell_dec SET_ARRAY "${targets[0]}")%"
      else
        local detail=''
        for t2 in "${targets[@]}"; do
          local d2; d2=$(cell_dec SET_ARRAY "$t2")
          [[ $d2 != "$duty" ]] && detail+="slot $t2 -> ${d2}%, "
        done
        warn "requested ${duty}% but the BMC stored: ${detail%, }"
      fi
      printf '%s: manual\n' "$(target_desc "$slot")"
      return 0
    fi

    (( attempt == 1 )) && warn "write did not take effect, retrying once"
  done

  die "failed to set $(target_desc "$slot"): wanted manual/${duty}%, BMC last reports ${got_mode:-?}/${got_duty:-?}${err_mode:+
  mode: $err_mode}${err_duty:+
  duty: $err_duty}"
}

set_fan_mode() {
  local target='' mode_arg='' dry=0 a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      -*)        die "unknown option '$a'" ;;
      *)
        if   [[ -z $target ]]; then target=$a
        elif [[ -z $mode_arg ]];   then mode_arg=$a
        else die "too many arguments to set_mode"; fi ;;
    esac
  done

  [[ -n $target && -n $mode_arg ]] \
    || die "usage: $SCRIPT_NAME set_mode <slot 1-$FAN_SLOTS|all> <auto|manual|custom> [--dry-run]"

  local val
  case $mode_arg in
    auto)   val=$FAN_MODE_AUTO_VALUE ;;
    manual) val=$FAN_MODE_MANUAL_VALUE ;;
    custom) val=$FAN_MODE_CUSTOM_VALUE ;;
    *)      die "mode must be auto, manual or custom, got '$mode_arg'" ;;
  esac

  load_mode || die "aborting: could not read the current fan modes; nothing was written"
  is_mode_shaped MODE_ARRAY \
    || die "aborting: $FAN_GET_MODE did not return a mode array (${MODE_ARRAY[*]})"

  local -a modes=( "${MODE_ARRAY[@]}" )
  local s
  if [[ $target == all ]]; then
    # Slots past FAN_SLOTS keep their current bytes: this is a targeted tool and
    # should not write padding the user did not ask about. `reset` differs, and
    # deliberately -- it follows the vendor's all-sixteen-zeros form verbatim.
    for (( s = 1; s <= FAN_SLOTS; s++ )); do
      (( s - 1 < ${#modes[@]} )) && modes[s-1]=$val
    done
  else
    validate_slot "$target"
    (( target - 1 < ${#modes[@]} )) \
      || die "aborting: the BMC returned only ${#modes[@]} bytes, so slot $target does not exist"
    modes[target-1]=$val
  fi

  local mode_args; mode_args=$(prefix_hex "${modes[@]}")
  local noop=0
  [[ ${modes[*]} == "${MODE_ARRAY[*]}" ]] && noop=1

  if (( dry )); then
    if (( noop )); then printf '# modes already as requested -- nothing to send\n'
    else printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_MODE" "$mode_args"; fi
    return 0
  fi

  # 0xd8 rewrites all 16 slots, so skip it when it would change nothing.
  if (( noop )); then
    printf 'mode already %s for %s -- nothing written\n' "$mode_arg" "$(target_desc "$target")"
    return 0
  fi

  local rc=0; ipmitool_write "$FAN_SET_MODE" $mode_args || rc=$?
  local err=$WRITE_ERR

  _loaded_mode=0
  load_mode || die "wrote, but could not read back to confirm; run 'show_mode' to check"

  local bad=0 s2
  if [[ $target == all ]]; then
    for (( s2 = 1; s2 <= FAN_SLOTS; s2++ )); do
      [[ ${MODE_ARRAY[s2-1]:-} == "$val" ]] || bad=1
    done
  else
    [[ ${MODE_ARRAY[target-1]:-} == "$val" ]] || bad=1
  fi

  if (( bad )); then
    die "failed to set mode: the BMC still reports ${MODE_ARRAY[*]}${err:+
  $err}"
  fi
  (( rc )) && warn "the BMC reported an error but the change did land${err:+
  $err}"

  printf 'mode set to %s for %s\n' "$mode_arg" "$(target_desc "$target")"
}

reset_fans() {
  local factory=0 assume_yes=0 dry=0 a
  for a in "$@"; do
    case $a in
      --factory)  factory=1 ;;
      --yes|-y)   assume_yes=1 ;;
      --dry-run)  dry=1 ;;
      *)          die "unknown option '$a' (usage: $SCRIPT_NAME reset [--factory] [--yes] [--dry-run])" ;;
    esac
  done

  local cmd args desc
  if (( factory )); then
    cmd=$FAN_RESET_FACTORY
    args=''
    desc='factory-reset every fan setting'
  else
    # The vendor's form verbatim: all sixteen bytes zeroed.
    local -a zeros=(); local i
    for (( i = 0; i < FAN_SLOT_COUNT; i++ )); do zeros+=( "$FAN_MODE_AUTO_VALUE" ); done
    cmd=$FAN_SET_MODE
    args=$(prefix_hex "${zeros[@]}")
    desc="hand all $FAN_SLOT_COUNT slots back to automatic (BMC curve) control"
  fi

  if (( dry )); then
    printf 'ipmitool raw %s %s%s\n' "$FAN" "$cmd" "${args:+ $args}"
    return 0
  fi

  printf 'Current fan state:\n\n'
  fan_table 0 NAME LABEL RPM RPM2 MODE DUTY SET || warn 'could not render the current state'
  printf '\nRaw arrays before:\n'
  load_mode && printf '  %s  %s\n' "$FAN_GET_MODE" "${MODE_ARRAY[*]}"
  load_set  && printf '  %s  %s\n' "$FAN_GET_SAVED_DUTY_PERCENTAGE" "${SET_ARRAY[*]}"
  printf '\nRecord those two lines: they are what you would rebuild from.\n'

  printf '\nThis will %s. Fan speeds will change audibly.\n' "$desc"
  if (( factory )); then
    cat <<'WARNTXT'

WARNING: `ipmitool raw 0x3a 0xdc` is community-sourced only. It does not appear in
ASRock Rack TSDQA-72, and it has never been verified on this board. Its exact effect
is unknown and it cannot be undone. The vendor-documented reset is plain `reset`.
WARNTXT
  fi

  if (( ! assume_yes )); then
    local reply
    printf "\nType 'yes' to proceed: "
    if ! IFS= read -r reply; then
      printf '\n'
      die 'aborted (no input); nothing was written'
    fi
    [[ $reply == yes ]] || die 'aborted; nothing was written'
  fi

  if ! ipmitool raw "$FAN" "$cmd" $args; then
    die 'reset command failed; fan state is most likely unchanged'
  fi

  _loaded_mode=0; _loaded_duty=0; _loaded_set=0
  printf '\nFan state after:\n\n'
  fan_table 0 NAME LABEL RPM RPM2 MODE DUTY SET || warn 'could not render the new state'
  printf '\nRaw arrays after:\n'
  load_mode && printf '  %s  %s\n' "$FAN_GET_MODE" "${MODE_ARRAY[*]}"
  load_set  && printf '  %s  %s\n' "$FAN_GET_SAVED_DUTY_PERCENTAGE" "${SET_ARRAY[*]}"
}

show_version() {
  local v=$VERSION d
  if [[ $v == dev ]] && d=$(git -C "$(dirname "$0")" describe --tags --always --dirty 2>/dev/null); then
    v="dev ($d)"
  fi
  printf '%s %s\n' "$SCRIPT_NAME" "$v"
}

resolve_fan_slots_quiet() {
  [[ -n $FAN_SLOTS ]] && return 0
  if load_sdr 2>/dev/null; then FAN_SLOTS=$SDR_MAX_SLOT; else FAN_SLOTS='<unknown>'; fi
}

help() {
  cat <<HELP_TXT
$SCRIPT_NAME <action> [arguments]

Fan slots are numbered 1-$FAN_SLOTS, matching the FANn sensor names. The same slot
number means the same fan in every action below.

Read actions:
  show [--all]           slot, name, RPM, mode and duty in one table
  show_rpm [--all]       tachometer readings
  show_mode [--all]      auto / manual / custom per slot
  show_current_duty [--all]   duty the fans are running at now (0xda)
  show_saved_duty [--all]     saved duty setpoints (0xd7); these differ from the
                              live duty whenever a fan is in auto mode

Write actions:
  set_duty <slot|all> <duty 20-100> [--dry-run]
      Sets a fan to a fixed duty, switching that slot to manual mode.
      'all' covers slots 1-$FAN_SLOTS in a single pair of writes.
      Minimum duty is ${FAN_MIN_DUTY}% -- the BMC rejects anything lower outright.
  set_mode <slot|all> <auto|manual|custom> [--dry-run]
      Changes mode without touching duty. 'all' covers slots 1-$FAN_SLOTS.
  reset [--yes] [--dry-run]
      Hands every slot back to the BMC curve, using the reset ASRock documents
      in TSDQA-72. This is the one to reach for first.
  reset --factory [--yes] [--dry-run]
      Sends 0x3a 0xdc instead. Community-sourced, undocumented by ASRock and
      unverified on this board. Not reversible.

Other:
  help                   this text
  --version              print the version

--all widens the tables to all $FAN_SLOT_COUNT array slots. It does not permit
writing to them: slots above $FAN_SLOTS have no physical header on this board.

Environment:
  FAN_SLOTS         override the SDR-derived slot count ($FAN_SLOTS here)
  FAN_MIN_DUTY      lowest duty the BMC accepts (${FAN_MIN_DUTY}% here)
  FAN_LABELS_FILE   optional 'slot = label' file, one per line
                    (default: $FAN_LABELS_FILE)
HELP_TXT
}

# ---------------------------------------------------------------------------

main() {
  local action=${1:-}
  shift || true

  local all=0
  local -a rest=()
  local a
  for a in "$@"; do
    case $a in
      --all) all=1 ;;
      *)     rest+=( "$a" ) ;;
    esac
  done

  case $action in
    show|show_rpm|show_mode|show_current_duty|show_saved_duty|set_duty|set_mode|reset)
      resolve_fan_slots
      load_labels
      ;;
  esac

  case $action in
    show)              fan_table "$all" NAME LABEL RPM RPM2 MODE DUTY SET ;;
    show_rpm)          fan_table "$all" NAME LABEL RPM RPM2 ;;
    show_mode)         fan_table "$all" NAME LABEL MODE ;;
    show_current_duty) fan_table "$all" NAME LABEL DUTY ;;
    show_saved_duty)   fan_table "$all" NAME LABEL SET ;;
    set_duty)          set_duty_percentage ${rest[@]+"${rest[@]}"} ;;
    set_mode)          set_fan_mode ${rest[@]+"${rest[@]}"} ;;
    reset)             reset_fans ${rest[@]+"${rest[@]}"} ;;
    help|--help|-h)    resolve_fan_slots_quiet; help ;;
    version|--version|-v) show_version ;;
    '')                resolve_fan_slots_quiet; help >&2; exit 2 ;;
    *)                 printf '%s: unknown action %s\n\n' "$SCRIPT_NAME" "$action" >&2
                       resolve_fan_slots_quiet; help >&2; exit 2 ;;
  esac
}

main "$@"

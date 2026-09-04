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

# 0xd7's meaning is contested and unresolved. This script's original name for it was
# FAN_GET_SAVED_DUTY_PERCENTAGE, which no authoritative source confirms:
#   - TSDQA-72 says 0x3a 0xd7 is "see fan setting mode"  -> contradicted here, it is
#     not mode-shaped; 0xd9 is.
#   - The ServeTheHome thread says it returns 1 byte     -> contradicted here, 16.
#   - Observed on ROMED8-2T: 16 duty-shaped bytes, byte-identical to 0xda in every
#     sample taken so far.
# It is used as the write-back baseline (a duty array), and set_duty shape-checks it
# at runtime rather than trusting the name.
FAN_GET_DUTY_D7='0xd7'

# Community-sourced only; absent from TSDQA-72; never verified on this board.
FAN_RESET_FACTORY='0xdc'

# Number of controllable fan slots. Auto-detected from the SDR; override if the BMC
# under-reports. The raw arrays are always 16 bytes regardless.
FAN_SLOT_COUNT=16
: "${FAN_SLOTS:=}"
: "${FAN_LABELS_FILE:=$(dirname "$0")/fan-labels.conf}"

SCRIPT_NAME=$(basename "$0")

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
  read_fan_array "$FAN_GET_DUTY_D7" || return 1
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
        SET)  hdr+='|SET%' ;;
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
    die "aborting: $FAN_GET_DUTY_D7 returned a mode-shaped array (${SET_ARRAY[*]}), not duties.
This board may differ from the one this script was written against -- see the note on
FAN_GET_DUTY_D7 at the top. Refusing to write a duty array built from mode bytes."
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
    || die "usage: $SCRIPT_NAME set_duty <slot 1-$FAN_SLOTS> <duty 0-100> [--dry-run]"
  validate_slot "$slot"
  [[ $duty =~ ^[0-9]+$ ]] || die "duty must be a whole number, got '$duty'"
  (( duty >= 0 && duty <= 100 )) || die "duty must be between 0 and 100, got $duty"

  load_mode || die "aborting: could not read the current fan modes; nothing was written"
  load_set  || die "aborting: could not read the current duty baseline; nothing was written"
  check_arrays_usable

  local idx=$(( slot - 1 ))
  (( idx < ${#MODE_ARRAY[@]} )) \
    || die "aborting: the BMC returned only ${#MODE_ARRAY[@]} bytes, so slot $slot does not exist"

  local -a modes=( "${MODE_ARRAY[@]}" ) duties=( "${SET_ARRAY[@]}" )
  modes[idx]=$FAN_MODE_MANUAL_VALUE
  duties[idx]=$(printf '%02x' "$duty")

  local mode_args duty_args
  mode_args=$(prefix_hex "${modes[@]}")
  duty_args=$(prefix_hex "${duties[@]}")

  if (( dry )); then
    printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_MODE" "$mode_args"
    printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_DUTY_PERCENTAGE" "$duty_args"
    return 0
  fi

  ipmitool raw "$FAN" "$FAN_SET_MODE" $mode_args \
    || die "setting fan mode failed; duty was not written"
  ipmitool raw "$FAN" "$FAN_SET_DUTY_PERCENTAGE" $duty_args \
    || die "setting fan duty failed (slot $slot is now in manual mode)"

  # The firmware is reported to clamp low duties on some versions, so report what
  # it actually stored rather than what was asked for.
  _loaded_set=0
  if load_set; then
    local stored; stored=$(cell_dec SET_ARRAY "$slot")
    if [[ $stored == "$duty" ]]; then
      printf 'slot %s: manual, %s%%\n' "$slot" "$stored"
    else
      warn "requested ${duty}% for slot $slot but the BMC stored ${stored}%"
    fi
  fi
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
  if (( dry )); then
    printf 'ipmitool raw %s %s %s\n' "$FAN" "$FAN_SET_MODE" "$mode_args"
    return 0
  fi

  ipmitool raw "$FAN" "$FAN_SET_MODE" $mode_args || die "setting fan mode failed"
  _loaded_mode=0
  printf 'mode set to %s for %s\n' "$mode_arg" \
    "$( [[ $target == all ]] && printf 'slots 1-%s' "$FAN_SLOTS" || printf 'slot %s' "$target" )"
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
  load_set  && printf '  %s  %s\n' "$FAN_GET_DUTY_D7" "${SET_ARRAY[*]}"
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
  load_set  && printf '  %s  %s\n' "$FAN_GET_DUTY_D7" "${SET_ARRAY[*]}"
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
  show_saved_duty [--all]     the 0xd7 duty array (see the note on 0xd7 in this file)

Write actions:
  set_duty <slot> <duty 0-100> [--dry-run]
      Sets one fan to a fixed duty, switching that slot to manual mode.
  set_mode <slot|all> <auto|manual|custom> [--dry-run]
      Changes mode without touching duty. 'all' covers slots 1-$FAN_SLOTS.
  reset [--yes] [--dry-run]
      Hands every slot back to the BMC curve, using the reset ASRock documents
      in TSDQA-72. This is the one to reach for first.
  reset --factory [--yes] [--dry-run]
      Sends 0x3a 0xdc instead. Community-sourced, undocumented by ASRock and
      unverified on this board. Not reversible.

--all widens the tables to all $FAN_SLOT_COUNT array slots. It does not permit
writing to them: slots above $FAN_SLOTS have no physical header on this board.

Environment:
  FAN_SLOTS         override the SDR-derived slot count ($FAN_SLOTS here)
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
    '')                resolve_fan_slots_quiet; help >&2; exit 2 ;;
    *)                 printf '%s: unknown action %s\n\n' "$SCRIPT_NAME" "$action" >&2
                       resolve_fan_slots_quiet; help >&2; exit 2 ;;
  esac
}

main "$@"

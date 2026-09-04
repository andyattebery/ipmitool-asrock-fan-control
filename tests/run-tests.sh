#!/usr/bin/env bash
#
# Test suite for ipmitool-asrock-fan-control.sh.
#
#   tests/run-tests.sh                 offline suite, mocked ipmitool (needs bash 4.3+)
#   tests/run-tests.sh --remote HOST   copy to HOST and run the offline suite there
#   tests/run-tests.sh --live HOST     read-only checks against real hardware (needs sudo)
#
# The offline suite needs no BMC. Because ipmitool is mocked, it can cover cases
# the real board cannot show: a second tachometer reading, non-zero padding in
# slots 8-16, 0xd7 differing from 0xda, and a firmware duty clamp.
#
# This runner deliberately avoids bash 4 features so that it still runs on
# bash 3.2 and can report why the script itself will not.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SCRIPT="$ROOT/ipmitool-asrock-fan-control.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/         /'; }

# ---------------------------------------------------------------- fixtures ---

SDR_ROMED8='FAN1             | 60h | ok  | 29.0 | 1900 RPM
FAN2             | 61h | ok  | 29.0 | 800 RPM
FAN3             | 62h | ok  | 29.0 | 4900 RPM
FAN4             | 63h | ok  | 29.0 | 1400 RPM
FAN5             | 64h | ns  | 29.0 | No Reading
FAN6             | 65h | ok  | 29.0 | 1700 RPM
FAN7             | 66h | ns  | 29.0 | No Reading
FAN1_2           | 68h | ns  | 29.0 | No Reading
FAN2_2           | 69h | ns  | 29.0 | No Reading
FAN3_2           | 6Ah | ns  | 29.0 | No Reading
FAN4_2           | 6Bh | ns  | 29.0 | No Reading
FAN5_2           | 6Ch | ns  | 29.0 | No Reading
FAN6_2           | 6Dh | ns  | 29.0 | No Reading
FAN7_2           | 6Eh | ns  | 29.0 | No Reading'

# Same board with both tachometers reporting -- the RPM2 column cannot be
# exercised on the real machine, where every FANn_2 reads "No Reading".
SDR_DUALTACH='FAN1             | 60h | ok  | 29.0 | 1900 RPM
FAN2             | 61h | ok  | 29.0 | 800 RPM
FAN1_2           | 68h | ok  | 29.0 | 1850 RPM
FAN2_2           | 69h | ok  | 29.0 | 790 RPM'

D9_ROMED8=' 00 00 00 01 01 01 01 00 00 00 00 00 00 00 00 00'
D7_ROMED8=' 23 23 23 46 46 64 46 23 1e 1e 1e 1e 1e 1e 1e 1e'

# setup <name> [sdr] [d9] [d7] [da]
setup() {
  MOCK_DIR=$(mktemp -d) || exit 1
  printf '%s\n' "${2:-$SDR_ROMED8}"  > "$MOCK_DIR/sdr"
  printf '%s\n' "${3:-$D9_ROMED8}"   > "$MOCK_DIR/d9"
  printf '%s\n' "${4:-$D7_ROMED8}"   > "$MOCK_DIR/d7"
  printf '%s\n' "${5:-$D7_ROMED8}"   > "$MOCK_DIR/da"
  : > "$MOCK_DIR/writes"
  BIN=$MOCK_DIR/bin; mkdir -p "$BIN"; ln -s "$HERE/mock-ipmitool" "$BIN/ipmitool"
  export MOCK_DIR
}
teardown() { [ -n "${MOCK_DIR:-}" ] && rm -rf "$MOCK_DIR"; MOCK_DIR=; }

# run <args...>  -> sets OUT, ERR, RC
run() {
  OUT=$(PATH="$BIN:$PATH" FAN_SLOTS='' FAN_LABELS_FILE="${LABELS:-/nonexistent}" \
        "$BASHBIN" "$SCRIPT" "$@" 2>"$MOCK_DIR/err" </dev/null)
  RC=$?
  ERR=$(cat "$MOCK_DIR/err")
}
writes() { cat "$MOCK_DIR/writes"; }
no_writes() { [ ! -s "$MOCK_DIR/writes" ]; }

assert_rc()       { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2" "expected rc=$1 got $RC; err=$ERR"; fi; }
assert_out()      { if printf '%s' "$OUT" | grep -qE "$1"; then ok "$2"; else bad "$2" "stdout lacked /$1/:
$OUT"; fi; }
assert_err()      { if printf '%s' "$ERR" | grep -qE "$1"; then ok "$2"; else bad "$2" "stderr lacked /$1/:
$ERR"; fi; }
assert_nowrite()  { if no_writes; then ok "$1"; else bad "$1" "unexpected writes: $(writes)"; fi; }
assert_write()    { if writes | grep -qE "$1"; then ok "$2"; else bad "$2" "writes lacked /$1/:
$(writes)"; fi; }

# ------------------------------------------------------------ offline suite ---

offline_suite() {
  printf '\nDispatch and help\n'
  setup
  run help;              assert_rc 0 'help exits 0'
                         assert_out 'numbered 1-7' 'help reports the real slot count'
  run typo;              assert_rc 2 'unknown action exits 2'
                         assert_nowrite 'unknown action writes nothing'
  teardown

  printf '\nF1 -- one slot index everywhere\n'
  setup
  run show
  assert_rc 0 'show succeeds'
  if [ "$(printf '%s\n' "$OUT" | grep -c '^[0-9]')" = 7 ]; then ok 'show lists 7 slots'
  else bad 'show lists 7 slots' "$OUT"; fi
  assert_out '^1 +FAN1 +1900 +auto +35 +35' 'slot 1 row matches the board'
  assert_out '^6 +FAN6 +1700 +manual +100 +100' 'slot 6 row matches the board'
  run show_rpm
  if printf '%s' "$OUT" | grep -q 'FAN1_2'; then bad 'show_rpm has no FANn_2 rows' "$OUT"
  else ok 'show_rpm has no FANn_2 rows'; fi
  teardown

  printf '\nF8 -- 0x1e is 30%%, not N/A\n'
  setup
  run show --all
  if [ "$(printf '%s\n' "$OUT" | grep -c '^[0-9]')" = 16 ]; then ok '--all lists 16 slots'
  else bad '--all lists 16 slots' "$OUT"; fi
  assert_out '^9 +- +- +auto +30 +30' 'slot 9 shows 30, not N/A'
  if printf '%s' "$OUT" | grep -q 'N/A'; then bad 'no N/A anywhere' "$OUT"; else ok 'no N/A anywhere'; fi
  teardown

  printf '\nRPM2 column (cannot be tested on the real board)\n'
  setup dual "$SDR_DUALTACH"
  run show
  assert_out 'RPM2' 'RPM2 column appears when a second tach reports'
  assert_out '^1 +FAN1 +1900 +1850' 'second tach lands on the same slot, not a new row'
  teardown
  setup
  run show
  if printf '%s' "$OUT" | grep -q 'RPM2'; then bad 'RPM2 hidden when no second tach' "$OUT"
  else ok 'RPM2 hidden when no second tach'; fi
  teardown

  printf '\nF2/F3/F4 -- input validation rejects before writing\n'
  for args in "set_duty abc 50" "set_duty 8 50" "set_duty 12 50" "set_duty 1 200" "set_duty 1" \
              "set_duty -1 50" "set_mode 1 turbo" "set_mode 99 auto" "set_mode all"; do
    setup
    run $args
    assert_rc 1 "rejects: $args"
    assert_nowrite "no write for: $args"
    teardown
  done

  printf '\nF5 -- a failed read never reaches a write\n'
  setup; touch "$MOCK_DIR/fail"
  run show;           assert_rc 1 'show fails when ipmitool fails'
                      assert_err 'Could not open device' 'surfaces the ipmitool error'
  run set_duty 1 35;  assert_rc 1 'set_duty fails when ipmitool fails'
                      assert_nowrite 'no 0xd8 emitted after a failed read'
  teardown

  printf '\nF18 -- refuses a mode-shaped duty baseline\n'
  setup mode7 "$SDR_ROMED8" "$D9_ROMED8" "$D9_ROMED8" "$D7_ROMED8"
  run set_duty 1 40
  assert_rc 1 'aborts when 0xd7 looks like a mode array'
  assert_err 'mode-shaped' 'explains why'
  assert_nowrite 'writes nothing'
  teardown

  printf '\nF7 -- the write-back baseline is 0xd7, not 0xda\n'
  # Only distinguishable when the two differ, which they never do on the real board.
  setup differ "$SDR_ROMED8" "$D9_ROMED8" \
        ' 0a 0b 0c 0d 0e 0f 10 11 1e 1e 1e 1e 1e 1e 1e 1e' \
        ' 63 63 63 63 63 63 63 63 1e 1e 1e 1e 1e 1e 1e 1e'
  run set_duty 1 50
  assert_rc 0 'set_duty succeeds'
  assert_write 'set_duty 0x32 0x0b 0x0c' 'other slots keep their 0xd7 bytes, not 0xda'
  teardown

  printf '\nset_duty writes\n'
  setup
  run set_duty 1 30 --dry-run
  assert_rc 0 'dry-run exits 0'
  assert_out '0xd8' 'dry-run prints the mode command'
  assert_out '0xd6' 'dry-run prints the duty command'
  assert_nowrite 'dry-run writes nothing'
  teardown
  setup
  run set_duty 1 30
  assert_rc 0 'set_duty 1 30 succeeds'
  assert_write 'set_mode 0x01 0x00 0x00' 'slot 1 switched to manual, others preserved'
  assert_write 'set_duty 0x1e 0x23 0x23' 'slot 1 duty set to 0x1e (30%), others preserved'
  assert_out 'slot 1: manual, 30%' 'reports the value read back'
  teardown

  printf '\nF15 -- reports what the BMC actually stored\n'
  setup; touch "$MOCK_DIR/clamp"
  run set_duty 1 10
  assert_rc 0 'set_duty succeeds against clamping firmware'
  assert_err 'requested 10% for slot 1 but the BMC stored 20%' 'warns about the clamp'
  teardown

  printf '\nF17 -- set_mode, and how it differs from reset\n'
  setup
  run set_mode 1 auto
  assert_rc 0 'set_mode 1 auto succeeds'
  assert_write 'set_mode 0x00 0x00 0x00 0x01' 'only slot 1 changed'
  teardown
  # Padding deliberately non-zero: on the real board slots 8-16 are already 00,
  # so this is the only way to show set_mode preserves them and reset does not.
  setup pad "$SDR_ROMED8" ' 00 00 00 01 01 01 01 02 02 02 02 02 02 02 02 02'
  run set_mode all auto
  assert_write 'set_mode 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x02 0x02' 'set_mode all preserves slots 8-16'
  teardown
  setup pad2 "$SDR_ROMED8" ' 00 00 00 01 01 01 01 02 02 02 02 02 02 02 02 02'
  run reset --yes
  assert_write 'set_mode 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00' \
               'reset zeroes all 16 bytes, as TSDQA-72 prescribes'
  teardown

  printf '\nreset guards\n'
  setup
  run reset --dry-run
  assert_rc 0 'reset --dry-run exits 0'
  assert_out '0xd8( 0x00){16}' 'reset --dry-run prints sixteen zero bytes'
  assert_nowrite 'reset --dry-run writes nothing'
  teardown
  setup
  run reset --factory --dry-run
  assert_out '0xdc' 'reset --factory targets 0xdc'
  if printf '%s' "$OUT" | grep -q '0x00'; then bad 'reset --factory takes no arguments' "$OUT"
  else ok 'reset --factory takes no arguments'; fi
  teardown
  setup
  run reset            # stdin is /dev/null, so the prompt gets EOF
  assert_rc 1 'reset aborts on EOF at the prompt'
  assert_nowrite 'reset writes nothing when not confirmed'
  teardown
  setup
  run reset --factory --yes
  assert_write 'factory_reset' 'reset --factory --yes sends 0xdc'
  teardown

  printf '\nLabels\n'
  setup
  LABELS=$MOCK_DIR/labels
  printf '# a comment\n\n3 = CPU tower\n99 = nope\ngarbage\n' > "$LABELS"
  run show
  assert_out 'LABEL' 'LABEL column appears when labels are loaded'
  assert_out '^3 +FAN3 +CPU tower' 'slot 3 carries its label'
  assert_err 'slot 99 is outside' 'warns about an out-of-range slot'
  assert_err "line 5: expected 'slot = label'" 'warns about an unparseable line'
  run set_duty "CPU tower" 50
  assert_rc 1 'a label is not accepted as an index'
  LABELS=
  teardown

  printf '\nFAN_SLOTS override\n'
  setup
  OUT=$(PATH="$BIN:$PATH" FAN_SLOTS=3 FAN_LABELS_FILE=/nonexistent "$BASHBIN" "$SCRIPT" show 2>&1); RC=$?
  if [ "$(printf '%s\n' "$OUT" | grep -c '^[0-9]')" = 3 ]; then ok 'FAN_SLOTS=3 limits the table'
  else bad 'FAN_SLOTS=3 limits the table' "$OUT"; fi
  OUT=$(PATH="$BIN:$PATH" FAN_SLOTS=99 FAN_LABELS_FILE=/nonexistent "$BASHBIN" "$SCRIPT" show 2>&1); RC=$?
  assert_rc 1 'FAN_SLOTS out of range is rejected'
  teardown
}

# --------------------------------------------------------------- live suite ---

live_suite() {
  host=$1
  printf '\nLive read-only checks on %s\n' "$host"
  scp -q "$SCRIPT" "$host:/tmp/fanctl-live.sh" || { bad 'scp'; return; }
  ssh "$host" "chmod +x /tmp/fanctl-live.sh"
  before=$(ssh "$host" "sudo -n ipmitool raw 0x3a 0xd9; sudo -n ipmitool raw 0x3a 0xd7")
  out=$(ssh "$host" "sudo -n /tmp/fanctl-live.sh show")
  if printf '%s' "$out" | grep -qE '^1 +FAN1'; then ok 'live show renders slot 1'
  else bad 'live show renders slot 1' "$out"; fi
  ssh "$host" "sudo -n /tmp/fanctl-live.sh set_duty abc 50" >/dev/null 2>&1
  if [ $? -ne 0 ]; then ok 'live set_duty rejects a non-numeric slot'; else bad 'live set_duty rejects a non-numeric slot'; fi
  after=$(ssh "$host" "sudo -n ipmitool raw 0x3a 0xd9; sudo -n ipmitool raw 0x3a 0xd7")
  if [ "$before" = "$after" ]; then ok 'live: BMC arrays unchanged by the read-only suite'
  else bad 'live: BMC arrays unchanged' "before:
$before
after:
$after"; fi
  ssh "$host" "rm -f /tmp/fanctl-live.sh"
}

# --------------------------------------------------------------------- main ---

find_bash() {
  b=
  for c in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash "$(command -v bash 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v=$("$c" -c 'echo ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}' 2>/dev/null)
    case $v in ''|*[!0-9]*) continue ;; esac
    if [ "$("$c" -c 'echo $(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))')" = 1 ]; then
      b=$c; break
    fi
  done
  printf '%s' "$b"
}

case "${1:-}" in
  --remote)
    # The remote login shell may not be bash (nas-host-01 uses fish), so every
    # remote command is wrapped in an explicit bash -c.
    host=${2:?--remote needs a host}
    rsh() { ssh "$host" "bash -c '$1'"; }
    dir=$(rsh 'mktemp -d') || exit 1
    [ -n "$dir" ] || { printf 'could not create a remote temp dir\n' >&2; exit 1; }
    rsh "mkdir -p $dir/tests" || exit 1
    scp -q "$SCRIPT" "$host:$dir/" || exit 1
    scp -q "$HERE/run-tests.sh" "$HERE/mock-ipmitool" "$host:$dir/tests/" || exit 1
    rsh "chmod +x $dir/tests/run-tests.sh $dir/tests/mock-ipmitool"
    rsh "bash $dir/tests/run-tests.sh"; rc=$?
    rsh "rm -rf $dir"
    exit $rc
    ;;
  --live)
    BASHBIN=$(find_bash)
    live_suite "${2:?--live needs a host}"
    ;;
  ''|--offline)
    BASHBIN=$(find_bash)
    if [ -z "$BASHBIN" ]; then
      printf 'No bash 4.3+ found; the script under test requires one.\n' >&2
      printf 'Run the suite where a newer bash exists:\n  %s --remote <host>\n' "$0" >&2
      exit 2
    fi
    printf 'Using %s (%s)\n' "$BASHBIN" "$("$BASHBIN" -c 'echo $BASH_VERSION')"
    offline_suite
    ;;
  *) printf 'usage: %s [--offline | --remote HOST | --live HOST]\n' "$0" >&2; exit 2 ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

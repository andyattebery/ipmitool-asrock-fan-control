# ipmitool-asrock-fan-control

Fan control for ASRock Rack boards with an **ASPEED AST2500** BMC, via `ipmitool`
raw OEM commands (netfn `0x3a`).

Developed and verified against a **ROMED8-2T** (board rev 1.02A, BMC firmware 2.02).

## Requirements

- `ipmitool`, run as root (the raw commands need `/dev/ipmi0`)
- `bash` 4.3 or newer (associative arrays and namerefs; macOS ships 3.2)
- `column` (util-linux or BSD)

## Usage

```
ipmitool-asrock-fan-control.sh <action> [arguments]
```

Read actions: `show`, `show_rpm`, `show_mode`, `show_current_duty`, `show_saved_duty`.
Write actions: `set_duty`, `set_mode`, `reset`. Run with no action for full help.

```
$ sudo ./ipmitool-asrock-fan-control.sh show
SLOT  NAME  RPM   MODE    DUTY%  SET%
1     FAN1  1900  auto    35     35
2     FAN2  800   auto    35     35
3     FAN3  4900  auto    35     35
4     FAN4  1400  manual  70     70
5     FAN5  -     manual  70     70
6     FAN6  1700  manual  100    100
7     FAN7  -     manual  70     70
```

`SLOT` is the same number in every action, and it is what `set_duty` and `set_mode`
take. There is no second numbering anywhere.

## The slot model

The raw arrays are always **16 bytes** ("fan1 to 16" in ASRock's own wording), but
the ROMED8-2T has only **7 fan headers**. Slot 8 exists in the firmware arrays and
responds to writes, but has no physical header; slots 9-16 are unpopulated. The
script takes its slot count from the BMC's SDR and refuses to write above it.

Each 6-pin header carries **two tachometers and one speed control**:

| pin | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| | GND | FAN_VOLTAGE | FAN_SPEED_SENSOR1 | FAN_SPEED_CONTROL | FAN_SPEED_SENSOR2 | NC |

That is why the BMC reports 14 fan sensors for 7 headers: `FANn` is the first
tachometer and `FANn_2` the second, both belonging to slot *n*. `FANn_2` is **not**
a fan you can control separately, and the script folds it into slot *n* as a second
RPM reading rather than listing it as its own row.

## Identifying a physical fan

The BMC stores no name richer than `FANn` — not in the SDR, not in FRU, and not in
Redfish, all of which return the same 14 names. The board manual calls every header
"System Fan Header", with no CPU/rear/front distinction. So label them yourself:
create `fan-labels.conf` next to the script (override with `FAN_LABELS_FILE`).

```
# slot = label
3 = CPU tower
6 = front intake
```

A `LABEL` column then appears in every table. Labels are display-only and are never
accepted as an index.

Two physical aids from the manual: each fan has an amber `FAN_LEDn` that lights when
that fan fails, and FAN1-FAN7 sit at board-layout positions #7, #9, #11, #17, #18,
#19 and #20.

## Returning to automatic control

`reset` sends `0x3a 0xd8` with all sixteen bytes `0x00`, which is the reset ASRock
documents in TSDQA-72. Reach for this one first.

`reset --factory` sends `0x3a 0xdc` instead. That command is **community-sourced
only** — it appears in no ASRock document — and it is not reversible. Both forms
print the current arrays before asking for confirmation.

Do not go probing neighbouring OEM command bytes to discover capabilities: `0xdc`
sits two bytes from the `0xda` this script reads, and other neighbours are
undocumented writes.

## Environment

| variable | meaning |
|---|---|
| `FAN_SLOTS` | override the SDR-derived slot count |
| `FAN_LABELS_FILE` | path to the labels file (default: beside the script) |

## Tests

```
tests/run-tests.sh                 # offline, ipmitool mocked (needs bash 4.3+)
tests/run-tests.sh --remote HOST   # run that suite on a host with a newer bash
tests/run-tests.sh --live HOST     # read-only checks against real hardware
```

The offline suite needs no BMC and covers cases the real board cannot show: a
second tachometer reporting, non-zero padding in slots 8-16, `0xd7` differing from
`0xda`, and a firmware duty clamp.

## Notes on the commands

This script is **AST2500-only**. AST2600 boards use entirely different commands and
`0x02` rather than `0x01` for manual mode; see the table at the top of the script.
`ipmitool mc info` does not distinguish the two, so this is not auto-detected.

`0x3a 0xd7` is used as the duty write-back baseline, but its meaning is genuinely
unsettled: TSDQA-72 calls it "see fan setting mode", the ServeTheHome thread says it
returns one byte, and this board returns 16 duty-shaped bytes identical to `0xda` in
every sample taken. The script shape-checks the array at runtime and refuses to write
if it comes back looking like modes.

`IANA PEN registry open failed: No such file or directory`
`sudo wget -O /usr/share/misc/enterprise-numbers.txt https://www.iana.org/assignments/enterprise-numbers.txt`

https://forum.proxmox.com/threads/ipmi-tool-error-after-v8-upgrade.129334/

## Resources

- https://www.asrockrack.com/support/faq.asp?kind=BMC
- https://download.asrock.com/Rack/TSD/FAQ/TSDQA-72.pdf
- https://www.asrockrack.com/support/IPMI.pdf
- https://download.asrock.com/Manual/ROMED8-2T.pdf
- https://forums.servethehome.com/index.php?threads/asrock-rack-bmc-fan-control.26941/

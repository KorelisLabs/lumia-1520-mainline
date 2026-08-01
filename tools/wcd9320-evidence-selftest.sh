#!/bin/sh
#
# Offline self-test for the two WCD9320 acceptance scripts.
#
# Builds synthetic sysfs trees and dmesg logs and checks that the scripts reach
# the right verdict on each. It touches no hardware and can run anywhere with a
# POSIX shell, so the acceptance logic can be trusted before a hardware run is
# spent on it.
#
# Fixtures are hand-written to match the driver's actual printf formats in
# patches/0002-slimbus-wcd9320-codec-core.patch. If a format there changes,
# this is where it will show up first.
#
# Usage: tools/wcd9320-evidence-selftest.sh
# Exit:  0 all cases behaved as expected, 1 otherwise.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0

# ------------------------------------------------------------------ fixtures --

mkdev() {	# mkdev <root> <rco_wake body> <bringup body>
	_r="$1"
	mkdir -p "$_r/devices/sb:217:a0:1:0" "$_r/devices/sb:217:a0:0:0"
	printf '%s\n' "$2" > "$_r/devices/sb:217:a0:1:0/rco_wake"
	printf '%s\n' "$3" > "$_r/devices/sb:217:a0:1:0/bringup"
	echo 'major 0x0217 minor 0x0001 version 0x01 laddr 0xcb up 1 down 0' \
		> "$_r/devices/sb:217:a0:1:0/identity"
	echo 'irq=87 trigger=0x1 requested=1 raw_at_setup=0 raw_last=0' \
		> "$_r/devices/sb:217:a0:1:0/irq_observe"
	: > "$_r/devices/sb:217:a0:1:0/sentinel_before"
	: > "$_r/devices/sb:217:a0:1:0/sentinel_after"
	echo 'not captured' > "$_r/devices/sb:217:a0:1:0/sentinel_teardown"
	echo 'interface function: not applicable' \
		> "$_r/devices/sb:217:a0:0:0/rco_wake"
	echo 'function=ifd path=fresh online=1 adopted=0 power_owned=0 reset_transitions=0 supply_enables=0 supply_disables=0 identity_reads=0 identity_failures=0 stale_bus_state=0' \
		> "$_r/devices/sb:217:a0:0:0/bringup"
	echo 'interface function: no chip id (laddr 0xca up 1 down 0)' \
		> "$_r/devices/sb:217:a0:0:0/identity"
}

mkver() {	# mkver <root> <version string>
	mkdir -p "$1/module/wcd9320"
	printf '%s\n' "$2" > "$1/module/wcd9320/version"
}

D='wcd9320 sb:217:a0:1:0:'

# A full, ordered cold-boot log. bg_read is the BIAS_OSC_BG_CTL readback: 17
# is the good case, 16 is the known failure (central bandgap still off).
cold_log() {	# cold_log <bg_read> <order:normal|swapped>
	_bg="$1"
	_order="${2:-normal}"
	_bu="[    5.10] $D control function UP (#1), logical address 0xcb
[    5.11] $D core init: 0/448 non-zero -- initialising
[    5.12] $D bring-up step  1/4: reg 0x1b0 (VE 0x01b0) old=00 mask=ff want=04 -> read=04  delay=0us  unverifiable  [bring_up: LEAKAGE_CTL = 0x04]
[    5.13] $D bring-up step  2/4: reg 0x1b1 (VE 0x01b1) old=03 mask=ff want=00 -> read=00  delay=5000us  unverifiable  [bring_up: CDC_CTL = 0 (assert digital-core reset), 5 ms]
[    5.14] $D bring-up step  3/4: reg 0x1b1 (VE 0x01b1) old=00 mask=ff want=03 -> read=03  delay=0us  unverifiable  [bring_up: CDC_CTL = 3 (release digital core)]
[    5.15] $D bring-up step  4/4: reg 0x1b0 (VE 0x01b0) old=04 mask=ff want=03 -> read=03  delay=0us  unverifiable  [bring_up: LEAKAGE_CTL = 0x03]
[    5.16] $D bring-up: all 4 steps applied cleanly
[    5.17] $D core init: after release, 12/448 non-zero"
	_rco="[    5.20] $D rco-wake step  1/15: reg 0x105 (VE 0x0105) old=50 mask=80 want=80 -> read=d0  delay=0us  OK  [BG: slow mode on]
[    5.21] $D rco-wake step  2/15: reg 0x105 (VE 0x0105) old=d0 mask=04 want=04 -> read=d4  delay=0us  OK  [BG: precharge]
[    5.22] $D rco-wake step  3/15: reg 0x105 (VE 0x0105) old=d4 mask=01 want=01 -> read=d5  delay=1000us  OK  [BG: enable, then 1 ms settle]
[    5.23] $D rco-wake step  4/15: reg 0x105 (VE 0x0105) old=d5 mask=80 want=00 -> read=55  delay=0us  OK  [BG: slow mode off]
[    5.24] $D rco-wake step  5/15: reg 0x107 (VE 0x0107) old=10 mask=10 want=00 -> read=00  delay=0us  OK  [RC_OSC_FREQ: clear bit 4]
[    5.25] $D rco-wake step  6/15: reg 0x106 (VE 0x0106) old=00 mask=ff want=17 -> read=$_bg  delay=5us  OK  [BIAS_OSC_BG_CTL = 0x17 (inherited magic: 'bandgap mode to fast')]
[    5.26] $D rco-wake step  7/15: reg 0x107 (VE 0x0107) old=00 mask=80 want=80 -> read=80  delay=0us  OK  [RC_OSC_FREQ: enable the RC oscillator]
[    5.27] $D rco-wake step  8/15: reg 0x108 (VE 0x0108) old=00 mask=80 want=80 -> read=80  delay=10us  OK  [RC_OSC_TEST: start pulse, rising]
[    5.28] $D rco-wake step  9/15: reg 0x108 (VE 0x0108) old=80 mask=80 want=00 -> read=00  delay=10000us  OK  [RC_OSC_TEST: start pulse, falling, then 10 ms settle]
[    5.29] $D rco-wake step 10/15: reg 0x109 (VE 0x0109) old=00 mask=08 want=08 -> read=08  delay=0us  OK  [CLK_BUFF_EN1: select RCO as the buffer source]
[    5.30] $D rco-wake step 11/15: reg 0x10a (VE 0x010a) old=00 mask=ff want=02 -> read=02  delay=1000us  OK  [CLK_BUFF_EN2 = 0x02]
[    5.31] $D rco-wake step 12/15: reg 0x109 (VE 0x0109) old=08 mask=01 want=01 -> read=09  delay=1200us  OK  [CLK_BUFF_EN1: enable clock buffer (hardware-required delay)]
[    5.32] $D rco-wake step 13/15: reg 0x10a (VE 0x010a) old=02 mask=02 want=00 -> read=00  delay=0us  OK  [CLK_BUFF_EN2: clear bit 1]
[    5.33] $D rco-wake step 14/15: reg 0x10a (VE 0x010a) old=00 mask=04 want=04 -> read=04  delay=0us  OK  [CLK_BUFF_EN2: clock on]
[    5.34] $D rco-wake step 15/15: reg 0x311 (VE 0x0311) old=00 mask=01 want=01 -> read=01  delay=50us  unverifiable  [CDC_CLK_MCLK_CTL: gate the clock into the CDC block (unverifiable)]
[    5.35] $D rco-wake: all 15 steps applied cleanly"
	_tail="[    5.40] $D core verify: 95/448 non-zero (min 48), canary 0x320 = e4 (want e4)
[    5.41] $D core init: complete, core_ready (0 -> 12 -> 95 non-zero)"

	if [ "$_order" = "swapped" ]; then
		printf '%s\n%s\n%s\n' "$_rco" "$_bu" "$_tail"
	else
		printf '%s\n%s\n%s\n' "$_bu" "$_rco" "$_tail"
	fi
}

adopt_log() {
	printf '%s\n' \
"[    5.10] $D bus reports enumerated (laddr 0xcb); verifying before adopting
[    5.11] $D late adoption: codec responded, no power or reset touched
[    5.12] $D control function UP (#1), logical address 0xcb
[    5.13] $D core init: already accessible (95/448 non-zero) -- adopting, no writes"
}

COLD_RCO='core_ready=1 core_adopted=0 init_calls=1 init_runs=1
state=idle attempts=0 failed_step=-1 last_error=0
sentinel_range=0x200-0x3bf count=448
nonzero_before=0 nonzero_after_bringup=12 nonzero_after=95 nonzero_teardown=0
have_before=1 have_after_bringup=1 have_after=1 have_teardown=0'

COLD_BRINGUP='function=pgd path=fresh online=1 adopted=0 power_owned=1 reset_transitions=2 supply_enables=1 supply_disables=0 identity_reads=1 identity_failures=0 stale_bus_state=0'

ADOPT_RCO='core_ready=1 core_adopted=1 init_calls=1 init_runs=0
state=idle attempts=0 failed_step=-1 last_error=0
sentinel_range=0x200-0x3bf count=448
nonzero_before=95 nonzero_after_bringup=0 nonzero_after=0 nonzero_teardown=0
have_before=1 have_after_bringup=0 have_after=0 have_teardown=0'

ADOPT_BRINGUP='function=pgd path=adopted online=1 adopted=1 power_owned=0 reset_transitions=0 supply_enables=0 supply_disables=0 identity_reads=1 identity_failures=0 stale_bus_state=0'

# ----------------------------------------------------------------- harness --

# run_case <name> <script> <version> <rco_wake> <bringup> <log> <want-exit>
run_case() {
	_name="$1"; _script="$2"; _ver="$3"
	_rcow="$4"; _bring="$5"; _log="$6"; _want="$7"

	_c="$WORK/$_name"
	mkdir -p "$_c/bin" "$_c/out"
	mkver "$_c/sys" "$_ver"
	mkdev "$_c/sys/bus/slimbus" "$_rcow" "$_bring"
	printf '%s\n' "$_log" > "$_c/dmesg.txt"
	printf '#!/bin/sh\ncat "%s/dmesg.txt"\n' "$_c" > "$_c/bin/dmesg"
	chmod +x "$_c/bin/dmesg"

	PATH="$_c/bin:$PATH" \
	MODULE_VERSION_PATH="$_c/sys/module/wcd9320/version" \
	SLIM_DEVICES="$_c/sys/bus/slimbus/devices" \
	OUTDIR="$_c/out" \
		sh "$DIR/$_script" > "$_c/stdout.txt" 2>&1
	_got=$?

	if [ "$_got" = "$_want" ]; then
		printf '  ok    %-34s exit=%s\n' "$_name" "$_got"
	else
		printf '  NOT OK %-33s exit=%s want=%s\n' "$_name" "$_got" "$_want"
		sed 's/^/          /' "$_c/stdout.txt"
		FAILED=1
	fi
}

echo "WCD9320 acceptance-script self-test"
echo

echo "cold-boot script:"
run_case cold-good        wcd9320-coldboot-evidence.sh core-init-rc2 \
	"$COLD_RCO" "$COLD_BRINGUP" "$(cold_log 17)" 0
run_case cold-bandgap-16  wcd9320-coldboot-evidence.sh core-init-rc2 \
	"$COLD_RCO" "$COLD_BRINGUP" "$(cold_log 16)" 1
run_case cold-swapped     wcd9320-coldboot-evidence.sh core-init-rc2 \
	"$COLD_RCO" "$COLD_BRINGUP" "$(cold_log 17 swapped)" 1
run_case cold-stale-ko    wcd9320-coldboot-evidence.sh core-init-rc1 \
	"$COLD_RCO" "$COLD_BRINGUP" "$(cold_log 17)" 2
run_case cold-is-adoption wcd9320-coldboot-evidence.sh core-init-rc2 \
	"$ADOPT_RCO" "$ADOPT_BRINGUP" "$(adopt_log)" 1

echo
echo "adoption script:"
run_case adopt-good       wcd9320-adoption-evidence.sh core-init-rc2 \
	"$ADOPT_RCO" "$ADOPT_BRINGUP" "$(adopt_log)" 0
run_case adopt-is-cold    wcd9320-adoption-evidence.sh core-init-rc2 \
	"$COLD_RCO" "$COLD_BRINGUP" "$(cold_log 17)" 1
run_case adopt-stale-ko   wcd9320-adoption-evidence.sh core-init-rc1 \
	"$ADOPT_RCO" "$ADOPT_BRINGUP" "$(adopt_log)" 2

# A run whose core was adopted but whose bus came up fresh: the gate must fail
# on the reset and supply counters rather than passing on core_adopted alone.
MIXED_BRINGUP='function=pgd path=fresh online=1 adopted=0 power_owned=1 reset_transitions=2 supply_enables=1 supply_disables=0 identity_reads=1 identity_failures=0 stale_bus_state=0'
run_case adopt-mixed      wcd9320-adoption-evidence.sh core-init-rc2 \
	"$ADOPT_RCO" "$MIXED_BRINGUP" "$(adopt_log)" 1

echo
echo "missing-module case:"
_c="$WORK/no-module"
mkdir -p "$_c/out" "$_c/sys/bus/slimbus/devices"
MODULE_VERSION_PATH="$_c/sys/module/wcd9320/version" \
SLIM_DEVICES="$_c/sys/bus/slimbus/devices" \
OUTDIR="$_c/out" \
	sh "$DIR/wcd9320-coldboot-evidence.sh" > "$_c/stdout.txt" 2>&1
_got=$?
_files=$(find "$_c/out" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$_got" = "2" ] && [ "$_files" = "0" ]; then
	printf '  ok    %-34s exit=2, no evidence file written\n' "no-module"
else
	printf '  NOT OK %-33s exit=%s files=%s\n' "no-module" "$_got" "$_files"
	sed 's/^/          /' "$_c/stdout.txt"
	FAILED=1
fi

echo
if [ "$FAILED" = "0" ]; then
	echo "SELF-TEST: all cases behaved as expected"
else
	echo "SELF-TEST: FAILED"
fi
exit "$FAILED"

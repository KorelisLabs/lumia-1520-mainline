#!/bin/sh
#
# WCD9320 full-map fresh-state capture: the reset state of all 1024 registers,
# at every stage of core init.
#
# This exists to close the reg_defaults ambiguity. 57 cacheable registers read
# something other than their documented __POR. Six are this driver's own
# writes. 23 sit in 0x200-0x3bf, where the three-stage sentinel already settles
# them. The remaining 28 are in the analog region, and until now there was no
# snapshot between reset release and core init covering it -- so a
# revision-dependent reset value could not be told apart from something written
# after reset, and the ADSP is running and owns the NGD.
#
# fullmap-rc7 adds low_before / low_after_bringup / low_after for 0x000-0x1ff,
# taken at the same three moments as the existing sentinel. Together they give
# the complete map at each stage:
#
#   fresh pre-init      low_before        + sentinel_before
#   after core release  low_after_bringup + sentinel_after_bringup
#   after RCO           low_after         + sentinel_after
#   final, live         regmap debugfs
#
# The CDC half of "fresh pre-init" reads all-zero: the digital core is held in
# reset and its register file returns zero rather than its defaults. That is
# the already-established behaviour, not a failure, and it is why the CDC
# defaults come from the after-release stage instead.
#
# REQUIRES A FRESH BOOT. The snapshots are captured during probe on the fresh
# path; an adopted codec skips them, and the run refuses rather than emitting
# a table built on the wrong state.
#
# Reads only. Writes nothing.
#
# Exit: 0 captured, 1 the run did not hold up, 2 invalid.

set -u

MODE="fullmap"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-fullmap-rc7}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-fullmap-$$"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-fullmap-$STAMP.txt"

REGS="/sys/kernel/debug/regmap/$PGD_NAME/registers"
PATH_TAKEN=$(kv "$PGD/bringup" path)
ADOPTED=$(kv "$PGD/bringup" adopted)
UPTIME_S=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)

if [ "$PATH_TAKEN" != "fresh" ] || [ "$ADOPTED" != "0" ]; then
	say "INVALID RUN: this boot took the '$PATH_TAKEN' path (adopted=$ADOPTED)."
	say "  The pre-init snapshots only exist on the fresh path. A table built"
	say "  from an adopted boot would describe the wrong state entirely."
	say "  Power off, restart into the bootloader, fastboot boot, try again."
	exit 2
fi

emit() {	# emit <label> <sysfs file>
	hdr "$1"
	if [ -r "$2" ]; then
		cat "$2"
	else
		say "unavailable: $2"
	fi
}

{
	hdr "capture identity"
	say "module version    : $RUNNING_VERSION"
	say "uptime            : ${UPTIME_S}s"
	say "bring-up path     : $PATH_TAKEN (adopted=$ADOPTED)"
	say "control function  : $PGD_NAME"
	say ""
	say "Ranges: low = 0x000-0x1ff (512), sentinel = 0x200-0x3bf (448)."
	say "Rows are 32 registers of 2 hex chars each, ascending."

	emit "low_before            0x000-0x1ff, after reset release, before any driver write" \
		"$PGD/low_before"
	emit "sentinel_before       0x200-0x3bf, same moment (core dark, reads zero)" \
		"$PGD/sentinel_before"
	emit "low_after_bringup     0x000-0x1ff, after the 4 core-release writes" \
		"$PGD/low_after_bringup"
	emit "sentinel_after_bringup 0x200-0x3bf, same moment" \
		"$PGD/sentinel_after_bringup"
	emit "low_after             0x000-0x1ff, after the 15-step RCO sequence" \
		"$PGD/low_after"
	emit "sentinel_after        0x200-0x3bf, same moment" \
		"$PGD/sentinel_after"

	hdr "final, live from regmap debugfs"
	if [ -r "$REGS" ]; then
		cat "$REGS"
	else
		say "unavailable: $REGS"
	fi

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "fresh path" "$PATH_TAKEN" "fresh"
	check "not adopted" "$ADOPTED" "0"
	check "driver owns power" "$(kv "$PGD/bringup" power_owned)" "1"
	check "codec was dark at probe" "$(kv "$PGD/rco_wake" nonzero_before)" "0"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	check_cond "low_before captured" \
		"$([ -r "$PGD/low_before" ] && ! grep -q 'not captured' "$PGD/low_before" && echo 1 || echo 0)" \
		"low_before reads 'not captured' -- the fresh-path snapshot did not happen" \
		"512 registers"
	check_cond "low_after_bringup captured" \
		"$([ -r "$PGD/low_after_bringup" ] && ! grep -q 'not captured' "$PGD/low_after_bringup" && echo 1 || echo 0)" \
		"not captured" "512 registers"
	check_cond "low_after captured" \
		"$([ -r "$PGD/low_after" ] && ! grep -q 'not captured' "$PGD/low_after" && echo 1 || echo 0)" \
		"not captured" "512 registers"
	check "low snapshot read failures" \
		"$(dmesg 2>/dev/null | grep -c 'low snapshot read failed')" "0"
	check "sentinel read failures" \
		"$(dmesg 2>/dev/null | grep -c 'sentinel read failed')" "0"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== capture identity/,/=== low_before/p' "$OUT" | sed '$d'
sed -n '/=== checks/,/=== run identity/p' "$OUT" | sed '$d'
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

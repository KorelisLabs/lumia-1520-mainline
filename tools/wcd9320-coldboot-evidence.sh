#!/bin/sh
#
# WCD9320 core-init acceptance run 1 of 2: COLD BOOT.
#
# Preconditions, and they are not optional:
#   - the phone was fully powered off, not rebooted. The CDC block survives a
#     warm reboot -- that is exactly what run 2 tests -- so running this after a
#     warm reboot proves nothing and will fail on core_adopted.
#   - the running kernel and the .ko in /lib/modules are both core-init-rc2.
#
# Acceptance gate, all of which must hold:
#   core_ready=1, core_adopted=0, init_runs=1
#   automatic 0 -> 95 non-zero
#   bring-up sequence before RCO sequence
#   bandgap writes taking on the first attempt
#   no manual wake trigger
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN (nothing collected).

set -u

MODE="cold-boot"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-cold-$$"

# Gate first: nothing is collected and no file is written if this fails.
require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-coldboot-$STAMP.txt"

{
	collect_evidence

	hdr "acceptance checks: COLD BOOT"

	check_version
	check_core_ready

	# --- fresh path, not adoption ------------------------------------------
	check "core_adopted" "$(kv "$PGD/rco_wake" core_adopted)" "0"
	check "init_runs" "$(kv "$PGD/rco_wake" init_runs)" "1"
	note  "init_calls" "$(kv "$PGD/rco_wake" init_calls) -- >1 is fine, extra entries are no-ops"

	# --- automatic 0 -> 95 --------------------------------------------------
	check "nonzero_before" "$(kv "$PGD/rco_wake" nonzero_before)" "0"
	check "nonzero_after" "$(kv "$PGD/rco_wake" nonzero_after)" "95"
	note  "nonzero_after_bringup" "$(kv "$PGD/rco_wake" nonzero_after_bringup) -- stage split, not gated"
	check_canary

	# --- ordering: bring-up strictly before RCO -----------------------------
	# The finding this whole milestone rests on. Stage 2's first bandgap write
	# is silently refused while the digital core is still in reset, so if these
	# ever ran in the other order the failure would look like an MCLK problem
	# again. Assert the order directly rather than trusting call sites.
	_bu=$(first_line 'bring-up step')
	_buok=$(first_line 'bring-up: all')
	_rco=$(first_line 'rco-wake step')

	if [ "$_bu" -eq 0 ] || [ "$_rco" -eq 0 ]; then
		check_cond "bring-up before RCO" 0 \
			"missing sequence lines (bring-up@$_bu rco-wake@$_rco)"
	elif [ "$_bu" -lt "$_rco" ] && [ "$_buok" -gt 0 ] && [ "$_buok" -lt "$_rco" ]; then
		check_cond "bring-up before RCO" 1 \
			"bring-up@$_bu complete@$_buok rco-wake@$_rco"
	else
		check_cond "bring-up before RCO" 0 \
			"out of order: bring-up@$_bu complete@$_buok rco-wake@$_rco"
	fi

	check_sequence_complete "bring-up"
	check_sequence_complete "rco-wake"

	# --- bandgap on the first attempt ---------------------------------------
	# There is no retry anywhere in the driver: each step is written once and
	# read back once. So "first attempt" means every verified step reported OK,
	# with no MISMATCH and no abort. The named check is the known failure
	# signature -- BIAS_OSC_BG_CTL written 0x17 reading back 0x16 because the
	# central bandgap was still off.
	check "sequence MISMATCH lines" "$(count_lines 'MISMATCH')" "0"
	check "sequence ABORTED lines" "$(count_lines 'ABORTED')" "0"

	_bg=$(grep 'BIAS_OSC_BG_CTL = 0x17' "$DMESG_FILE" 2>/dev/null | head -n1)
	if [ -z "$_bg" ]; then
		check_cond "BIAS_OSC_BG_CTL first attempt" 0 "step line not found in dmesg"
	else
		_read=$(echo "$_bg" | sed -n 's/.*-> read=\([0-9a-f]*\).*/\1/p')
		if [ "$_read" = "17" ] && echo "$_bg" | grep -q 'OK  \[BIAS_OSC_BG_CTL'; then
			check_cond "BIAS_OSC_BG_CTL first attempt" 1 "read=17, OK"
		else
			check_cond "BIAS_OSC_BG_CTL first attempt" 0 \
				"read=$_read -- 0x16 means the central bandgap was still off"
		fi
	fi

	# The four central-bandgap steps of phase A, each verified by readback.
	check "central bandgap steps OK" "$(count_lines 'OK  \[BG: ')" "4"

	# --- no manual trigger ---------------------------------------------------
	check_no_manual_wake

	# --- health --------------------------------------------------------------
	check "core init FAILED lines" "$(count_lines 'core init: FAILED')" "0"
	check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
	check "stale bus state" "$(kv "$PGD/bringup" stale_bus_state)" "0"

	# Recorded, not gated: on the cold path the driver legitimately owns power
	# and drives reset. These are the counters run 2 requires to be zero.
	note  "reset_transitions" "$(kv "$PGD/bringup" reset_transitions) -- fresh path, not gated here"
	note  "supply_enables" "$(kv "$PGD/bringup" supply_enables) -- fresh path, not gated here"
	note  "bus enumeration path" "$(kv "$PGD/bringup" path) -- SLIMbus adoption, distinct from core_adopted"

	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== acceptance checks/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

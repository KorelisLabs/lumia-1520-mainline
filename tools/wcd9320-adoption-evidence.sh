#!/bin/sh
#
# WCD9320 core-init acceptance run 2 of 2: ADOPTION.
#
# Preconditions:
#   - run 1 (cold boot) has already PASSED, so the core is initialised.
#   - the phone was rebooted WITHOUT removing power. A power-off invalidates
#     this run: the CDC block goes dark again and the driver correctly takes
#     the fresh path, which is run 1, not run 2.
#   - the running kernel and the .ko in /lib/modules are both core-init-rc2.
#
# Acceptance gate, all of which must hold:
#   core_ready=1, core_adopted=1, init_runs=0
#   zero reset transitions, zero supply operations
#   no replay of the bring-up or RCO sequences
#
# A note on the two senses of "adopted", because they are easy to conflate and
# only one of them is gated here:
#   core_adopted  -- the CDC register file already answered, so core init wrote
#                    nothing. This is what the gate is about.
#   bringup path= -- the SLIMbus enumeration was already live at probe, so the
#                    driver took no power and no reset.
# They are independent. The gate demands zero reset and supply operations,
# which requires *both*: a core that was already up AND a bus that was already
# enumerated. If the core is adopted but the bus came up fresh, the counters
# will be non-zero and this run fails -- correctly, and the report below makes
# that specific combination legible instead of mysterious.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN (nothing collected).

set -u

MODE="adoption"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-adopt-$$"

# Gate first: nothing is collected and no file is written if this fails.
require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-adoption-$STAMP.txt"

{
	collect_evidence

	hdr "acceptance checks: ADOPTION"

	check_version
	check_core_ready

	# --- adoption, and no initialisation run --------------------------------
	check "core_adopted" "$(kv "$PGD/rco_wake" core_adopted)" "1"
	check "init_runs" "$(kv "$PGD/rco_wake" init_runs)" "0"
	note  "init_calls" "$(kv "$PGD/rco_wake" init_calls) -- entries that all no-opped"

	# The decision is made by reading the sentinel, not by driver state: the
	# core is adopted because >= 48 of 448 registers already answered.
	_nzb=$(kv "$PGD/rco_wake" nonzero_before)
	if [ -n "$_nzb" ] && [ "$_nzb" -ge 48 ]; then
		check_cond "sentinel already accessible" 1 "nonzero_before=$_nzb (>= 48)"
	else
		check_cond "sentinel already accessible" 0 \
			"nonzero_before=$_nzb -- below the floor, so this was not an adoption"
	fi
	note  "nonzero_before" "$_nzb -- expect 95 carried over from run 1"

	# have_after must be 0: nothing ran, so no post-RCO snapshot exists.
	_ha=$(kv "$PGD/rco_wake" have_after)
	if [ "$_ha" = "0" ]; then
		check_cond "no post-RCO snapshot" 1 "have_after=0, as expected when nothing ran"
	else
		check_cond "no post-RCO snapshot" 0 "have_after=$_ha -- a snapshot was taken, so a sequence ran"
	fi

	# --- zero reset transitions, zero supply operations ---------------------
	check "reset_transitions" "$(kv "$PGD/bringup" reset_transitions)" "0"
	check "supply_enables" "$(kv "$PGD/bringup" supply_enables)" "0"
	check "supply_disables" "$(kv "$PGD/bringup" supply_disables)" "0"
	check "power_owned" "$(kv "$PGD/bringup" power_owned)" "0"
	check "stale bus state" "$(kv "$PGD/bringup" stale_bus_state)" "0"
	note  "bus enumeration path" "$(kv "$PGD/bringup" path) -- must be 'adopted' for the counters to be zero"

	# --- no replay of either sequence ---------------------------------------
	# The point of the adoption path: not one write into a block another owner
	# may be using. A single step line here is a failure.
	check "bring-up step lines" "$(count_lines 'bring-up step')" "0"
	check "rco-wake step lines" "$(count_lines 'rco-wake step')" "0"
	check "fresh bring-up lines" "$(count_lines 'fresh bring-up')" "0"

	_adopt=$(count_lines 'core init: already accessible')
	check_cond "adoption logged, no writes" \
		"$([ "$_adopt" -ge 1 ] && echo 1 || echo 0)" \
		"'core init: already accessible ... adopting, no writes' x$_adopt"

	check "core init initialising lines" "$(count_lines 'core init: .* -- initialising')" "0"

	# --- no manual trigger ---------------------------------------------------
	check_no_manual_wake

	# --- health --------------------------------------------------------------
	check "core init FAILED lines" "$(count_lines 'core init: FAILED')" "0"
	check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
	check "sequence ABORTED lines" "$(count_lines 'ABORTED')" "0"

	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== acceptance checks/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

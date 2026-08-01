#!/bin/sh
#
# WCD9320 core-init acceptance run 2 of 2: ADOPTION.
#
# Preconditions:
#   - run 1 (cold boot) has already PASSED, and its evidence file has already
#     been pulled off the device. /tmp does not survive the reboot below.
#   - the phone was rebooted WITHOUT removing power.
#   - the running kernel and the .ko in /lib/modules are both core-init-rc2.
#
# Acceptance gate, all of which must hold:
#   the codec was ALREADY initialised when the driver looked (proved below)
#   core_ready=1, core_adopted=1, init_runs=0
#   zero reset transitions, zero supply operations
#   no replay of the bring-up or RCO sequences
#
# Proving the starting condition, and why it gets its own stage:
#
#   A reboot that does not physically remove power is not the same thing as a
#   reboot that preserved codec state. The rails could drop, or the bootloader
#   could reset the part, and the driver would then correctly run the fresh
#   path again -- which looks identical to rc2 failing to adopt if you only
#   read the outcome. So the precondition is established from the as-found
#   sentinel snapshot the driver takes before it writes anything, recounted
#   here straight off the raw dump rather than trusted from a counter.
#
#   Codec still initialised  -> proceed to the gate.
#   Codec came up dark       -> INVALID SETUP (exit 2). The reboot-to-bootloader
#                               route did not preserve codec power, and another
#                               way of rebinding or reloading the driver with
#                               the codec left powered is needed. This is a
#                               statement about the test method, not about rc2.
#
# A note on the two senses of "adopted", because only one of them is gated:
#   core_adopted  -- the CDC register file already answered, so core init wrote
#                    nothing. This is what the gate is about.
#   bringup path= -- the SLIMbus enumeration was already live at probe, so the
#                    driver took no power and no reset.
# They are independent. Zero reset and supply operations requires *both*. If
# the core is adopted but the bus came up fresh, this run fails -- correctly --
# and the report names that combination rather than leaving it mysterious.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN or INVALID SETUP.

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

# ---------------------------------------------------------------------------
# Classify the starting condition before judging anything.
# ---------------------------------------------------------------------------
NZB=$(num "$(kv "$PGD/rco_wake" nonzero_before)" -1)
HAVE_BEFORE=$(kv "$PGD/rco_wake" have_before)
INIT_RUNS=$(num "$(kv "$PGD/rco_wake" init_runs)" -1)
CORE_ADOPTED=$(kv "$PGD/rco_wake" core_adopted)

# Independent of the driver's counters: recount the as-found dump, and read the
# 0x320 canary out of it. 0x320 CDC_CLSH_B1_CTL has a documented POR of 0xe4
# and read 0x00 in every pre-wake dump, so finding 0xe4 in the *as-found*
# snapshot is direct evidence that the block was already alive before the
# driver touched it.
CANARY_IDX=$(sentinel_index 320)
NZB_RECOUNT=$(sentinel_nonzero "$PGD/sentinel_before")
CANARY_BEFORE=$(sentinel_byte "$PGD/sentinel_before" "$CANARY_IDX")

SETUP="ok"
SETUP_REASON=""
if [ "$HAVE_BEFORE" != "1" ]; then
	SETUP="no-snapshot"
	SETUP_REASON="core init never took an as-found snapshot (have_before=$HAVE_BEFORE); there is nothing to judge the starting condition from"
elif [ "$NZB" -ge 0 ] && [ "$NZB" -lt 48 ] && [ "$INIT_RUNS" -ge 1 ]; then
	SETUP="codec-reset"
	SETUP_REASON="the codec was dark at probe (nonzero_before=$NZB) and rc2 correctly ran the fresh path again -- the reboot did not preserve codec state"
fi

if [ "$SETUP" = "ok" ]; then
	open_output "$OUTDIR/wcd9320-adoption-$STAMP.txt"
else
	open_output "$OUTDIR/wcd9320-adoption-INVALID-$STAMP.txt"
fi

{
	collect_evidence

	hdr "precondition: was the codec still initialised?"
	say "have_before        : $HAVE_BEFORE"
	say "nonzero_before     : $NZB          (driver counter)"
	say "nonzero recounted  : $NZB_RECOUNT          (independent, from sentinel_before)"
	say "0x320 as-found     : $CANARY_BEFORE          (POR 0xe4; reads 00 on a dark block)"
	say "core_adopted       : $CORE_ADOPTED"
	say "init_runs          : $INIT_RUNS"
	say "classification     : $SETUP"

	if [ "$SETUP" != "ok" ]; then
		hdr "invalid adoption setup"
		say "$SETUP_REASON"
		say ""
		say "This is a statement about the test method, not about core-init-rc2."
		say "rc2 behaved correctly for the state it found; the state was simply"
		say "not the one this proof requires."
		say ""
		say "What it means: rebooting to the bootloader dropped codec power (or"
		say "the bootloader reset the part). The adoption proof needs the driver"
		say "to be re-entered while the codec stays powered. Options, in rough"
		say "order of least disturbance:"
		say "  - unbind and rebind the slim_device without rebooting:"
		say "      echo <dev> > /sys/bus/slimbus/drivers/wcd9320/unbind"
		say "      echo <dev> > /sys/bus/slimbus/drivers/wcd9320/bind"
		say "  - rmmod wcd9320 && modprobe wcd9320, which re-probes without a"
		say "    power cycle (note the driver leaves the CDC gate set on"
		say "    teardown by design, so the block should stay readable)"
		say "  - a kexec-style warm restart, if one is available on this device"
		say "Whichever route is used, the same precondition stage above must"
		say "show the codec still initialised before the result counts."
		emit_invalid_setup "$SETUP_REASON"
	else

	hdr "acceptance checks: ADOPTION"

	check_version
	check_core_ready

	# --- the starting condition, gated ---------------------------------------
	check_cond "codec already initialised" \
		"$([ "$NZB" -ge 48 ] && echo 1 || echo 0)" \
		"nonzero_before=$NZB (>= 48 floor)"
	check "as-found recount agrees" "$NZB_RECOUNT" "$NZB"
	check "0x320 as-found" "$CANARY_BEFORE" "e4"

	# --- adoption, and no initialisation run --------------------------------
	check "core_adopted" "$CORE_ADOPTED" "1"
	check "init_runs" "$INIT_RUNS" "0"
	note  "init_calls" "$(kv "$PGD/rco_wake" init_calls) -- entries that all no-opped"

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
	fi
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== precondition/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

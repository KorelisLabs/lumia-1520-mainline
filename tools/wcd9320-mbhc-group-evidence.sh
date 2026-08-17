#!/bin/sh
#
# WCD9320 nested IRQ, step 4 DIAGNOSTIC: does the codec raise ANY MBHC source
# with the MBHC block unconfigured?
#
# This is NOT the acceptance gate. wcd9320-mbhc-irq-evidence.sh is, and it
# stays single-source on purpose. This script exists to answer one question
# that the acceptance run left open.
#
# What the acceptance runs established:
#
#   rc1  MBHC_INSERTION armed, headset inserted, nothing fired. Inconclusive,
#        because nothing could show whether the unmask had reached the chip.
#   rc2  irq_live proved it had: INTR_MASK0 read back bf, exactly bit 6 clear,
#        restored to ff on disarm. With the source genuinely unmasked, live
#        status stayed 00 00 00 00 across an insertion. So the codec does not
#        assert MBHC_INSERTION unconfigured -- measured, not inferred.
#
# What is still open is whether it asserts anything else. MBHC_JACK_SWITCH is
# the candidate worth the run: on this family it reflects a mechanical contact
# in the jack rather than the detection block, so it may assert with no setup
# at all. Arming all seven MBHC sources answers that in one pass.
#
# Exit: 0 a source fired and behaved -- there is a usable stimulus
#       1 valid run, nothing fired -- a conclusive negative, NOT a driver fault
#       2 invalid run, nothing collected

set -u

MODE="mbhc-group"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-group-$$"
SETTLE="${SETTLE:-20}"

MASK_ALL="ff ff 3f 7f"
# Six MBHC sources in INTR_REG0 bits 1-6 and JACK_SWITCH in INTR_REG3 bit 4.
MASK_GROUP="81 ff 3f 6f"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-mbhc-group-$STAMP.txt"

live_status() {
	sed -n 's/^status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
live_mask() {
	sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
parent_count() {
	grep 'wcd9320' /proc/interrupts 2>/dev/null |
		grep -v 'wcd9320-mbhc' | head -n1 | awk '{print $2+0}'
}
# Every child is a separate line now, so the total is a sum rather than a read.
child_total() {
	grep 'wcd9320-mbhc' /proc/interrupts 2>/dev/null |
		awk '{s += $2} END {print s+0}'
}
# The per-source table straight out of /proc/interrupts, which the irq core
# maintains and this driver cannot skew.
child_table() {
	grep 'wcd9320-mbhc' /proc/interrupts 2>/dev/null |
		sed 's/^ *//; s/  */ /g'
}
tty_note() { printf '%s\n' "$*" >&2; }

# --- COLLECT ----------------------------------------------------------------

MASK_BEFORE=$(live_mask)
STATUS_BEFORE=$(live_status)
PARENT_BEFORE=$(parent_count)

if [ -z "$MASK_BEFORE" ]; then
	say "INVALID RUN: $PGD/irq_live is missing or unreadable."
	say "  This build predates the live interrupt-state attribute."
	exit 2
fi

tty_note "arming the MBHC group on $PGD_NAME"
if ! echo arm-group > "$PGD/mbhc_test" 2>/dev/null; then
	say "could not arm the group; nothing collected"
	emit_invalid_setup "writing 'arm-group' to mbhc_test failed"
	exit 2
fi
sleep 1

ARMED_HDR=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)
ARMED_TABLE=$(sed -n 's/^source=/source=/p' "$PGD/mbhc_test" 2>/dev/null)
MASK_ARMED=$(live_mask)
STATUS_ARMED=$(live_status)
CHILD_BEFORE=$(child_total)
TABLE_BEFORE=$(child_table)
tty_note "armed: $ARMED_HDR"
tty_note "live mask while armed: $MASK_ARMED (want $MASK_GROUP)"

# Two windows: insertion and removal are different sources, and a run that
# only ever inserts cannot see REMOVAL or the switch opening.
printf '\n>>> INSERT A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
i=0
while [ "$i" -lt "$SETTLE" ]; do
	sleep 1
	i=$((i + 1))
	[ "$(child_total)" -gt "${CHILD_BEFORE:-0}" ] && break
done
WAIT_IN=$i
CHILD_MID=$(child_total)
PARENT_MID=$(parent_count)
TABLE_MID=$(child_table)
tty_note "after insertion: child ${CHILD_BEFORE:-0} -> ${CHILD_MID:-0} (${WAIT_IN}s)"

printf '\n>>> NOW REMOVE THE HEADSET (%ss) <<<\n\n' "$SETTLE" >&2
i=0
while [ "$i" -lt "$SETTLE" ]; do
	sleep 1
	i=$((i + 1))
	[ "$(child_total)" -gt "${CHILD_MID:-0}" ] && break
done
WAIT_OUT=$i
CHILD_AFTER=$(child_total)
PARENT_AFTER=$(parent_count)
TABLE_AFTER=$(child_table)
tty_note "after removal: child ${CHILD_MID:-0} -> ${CHILD_AFTER:-0} (${WAIT_OUT}s)"

tty_note "resampling for quiescence in 5s"
sleep 5
PARENT_Q=$(parent_count)
CHILD_Q=$(child_total)
STATUS_Q=$(live_status)
MASK_Q=$(live_mask)

FIRED_TABLE=$(sed -n 's/^source=/source=/p' "$PGD/mbhc_test" 2>/dev/null)
IRQ_TOTAL=$(num "$(kv "$PGD/mbhc_test" irq_count)" 0)

echo disarm > "$PGD/mbhc_test" 2>/dev/null
sleep 1
MASK_DISARMED=$(live_mask)
MBHC_AFTER=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)

snap_dmesg
GROUP_LINES=$(count_lines 'mbhc group: [A-Z_]* (source')
STATUS_POSTACK=$(sed -n 's/.*post-ack status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
	"$DMESG_FILE" 2>/dev/null | tail -n1)
tty_note "collected; writing $OUT"

# --- REPORT -----------------------------------------------------------------

{
	hdr "before arming"
	say "live mask         : $MASK_BEFORE"
	say "live status       : $STATUS_BEFORE"
	say "parent assertions : ${PARENT_BEFORE:-0}"

	hdr "armed: the whole MBHC group"
	say "mbhc_test         : $ARMED_HDR"
	say "live mask         : $MASK_ARMED   (want $MASK_GROUP)"
	say "live status       : $STATUS_ARMED"
	say "sources armed:"
	printf '%s\n' "$ARMED_TABLE" | sed 's/^/  /'
	say "/proc/interrupts children:"
	printf '%s\n' "$TABLE_BEFORE" | sed 's/^/  /'

	hdr "insertion window"
	say "waited            : ${WAIT_IN}s of ${SETTLE}s"
	say "child assertions  : ${CHILD_MID:-0}  (was ${CHILD_BEFORE:-0})"
	say "parent assertions : ${PARENT_MID:-0}  (was ${PARENT_BEFORE:-0})"
	printf '%s\n' "$TABLE_MID" | sed 's/^/  /'

	hdr "removal window"
	say "waited            : ${WAIT_OUT}s of ${SETTLE}s"
	say "child assertions  : ${CHILD_AFTER:-0}  (was ${CHILD_MID:-0})"
	say "parent assertions : ${PARENT_AFTER:-0}  (was ${PARENT_MID:-0})"
	printf '%s\n' "$TABLE_AFTER" | sed 's/^/  /'

	hdr "per-source counts, from the driver"
	printf '%s\n' "$FIRED_TABLE" | sed 's/^/  /'

	hdr "quiescence, 5s after the last window"
	say "parent assertions : ${PARENT_Q:-0}"
	say "child assertions  : ${CHILD_Q:-0}"
	say "live status       : $STATUS_Q"
	say "live mask         : $MASK_Q"
	say "delta             : parent $(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} )), child $(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))"

	hdr "disarmed"
	say "mbhc_test         : $MBHC_AFTER"
	say "live mask         : $MASK_DISARMED   (want $MASK_ALL)"

	# --- GATE ---------------------------------------------------------------
	# These hold whether or not a source fires. They are what makes a negative
	# result mean something: if the group was not actually armed, "nothing
	# fired" would say nothing at all.
	hdr "run validity"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "masks quiet before arming" "$MASK_BEFORE" "$MASK_ALL"
	check "nothing asserted before arming" "$STATUS_BEFORE" "00 00 00 00"
	check "group armed (live)" "$MASK_ARMED" "$MASK_GROUP"
	check "re-masked after disarm (live)" "$MASK_DISARMED" "$MASK_ALL"
	check "armed flag cleared" "$(kv "$PGD/mbhc_test" armed)" "0"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "spurious irq complaints" \
		"$(dmesg 2>/dev/null | grep -ci 'nobody cared\|disabling IRQ')" "0"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"
	check "returned to quiescence (parent)" \
		"$(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} ))" "0"
	check "returned to quiescence (child)" \
		"$(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))" "0"

	_fired=$(( ${CHILD_AFTER:-0} - ${CHILD_BEFORE:-0} ))

	hdr "finding"
	if [ "$_fired" -ge 1 ]; then
		say "A STIMULUS EXISTS. $_fired child assertion(s) across $GROUP_LINES"
		say "handler line(s), total irq_count=$IRQ_TOTAL."
		say ""
		say "Per-source counts above name which source responded. That source"
		say "is the candidate for the single-source acceptance run; rerun"
		say "wcd9320-mbhc-irq-evidence.sh against it."
		say ""
		say "post-ack status on the last handler line: ${STATUS_POSTACK:-none}"
		if [ -n "$STATUS_POSTACK" ] && [ "$STATUS_POSTACK" != "00 00 00 00" ]; then
			say "NOTE: that is non-zero. The source may be holding itself"
			say "asserted, which is the failure the acceptance bar rejects."
		fi
	else
		say "NO STIMULUS. Not one of the 7 MBHC sources asserted across an"
		say "insertion and a removal, with all 7 verifiably unmasked"
		say "($MASK_ARMED read live off the chip) and the codec healthy."
		say ""
		say "This is a conclusive negative, not a driver failure: the WCD9320"
		say "raises no MBHC interrupt at all until the MBHC block is"
		say "configured. Jack detection needs programming before any physical"
		say "event can reach the nested controller."
		say ""
		say "The remaining routes to an end-to-end proof are to program MBHC"
		say "insert detection, or to use a driver-triggerable source such as"
		say "MICBIAS precharge, which reinterprets 'one physical event'."
	fi

	collect_evidence

	hdr "verdict"
	say "mode   : $MODE"
	say "checks : $PASS_N passed, $FAIL_N failed"
	if [ "$FAIL_N" -ne 0 ]; then
		say "VERDICT: INVALID ($MODE) -- the run itself did not hold up"
	elif [ "$_fired" -ge 1 ]; then
		say "VERDICT: STIMULUS FOUND ($MODE)"
	else
		say "VERDICT: NO STIMULUS ($MODE) -- valid run, conclusive negative"
	fi
} > "$OUT" 2>&1

# Recompute for the exit code: the block above runs in this shell, so PASS_N,
# FAIL_N and _fired are all still set.
if [ "$FAIL_N" -ne 0 ]; then
	RC=2
elif [ "$_fired" -ge 1 ]; then
	RC=0
else
	RC=1
fi

rm -f "$DMESG_FILE"

sed -n '/=== before arming/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

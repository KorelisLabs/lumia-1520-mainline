#!/bin/sh
#
# WCD9320 nested IRQ, step 5/5: THE ACCEPTANCE PROOF.
#
# One literal physical headset event, using the minimum hardware configuration
# necessary, causes one known WCD9320 MBHC interrupt source to assert,
# propagate through GPIO 72 and regmap-irq, execute its nested Linux handler,
# ACK successfully, clear its status, and return to a quiescent masked/idle
# state without warnings or repeated assertions.
#
# It uses only the two pieces already proven on hardware, unchanged:
#
#   rc5 (r140)  three writes to 0x14a enable insert detection; a physical
#               event moves 0x14b bit 2 and returns on removal. 17/17.
#   rc2 (r137)  arming one source unmasks exactly its bit, measured live,
#               and free_irq re-masks it.
#
# WHICH SOURCE, AND WHY IT CHANGED
#
# The first acceptance attempt armed MBHC_INSERTION and got a clean
# physical transition on 0x14b bit 2 with INTR_STATUS still 00 00 00 00.
# Insert detection does not feed that source. Downstream says why: in the
# insert_detect branch of wcd9xxx_mbhc_init() the jack interrupt is
# WCD9320_IRQ_MBHC_JACK_SWITCH, handled by wcd9xxx_mech_plug_detect_irq.
# MBHC_INSERTION belongs to the headset-type state machine that runs after
# the switch fires, and downstream disables it immediately after request.
#
# No broader MBHC initialisation. No other interrupt source unmasked. No new
# driver code: this script drives the two existing hooks in sequence.
#
# TWO WAYS TO FAIL THAT ARE NOT "nothing happened":
#
#   - a source that fires and stays asserted. With a separate write-1-to-clear
#     register that is exactly what a botched ack looks like, so status after
#     ack and quiescence afterwards are checked separately.
#   - a nested handler firing WITHOUT the physical status transition. That
#     would mean the interrupt came from something other than the jack, and
#     the whole proof would be about the wrong thing. 0x14b bit 2 must move.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="irq-acceptance"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-mbhc-switch-rc6}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-accept-$$"
SETTLE="${SETTLE:-25}"
MASK_ALL="ff ff 3f 7f"
# MBHC_JACK_SWITCH is INTR_REG3 bit 4, so arming it alone clears exactly
# that bit: 7f & ~0x10 = 6f. MBHC_INSERTION (INTR_REG0 bit 6) would be
# bf ff 3f 7f, which is what rc5 armed and why nothing fired.
ARM_CMD="${ARM_CMD:-arm-switch}"
case "$ARM_CMD" in
	arm-switch) MASK_ONE_ARMED="ff ff 3f 6f"; SRC_NAME="MBHC_JACK_SWITCH" ;;
	*)          MASK_ONE_ARMED="bf ff 3f 7f"; SRC_NAME="MBHC_INSERTION" ;;
esac
MAX_ASSERTIONS="${MAX_ASSERTIONS:-20}"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-irq-acceptance-$STAMP.txt"

# --- reading -----------------------------------------------------------------

live_status() {
	sed -n 's/^status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
live_mask() {
	sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
det_field()  { head -n1 "$PGD/mbhc_detect" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
present()    { det_field present_bit; }
parent_count() {
	grep 'wcd9320' /proc/interrupts 2>/dev/null |
		grep -v 'wcd9320-mbhc' | head -n1 | awk '{print $2+0}'
}
child_count() {
	grep 'wcd9320-mbhc' /proc/interrupts 2>/dev/null |
		awk '{s += $2} END {print s+0}'
}
handler_status() {
	sed -n 's/.*post-ack status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
		"$DMESG_FILE" 2>/dev/null | tail -n1
}
handler_mask() {
	sed -n 's/.*post-ack status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$DMESG_FILE" 2>/dev/null | tail -n1
}
tty_note() { printf '%s\n' "$*" >&2; }

cleanup() {
	echo disarm > "$PGD/mbhc_test" 2>/dev/null
	echo off > "$PGD/mbhc_detect" 2>/dev/null
}

# --- S0: baseline ------------------------------------------------------------

if [ ! -r "$PGD/mbhc_detect" ] || [ ! -r "$PGD/irq_live" ]; then
	say "INVALID RUN: this build lacks mbhc_detect or irq_live."
	exit 2
fi

S0_MASK=$(live_mask)
S0_STATUS=$(live_status)
S0_PARENT=$(parent_count)
S0_CHILD=$(child_count)
S0_PRESENT=$(present)
S0_DET=$(det_field detect)
tty_note "S0 baseline: mask=$S0_MASK status=$S0_STATUS parent=$S0_PARENT present=$S0_PRESENT"

# --- S1: enable detection ----------------------------------------------------

tty_note "S1 enabling insert detection"
if ! echo "${DET_CMD:-on}" > "$PGD/mbhc_detect" 2>/dev/null; then
	say "could not enable insert detection"
	emit_invalid_setup "writing '${DET_CMD:-on}' to mbhc_detect failed"
	exit 2
fi
sleep 2
S1_DET=$(det_field detect)
S1_STATUS=$(live_status)
S1_MASK=$(live_mask)
S1_PRESENT=$(present)
S1_PARENT=$(parent_count)
S1_CHILD=$(child_count)
tty_note "S1 detection on: 0x14a=$S1_DET status=$S1_STATUS present=$S1_PRESENT"

# --- S2: arm exactly one source ----------------------------------------------
#
# Order matters. Detection is enabled first and its live status recorded, so
# that a bit latched by the enable itself is visible BEFORE anything is
# unmasked, rather than firing on arm and being mistaken for the jack event.

tty_note "S2 arming $SRC_NAME ($ARM_CMD)"
if ! echo "$ARM_CMD" > "$PGD/mbhc_test" 2>/dev/null; then
	say "could not arm $SRC_NAME"
	echo off > "$PGD/mbhc_detect" 2>/dev/null
	emit_invalid_setup "writing '$ARM_CMD' to mbhc_test failed"
	exit 2
fi
sleep 2
ARMED=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)
CHILD_VIRQ=$(printf '%s' "$ARMED" | tr ' ' '\n' | sed -n 's/^child_virq=//p')
S2_MASK=$(live_mask)
S2_STATUS=$(live_status)
S2_PARENT=$(parent_count)
S2_CHILD=$(child_count)
S2_PRESENT=$(present)
tty_note "S2 armed: mask=$S2_MASK (want $MASK_ONE_ARMED) virq=$CHILD_VIRQ"
tty_note "   parent=$S2_PARENT child=$S2_CHILD  <- the pre-event baseline"

# --- S3: the physical event --------------------------------------------------

printf '\n>>> INSERT A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
PRESENT_SEQ="$S2_PRESENT"
i=0
while [ "$i" -lt "$SETTLE" ]; do
	sleep 1
	i=$((i + 1))
	_p=$(present)
	case " $PRESENT_SEQ " in
		*" $_p "*) ;;
		*) PRESENT_SEQ="$PRESENT_SEQ $_p" ;;
	esac
	[ "$(child_count)" -gt "${S2_CHILD:-0}" ] && [ "$_p" != "$S2_PRESENT" ] && break
done
WAITED=$i

S3_PARENT=$(parent_count)
S3_CHILD=$(child_count)
S3_PRESENT=$(present)
S3_STATUS=$(live_status)
S3_MASK=$(live_mask)
tty_note "S3 after event (${WAITED}s): parent=$S3_PARENT child=$S3_CHILD present=$S3_PRESENT"

# --- S4: quiescence ----------------------------------------------------------

tty_note "S4 resampling for quiescence in 5s"
sleep 5
S4_PARENT=$(parent_count)
S4_CHILD=$(child_count)
S4_STATUS=$(live_status)
S4_MASK=$(live_mask)

# --- S5/S6: teardown, in reverse order ---------------------------------------

tty_note "S5 disarming"
echo disarm > "$PGD/mbhc_test" 2>/dev/null
sleep 1
S5_MASK=$(live_mask)
S5_ARMED=$(kv "$PGD/mbhc_test" armed)
IRQ_COUNT=$(num "$(kv "$PGD/mbhc_test" irq_count)" 0)

tty_note "S6 restoring 0x14a"
echo off > "$PGD/mbhc_detect" 2>/dev/null
sleep 1
S6_DET=$(det_field detect)
S6_MASK=$(live_mask)
S6_STATUS=$(live_status)

snap_dmesg
POSTACK_STATUS=$(handler_status)
POSTACK_MASK=$(handler_mask)
HANDLER_LINES=$(count_lines 'mbhc test: irq #')
tty_note "collected; writing $OUT"

FIRED=$(( ${S3_CHILD:-0} - ${S2_CHILD:-0} ))
PFIRED=$(( ${S3_PARENT:-0} - ${S2_PARENT:-0} ))
PRE_EVENT_FIRED=$(( ${S2_CHILD:-0} - ${S1_CHILD:-0} ))
TRANSITIONED=0
[ "$S2_PRESENT" != "$S3_PRESENT" ] && TRANSITIONED=1
case "$PRESENT_SEQ" in *" "*) TRANSITIONED=1 ;; esac

# --- REPORT ------------------------------------------------------------------

{
	hdr "the chain, stage by stage"
	say "                        0x14a  present  mask            status          parent  child"
	say "S0 baseline           : ${S0_DET:-??}     ${S0_PRESENT:-?}        $S0_MASK  $S0_STATUS  ${S0_PARENT:-0}       ${S0_CHILD:-0}"
	say "S1 detection enabled  : ${S1_DET:-??}     ${S1_PRESENT:-?}        $S1_MASK  $S1_STATUS  ${S1_PARENT:-0}       ${S1_CHILD:-0}"
	say "S2 armed              : ${S1_DET:-??}     ${S2_PRESENT:-?}        $S2_MASK  $S2_STATUS  ${S2_PARENT:-0}       ${S2_CHILD:-0}"
	say "S3 after insertion    : ${S1_DET:-??}     ${S3_PRESENT:-?}        $S3_MASK  $S3_STATUS  ${S3_PARENT:-0}       ${S3_CHILD:-0}"
	say "S4 quiescence +5s     : ${S1_DET:-??}     -        $S4_MASK  $S4_STATUS  ${S4_PARENT:-0}       ${S4_CHILD:-0}"
	say "S5 disarmed           : ${S1_DET:-??}     -        $S5_MASK  -               -       -"
	say "S6 detection off      : ${S6_DET:-??}     -        $S6_MASK  $S6_STATUS  -       -"

	hdr "the physical event"
	say "waited              : ${WAITED}s of ${SETTLE}s"
	say "child virq          : ${CHILD_VIRQ:-none}"
	say "present bit values  : $PRESENT_SEQ"
	say "child assertions    : +$FIRED   (S2 ${S2_CHILD:-0} -> S3 ${S3_CHILD:-0})"
	say "parent assertions   : +$PFIRED   (S2 ${S2_PARENT:-0} -> S3 ${S3_PARENT:-0})"
	say "driver irq_count    : $IRQ_COUNT   (cumulative since module load)"
	say "handler lines       : $HANDLER_LINES   (cumulative; this run contributed $FIRED)"
	say "post-ack status     : ${POSTACK_STATUS:-none logged}   (live, read by the handler after regmap-irq acked)"
	say "post-ack mask       : ${POSTACK_MASK:-none logged}"
	# NOT a delta. /proc/interrupts has no child line at all until the source
	# is armed, so S1 always reads 0 and S1->S2 measures the counter
	# appearing, not assertions. The counter is cumulative for the boot; only
	# S2->S3 belongs to this run.
	note "child counter at arm" \
		"${S2_CHILD:-0} -- cumulative for this boot; this run's event delta is +$FIRED"
	note "latched-bit check" \
		"S2 live status $S2_STATUS -- a bit latched by enabling detection would show here, before anything was unmasked"

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- configuration was exactly the two proven pieces --
	check "detection enabled" "$S1_DET" "6f"
	check "masks before arming" "$S1_MASK" "$MASK_ALL"
	check_cond "child irq allocated" \
		"$([ -n "${CHILD_VIRQ:-}" ] && [ "$(num "${CHILD_VIRQ:-}" 0)" -gt 0 ] && echo 1 || echo 0)" \
		"no child virq" "virq $CHILD_VIRQ"
	check "exactly one source armed (live)" "$S2_MASK" "$MASK_ONE_ARMED"
	note "source armed" "$SRC_NAME via $ARM_CMD"

	# -- the physical event reached the codec --
	check_cond "0x14b bit 2 transitioned" "$TRANSITIONED" \
		"present bit stayed ${S2_PRESENT:-?} -- no physical transition, so any interrupt came from elsewhere" \
		"${S2_PRESENT:-?} -> ${S3_PRESENT:-?}"

	# -- and travelled the whole chain --
	check_cond "nested source fired" "$([ "$FIRED" -ge 1 ] && echo 1 || echo 0)" \
		"child count did not increase" "child +$FIRED"
	check_cond "parent asserted" "$([ "$PFIRED" -ge 1 ] && echo 1 || echo 0)" \
		"parent count did not increase -- nested dispatch without a parent edge is impossible" \
		"parent +$PFIRED"
	check_cond "handler ran" "$([ "$IRQ_COUNT" -ge 1 ] && echo 1 || echo 0)" \
		"driver handler never ran" "irq_count=$IRQ_COUNT"
	check "handler status reads" \
		"$(count_lines 'mbhc test: irq #[0-9]*, status read failed')" "0"

	# -- the ack took --
	check "status cleared after ack (handler)" "$POSTACK_STATUS" "00 00 00 00"
	check "status clear afterwards (live)" "$S4_STATUS" "00 00 00 00"

	# -- and it stopped --
	check "quiescence, parent" "$(( ${S4_PARENT:-0} - ${S3_PARENT:-0} ))" "0"
	check "quiescence, child" "$(( ${S4_CHILD:-0} - ${S3_CHILD:-0} ))" "0"
	check_cond "finite sequence" "$([ "$FIRED" -le "$MAX_ASSERTIONS" ] && echo 1 || echo 0)" \
		"$FIRED assertions from one event -- not finite or explainable" \
		"$FIRED assertion(s)"

	# -- no manual recovery, and everything put back --
	check "re-masked after disarm (live)" "$S5_MASK" "$MASK_ALL"
	check "all 29 masked after teardown" "$S6_MASK" "$MASK_ALL"
	check "armed flag cleared" "$S5_ARMED" "0"
	check "0x14a restored" "$S6_DET" "00"

	# -- nothing else went wrong --
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "spurious irq complaints" \
		"$(dmesg 2>/dev/null | grep -ci 'nobody cared\|disabling IRQ')" "0"
	check "regulator warnings" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE CHAIN IS PROVEN, END TO END."
		say ""
		say "One physical headset insertion moved 0x14b bit 2, asserted"
		say "$SRC_NAME, raised GPIO 72, dispatched through regmap-irq"
		say "to the nested handler, was acknowledged, cleared its status,"
		say "and returned to quiescence. All 29 sources masked again, 0x14a"
		say "back to its reset value, no manual recovery."
		say ""
		say "Minimum configuration used: three writes to one register."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed; see above."
		say ""
		say "Read the stage table first: it says how far the chain got."
		say "A transition without dispatch is a wiring or mask problem;"
		say "dispatch without a transition means the interrupt came from"
		say "something other than the jack, which is a different failure"
		say "and must not be written up as a partial pass."
	fi

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

# Whatever happened, leave the codec as we found it.
cleanup

rm -f "$DMESG_FILE"

sed -n '/=== the chain, stage by stage/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

#!/bin/sh
#
# WCD9320 nested IRQ, step 4/5: ONE CONTROLLED MBHC SOURCE, END TO END.
#
# Unmasks exactly one already-mapped source -- MBHC_INSERTION -- and proves the
# whole chain for one physical event:
#
#   MBHC event -> codec status bit -> regmap-irq dispatch -> nested handler
#     -> parent GPIO 72 assertion -> ack -> status clears -> line idle
#
# THE STRICT REQUIREMENT: one physical event must produce a finite,
# explainable interrupt sequence and return to quiescence with no manual
# recovery. A source that fires and stays asserted is a FAILURE, not a partial
# pass -- with a separate write-1-to-clear register, a botched ack is exactly
# how that happens.
#
# Interactive: run it, then insert or remove a headset when prompted.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.
#
# ---------------------------------------------------------------------------
# WHERE THE POST-ACK EVIDENCE COMES FROM, AND WHERE IT MUST NOT
#
# The two facts this milestone turns on -- "the status bit cleared" and "only
# one source was unmasked" -- are read from the handler's own dmesg line, not
# from irq_observe.
#
# irq_observe cannot supply them. Its last_status is written only by the
# bounded diagnostic sampler, which finished about half a minute into probe
# with every source masked, and its mask_readback is written exactly once, at
# IRQ setup, immediately after the driver masks everything. Both are frozen
# for the life of the module: last_status at 00 00 00 00 and mask_readback at
# ff ff 3f 7f. Asserting the acceptance bar against them passes whatever the
# hardware actually did.
#
# The handler reads both registers live, straight off the chip, after
# regmap-irq has already acknowledged. That is the only source in this build
# that can distinguish an ack that took from one that did not.
# ---------------------------------------------------------------------------

set -u

MODE="mbhc-irq"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-mbhc-irq-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-mbhc-$$"
SETTLE="${SETTLE:-20}"		# seconds to wait for the physical event

# Every source masked: reg0 and reg1 carry eight sources each, reg2 bits 0-5,
# reg3 bits 0-6.
MASK_ALL="ff ff 3f 7f"
# MBHC_INSERTION is INTR_REG 0 bit 6, so arming exactly one source has to clear
# that one bit and leave all 28 others set. Anything else means the request
# unmasked more than it was asked to.
MASK_ONE_ARMED="bf ff 3f 7f"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-mbhc-irq-$STAMP.txt"

parent_count() {
	# The child interrupt is also named wcd9320-something, so it has to be
	# excluded by name rather than by position: counting the wrong line
	# would silently invalidate both the parent assertion and the
	# quiescence resample.
	grep 'wcd9320' /proc/interrupts 2>/dev/null |
		grep -v 'wcd9320-mbhc' | head -n1 | awk '{print $2+0}'
}
child_count() {
	grep 'wcd9320-mbhc' /proc/interrupts 2>/dev/null |
		head -n1 | awk '{print $2+0}'
}
# Frozen driver snapshot, recorded for the file only -- see the header.
stale_masks() {
	grep -o 'mask_readback=[0-9a-f ]*' "$PGD/irq_observe" 2>/dev/null |
		head -n1 | sed 's/mask_readback=//; s/ *$//'
}
# post-ack status and mask off the LAST handler line, which is the settled one.
handler_status() {
	sed -n 's/.*post-ack status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
		"$DMESG_FILE" 2>/dev/null | tail -n1
}
handler_mask() {
	sed -n 's/.*post-ack status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$DMESG_FILE" 2>/dev/null | tail -n1
}
# Progress for the human. Collection runs before the evidence file is opened
# for writing, so this deliberately goes to the terminal and nowhere else.
tty_note() { printf '%s\n' "$*" >&2; }

# --- COLLECT ----------------------------------------------------------------
# Everything is gathered first and reported afterwards, so that the run body
# can be redirected into the evidence file without the prompt disappearing
# into it.

MASK_STALE_BEFORE=$(stale_masks)
PARENT_BEFORE=$(parent_count)
MBHC_BEFORE=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)

tty_note "arming MBHC_INSERTION on $PGD_NAME"
if ! echo arm > "$PGD/mbhc_test" 2>/dev/null; then
	say "could not arm; nothing collected"
	emit_invalid_setup "writing 'arm' to mbhc_test failed"
	exit 2
fi
sleep 1
ARMED=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)
CHILD_VIRQ=$(printf '%s' "$ARMED" | tr ' ' '\n' | sed -n 's/^child_virq=//p')
CHILD_BEFORE=$(child_count)
tty_note "armed: $ARMED"

printf '\n>>> INSERT OR REMOVE A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
i=0
while [ "$i" -lt "$SETTLE" ]; do
	sleep 1
	i=$((i + 1))
	_c=$(child_count)
	[ "${_c:-0}" -gt "${CHILD_BEFORE:-0}" ] && break
done
WAITED=$i

PARENT_AFTER=$(parent_count)
CHILD_AFTER=$(child_count)
tty_note "event window closed after ${WAITED}s; child ${CHILD_BEFORE:-0} -> ${CHILD_AFTER:-0}"

# The strict part. Resample after a settling period: if the counts are still
# climbing, the source never returned to idle.
tty_note "resampling for quiescence in 5s"
sleep 5
PARENT_Q=$(parent_count)
CHILD_Q=$(child_count)

echo disarm > "$PGD/mbhc_test" 2>/dev/null
sleep 1
MASK_STALE_AFTER=$(stale_masks)
MBHC_AFTER=$(head -n1 "$PGD/mbhc_test" 2>/dev/null)

snap_dmesg
STATUS_POSTACK=$(handler_status)
MASK_POSTACK=$(handler_mask)
HANDLER_LINES=$(count_lines 'mbhc test: irq #')
tty_note "collected; writing $OUT"

# --- REPORT -----------------------------------------------------------------

{
	hdr "before arming"
	say "parent assertions : ${PARENT_BEFORE:-0}"
	say "mbhc_test         : $MBHC_BEFORE"
	note "irq_observe masks" "$MASK_STALE_BEFORE -- frozen probe-time snapshot, not a live read"

	hdr "armed"
	say "mbhc_test         : $ARMED"
	say "child virq        : ${CHILD_VIRQ:-none}"
	say "child assertions  : ${CHILD_BEFORE:-0}"

	hdr "physical event"
	say "waited            : ${WAITED}s of ${SETTLE}s"
	say "parent assertions : ${PARENT_AFTER:-0}  (was ${PARENT_BEFORE:-0})"
	say "child assertions  : ${CHILD_AFTER:-0}  (was ${CHILD_BEFORE:-0})"
	say "handler lines     : $HANDLER_LINES"
	say "post-ack status   : ${STATUS_POSTACK:-none logged}   (live, from the handler)"
	say "post-ack mask     : ${MASK_POSTACK:-none logged}   (live, from the handler)"

	hdr "quiescence, 5s after the event"
	say "parent assertions : ${PARENT_Q:-0}"
	say "child assertions  : ${CHILD_Q:-0}"
	say "delta since event : parent $(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} )), child $(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))"

	hdr "disarmed"
	say "mbhc_test         : $MBHC_AFTER"
	note "irq_observe masks" "$MASK_STALE_AFTER -- same frozen snapshot; it cannot show re-masking"

	# --- GATE ---------------------------------------------------------------
	hdr "acceptance checks: MBHC SINGLE SOURCE"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "child irq was armed" \
		"$([ -n "${CHILD_VIRQ:-}" ] && [ "$(num "${CHILD_VIRQ:-}" 0)" -gt 0 ] && echo 1 || echo 0)" \
		"no child virq allocated" "virq $CHILD_VIRQ"

	_fired=$(( ${CHILD_AFTER:-0} - ${CHILD_BEFORE:-0} ))
	_pfired=$(( ${PARENT_AFTER:-0} - ${PARENT_BEFORE:-0} ))
	check_cond "nested source fired" "$([ "$_fired" -ge 1 ] && echo 1 || echo 0)" \
		"child count did not increase -- no event, or it never reached the handler" \
		"child +$_fired"
	check_cond "parent asserted" "$([ "$_pfired" -ge 1 ] && echo 1 || echo 0)" \
		"parent count did not increase -- nested dispatch without a parent edge is impossible" \
		"parent +$_pfired"

	_irqc=$(num "$(kv "$PGD/mbhc_test" irq_count)" 0)
	check_cond "handler ran" "$([ "$_irqc" -ge 1 ] && echo 1 || echo 0)" \
		"driver handler never ran" "irq_count=$_irqc"
	check "handler status reads" \
		"$(count_lines 'mbhc test: irq #[0-9]*, status read failed')" "0"

	# Exactly one source unmasked, read live off the chip while armed. This is
	# what makes "all others remain masked" a measurement rather than a claim.
	check "armed mask (live)" "$MASK_POSTACK" "$MASK_ONE_ARMED"

	# The strict requirement, split so a failure says which half broke.
	check "status cleared after ack (live)" "$STATUS_POSTACK" "00 00 00 00"
	check "returned to quiescence (parent)" "$(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} ))" "0"
	check "returned to quiescence (child)" "$(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))" "0"

	# Finite: a plausible event is a handful of edges, not hundreds.
	check_cond "finite sequence" "$([ "$_fired" -le 20 ] && echo 1 || echo 0)" \
		"$_fired assertions from one event -- not a finite, explainable sequence" \
		"$_fired assertion(s)"

	check_cond "disarm acknowledged" \
		"$([ "$(count_lines 'mbhc test: DISARMED')" -ge 1 ] && echo 1 || echo 0)" \
		"no DISARMED line -- free_irq did not run, so the source may still be live" \
		"free_irq ran"
	check "armed flag cleared" "$(kv "$PGD/mbhc_test" armed)" "0"

	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "spurious irq complaints" \
		"$(dmesg 2>/dev/null | grep -ci 'nobody cared\|disabling IRQ')" "0"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	note "source" "$(kv "$PGD/mbhc_test" source) MBHC_INSERTION -- all others stayed masked"
	note "re-masking after disarm" \
		"not directly observable in this build; regmap-irq re-masks on free, and the DISARMED line plus continued quiescence are the evidence for it"

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== before arming/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

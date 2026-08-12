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

set -u

MODE="mbhc-irq"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-mbhc-irq-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-mbhc-$$"
SETTLE="${SETTLE:-20}"		# seconds to wait for the physical event

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-mbhc-irq-$STAMP.txt"

parent_count() {
	grep 'wcd9320' /proc/interrupts 2>/dev/null | head -n1 | awk '{print $2+0}'
}
child_count() {
	grep 'wcd9320-mbhc' /proc/interrupts 2>/dev/null | head -n1 | awk '{print $2+0}'
}
masks_now() {
	grep -o 'mask_readback=[0-9a-f ]*' "$PGD/irq_observe" 2>/dev/null |
		head -n1 | sed 's/mask_readback=//; s/ *$//'
}
status_now() {
	grep -o 'last_status=[0-9a-f ]*' "$PGD/irq_observe" 2>/dev/null |
		head -n1 | sed 's/last_status=//; s/ *$//'
}

# --- BEFORE -----------------------------------------------------------------
hdr "before arming"
MASK_BEFORE=$(masks_now)
PARENT_BEFORE=$(parent_count)
say "masks             : $MASK_BEFORE"
say "parent assertions : ${PARENT_BEFORE:-0}"
say "mbhc_test         : $(cat "$PGD/mbhc_test" 2>/dev/null | head -n1)"

# --- ARM --------------------------------------------------------------------
hdr "arming exactly one source"
if ! echo arm > "$PGD/mbhc_test" 2>/dev/null; then
	say "could not arm; nothing collected"
	emit_invalid_setup "writing 'arm' to mbhc_test failed"
	exit 2
fi
sleep 1
ARMED=$(cat "$PGD/mbhc_test" 2>/dev/null | head -n1)
CHILD_VIRQ=$(printf '%s' "$ARMED" | tr ' ' '\n' | sed -n 's/^child_virq=//p')
say "armed             : $ARMED"
say "child virq        : ${CHILD_VIRQ:-none}"
say "masks after arm   : $(masks_now)  (driver snapshot; regmap-irq owns them now)"
CHILD_BEFORE=$(child_count)
say "child assertions  : ${CHILD_BEFORE:-0}"

# --- EVENT ------------------------------------------------------------------
hdr "physical event"
say "INSERT OR REMOVE A HEADSET NOW -- waiting ${SETTLE}s"
printf '\n>>> INSERT OR REMOVE A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
i=0
while [ "$i" -lt "$SETTLE" ]; do
	sleep 1
	i=$((i + 1))
	_c=$(child_count)
	[ "${_c:-0}" -gt "${CHILD_BEFORE:-0}" ] && break
done
say "waited            : ${i}s"

PARENT_AFTER=$(parent_count)
CHILD_AFTER=$(child_count)
STATUS_AFTER=$(status_now)
say "parent assertions : ${PARENT_AFTER:-0}  (was ${PARENT_BEFORE:-0})"
say "child assertions  : ${CHILD_AFTER:-0}  (was ${CHILD_BEFORE:-0})"
say "post-ack status   : $STATUS_AFTER"

# --- QUIESCENCE -------------------------------------------------------------
# The strict part. Sample again after a settling period: if the counts are
# still climbing the source never returned to idle.
hdr "quiescence, 5s after the event"
sleep 5
PARENT_Q=$(parent_count)
CHILD_Q=$(child_count)
say "parent assertions : ${PARENT_Q:-0}"
say "child assertions  : ${CHILD_Q:-0}"
say "delta since event : parent $(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} )), child $(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))"

# --- DISARM -----------------------------------------------------------------
hdr "disarm and re-mask"
echo disarm > "$PGD/mbhc_test" 2>/dev/null
sleep 1
MASK_AFTER=$(masks_now)
say "mbhc_test         : $(cat "$PGD/mbhc_test" 2>/dev/null | head -n1)"
say "masks after       : $MASK_AFTER"

snap_dmesg

# --- GATE -------------------------------------------------------------------
hdr "acceptance checks: MBHC SINGLE SOURCE"

check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
check_cond "child irq was armed" \
	"$([ -n "${CHILD_VIRQ:-}" ] && [ "${CHILD_VIRQ:-0}" -gt 0 ] && echo 1 || echo 0)" \
	"no child virq allocated" "virq $CHILD_VIRQ"

_fired=$(( ${CHILD_AFTER:-0} - ${CHILD_BEFORE:-0} ))
_pfired=$(( ${PARENT_AFTER:-0} - ${PARENT_BEFORE:-0} ))
check_cond "nested source fired" "$([ "$_fired" -ge 1 ] && echo 1 || echo 0)" \
	"child count did not increase -- no event, or it never reached the handler" \
	"child +$_fired"
check_cond "parent asserted" "$([ "$_pfired" -ge 1 ] && echo 1 || echo 0)" \
	"parent count did not increase -- nested dispatch without a parent edge is impossible" \
	"parent +$_pfired"
check_cond "handler ran" "$([ "$(kv "$PGD/mbhc_test" irq_count)" -ge 1 ] && echo 1 || echo 0)" \
	"driver handler never ran" \
	"irq_count=$(kv "$PGD/mbhc_test" irq_count)"

# The strict requirement, split so a failure says which half broke.
check "status cleared after ack" "$STATUS_AFTER" "00 00 00 00"
check "returned to quiescence (parent)" "$(( ${PARENT_Q:-0} - ${PARENT_AFTER:-0} ))" "0"
check "returned to quiescence (child)" "$(( ${CHILD_Q:-0} - ${CHILD_AFTER:-0} ))" "0"

# Finite: a plausible event is a handful of edges, not hundreds.
check_cond "finite sequence" "$([ "$_fired" -le 20 ] && echo 1 || echo 0)" \
	"$_fired assertions from one event -- not a finite, explainable sequence" \
	"$_fired assertion(s)"

check "re-masked after disarm" "$MASK_AFTER" "ff ff 3f 7f"
check "armed flag cleared" "$(kv "$PGD/mbhc_test" armed)" "0"

check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
check "spurious irq complaints" \
	"$(dmesg 2>/dev/null | grep -ci 'nobody cared\|disabling IRQ')" "0"
check "identity major" \
	"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

note "source" "$(kv "$PGD/mbhc_test" source) MBHC_INSERTION -- all others stayed masked"

collect_evidence
emit_verdict
RC=$?
sed -n '/=== before arming/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

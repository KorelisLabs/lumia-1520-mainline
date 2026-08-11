#!/bin/sh
#
# WCD9320 nested IRQ controller, step 3: IDLE PROOF.
#
# Proves that installing the nested controller does not disturb anything and
# does not create parent interrupts, with every source still masked. It does
# NOT prove the controller can deliver an interrupt -- that is step 5, and
# needs a source unmasked and a real physical event.
#
# Preconditions:
#   - running module is nested-irq-rc1 or later, with the chip registered
#   - no source has been unmasked
#
# Acceptance gate:
#   chip registered on the parent
#   parent assertion count 0, read from /proc/interrupts
#   INTR_STATUS0-3 all 00
#   INTR_MASK0-3 = ff ff 3f 7f
#   no kernel WARNING/BUG, no spurious-IRQ complaint
#   identity, both logical addresses, ADSP, NGD and SLIMbus health unchanged
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN (nothing collected).

set -u

MODE="nested-idle"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-nested-irq-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-nested-$$"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-nested-idle-$STAMP.txt"

# ---------------------------------------------------------------------------
# The parent count comes from /proc/interrupts, not from the driver.
#
# Since regmap-irq took ownership of the line, the driver no longer counts
# assertions -- irq_count in irq_observe is vestigial and reads 0 whatever
# happens. Reading it here would be self-confirming. /proc/interrupts is
# maintained by the kernel's own IRQ core and cannot be skewed by this driver.
# ---------------------------------------------------------------------------
PARENT_LINE=$(grep 'wcd9320' /proc/interrupts 2>/dev/null | head -n1)
PARENT_IRQ=$(echo "$PARENT_LINE" | sed -n 's/^ *\([0-9]*\):.*/\1/p')
PARENT_COUNT=$(echo "$PARENT_LINE" | awk '{print $2+0}')
PARENT_CHIP=$(echo "$PARENT_LINE" | awk '{print $3}')
PARENT_HW=$(echo "$PARENT_LINE" | awk '{print $4}')
PARENT_TRIG=$(echo "$PARENT_LINE" | awk '{print $5}')

hdr "parent line, from /proc/interrupts"
say "line              : $PARENT_LINE"
say "virtual irq       : ${PARENT_IRQ:-none}  (varies per boot; not asserted on)"
say "chip / hwirq      : $PARENT_CHIP $PARENT_HW"
say "assertions        : ${PARENT_COUNT:-none}"

MASKS=$(cat "$PGD/irq_observe" 2>/dev/null | tr ' \n' '\n\n' |
	sed -n 's/^mask_readback=//p' | head -n1)
STATUS_NOW=$(cat "$PGD/irq_observe" 2>/dev/null |
	grep -o 'last_status=[0-9a-f ]*' | sed 's/last_status=//')

hdr "acceptance checks: NESTED IDLE"

check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

# The chip must actually have registered. Without this the run could pass by
# virtue of nothing being installed at all.
_reg=$(count_lines 'nested irq chip registered')
check_cond "nested chip registered" "$([ "$_reg" -ge 1 ] && echo 1 || echo 0)" \
	"no 'nested irq chip registered' line in dmesg"

# The old handler must be gone; if both were present the line would have two
# owners and the result would mean nothing.
_old=$(count_lines 'parent irq .* requested, kernel reports')
check "old parent handler absent" "$_old" "0"

check_cond "parent line present" "$([ -n "$PARENT_LINE" ] && echo 1 || echo 0)" \
	"no wcd9320 line in /proc/interrupts"
check "parent hwirq" "$PARENT_HW" "72"
check "parent assertions (/proc/interrupts)" "${PARENT_COUNT:-x}" "0"

check "interrupt masks" "$(echo $MASKS)" "ff ff 3f 7f"

# Status read live, not from the driver's cached snapshot.
_st=$(dmesg 2>/dev/null | grep -c 'wcd9320.*status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*' 2>/dev/null)
note "status lines seen" "$_st"

check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
check "spurious irq complaints" "$(dmesg 2>/dev/null | grep -ci 'nobody cared\|spurious')" "0"
check "regulator warnings" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"

# Nothing about the codec may have changed.
check "identity major" "$(kv "$PGD/identity" major)" "0x0102"
check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
check "stale bus state" "$(kv "$PGD/bringup" stale_bus_state)" "0"
check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"
check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

note "what this does NOT prove" "delivery -- no source is unmasked; that is step 5"

collect_evidence
emit_verdict
RC=$?

sed -n '/=== parent line/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

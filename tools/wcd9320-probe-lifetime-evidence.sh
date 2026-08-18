#!/bin/sh
#
# Acceptance gate for the probe-lifetime fix.
#
# WHAT IS BEING PROVEN, AND WHAT IS NOT
#
# Not "the double probe is gone". Deferred probing is normal, correct bus
# behaviour and this fix deliberately does not suppress it. What is proven is
# that the driver's globally published instance pointer is withdrawn by the
# same devres lifetime that owns the object, so no unwind can leave it
# pointing at freed memory.
#
# THE ANTI-VACUITY CONDITION IS THE WHOLE DESIGN
#
# The interface function defers on every boot observed so far -- but "so far"
# is not a guarantee, and a boot where the ADSP's manager happened to answer
# the first query would sail through every check below while proving nothing
# about the fix. That run must be INVALID, not PASS. So the deferral itself is
# asserted first, from two independent markers, and a run without it collects
# nothing and exits 3.
#
# Exit: 0 proven, 1 checks failed, 2 invalid setup, 3 no deferral occurred.

set -u

MODE="probe-lifetime"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-lifetime-$$"

require_module_version
find_devices

# ------------------------------------------------ the deferral must be real --
#
# Two independent markers. The bus's own error is what actually triggers the
# unwind; a second IFD probe is what proves the retry happened. Requiring both
# means a log that merely looks right cannot pass.
#
DEFER_MARK=$(dmesg 2>/dev/null | grep -c '217:a0:0:0: Failed to get logical address')
IFD_PROBES=$(dmesg 2>/dev/null | grep -c 'IFD probe #[0-9]*: returning 0')

if [ "$DEFER_MARK" -lt 1 ] || [ "$IFD_PROBES" -lt 2 ]; then
	say "INVALID RUN: the interface function did not defer on this boot."
	say ""
	say "  Failed-to-get-logical-address lines : $DEFER_MARK (need >= 1)"
	say "  IFD probes completed                : $IFD_PROBES (need >= 2)"
	say ""
	say "  The fix withdraws a published pointer during devres unwind."
	say "  Without an unwind there is nothing to withdraw, and every check"
	say "  below would pass while proving nothing at all. That is why this"
	say "  is INVALID and not PASS."
	say ""
	say "  Whether it defers depends on whether the ADSP manager knows the"
	say "  interface function's enumeration address at the moment"
	say "  slim_get_logical_addr() asks. It has deferred on every boot"
	say "  observed, but it is a race and not a certainty. Cold boot and run"
	say "  this again."
	exit 3
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-probe-lifetime-$STAMP.txt"

# --------------------------------------------------------- parse the probes --
p_field() {	# p_field <probe#> <before|after> <key>
	dmesg 2>/dev/null |
		sed -n "s/.*IFD probe #$1: $2: .*$3=\([0-9a-fx]*\).*/\1/p" | head -n1
}

P1_AFTER_INST=$(p_field 1 after ifd_instance)
P1_AFTER_REPL=$(p_field 1 after replaced)
P2_BEFORE_INST=$(p_field 2 before ifd_instance)
P2_BEFORE_DRV=$(p_field 2 before drvdata)
P2_AFTER_INST=$(p_field 2 after ifd_instance)
P2_AFTER_REPL=$(p_field 2 after replaced)
IFD_UP=$(dmesg 2>/dev/null | grep -c 'interface function UP')
CTL_SECOND=$(dmesg 2>/dev/null | grep -c 'CTL probe #2')

# ------------------------------------- exercise the REBOUND object, not just --
#                                       the pointer
#
# Proving the global is NULL at the right moment is only half of it. The other
# half is that the instance published by the retry is the one the production
# path actually uses -- otherwise a fix that cleared the pointer and never
# republished it would look identical here.
#
RX_ON_RC=""
RX_OFF_RC=""
RX_WRITES=""
if [ -n "${PGD:-}" ] && [ -w "$PGD/rx_port_test" ]; then
	printf 'rx-port-on' > "$PGD/rx_port_test" 2>/dev/null
	RX_ON_RC=$?
	sleep 1
	printf 'rx-port-off' > "$PGD/rx_port_test" 2>/dev/null
	RX_OFF_RC=$?
	sleep 1
	RX_WRITES=$(sed -n 's/.*writes=\([0-9]*\).*/\1/p' "$PGD/rx_port_state" 2>/dev/null | head -n1)
fi

{
	hdr "the deferral this run depends on"
	say "Failed-to-get-logical-address   : $DEFER_MARK"
	say "IFD probes completed            : $IFD_PROBES"
	say "interface function UP           : $IFD_UP"
	say "CTL probe #2 (must be absent)   : $CTL_SECOND"

	hdr "the published pointer, across the unwind"
	say "probe #1 after : ifd_instance=$P1_AFTER_INST replaced=$P1_AFTER_REPL"
	say "probe #2 before: ifd_instance=$P2_BEFORE_INST drvdata=$P2_BEFORE_DRV"
	say "probe #2 after : ifd_instance=$P2_AFTER_INST replaced=$P2_AFTER_REPL"
	say ""
	say "Before the fix, probe #2 before read a stale non-NULL ifd_instance"
	say "with replaced=1. The devres action now clears it during"
	say "device_unbind_cleanup(), so the retry sees a NULL global."

	hdr "the rebound object drives the production path"
	say "rx-port-on  rc : ${RX_ON_RC:-not attempted}"
	say "rx-port-off rc : ${RX_OFF_RC:-not attempted}"
	say "port writes    : ${RX_WRITES:-unknown}"

	hdr "the probe lines, verbatim"
	dmesg 2>/dev/null |
		grep -E 'IFD probe|CTL probe|Failed to get logical|function UP' |
		sed 's/^/  /'

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# The proof itself.
	check "probe #2 saw a CLEARED global" "$P2_BEFORE_INST" "00000000"
	check "probe #2 replaced nothing" "$P2_AFTER_REPL" "0"

	# The retry must still publish a live instance -- clearing without
	# republishing would satisfy both checks above and break the driver.
	check_cond "probe #2 published a live instance" \
		"$([ -n "$P2_AFTER_INST" ] && [ "$P2_AFTER_INST" != "00000000" ] && echo 1 || echo 0)" \
		"ifd_instance is still NULL after the retry" "$P2_AFTER_INST"
	check_cond "the retry's instance differs from the freed one" \
		"$([ "$P2_AFTER_INST" != "$P1_AFTER_INST" ] && echo 1 || echo 0)" \
		"same pointer -- the allocation was not actually replaced" "ok"

	# Unchanged behaviour: the deferral is legitimate and must survive.
	check_cond "the deferral still happens (not suppressed)" \
		"$([ "$DEFER_MARK" -ge 1 ] && echo 1 || echo 0)" \
		"the fix suppressed deferred probing, which it must not" "$DEFER_MARK"
	check "the interface function came up" "$IFD_UP" "1"
	check "control function did not defer" "$CTL_SECOND" "0"

	# The rebound object is the one in use.
	check "hook accepted rx-port-on" "${RX_ON_RC:-x}" "0"
	check "hook accepted rx-port-off" "${RX_OFF_RC:-x}" "0"
	check_cond "the port path reached hardware through it" \
		"$([ -n "$RX_WRITES" ] && [ "$RX_WRITES" -ge 2 ] 2>/dev/null && echo 1 || echo 0)" \
		"no register writes -- the global may point nowhere useful" \
		"${RX_WRITES:-0} writes"

	# Health, unchanged from every other gate.
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	# The identity blob is SPACE-separated ("major 0x0102"), not
	# key=value, so kv() -- which splits on "=" -- reads it as empty.
	# Every other gate uses this sed for exactly that reason.
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check_cond "no kernel WARNING/BUG" \
		"$([ "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" -eq 0 ] && echo 1 || echo 0)" \
		"the log carries a WARNING or BUG" "none"
	check_cond "no memory-error report" \
		"$([ "$(dmesg 2>/dev/null | grep -ci 'use-after-free\|KASAN\|slab-out-of-bounds')" -eq 0 ] && echo 1 || echo 0)" \
		"the log reports a memory error" "none"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE PUBLISHED POINTER NO LONGER OUTLIVES ITS OBJECT."
		say ""
		say "The interface function deferred, as it does on every boot: the"
		say "bus asked the ADSP manager for a logical address, the manager"
		say "did not know the device yet, and slim_device_probe() converted"
		say "our success into -EPROBE_DEFER. The driver core unwound through"
		say "device_unbind_cleanup(), and this time the devres action cleared"
		say "wcd9320_ifd_instance before devres_release_all() freed the"
		say "struct it pointed at."
		say ""
		say "The retry then published a NEW instance into a NULL global"
		say "(replaced=0, where it read 1 before the fix), and the production"
		say "RX port path reached hardware through that instance."
		say ""
		say "WHAT THIS DOES NOT CLAIM. Deferred probing is untouched and"
		say "still happens. The control function's rollback behaviour is"
		say "unproven: it has never been observed to defer, and its unwind"
		say "would drop supplies and re-assert reset mid-bring-up. That"
		say "remains an open question, not a fixed one."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the deferral this run depends on/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

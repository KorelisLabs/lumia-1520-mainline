#!/bin/sh
#
# r172: does a 0x30d write move a per-channel HPH status register?
#
# THE QUESTION
#
# r171 returned W0 -- no documented bit of 0x314 or 0x30d latches, and 0x30d
# bit 2 (HPHR) refuses identically to bit 1 (HPHL). That eliminated per-bit,
# per-path and combination gating and left exactly one thing it could not
# settle: WRITE-ONLY versus REFUSED. Both produce a readback of 00.
#
# 0x30d is unusually well suited to providing an observable, because the
# stimulus is channel-specific -- bit 1 is HPHL, bit 2 is HPHR -- and there are
# two independent per-channel status registers to watch.
#
# THE EVIDENCE BOUNDARY, STATED BEFORE THE RESULT
#
# RX_HPH_L_STATUS (0x1b3) and RX_HPH_R_STATUS (0x1b9) appear in exactly three
# places across every cached generation: taiko_volatile(), which only says
# downstream reads them from the chip; the readable and POR tables; and
# wcd9xxx_hphl_status() in wcd9xxx-mbhc.c -- the ONLY functional read anywhere,
# which uses L_STATUS as an MBHC PLUG-DETECTION COMPARATOR output, asserting
# MBHC_HPH bit 1, waiting 1 ms, then reading.
#
# So NO semantic interpretation of these bits as an RDAC-clock acknowledgement
# exists, in any generation. Therefore:
#
#   - a reproducible CHANNEL-SPECIFIC response is strong positive evidence;
#   - NO RESPONSE IS NOT EVIDENCE that the 0x30d write failed;
#   - the existing 04 baseline is NOT interpreted, only compared against.
#
# S0 is the EXPECTED outcome. This run is worth making because it is cheap and
# because a positive would overturn the assumption the whole branch rests on.
#
# The 1 ms settle between stimulus and status read is downstream's own
# (WCD9XXX_HPHL_STATUS_READY_WAIT_US = 1000), not invented here. MBHC_HPH is
# deliberately NOT asserted: that is a different experiment.
#
# The middle sample is taken INSIDE THE DRIVER between the write and the
# restore. A shell-side read would be looking at a codec already put back.
#
# RCO only. No MCLK, no DAC, no PA. 0x314 takes no part in this run.
#
# Exit: 0 = S1 channel-correlated, reproducible response
#       1 = S0 no response -- INCONCLUSIVE, not a refusal
#       2 = SX response is nonspecific, coupled, or not reproducible
#       3 = setup failure, or a failed check

set -u

MODE="wcd9320-hph-status"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r172-$$"
DMESG_MARKER="${DMESG_MARKER:-hs: ---- cycle 0, HPHL}"

require_module_version
find_devices

HST="$PGD/hph_status_test"
HSS="$PGD/hph_status_state"
DACS="$PGD/hphl_dac_state"
CSRCS="$PGD/clk_source_state"

for f in "$HST" "$HSS" "$DACS" "$CSRCS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }
hss() { cat "$HSS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst); CPRE=$(cat "$CSRCS" 2>/dev/null)
BAD=""
[ "$(rv "$PRE" guard_tripped)" = "0" ]    || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" pa_0x1ab)" = "80" ]        || BAD="$BAD pa_not_at_baseline"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]       || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" on)" = "0" ]               || BAD="$BAD c2b_up"
[ "$(rv "$PRE" rdac_0x30d)" = "00" ]      || BAD="$BAD 0x30d_not_at_por"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ] || BAD="$BAD 0x314_moved"
[ "$(rv "$CPRE" source)" = "RCO" ]        || BAD="$BAD not_on_rco"
[ "$(rv "$CPRE" on_mclk)" = "0" ]         || BAD="$BAD on_mclk"

if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not pristine:$BAD"
	exit 3
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-hph-status-$STAMP.txt"

WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------------------------- run ----
echo run > "$HST" 2>/dev/null; RUN_RC=$?
H=$(hss)
POST=$(dst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

# ------------------------------------------------------------- analysis -----
# moved <cycle> <channel> <reg> -> 1 if the "during" sample differs from "pre"
moved() {
	_a=$(rv "$H" "c$1$2_pre_$3")
	_b=$(rv "$H" "c$1$2_dur_$3")
	[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" != "$_b" ] && echo 1 || echo 0
}
# returned <cycle> <channel> <reg> -> 1 if "post" equals "pre"
returned() {
	_c=$(rv "$H" "c$1$2_pre_$3")
	_d=$(rv "$H" "c$1$2_post_$3")
	[ "$_c" = "$_d" ] && echo 1 || echo 0
}

# The HPHL stimulus against each status register, per cycle
L0L=$(moved 0 l 1b3); L0R=$(moved 0 l 1b9)
L1L=$(moved 1 l 1b3); L1R=$(moved 1 l 1b9)
# The HPHR stimulus against each status register, per cycle
R0R=$(moved 0 r 1b9); R0L=$(moved 0 r 1b3)
R1R=$(moved 1 r 1b9); R1L=$(moved 1 r 1b3)

ANY=$((L0L + L0R + L1L + L1R + R0R + R0L + R1R + R1L))

# Channel-correct and reproducible: the stimulus moves its OWN status register
# in BOTH cycles and never the other channel's.
LSPEC=0
[ "$L0L" = "1" ] && [ "$L1L" = "1" ] && [ "$L0R" = "0" ] && [ "$L1R" = "0" ] && LSPEC=1
RSPEC=0
[ "$R0R" = "1" ] && [ "$R1R" = "1" ] && [ "$R0L" = "0" ] && [ "$R1L" = "0" ] && RSPEC=1

# 0x30d must have kept reading 00 while attempted, or this is a different
# result entirely (the bit latched, which r171 says it does not).
#
# Defaulted before the arithmetic: if the run did not produce state, rv gives
# an empty string and $(( )) would be a syntax error rather than a failed
# check -- turning a bad run into a broken reporter.
LATCHED=0
for _k in c0l_latched c0r_latched c1l_latched c1r_latched; do
	_v=$(rv "$H" "$_k")
	[ -n "$_v" ] || _v=0
	LATCHED=$((LATCHED + _v))
done

{
	hdr "the samples"
	say "each row: 0x30d / L_STATUS 0x1b3 / R_STATUS 0x1b9"
	for c in 0 1; do
		for ch in l r; do
			say ""
			say "cycle $c, $(echo "$ch" | tr 'lr' 'LR')PH stimulus (0x30d bit $([ "$ch" = "l" ] && echo 1 || echo 2)), latched=$(rv "$H" "c$c${ch}_latched")"
			say "  before : $(rv "$H" "c$c${ch}_pre_30d")  $(rv "$H" "c$c${ch}_pre_1b3")  $(rv "$H" "c$c${ch}_pre_1b9")"
			say "  DURING : $(rv "$H" "c$c${ch}_dur_30d")  $(rv "$H" "c$c${ch}_dur_1b3")  $(rv "$H" "c$c${ch}_dur_1b9")"
			say "  after  : $(rv "$H" "c$c${ch}_post_30d")  $(rv "$H" "c$c${ch}_post_1b3")  $(rv "$H" "c$c${ch}_post_1b9")"
		done
	done

	hdr "movement matrix (during vs before)"
	say "  HPHL stimulus -> L_STATUS: cycle0 $L0L cycle1 $L1L"
	say "  HPHL stimulus -> R_STATUS: cycle0 $L0R cycle1 $L1R   (cross-talk)"
	say "  HPHR stimulus -> R_STATUS: cycle0 $R0R cycle1 $R1R"
	say "  HPHR stimulus -> L_STATUS: cycle0 $R0L cycle1 $R1L   (cross-talk)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "the run completed" "$RUN_RC" "0"
	check "observable ran" "$(rv "$H" done)" "1"
	check "0x30d never latched (r171 agreement)" "$LATCHED" "0"

	say ""
	say "-- everything returned to baseline --"
	for c in 0 1; do
		for ch in l r; do
			check "c$c$ch 0x30d returned" "$(returned $c $ch 30d)" "1"
			check "c$c$ch L_STATUS returned" "$(returned $c $ch 1b3)" "1"
			check "c$c$ch R_STATUS returned" "$(returned $c $ch 1b9)" "1"
		done
	done

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "80"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "0x314 untouched" "$(rv "$POST" clk_power_0x314)" "00"
	check "still on RCO" "$(rv "$(cat "$CSRCS")" source)" "RCO"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- delta only"

	hdr "finding"
	if [ "$ANY" = "0" ]; then
		say "S0 -- NEITHER STATUS RESPONDED. INCONCLUSIVE."
		say ""
		say "THIS IS NOT EVIDENCE THAT THE 0x30d WRITE FAILED, and it must not"
		say "be recorded as one. The bit semantics of 0x1b3 and 0x1b9 are"
		say "undocumented in every generation we hold; the only functional use"
		say "downstream makes of them is as an MBHC plug-detection comparator,"
		say "read 1 ms after asserting MBHC_HPH bit 1 -- a stimulus this run"
		say "deliberately does not apply."
		say ""
		say "So the observable was never known to be sensitive to the RDAC"
		say "clock, and its silence says nothing either way. Write-only versus"
		say "refused remains open, exactly as r171 left it."
		say ""
		say "The baseline value 04 in both registers is NOT interpreted."
		say ""
		say "Next: the still-untested MCLK-selected + CHIP_CTL = 9.6 MHz"
		say "conjunction, which is the last cell of the matrix."
	elif [ "$LSPEC" = "1" ] || [ "$RSPEC" = "1" ]; then
		say "S1 -- CHANNEL-CORRELATED, REPRODUCIBLE RESPONSE."
		say ""
		if [ "$LSPEC" = "1" ]; then
			say "  The HPHL stimulus moved L_STATUS in BOTH cycles and never"
			say "  moved R_STATUS."
		fi
		if [ "$RSPEC" = "1" ]; then
			say "  The HPHR stimulus moved R_STATUS in BOTH cycles and never"
			say "  moved L_STATUS."
		fi
		say ""
		say "0x30d itself continued to read 00 throughout."
		say ""
		say "THIS IS STRONG EVIDENCE THAT 0x30d HAS WRITE EFFECTS NOT"
		say "REFLECTED BY ITS READBACK. A left-channel write moving only the"
		say "left status register, reproducibly, is very hard to explain any"
		say "other way."
		say ""
		say "STOP HERE. Do NOT proceed to the MCLK + rate conjunction. The"
		say "assumption that has underpinned this entire branch -- that a"
		say "bypassed readback is a valid success criterion for 0x30d -- is now"
		say "in question, and with it every 'refused' verdict recorded against"
		say "these registers, including the C2b stage 6 blocker itself."
		say ""
		say "Reassess before building anything else."
	else
		say "SX -- RESPONSE IS NONSPECIFIC, COUPLED, OR NOT REPRODUCIBLE."
		say ""
		say "Something moved, but not in a way that can carry weight: either"
		say "both status registers moved together, or a stimulus moved the"
		say "other channel's register, or the behaviour differed between the"
		say "two cycles."
		say ""
		say "The observable is REJECTED as insufficiently specific. It cannot"
		say "distinguish write-only from refused, and no conclusion about"
		say "0x30d is drawn from it."
		say ""
		say "Next: the still-untested MCLK-selected + CHIP_CTL = 9.6 MHz"
		say "conjunction."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 3
fi

sed -n '/=== the samples ===/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 3
[ "$ANY" = "0" ] && exit 1
{ [ "$LSPEC" = "1" ] || [ "$RSPEC" = "1" ]; } && exit 0
exit 2

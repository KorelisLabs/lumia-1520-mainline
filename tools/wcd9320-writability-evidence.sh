#!/bin/sh
#
# r171: are the documented bits of 0x314 and 0x30d writable AT ALL?
#
# THE QUESTION, AND WHY IT HAS NEVER BEEN ASKED
#
# Every write this project has made to CDC_CLK_POWER_CTL used mask 0x03, and
# every write to CDC_CLK_RDAC_CLK_EN_CTL used bit 1 alone. So "the register
# refuses" has never been separated from "these particular bits are gated",
# and those are very different findings. This tests each documented bit
# independently.
#
# WHICH BITS, AND WHY ONLY THESE
#
# Enumerated from downstream across three source generations, which agree
# exactly -- see section 11 of docs/audio/wcd9320-refused-registers-audit.md:
#
#   0x314  ONE write site, taiko_reg_defaults[], a full-byte
#          snd_soc_write(0x03). Bits 0 and 1, only ever together. Our baseline
#          is 0x00, so a masked 0x03 <- 0x03 puts the IDENTICAL byte on the
#          wire as that full write; the combined step is a faithful
#          reproduction and no separate full-byte case is needed.
#
#   0x30d  FOUR write sites, all masked: bit 1 (0x02) HPHL RDAC clock, bit 2
#          (0x04) HPHR. Downstream never writes both together, so that step is
#          diagnostic and labelled so. BIT 2 HAS NEVER BEEN TRIED HERE and is
#          the exact structural twin of bit 1.
#
# Bits 2-7 of 0x314 and bits 0 and 3-7 of 0x30d are written by nothing in any
# generation, are undefined to us, and are NOT touched. There is no blind
# bit-walk in this run.
#
# WHAT THIS RUN IS NOT
#
# RCO only. No PMIC divider, no gpio15, no source switch. CHIP_CTL stays at
# its baseline -- this is about writability, not rate configuration, and r170's
# conclusion stays narrow: the rate declaration ALONE on RCO does not unlock
# 0x314. The MCLK-selected + rate-declared conjunction is NOT tested here and
# is preserved as the next experiment if this result leaves it relevant.
#
# No DAC power. No PA. This is a diagnostic, not the C2b production sequence.
#
# Exit: 0 = W4 the production bits latch in isolation
#       1 = W0 no documented bit in either register ever latches
#       2 = W1/W2 per-bit gating: some bits latch, others do not
#       4 = W3 individual bits latch but the combined value does not
#       3 = setup failure, or a failed check

set -u

MODE="wcd9320-writability"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r171-$$"
DMESG_MARKER="${DMESG_MARKER:-wr: baseline 0x314}"

require_module_version
find_devices

WRT="$PGD/writability_test"
WRS="$PGD/writability_state"
DACS="$PGD/hphl_dac_state"
CSRCS="$PGD/clk_source_state"

for f in "$WRT" "$WRS" "$DACS" "$CSRCS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }
wst() { cat "$WRS" 2>/dev/null; }
cst() { cat "$CSRCS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst); CPRE=$(cst)
BAD=""
[ "$(rv "$PRE" guard_tripped)" = "0" ]    || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" pa_0x1ab)" = "80" ]        || BAD="$BAD pa_not_at_baseline"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]       || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" on)" = "0" ]               || BAD="$BAD c2b_up"
[ "$(rv "$PRE" prereq_on)" = "0" ]        || BAD="$BAD prereq_on"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ] || BAD="$BAD 0x314_not_at_por"
[ "$(rv "$PRE" rdac_0x30d)" = "00" ]      || BAD="$BAD 0x30d_not_at_por"
# RCO only, and say so from the chip rather than from intent.
[ "$(rv "$CPRE" source)" = "RCO" ]        || BAD="$BAD not_on_rco"
[ "$(rv "$CPRE" on_mclk)" = "0" ]         || BAD="$BAD on_mclk"
CC0=$(rv "$PRE" chip_ctl_0x000)

if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not pristine:$BAD"
	say "  0x314=$(rv "$PRE" clk_power_0x314) 0x30d=$(rv "$PRE" rdac_0x30d) chip_ctl=$CC0"
	exit 3
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-writability-$STAMP.txt"

WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------------------------- run ----
echo run > "$WRT" 2>/dev/null; RUN_RC=$?
W=$(wst)

A0=$(rv "$W" s0_latched); A1=$(rv "$W" s1_latched); A2=$(rv "$W" s2_latched)
B1=$(rv "$W" s3_latched); B2=$(rv "$W" s4_latched); B3=$(rv "$W" s5_latched)
R0=$(rv "$W" s0_read); R1=$(rv "$W" s1_read); R2=$(rv "$W" s2_read)
R3=$(rv "$W" s3_read); R4=$(rv "$W" s4_read); R5=$(rv "$W" s5_read)
for v in A0 A1 A2 B1 B2 B3; do eval "[ -n \"\$$v\" ] || $v=0"; done

POST=$(dst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

ANY=$((A0 + A1 + A2 + B1 + B2 + B3))
lat() { [ "$1" = "1" ] && echo LATCHED || echo REFUSED; }

{
	hdr "the characterisation"
	say "baseline  0x314 = $(rv "$W" base_0x314)   0x30d = $(rv "$W" base_0x30d)"
	say "CHIP_CTL  0x000 = $CC0  (untouched: this run is about writability)"
	say ""
	say "  0x314 bit 0   mask 01  -> read $R0   $(lat "$A0")   diagnostic"
	say "  0x314 bit 1   mask 02  -> read $R1   $(lat "$A1")   diagnostic"
	say "  0x314 bits01  mask 03  -> read $R2   $(lat "$A2")   PRODUCTION"
	say ""
	say "  0x30d bit 1   mask 02  -> read $R3   $(lat "$B1")   PRODUCTION (HPHL)"
	say "  0x30d bit 2   mask 04  -> read $R4   $(lat "$B2")   PRODUCTION (HPHR)"
	say "  0x30d bits12  mask 06  -> read $R5   $(lat "$B3")   diagnostic"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "the run completed" "$RUN_RC" "0"
	check "characterisation ran" "$(rv "$W" done)" "1"

	say ""
	say "-- the codec stayed where it started --"
	check "still on RCO" "$(rv "$(cst)" source)" "RCO"
	check "CHIP_CTL untouched" "$(rv "$POST" chip_ctl_0x000)" "$CC0"
	check "0x314 back at baseline" "$(rv "$W" now_0x314)" "$(rv "$W" base_0x314)"
	check "0x30d back at baseline" "$(rv "$W" now_0x30d)" "$(rv "$W" base_0x30d)"

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "80"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- delta only"

	hdr "finding"
	if [ "$ANY" = "0" ]; then
		say "W0 -- NO DOCUMENTED BIT IN EITHER REGISTER LATCHES."
		say ""
		say "Six independent attempts, every one of them a bit downstream"
		say "actually writes, and not one held. That is a REGISTER-LEVEL or"
		say "DOMAIN-LEVEL condition, not a functional gate on a particular"
		say "bit: whatever is refusing does not distinguish between the"
		say "clock-power bits and the RDAC clock bits, or between HPHL and"
		say "HPHR."
		say ""
		say "It also means bit 2 of 0x30d -- the HPHR twin of the bit C2b"
		say "needs, never tried before this run -- refuses identically. The"
		say "two registers are in the same condition."
		say ""
		say "This does NOT settle write-only versus refused. Both produce"
		say "exactly this pattern, and telling them apart needs an OBSERVABLE"
		say "rather than a readback."
		say ""
		say "The untested conjunction -- MCLK selected AND the rate declared"
		say "-- is now the strongest remaining lead, and this result makes it"
		say "more attractive rather than less: a whole-register condition is"
		say "what a clock-domain prerequisite would look like."
	elif [ "$A2" = "1" ] && [ "$B1" = "1" ]; then
		say "W4 -- THE PRODUCTION BITS LATCH IN ISOLATION."
		say ""
		say "0x314 <- 03 and 0x30d bit 1 both held when written on their own,"
		say "from a pristine RCO baseline, with nothing else established."
		say ""
		say "So the registers are writable and the earlier refusals depend on"
		say "SURROUNDING SEQUENCE OR STATE, not on raw writability. Something"
		say "the C2b path establishes before reaching them is what makes them"
		say "refuse -- which is the opposite of every hypothesis this branch"
		say "has been pursuing, and is testable by bisecting the C2b"
		say "prerequisites."
		say ""
		say "Note this run wrote them from a bare baseline; C2b reaches them"
		say "with the compander, RX1, the DSM mux, RX bias and class-H all up."
	elif { [ "$A0" = "1" ] && [ "$A1" = "1" ] && [ "$A2" != "1" ]; } ||
	     { [ "$B1" = "1" ] && [ "$B2" = "1" ] && [ "$B3" != "1" ]; }; then
		say "W3 -- INDIVIDUAL BITS LATCH, THE COMBINED VALUE DOES NOT."
		say ""
		say "A combination or state interaction, and a very unusual one: the"
		say "same bits that hold separately refuse together. That points at"
		say "something sequenced inside the register rather than at a gate on"
		say "either bit."
		say ""
		say "For 0x314 this would also mean downstream's single full-byte"
		say "write of 0x03 is precisely the case that fails here, while"
		say "neither of its halves does."
	else
		say "W1/W2 -- PER-BIT GATING ESTABLISHED."
		say ""
		say "Some documented bits hold and others do not, so this is not a"
		say "whole-register or whole-domain condition. The refusing bit has a"
		say "dependency the latching one does not, and that dependency is now"
		say "the thing to map."
		say ""
		if [ "$A0" != "$A1" ]; then
			say "  0x314 is split: bit 0 $(lat "$A0"), bit 1 $(lat "$A1")."
			say "  These two are only ever written together downstream, so"
			say "  their bits have never been distinguished before."
		fi
		if [ "$B1" != "$B2" ]; then
			say "  0x30d is split: bit 1 (HPHL) $(lat "$B1"), bit 2 (HPHR)"
			say "  $(lat "$B2"). Same register, same mechanism, different"
			say "  channel -- so the condition is per-PATH, not per-register."
			say "  That is the sharpest result this run could have produced."
		fi
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

sed -n '/=== the characterisation ===/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 3
[ "$ANY" = "0" ] && exit 1
{ [ "$A2" = "1" ] && [ "$B1" = "1" ]; } && exit 0
if { [ "$A0" = "1" ] && [ "$A1" = "1" ] && [ "$A2" != "1" ]; } ||
   { [ "$B1" = "1" ] && [ "$B2" = "1" ] && [ "$B3" != "1" ]; }; then
	exit 4
fi
exit 2

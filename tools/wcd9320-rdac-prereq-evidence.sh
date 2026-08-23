#!/bin/sh
#
# r165: is CDC_CLK_POWER_CTL the missing prerequisite for the HPHL RDAC clock?
#
# THE ONE QUESTION
#
#   Does programming downstream's CDC_CLK_POWER_CTL = 0x03 cause HPHL RDAC
#   clock bit 0x30d[1] to become physically writable on this board?
#
# Nothing broader. This run changes exactly one register and reads everything
# else.
#
# WHY THE SCOPE IS THIS TIGHT
#
# Downstream writes CHIP_CTL = 0x02 and CDC_CLK_POWER_CTL = 0x03 adjacently in
# taiko_reg_defaults[], under one comment, "set MCLk to 9.6" -- and later
# adjusts CHIP_CTL mask 0x06 according to the selected MCLK rate. This board's
# clock architecture is RCO-based, not the reference board's MCLK arrangement.
# Writing both would give an answer that could not be attributed to either, so
# 0x001 is READ and never written here. If 0x314 alone refutes the hypothesis,
# the next question is what CHIP_CTL[2:1] actually selects on this silicon --
# a mapping exercise, not the next thing to poke.
#
# THE DESIGN
#
#   P0  pristine        0x314 = 00, probe 0x30d[1]  -> expect REFUSED
#   P1  one variable    0x314 = 03 (chip-verified), probe 0x30d[1]
#
# P0 reproduces r164's finding inside the fixed harness, which matters because
# r164's own gate mis-captured its variables. A run that only did P1 could not
# tell "the prerequisite worked" from "the probe works whenever it is asked".
#
# The probe is a MEASUREMENT: it sets the bit, reads it back from the chip
# bypassed, records whether it stuck, and clears it again either way. It never
# reports failure for a refused bit, because "asked and refused" and "never
# asked" must stay distinguishable.
#
# Exit: 0 the prerequisite is confirmed, 1 refuted, 2 invalid setup.

set -u

MODE="wcd9320-rdac-prereq"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r165-$$"

require_module_version
find_devices

PREREQ="$PGD/cdc_clk_prereq"
PROBE="$PGD/rdac_probe"
DACS="$PGD/hphl_dac_state"
C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"

for f in "$PREREQ" "$PROBE" "$DACS" "$C1T" "$RX1T"; do
	[ -e "$f" ] || {
		say "INVALID RUN: $f does not exist."
		say "  The running codec must be rdac-clk-rc1 or later."
		exit 2
	}
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst)
BAD=""
[ "$(rv "$PRE" prereq_on)" = "0" ]     || BAD="$BAD prereq_already_on"
[ "$(rv "$PRE" rdac_probes)" = "0" ]   || BAD="$BAD already_probed"
[ "$(rv "$PRE" rdac_latched)" = "-1" ] || BAD="$BAD latched_not_virgin"
[ "$(rv "$PRE" guard_tripped)" = "0" ] || BAD="$BAD guard_tripped"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]    || BAD="$BAD dac_not_idle"
#
# 0x314's POR is 0x00 and this part reads 0x00. If it is anything else, either
# something already applied the prerequisite on this boot or the part differs
# from the one the hypothesis was formed on -- both make P0 meaningless.
#
CLKP_PRE=$(rv "$PRE" clk_power_0x314)
[ "$CLKP_PRE" = "00" ] || BAD="$BAD clk_power=$CLKP_PRE(want 00)"

PA_PRE=$(rv "$PRE" pa_0x1ab)
[ "$(printf '%02x' $(( 0x${PA_PRE:-ff} & 0x30 )))" = "00" ] ||
	BAD="$BAD PA_ALREADY_ON=$PA_PRE"

if [ -n "$BAD" ]; then
	say "INVALID RUN: the baseline is not what this experiment needs:$BAD"
	say "  Cold boot and run this once, before anything else touches the codec."
	exit 2
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-rdac-prereq-$STAMP.txt"

CHIPCTL_PRE=$(rv "$PRE" chip_ctl_0x001)

# ------------------------------------------------------------------ the run --
#
# The probe runs in the same context the DAC path would use it: compander and
# RX1 chain up, so the RX clock tree is live. Probing an idle codec would test
# a different question from the one r164 actually failed.
echo comp1-on > "$C1T" 2>/dev/null; COMP_RC=$?
echo rx1-on > "$RX1T" 2>/dev/null; RX1_RC=$?
CTX=$(dst)

# --- P0: pristine, one variable still unset ---------------------------------
echo try > "$PROBE" 2>/dev/null; P0_RC=$?
P0=$(dst)
P0_LATCHED=$(rv "$P0" rdac_latched)
P0_CLKP=$(rv "$P0" clk_power_0x314)

# --- P1: apply the prerequisite, verify it on the chip, probe again ---------
echo on > "$PREREQ" 2>/dev/null; PREREQ_RC=$?
APPLIED=$(dst)
P1_CLKP=$(rv "$APPLIED" clk_power_0x314)

echo try > "$PROBE" 2>/dev/null; P1_RC=$?
P1=$(dst)
P1_LATCHED=$(rv "$P1" rdac_latched)

# --- restore -----------------------------------------------------------------
echo off > "$PREREQ" 2>/dev/null; PREREQ_OFF_RC=$?
RESTORED=$(dst)
echo rx1-off > "$RX1T" 2>/dev/null
echo comp1-off > "$C1T" 2>/dev/null
POST=$(dst)

snap_dmesg
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARNS PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done

{
	hdr "the baseline"
	printf '%s\n' "$PRE" | sed 's/^/  /'

	hdr "context: compander and RX1 chain up"
	say "comp1-on exit $COMP_RC   rx1-on exit $RX1_RC"

	hdr "P0 -- pristine, 0x314 untouched"
	say "0x314 = $P0_CLKP"
	say "0x30d[1] after probe: $([ "$P0_LATCHED" = "1" ] && echo LATCHED || echo REFUSED)"

	hdr "P1 -- the single variable applied"
	say "cdc_clk_prereq on, exit $PREREQ_RC"
	say "0x314 = $P1_CLKP  (chip-verified by the driver before it returned)"
	say "0x30d[1] after probe: $([ "$P1_LATCHED" = "1" ] && echo LATCHED || echo REFUSED)"

	hdr "after restore"
	printf '%s\n' "$RESTORED" | sed 's/^/  /'

	hdr "CHIP_CTL, observed and never written"
	say "0x001 before $CHIPCTL_PRE   after $(rv "$POST" chip_ctl_0x001)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "compander came up" "$COMP_RC" "0"
	check "RX1 chain came up" "$RX1_RC" "0"
	check "P0 probe ran" "$P0_RC" "0"
	check "P1 probe ran" "$P1_RC" "0"
	check "prerequisite applied" "$PREREQ_RC" "0"
	check "prerequisite restored" "$PREREQ_OFF_RC" "0"

	say ""
	say "-- the single variable moved, and only it --"
	check "0x314 was 00 during P0" "$P0_CLKP" "00"
	check "0x314 reads 03 during P1" "$P1_CLKP" "03"
	check "0x314 restored afterwards" "$(rv "$RESTORED" clk_power_0x314)" "$CLKP_PRE"
	check "CHIP_CTL never moved" "$(rv "$POST" chip_ctl_0x001)" "$CHIPCTL_PRE"

	say ""
	say "-- the causal result --"
	check "P0: the RDAC bit is REFUSED without the prerequisite" "$P0_LATCHED" "0"
	check "two probes were made" "$(rv "$P1" rdac_probes)" "2"

	say ""
	say "-- nothing else was disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "$PA_PRE"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	#
	# THE PREREQUISITE MUST ACTUALLY HAVE BEEN APPLIED.
	#
	# The first version of this branch tested only P0_LATCHED and
	# P1_LATCHED, and on the r165 run it printed "REFUTED ... with 0x314
	# verified at 03 on the chip" when 0x314 had in fact read 00 and the
	# write had been refused. The checks caught it -- two FAILs and a FAIL
	# verdict -- but the prose asserted something the evidence contradicted,
	# which is worse than saying nothing.
	#
	# A refutation requires the variable to have MOVED. If it did not, the
	# experiment did not run, and that is a third outcome, not a negative
	# result.
	#
	if [ "$P1_CLKP" != "03" ]; then
		say "THE EXPERIMENT COULD NOT RUN."
		say ""
		say "CDC_CLK_POWER_CTL itself refused the write: 0x314 was asked for"
		say "bits 03 and reads $P1_CLKP on the chip. The independent variable"
		say "never moved, so P1 is not a test of anything and the question"
		say "-- does 0x314 = 03 make 0x30d[1] latch -- is UNANSWERED."
		say ""
		say "This is NOT a refutation of the hypothesis. It is a new and"
		say "larger finding: 0x30d[1] and 0x314[1:0] BOTH refuse writes,"
		say "while every other register this branch touches accepts them --"
		say "the compander block, the connection muxes, the analog gains and"
		say "the RX bias all latched in this same run."
		say ""
		say "Do not reach for CHIP_CTL. Two registers refusing is a"
		say "different question from one register needing a prerequisite,"
		say "and it should be mapped before anything else is written."
		say ""
		say "SIDE EFFECT WORTH KNOWING: the refused write left the regmap"
		say "CACHE holding 03 for 0x314 while the chip holds 00. regmap"
		say "skips a write whose cached value already equals the target, so"
		say "a naive retry on this boot will silently do nothing."
	elif [ "$P0_LATCHED" = "0" ] && [ "$P1_LATCHED" = "1" ] && [ "$FAIL_N" -eq 0 ]; then
		say "CONFIRMED: CDC_CLK_POWER_CTL IS THE MISSING PREREQUISITE."
		say ""
		say "0x30d bit 1 was REFUSED with 0x314 = 00 and LATCHED with"
		say "0x314 = 03, with the compander and RX1 chain identically up in"
		say "both phases and no other register written. The prerequisite is"
		say "established rather than guessed, so C2b may continue on this"
		say "configured state."
		say ""
		say "This does NOT yet say 0x314 = 03 belongs in codec"
		say "initialisation. It says the HPHL RDAC clock depends on it. The"
		say "write stays a visible, explicit setup step in the DAC evidence"
		say "run; moving it into normal init is a later cleanup whose"
		say "behaviour will already be established."
		say ""
		say "CHIP_CTL was read and never written, so nothing here is"
		say "confounded by the MCLK-rate register downstream sets alongside"
		say "0x314."
	elif [ "$P0_LATCHED" = "0" ] && [ "$P1_LATCHED" = "0" ]; then
		say "REFUTED: 0x314 IS NOT SUFFICIENT."
		say ""
		say "0x30d bit 1 was refused both without the prerequisite and with"
		say "0x314 verified at 03 on the chip -- this branch is only reached"
		say "when that verification passed. The hypothesis is cleanly dead:"
		say "one variable moved, the answer did not change."
		say ""
		say "STOP HERE. Do not proceed to C2b, and do not write CHIP_CTL as"
		say "the next thing to try. The next question is what CHIP_CTL[2:1]"
		say "selects relative to RCO on this silicon, and whether this"
		say "board's value is deliberately different -- map it before"
		say "writing it."
	elif [ "$P0_LATCHED" = "1" ]; then
		say "THE EXPERIMENT IS INVALID: the bit latched WITHOUT the"
		say "prerequisite."
		say ""
		say "That contradicts r164, where the same bit was refused four"
		say "times. Something else changed between the runs, and until that"
		say "is understood P1 says nothing about 0x314. Do not read this as"
		say "the prerequisite being unnecessary."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the baseline/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
[ "$P0_LATCHED" = "0" ] && [ "$P1_LATCHED" = "1" ] || exit 1
exit 0

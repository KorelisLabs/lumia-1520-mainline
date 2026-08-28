#!/bin/sh
#
# r170: does declaring the MCLK rate in the REAL CHIP_CTL make the refused
# clock registers writable?
#
# THE CORRECTION THIS BUILD EXISTS FOR
#
# r165 to r169 defined CHIP_CTL as 0x001. 0x001 is CHIP_STATUS. The real
# CHIP_CTL is 0x000 -- three independent downstream generations agree, and our
# own low dump decodes correctly only that way. So five builds wrote a status
# register, reported its refusal as a silicon finding, and the 9.6 MHz rate
# declaration was never actually attempted.
#
# THE CHAIN THIS RUN TESTS, IN DOWNSTREAM'S OWN ORDER
#
# taiko_reg_defaults[] opens with these two entries, adjacent, under one
# comment, and nothing else in the driver writes either register:
#
#     /* set MCLk to 9.6 */
#     TAIKO_REG_VAL(TAIKO_A_CHIP_CTL, 0x02),
#     TAIKO_REG_VAL(TAIKO_A_CDC_CLK_POWER_CTL, 0x03),
#
# CHIP_CTL first, CLK_POWER second. That ordering has never been reproduced
# here. This run reproduces it and then retries the RDAC clock in the state it
# originally failed in.
#
# MASKED, AND WHY THE PREDICTION IS 0x0a AND NOT 0x02
#
# This part reads CHIP_CTL = 0x08 against a POR of 0x00. Bit 3 is set by
# something no header we hold describes. Downstream's snd_soc_write(0x02) is a
# full byte and would clear it; a masked 0x06 <- 0x02 preserves it and lands on
# 0x0a. Preserving an unexplained bit is the conservative choice, and changing
# it in the same act as the rate field would make a positive 0x314 result
# unattributable. The expectation is DERIVED from the measured baseline rather
# than hardcoded, so a part presenting a different bit 3 is still checked
# correctly.
#
# RCO ONLY. No PMIC divider, no gpio15, no MCLK selection. The MCLK branch is
# closed and this run does not touch it.
#
# NO DAC AND NO PA. 0x1b1 stays at 00 and is asserted at every stage.
#
# Exit: 0 = R4 chip_ctl, 0x314 and 0x30d all latch -- the blocker is gone
#       1 = R2 chip_ctl latches, 0x314 still refuses
#       2 = R3 chip_ctl and 0x314 latch, 0x30d still refuses under C2b state
#       4 = R1 chip_ctl itself refuses at the correct address
#       3 = S setup failure

set -u

MODE="wcd9320-chip-ctl"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r170-$$"

# dmesg is cumulative, so a second run on one boot double-counts step lines and
# fails itself. The driver logs this once per attempt, before anything moves.
DMESG_MARKER="${DMESG_MARKER:-chip-ctl: 0x000 measured}"

require_module_version
find_devices

CCT="$PGD/chip_ctl_test"
PREREQ="$PGD/cdc_clk_prereq"
PROBE="$PGD/rdac_probe"
DACT="$PGD/hphl_dac_test"
DACS="$PGD/hphl_dac_state"
C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"

for f in "$CCT" "$PREREQ" "$PROBE" "$DACT" "$DACS" "$C1T" "$RX1T"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst)
BAD=""
[ "$(rv "$PRE" guard_tripped)" = "0" ]     || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" pa_0x1ab)" = "80" ]         || BAD="$BAD pa_not_at_baseline"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]        || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" prereq_on)" = "0" ]         || BAD="$BAD prereq_already_on"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ]  || BAD="$BAD 0x314_not_at_por"
[ "$(rv "$PRE" rdac_0x30d)" = "00" ]       || BAD="$BAD 0x30d_not_at_por"
[ "$(rv "$PRE" on)" = "0" ]                || BAD="$BAD c2b_already_up"

#
# THE BASELINE THE WHOLE RUN RESTS ON.
#
# CHIP_CTL must be readable and must currently declare 12.288 MHz, i.e. rate
# bits clear. If the field is already 0x2 then something else set it and the
# experiment has no independent variable.
#
CC0=$(rv "$PRE" chip_ctl_0x000)
case "$CC0" in
	"" ) BAD="$BAD chip_ctl_unreadable" ;;
	* )
		# rate bits are 0x06; require them clear
		RATE=$(( 0x$CC0 & 0x06 ))
		[ "$RATE" = "0" ] || BAD="$BAD chip_ctl_rate_already_set"
		;;
esac
# CHIP_STATUS is reported so the transposition is visible, and is never written.
CS0=$(rv "$PRE" chip_status_0x001)

if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not what this experiment needs:$BAD"
	say "  chip_ctl 0x000 = $CC0   chip_status 0x001 = $CS0"
	say "  Cold boot and run this once, before anything else touches the codec."
	exit 3
fi

# The prediction, derived here as well as in the driver, so the evidence file
# carries an expectation computed independently of the code under test.
WANT_CC=$(printf '%02x' $(( (0x$CC0 & 0xf9) | 0x02 )))

snap_dmesg
open_output "$OUTDIR/wcd9320-chip-ctl-$STAMP.txt"

WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------------- baseline behaviour --
# Reproduce the refusal in THIS harness before anything changes, so the run
# carries its own control rather than citing r165's.
echo on > "$PREREQ" 2>/dev/null
B_314=$(rv "$(dst)" clk_power_0x314)
[ "$B_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null
echo try > "$PROBE" 2>/dev/null
B_RDAC=$(rv "$(dst)" rdac_latched)

# ------------------------------------------- STEP 1: the rate declaration ---
echo on > "$CCT" 2>/dev/null; CC_RC=$?
AFTER=$(dst)
CC1=$(rv "$AFTER" chip_ctl_0x000)
CC_LATCHED=$(rv "$AFTER" chip_ctl_latched)
CC_EXPECT=$(rv "$AFTER" chip_ctl_expected)

# ------------------------------------------- STEP 2: 0x314, immediately -----
A_314="n/a"
if [ "$CC_LATCHED" = "1" ]; then
	echo on > "$PREREQ" 2>/dev/null
	A_314=$(rv "$(dst)" clk_power_0x314)
fi

# ------------------------- STEP 3: 0x30d, under the REAL C2b prerequisites --
#
# Not a naked probe. r164's negative was obtained with RX1, the compander, the
# DSM mux, RX bias and class-H all established, and a result from a different
# state would not be comparable with it. The DAC is NOT powered: prereq-on runs
# stages 3 to 6 and stops.
#
C1_RC="n/a"; RX1_RC="n/a"; C2B_RC="n/a"; A_RDAC="n/a"; A_30D="n/a"
if [ "$A_314" = "03" ]; then
	echo comp1-on > "$C1T" 2>/dev/null; C1_RC=$?
	echo rx1-on > "$RX1T" 2>/dev/null; RX1_RC=$?
	echo prereq-on > "$DACT" 2>/dev/null; C2B_RC=$?
	A_30D=$(rv "$(dst)" rdac_0x30d)
	[ "$C2B_RC" = "0" ] && A_RDAC=1 || A_RDAC=0
fi

# ----------------------------------------- teardown, in DEPENDENCY ORDER ----
# RDAC clock first, then 0x314, then CHIP_CTL last -- the inverse of the order
# they were established in. Every inverse is chip-verified by the driver.
[ "$C2B_RC" = "0" ] && echo prereq-off > "$DACT" 2>/dev/null
[ "$RX1_RC" = "0" ] && echo rx1-off > "$RX1T" 2>/dev/null
[ "$C1_RC" = "0" ] && echo comp1-off > "$C1T" 2>/dev/null
echo off > "$PREREQ" 2>/dev/null
echo off > "$CCT" 2>/dev/null; CCOFF_RC=$?
POST=$(dst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

{
	hdr "baseline, on the RC oscillator"
	say "chip_ctl   0x000 = $CC0   (rate bits clear = 12.288 MHz declared)"
	say "chip_status 0x001 = $CS0   (a STATUS register -- never written)"
	say "0x314 = $B_314    0x30d[1] $([ "$B_RDAC" = "1" ] && echo LATCHED || echo REFUSED)"

	hdr "step 1 -- the rate declaration, at the real address"
	say "0x000 mask 06 <- 02 : $CC0 -> $CC1   predicted $WANT_CC (driver derived $CC_EXPECT)"
	say "result: $([ "$CC_LATCHED" = "1" ] && echo LATCHED || echo REFUSED)"

	hdr "step 2 -- CDC_CLK_POWER_CTL, in downstream's order"
	say "0x314 = $A_314"

	hdr "step 3 -- the RDAC clock, under the full C2b prerequisite state"
	say "stages 3-6 rc=$C2B_RC   0x30d = $A_30D"
	say "the DAC was NOT powered: 0x1b1 = $(rv "$POST" dac_0x1b1)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "chip_ctl prediction agrees with the driver" "$CC_EXPECT" "$WANT_CC"

	say ""
	say "-- the rate declaration --"
	check "chip_ctl_test returned 0" "$CC_RC" "0"
	check_cond "0x000 physically changed" \
		"$([ "$CC1" != "$CC0" ] && echo 1 || echo 0)" \
		"0x000 still reads $CC0" "$CC0 -> $CC1"
	check "0x000 reads the derived expectation" "$CC1" "$WANT_CC"
	check "CHIP_STATUS never written" "$(rv "$POST" chip_status_0x001)" "$CS0"

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "80"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "0x314 restored" "$(rv "$POST" clk_power_0x314)" "00"
	check "0x30d restored" "$(rv "$POST" rdac_0x30d)" "00"
	check "CHIP_CTL restored" "$(rv "$POST" chip_ctl_0x000)" "$CC0"
	check "chip_ctl_test off returned 0" "$CCOFF_RC" "0"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- delta only"

	hdr "finding"
	if [ "$CC_LATCHED" != "1" ]; then
		say "R1 -- CHIP_CTL REFUSES AT THE CORRECT ADDRESS."
		say ""
		say "0x000 mask 06 <- 02 left the register reading $CC1, where $WANT_CC"
		say "was derived from its own measured baseline of $CC0."
		say ""
		say "This is now a real result about the top-level control register,"
		say "and the first one this project has had: the previous refusals were"
		say "at 0x001, which is CHIP_STATUS and was never going to accept a"
		say "write. So there IS an access or state problem around CHIP_CTL"
		say "itself, and 0x314 was not retried because its stated prerequisite"
		say "could not be established."
		say ""
		say "Do not proceed to the DAC or the PA. The next question is what"
		say "gates writes to the top-level control register."
	elif [ "$A_314" != "03" ]; then
		say "R2 -- CHIP_CTL LATCHES, 0x314 STILL REFUSES."
		say ""
		say "The rate declaration took: 0x000 went $CC0 -> $CC1, chip-verified,"
		say "with the unexplained bit 3 preserved. Immediately afterwards"
		say "0x314 <- 03 read back $A_314."
		say ""
		say "So downstream's adjacency and ordering are NOT sufficient. The two"
		say "registers are written together in taiko_reg_defaults[] because"
		say "they belong to one initialisation step, not because the first"
		say "unlocks the second. 0x314 has another prerequisite, and it is not"
		say "the clock (r169) and not the rate declaration (this run)."
		say ""
		say "Candidate 1 from the audit is refuted. Candidate 3 -- that 0x314"
		say "is write-only on this silicon and downstream cannot tell, because"
		say "taiko_read() returns the ASoC cache for it -- is now the strongest"
		say "remaining, and needs an observable rather than a readback."
	elif [ "$A_RDAC" != "1" ]; then
		say "R3 -- CHIP_CTL AND 0x314 LATCH, 0x30d STILL REFUSES."
		say ""
		say "This is a large result. The general clock-configuration problem is"
		say "solved: declaring the rate in the real CHIP_CTL made"
		say "CDC_CLK_POWER_CTL writable, which is exactly downstream's ordering"
		say "and exactly what five builds could not test because the rate was"
		say "being written to a status register."
		say ""
		say "0x30d[1] still did not take, and it was retried in the state it"
		say "originally failed in -- RX1, compander, DSM mux, RX bias and"
		say "class-H all established -- so this is comparable with r164 rather"
		say "than a weaker naked probe."
		say ""
		say "The RDAC clock therefore has its own remaining condition. The"
		say "audit's candidate 2, an interlock with the analog DAC power state,"
		say "is now the one to test -- and it is the only one left that the DAC"
		say "milestone itself would settle."
	else
		say "R4 -- ALL THREE WRITES LATCH."
		say ""
		say "CHIP_CTL took the 9.6 MHz declaration, CDC_CLK_POWER_CTL took 0x03"
		say "immediately afterwards in downstream's own order, and the HPHL"
		say "RDAC clock enable took under the full C2b prerequisite state."
		say ""
		say "The blocker that stopped C2b at stage 6 of 7 is very probably"
		say "gone, and its cause was a single incorrect register constant:"
		say "CHIP_CTL was being written to 0x001, which is CHIP_STATUS."
		say ""
		say "The next milestone returns to C2b stage 7 -- 0x1b1 <- 0xc0, the"
		say "DAC input switch and power bit -- which r170 deliberately did not"
		say "touch. The PA stays off there too; that is a conversion and"
		say "routing result, not an audible one."
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

sed -n '/=== baseline, on the RC/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
[ "$CC_LATCHED" = "1" ] || exit 4
[ "$A_314" = "03" ] || exit 1
[ "$A_RDAC" = "1" ] || exit 2
exit 0

#!/bin/sh
#
# r168: with the board's 9.6 MHz MCLK established AND the codec switched onto
# it, do the two refused clock registers accept writes?
#
# THE ONE QUESTION
#
#   r167 proved the external path as far as the PMIC pad -- DIV_CTL1 = 2,
#   gpio15 on func1 = DIV_CLK, the RPM enable vote held, all of it re-read
#   AFTER the vote transition -- and CDC_CLK_POWER_CTL (0x314) and
#   CDC_CLK_RDAC_CLK_EN_CTL (0x30d) bit 1 still refused while the codec ran
#   from its RC oscillator. So: does the codec have to be RUNNING FROM that
#   clock?
#
# WHAT MOVES, AND WHAT IS FROZEN
#
# Frozen: the whole PMIC side. r167's configuration is a prerequisite here,
# re-established and not re-investigated. No clkdiv provider, no
# CONFIG_SPMI_PMIC_CLKDIV, nothing writes 0x5b43 that did not write it in
# r167.
#
# Moves: the codec's clock source, CLK_BUFF_EN1. That is the only change.
#
# WHY CHIP_CTL IS NO LONGER PART OF THE SWITCH (r169)
#
# r168 wrote CHIP_CTL[2:1] = 0x2 as step 2, before the switch, to declare the
# 9.6 MHz rate. THE PART REFUSED THE WRITE -- 0x001 read back 00 -- and the run
# aborted before the clock block was touched, returning no conclusion.
#
# That refusal is itself the finding. 0x001 joins 0x314 and 0x30d[1], and the
# three of them share exactly one property: they are MCLK-domain registers on a
# codec that has never had an MCLK. Downstream corroborates the grouping --
# taiko_reg_defaults[] opens with CHIP_CTL = 0x02 and CDC_CLK_POWER_CTL = 0x03,
# adjacent, under one "set MCLk to 9.6" comment, on a board where the MCLK is
# already running when that executes.
#
# So the order inverts: switch first, then attempt the rate declaration against
# a codec running from the external clock. The write is a MEASUREMENT that
# never gates anything. This also means the codec is switched while declaring
# 12.288 MHz against a 9.6 MHz input -- not a choice any more, but the only
# configuration the hardware permits.
#
# WHY THERE IS A POSITIVE CONTROL, AND WHY THE RUN IS VOID WITHOUT IT
#
# A CDC-block register reading 00 is ambiguous between "the write was refused"
# and "the block has no clock and reads as zero". If the codec is switched onto
# an MCLK that is not physically arriving, the second is exactly what happens --
# and reporting that as "MCLK still insufficient" would be a false negative
# that looked like a clean result.
#
# So three CDC-block registers with known non-zero POR contents -- 0x2b4 = 78,
# 0x370 = 30, 0x373 = 37 -- are read before and after the switch. They are the
# instrument: if they hold, the CDC block is responding and a refusal is a real
# refusal; if they read 00, the core is unclocked and this run says NOTHING
# about the RDAC question.
#
# THE SWITCH IS NOT A HOT SWAP
#
# Downstream's get_clk_block(MCLK) from an RCO state calls
# disable_clock_block() and only then enable_clock_block(0), so the codec
# passes through a state with no clock at all -- and enabling on MCLK disables
# the RC oscillator, so there is no warm fallback. Recovery is nonetheless
# guaranteed in software: codec register access rides the SLIMbus interface
# function and does not depend on the CDC clock, which is why downstream can
# issue eight register writes while the block is off. The driver's teardown
# runs unconditionally, including from a mid-sequence abort.
#
# Exit: 0 = M4 registers accepted with the control intact
#       1 = M2' real refusal with the control intact, or a failed check
#       2 = M5 the CDC block went dark -- no clock is arriving, no conclusion
#       3 = S setup failure

set -u

MODE="wcd9320-clk-source"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r168-$$"

require_module_version
find_devices

CSRCT="$PGD/clk_source_test"
CSRCS="$PGD/clk_source_state"
MCLKT="$PGD/mclk_test"
MCLKS="$PGD/mclk_state"
PREREQ="$PGD/cdc_clk_prereq"
PROBE="$PGD/rdac_probe"
DACS="$PGD/hphl_dac_state"

# The r167 experiment device: a PM8941 child, so it is on the platform bus.
DIVD=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -d "$d" ] && { DIVD="$d"; break; }
done
[ -n "$DIVD" ] || {
	say "INVALID RUN: the MCLK experiment device did not probe."
	say "  Looked for *mclk-divider-experiment* on the platform bus."
	exit 3
}
DIVT="$DIVD/mclk_div_test"
DIVS="$DIVD/mclk_div_state"

for f in "$CSRCT" "$CSRCS" "$MCLKT" "$MCLKS" "$PREREQ" "$PROBE" "$DACS" \
         "$DIVT" "$DIVS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
cst() { cat "$CSRCS" 2>/dev/null; }
dst() { cat "$DACS" 2>/dev/null; }
mst() { cat "$MCLKS" 2>/dev/null; }
divst() { cat "$DIVS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst); MPRE=$(mst); DPRE=$(divst); CPRE=$(cst)
BAD=""
[ "$(rv "$MPRE" present)" = "1" ]          || BAD="$BAD no_mclk_clock_in_dt"
[ "$(rv "$MPRE" refs)" = "0" ]             || BAD="$BAD mclk_already_held"
[ "$(rv "$DPRE" applied)" = "0" ]          || BAD="$BAD divider_already_applied"
[ "$(rv "$DPRE" factor)" = "0" ]           || BAD="$BAD divider_not_at_1"
[ "$(rv "$CPRE" on_mclk)" = "0" ]          || BAD="$BAD already_on_mclk"
[ "$(rv "$CPRE" source)" = "RCO" ]         || BAD="$BAD codec_not_on_rco"
[ "$(rv "$CPRE" chip_ctl_0x001)" = "00" ]  || BAD="$BAD chip_ctl_not_at_por"
[ "$(rv "$PRE" prereq_on)" = "0" ]         || BAD="$BAD prereq_already_on"
[ "$(rv "$PRE" guard_tripped)" = "0" ]     || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]        || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ]  || BAD="$BAD 0x314_not_at_por"
#
# The positive control has to hold its POR values BEFORE the switch, or it
# cannot discriminate afterwards. This is the instrument's own calibration and
# a run without it is void, not merely inconclusive.
#
[ "$(rv "$CPRE" cdc_alive)" = "1" ]        || BAD="$BAD positive_control_not_at_por"
if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not what this experiment needs:$BAD"
	say "  Cold boot and run this once, before anything else touches the codec."
	say "  positive control: $(rv "$CPRE" ctl_0x2b4) $(rv "$CPRE" ctl_0x370) $(rv "$CPRE" ctl_0x373)"
	say "  wanted          : $(rv "$CPRE" want_0x2b4) $(rv "$CPRE" want_0x370) $(rv "$CPRE" want_0x373)"
	exit 3
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-clk-source-$STAMP.txt"

# Warnings are judged as a DELTA, not as the buffer's contents: the r167 run
# was failed by 88 warnings that predated it by 140 seconds, every one from a
# debugfs regmap dump of the PMIC walking unimplemented addresses.
WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------------- baseline behaviour --
# Reproduce the refusal in THIS harness, on RCO, before anything is switched --
# so the run carries its own control rather than citing r167's.
#
# The compander and RX1 chain are deliberately NOT brought up. Both would move
# registers in the positive control set, and r165 established by measurement
# that neither affects whether these two registers latch.
echo try > "$PROBE" 2>/dev/null
B_RDAC=$(rv "$(dst)" rdac_latched)
echo on > "$PREREQ" 2>/dev/null
B_314=$(rv "$(dst)" clk_power_0x314)
[ "$B_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null

# ------------------------------------- re-establish the r167 path (frozen) --
echo on > "$DIVT" 2>/dev/null; DIV_RC=$?
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?

# The path is judged on POST-VOTE values only: RPM owns the resource and could
# rewrite the peripheral when its vote changes.
POSTVOTE=$(divst)
P_FACTOR=$(rv "$POSTVOTE" factor)
P_FUNC=$(rv "$POSTVOTE" function)
P_DIR=$(rv "$POSTVOTE" dir)
P_EN=$(rv "$POSTVOTE" enabled)

# Direction is 1 OR 2. pinctrl-spmi-gpio encodes MODE_CTL[6:4] as 0 input,
# 1 output, 2 input+output, and the pad state persists across state changes.
# Asserting == 1 cost a run in r167; only 0 means the pad is not driven.
pa_driven() { [ "$1" = "1" ] || [ "$1" = "2" ]; }

PATH_OK=1
[ "$P_FACTOR" = "2" ] || PATH_OK=0
[ "$P_FUNC" = "2" ]   || PATH_OK=0	# pinctrl index 2 == func1 == DIV_CLK
pa_driven "$P_DIR"    || PATH_OK=0
[ "$P_EN" = "1" ]     || PATH_OK=0
[ "$DIV_RC" = "0" ]   || PATH_OK=0
[ "$MCLK_RC" = "0" ]  || PATH_OK=0

# ------------------------------------------------- THE SWITCH, and the test --
SW_RC="n/a"; S_SOURCE="n/a"; S_ALIVE="n/a"; S_CHIP="n/a"; S_CHIPLAT="n/a"
A_RDAC="n/a"; A_314="n/a"
S_C1="n/a"; S_C2="n/a"; S_C3="n/a"
SWITCH_OK=0

if [ "$PATH_OK" = "1" ]; then
	echo mclk > "$CSRCT" 2>/dev/null; SW_RC=$?
	SWITCHED=$(cst)
	S_SOURCE=$(rv "$SWITCHED" source)
	S_ALIVE=$(rv "$SWITCHED" cdc_alive)
	S_CHIP=$(rv "$SWITCHED" chip_ctl_0x001)
	S_CHIPLAT=$(rv "$SWITCHED" chip_ctl_latched)
	S_C1=$(rv "$SWITCHED" ctl_0x2b4)
	S_C2=$(rv "$SWITCHED" ctl_0x370)
	S_C3=$(rv "$SWITCHED" ctl_0x373)

	[ "$SW_RC" = "0" ] && [ "$S_SOURCE" = "EXTERNAL" ] && SWITCH_OK=1
fi

#
# THE RETRY NEEDS BOTH CONDITIONS, AND r168 PROVED IT.
#
# This used to be gated on cdc_alive alone. In the r168 run the switch aborted
# at its first write and never touched the clock block, so the codec was still
# on RCO -- and because cdc_alive is computed live from three registers that
# were therefore untouched, it read 1 and the retry ran anyway. It reproduced
# the ordinary RCO-baseline refusal, and the evidence file filed it under "the
# retry, run only against a responding CDC block", which is exactly the kind of
# label that gets read later as an MCLK result.
#
# So the retry now requires that the switch ACTUALLY HAPPENED as well as that
# the block is responding. A retry on RCO is the baseline, not the experiment.
#
if [ "$SWITCH_OK" = "1" ] && [ "$S_ALIVE" = "1" ]; then
	echo try > "$PROBE" 2>/dev/null
	A_RDAC=$(rv "$(dst)" rdac_latched)
	echo on > "$PREREQ" 2>/dev/null
	A_314=$(rv "$(dst)" clk_power_0x314)
	[ "$A_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null
fi

# ------------------------------------------------------------- restore ------
# Unconditional: the driver's own teardown also runs from a mid-sequence abort,
# and this is the outer half of the same guarantee.
echo rco > "$CSRCT" 2>/dev/null; RST_RC=$?
RESTORED=$(cst)
R_SOURCE=$(rv "$RESTORED" source)
R_ALIVE=$(rv "$RESTORED" cdc_alive)
R_CHIP=$(rv "$RESTORED" chip_ctl_0x001)

echo off > "$MCLKT" 2>/dev/null
echo off > "$DIVT" 2>/dev/null
POST=$(dst); MPOST=$(mst); DPOST=$(divst); CPOST=$(cst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

UNLOCKED=0
{ [ "$A_RDAC" = "1" ] || [ "$A_314" = "03" ]; } && UNLOCKED=1

{
	hdr "baseline, on the RC oscillator, before anything was configured"
	say "codec source $(rv "$CPRE" source)   chip_ctl $(rv "$CPRE" chip_ctl_0x001)"
	say "positive control 0x2b4=$(rv "$CPRE" ctl_0x2b4) 0x370=$(rv "$CPRE" ctl_0x370) 0x373=$(rv "$CPRE" ctl_0x373)  alive=$(rv "$CPRE" cdc_alive)"
	say "0x30d[1] $([ "$B_RDAC" = "1" ] && echo LATCHED || echo REFUSED)    0x314 $B_314"

	hdr "the r167 path, re-established and re-read after the RPM vote"
	say "DIV_CTL1 factor $P_FACTOR   gpio15 dir $P_DIR function $P_FUNC   enabled $P_EN"

	hdr "after the switch to MCLK"
	say "codec source : $S_SOURCE"
	say "positive control 0x2b4=$S_C1 0x370=$S_C2 0x373=$S_C3"
	say "CDC block    : $([ "$S_ALIVE" = "1" ] && echo RESPONDING || echo DARK)"

	hdr "CHIP_CTL retried ON MCLK -- the register r168 could not write"
	say "0x001 reads $S_CHIP, rate bits $([ "$S_CHIPLAT" = "1" ] && echo LATCHED || echo REFUSED)"
	say "(on RCO, before the switch, it read $(rv "$CPRE" chip_ctl_0x001) and r168 could not write it at all)"

	hdr "the retry, run only after a completed switch AND a responding block"
	say "0x30d[1] : $([ "$A_RDAC" = "1" ] && echo LATCHED || echo "$A_RDAC")"
	say "0x314    : $A_314"

	hdr "after the restore to RCO"
	say "codec source : $R_SOURCE   chip_ctl : $R_CHIP   CDC alive : $R_ALIVE"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "divider configured" "$DIV_RC" "0"
	check "RPM vote taken" "$MCLK_RC" "0"

	say ""
	say "-- the frozen r167 path, after the vote transition --"
	check "divide factor still 2" "$P_FACTOR" "2"
	check "gpio15 still function 2 (func1)" "$P_FUNC" "2"
	check_cond "gpio15 still driven (dir 1 or 2)" \
		"$(pa_driven "$P_DIR" && echo 1 || echo 0)" \
		"dir $P_DIR means the pad is not driven" "dir $P_DIR"
	check "divider still enabled" "$P_EN" "1"

	say ""
	say "-- the switch itself --"
	check "switch to MCLK returned 0" "$SW_RC" "0"
	check "codec selects EXTERNAL" "$S_SOURCE" "EXTERNAL"
	check_sequence_complete "clk-src block-off"
	check_sequence_complete "clk-src mclk-tail"
	#
	# CHIP_CTL is NOT checked for a value. Whether it latches is the
	# measurement, and a gate that required 02 would fail the run for
	# reporting its own result -- which is what r168 did.
	#
	note "CHIP_CTL on MCLK" "0x001=$S_CHIP latched=$S_CHIPLAT (measured, not required)"

	say ""
	say "-- the restore, which is the recovery guarantee --"
	check "restore returned 0" "$RST_RC" "0"
	check "codec back on RCO" "$R_SOURCE" "RCO"
	check "CDC responding after the restore" "$R_ALIVE" "1"
	check "CHIP_CTL restored" "$R_CHIP" "$(rv "$CPRE" chip_ctl_0x001)"
	check_sequence_complete "clk-src rco-restore"

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "$(rv "$PRE" pa_0x1ab)"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "0x314 back at POR" "$(rv "$CPOST" clk_power_0x314)" "00"
	check "0x30d back at POR" "$(rv "$CPOST" rdac_0x30d)" "00"
	check "divider restored" "$(rv "$DPOST" factor)" "$(rv "$DPRE" factor)"
	check "mclk released" "$(rv "$MPOST" refs)" "0"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- only the delta is judged"

	hdr "finding"
	if [ "$PATH_OK" != "1" ]; then
		say "S -- THE FROZEN r167 PATH DID NOT RE-ESTABLISH. No conclusion."
		say ""
		say "  factor $P_FACTOR (want 2), function $P_FUNC (want 2 = func1),"
		say "  dir $P_DIR (want 1 or 2), enabled $P_EN (want 1)."
		say ""
		say "This is a prerequisite failure, NOT a result about the codec."
	elif [ "$SW_RC" != "0" ] || [ "$S_SOURCE" != "EXTERNAL" ]; then
		say "S -- THE SWITCH DID NOT COMPLETE. No conclusion."
		say ""
		say "The driver's teardown runs unconditionally from a mid-sequence"
		say "abort, so the codec should be back on its RC oscillator; the"
		say "restore checks above say whether it is. Read the clk-src step"
		say "lines in dmesg: the sequence aborts at the first register that"
		say "does not read back what was requested, and names it."
	elif [ "$S_ALIVE" != "1" ]; then
		say "M5 -- THE CDC BLOCK WENT DARK. NO RDAC CONCLUSION."
		say ""
		say "The positive control read 0x2b4=$S_C1 0x370=$S_C2 0x373=$S_C3"
		say "where the POR values are 78, 30 and 37. Those registers were"
		say "holding their defaults immediately before the switch, and the"
		say "only thing that changed is which clock the codec selects."
		say ""
		say "So the CDC core stopped when it was taken off its RC oscillator,"
		say "which means NO CLOCK IS ARRIVING at the codec's MCLK pin -- the"
		say "codec is acting as its own clock detector and the answer is no."
		say ""
		say "THIS SAYS NOTHING ABOUT 0x30d OR 0x314. The retry was deliberately"
		say "not run: on a dark block both would read 00 for a reason that has"
		say "nothing to do with whether the writes are refused."
		say ""
		say "What it DOES establish is the missing half of r167. The PMIC-side"
		say "path is configured correctly as far as software can see -- factor,"
		say "enable bit and pad mux all verified after the RPM vote -- and the"
		say "clock still does not reach the codec. The next question is the"
		say "physical route from PM8941 gpio15 to the WCD9320 MCLK pin on"
		say "RM-940, and that needs measurement, not more register work."
	elif [ "$UNLOCKED" = "1" ]; then
		say "M4 -- SWITCHED TO MCLK, CLOCK REGISTERS ACCEPTED."
		say ""
		say "THE CLAIM, STATED AS NARROWLY AS THE EVIDENCE ALLOWS:"
		say ""
		say "  With the PM8941 DIV_CLK1 /2 path configured and gpio15 routed"
		say "  as DIV_CLK, switching the WCD9320 onto that clock caused the"
		say "  previously refused clock-domain register(s) to become writable."
		say ""
		say "  The clock source is the ONLY thing this run changed on the"
		say "  codec. CHIP_CTL was not written before the switch -- r168"
		say "  proved the part refuses that -- so there is no second variable"
		say "  to attribute the unlock to."
		say ""
		say "  The CDC block kept running across the switch, which is"
		say "  independent corroboration that a clock is physically arriving:"
		say "  the positive control held its POR values with the RC oscillator"
		say "  disabled."
		say ""
		if [ "$S_CHIPLAT" = "1" ]; then
			say "CHIP_CTL ALSO BECAME WRITABLE (0x001 = $S_CHIP). Three"
			say "registers that refused on RCO -- 0x001, 0x314, 0x30d[1] --"
			say "all accept once the codec runs from the external clock."
			say "That is the MCLK-domain hypothesis confirmed on all three,"
			say "and it explains every refusal this branch has hit."
		else
			say "CHIP_CTL still refuses (0x001 = $S_CHIP) even on MCLK, while"
			say "0x314/0x30d do not. So 0x001 is NOT in the same class after"
			say "all, and the codec is running at a declared 12.288 MHz"
			say "against a 9.6 MHz input. Anything rate-dependent from here"
			say "is suspect until that is understood."
		fi
		say ""
		say "WHAT IT DOES NOT CLAIM. Not that 9.6 MHz was measured at the"
		say "codec's MCLK pin; nothing here observes the pad."
		say ""
		say "C2b may resume, but only with the codec on MCLK."
	else
		say "M2' -- SWITCHED TO MCLK, REGISTERS STILL REFUSED."
		say ""
		say "The positive control held across the switch -- 0x2b4=$S_C1"
		say "0x370=$S_C2 0x373=$S_C3, all at their POR values with the RC"
		say "oscillator disabled -- so the CDC block IS clocked and IS"
		say "responding, and a refusal is a real refusal rather than a dark"
		say "block reading zero."
		say ""
		say "That is a genuine negative, and a strong one. It also establishes"
		say "something r167 could not: a clock really is arriving at the codec,"
		say "because the digital core kept running on it with the RC oscillator"
		say "off. The external MCLK is therefore present, routed and selected"
		say "-- and 0x314 and 0x30d[1] still will not take."
		say ""
		if [ "$S_CHIPLAT" = "1" ]; then
			say "NOTE THE SPLIT. CHIP_CTL DID latch on MCLK (0x001 = $S_CHIP)"
			say "having refused on RCO. So being on MCLK genuinely does unlock"
			say "an MCLK-domain register -- just not these two. That separates"
			say "0x314 and 0x30d[1] from 0x001 and makes the remaining refusal"
			say "much narrower than 'the clock'."
		else
			say "CHIP_CTL also still refuses (0x001 = $S_CHIP), so all three"
			say "registers refuse even with the codec running on the external"
			say "clock. Being on MCLK is not the unlock for any of them."
		fi
		say ""
		say "The MCLK hypothesis for these two registers is now exhausted. The"
		say "next question is not the clock. Do NOT reach for the DAC or the"
		say "PA to work around it."
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

[ "$PATH_OK" = "1" ] || exit 3
[ "$SW_RC" = "0" ] || exit 3
[ "$S_ALIVE" = "1" ] || exit 2
[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
[ "$UNLOCKED" = "1" ] || exit 1
exit 0

#!/bin/sh
#
# r167: does establishing the board's 9.6 MHz MCLK unlock the refused clock
# registers, while the codec still runs from its RC oscillator?
#
# THE ONE QUESTION
#
#   With PM8941 DIV_CTL1 at /2, gpio15 muxed to DIV_CLK, and the RPM enable
#   vote taken -- and with the WCD9320 still internally selecting RCO -- do
#   CDC_CLK_POWER_CTL (0x314) and CDC_CLK_RDAC_CLK_EN_CTL (0x30d) bit 1 accept
#   writes?
#
# WHY THE CODEC STAYS ON RCO
#
# Supplying a clock and selecting it are two changes. r167 makes only the
# first, so a positive result is attributable to the clock being PRESENT rather
# than SELECTED. The artefact gate proves the driver has no write site for
# CLK_BUFF_EN1 (0x108), so this is enforced and not merely intended. If the
# answer is no, the source switch becomes r168 with the clock already proven.
#
# THE OWNERSHIP SPLIT THIS ENCODES
#
#   RPM          owns the enable vote     -- taken via <&rpmcc RPM_SMD_DIV_A_CLK1>
#   AP software  owns the divide factor   -- DIV_CTL1 = 2, as downstream's
#                                            qpnp_clkdiv_config(Q_CLKDIV_XO_DIV_2)
#                                            and msm8974-clock.dtsi's
#                                            qcom,cxo-div = <2> both do
#   pinctrl      owns the routing         -- gpio15 func1 = DIV_CLK
#
# THE MANDATORY RE-READ
#
# RPM owns the resource. Proving /2 immediately after the AP writes it is NOT
# enough: RPM could rewrite the peripheral when its vote changes. So the
# divider AND the pin mux are re-read AFTER the RPM vote transition, and it is
# those post-vote values the verdict rests on.
#
# clk_get_rate() TAKES NO PART IN ANY VERDICT. div_clk1 is a branch clock whose
# recalc_rate reports a fixed nominal 19.2 MHz and never reads DIV_CTL1. The
# PMIC register is the only witness to the physical divider.
#
# Exit: 0 = M3 unlocked, 1 = M2 still refused, 2 = M1 path not established,
#       3 = S setup failure.

set -u

MODE="wcd9320-mclk"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r167-$$"

require_module_version
find_devices

MCLKT="$PGD/mclk_test"
MCLKS="$PGD/mclk_state"
PREREQ="$PGD/cdc_clk_prereq"
PROBE="$PGD/rdac_probe"
DACS="$PGD/hphl_dac_state"
C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"

# The experiment device: a PM8941 child, so it is on the platform bus.
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

for f in "$MCLKT" "$MCLKS" "$PREREQ" "$PROBE" "$DACS" "$C1T" "$RX1T" \
         "$DIVT" "$DIVS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }
mst() { cat "$MCLKS" 2>/dev/null; }
divst() { cat "$DIVS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst); MPRE=$(mst); DPRE=$(divst)
BAD=""
[ "$(rv "$MPRE" present)" = "1" ]         || BAD="$BAD no_mclk_clock_in_dt"
[ "$(rv "$MPRE" refs)" = "0" ]            || BAD="$BAD mclk_already_held"
[ "$(rv "$DPRE" applied)" = "0" ]         || BAD="$BAD divider_already_applied"
#
# rdac_probes is a COUNTER, not state. A previous run that restored everything
# leaves it non-zero while the registers are genuinely pristine, and refusing
# on that alone would force a power cycle to re-run a gate whose own teardown
# worked. The register preconditions below are what actually guard the control.
#
[ "$(rv "$PRE" prereq_on)" = "0" ]        || BAD="$BAD prereq_already_on"
[ "$(rv "$PRE" guard_tripped)" = "0" ]    || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]       || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ] || BAD="$BAD 0x314_not_at_por"
[ "$(rv "$DPRE" factor)" = "0" ]          || BAD="$BAD divider_not_at_1"
[ "$(rv "$MPRE" source)" = "RCO" ]        || BAD="$BAD codec_not_on_rco"
if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not what this experiment needs:$BAD"
	say "  Cold boot and run this once, before anything else touches the codec."
	exit 3
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-mclk-$STAMP.txt"

#
# Count warnings as a DELTA, not as the buffer's contents.
#
# The r167 run failed this check on 88 warnings that predated it by 140
# seconds -- every one from a debugfs regmap dump of the PMIC's full
# 0-0xffff space, which walks unimplemented addresses and makes
# spmi-pmic-arb WARN once per miss (Comm: grep in every trace). Judging a run
# by the whole ring buffer means anything that happened earlier on the boot
# can fail it, which is both wrong and easy to misread as the run's own fault.
#
WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------------- baseline behaviour --
# Reproduce the refusal in this harness before changing anything, so the run
# carries its own control rather than citing r165's.
echo comp1-on > "$C1T" 2>/dev/null; COMP_RC=$?
echo rx1-on > "$RX1T" 2>/dev/null; RX1_RC=$?
echo try > "$PROBE" 2>/dev/null
B_RDAC=$(rv "$(dst)" rdac_latched)
echo on > "$PREREQ" 2>/dev/null
B_314=$(rv "$(dst)" clk_power_0x314)
[ "$B_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null

# ------------------------------------------------------ construct the path --
echo on > "$DIVT" 2>/dev/null; DIV_RC=$?
APPLIED=$(divst)
A_FACTOR=$(rv "$APPLIED" factor)
A_FUNC=$(rv "$APPLIED" function)
A_DIR=$(rv "$APPLIED" dir)
A_EN=$(rv "$APPLIED" enabled)

# ---------------------------------------------- the RPM vote, then re-read --
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?
MON=$(mst)
POSTVOTE=$(divst)
P_FACTOR=$(rv "$POSTVOTE" factor)
P_FUNC=$(rv "$POSTVOTE" function)
P_DIR=$(rv "$POSTVOTE" dir)
P_EN=$(rv "$POSTVOTE" enabled)
P_SOURCE=$(rv "$MON" source)

# The path is judged on the POST-VOTE values only.
#
# DIRECTION IS 1 *OR* 2, and this cost a run. pinctrl-spmi-gpio encodes
# MODE_CTL[6:4] as:
#
#   0  DIGITAL_INPUT
#   1  DIGITAL_OUTPUT          output_enabled && !input_enabled
#   2  DIGITAL_INPUT_OUTPUT    output_enabled &&  input_enabled
#
# and the driver's pad state PERSISTS across state changes, so applying
# output-high on top of a state that set input-enable yields 2, not 1. Both
# mean the pad is driven; only 0 means it is not. Asserting == 1 refused a
# correctly configured pad and blocked the retry, which is a gate defect and
# not a hardware result.
pa_driven() { [ "$1" = "1" ] || [ "$1" = "2" ]; }

PATH_OK=1
[ "$P_FACTOR" = "2" ]   || PATH_OK=0
[ "$P_FUNC" = "2" ]     || PATH_OK=0   # pinctrl index 2 == func1 == DIV_CLK
pa_driven "$P_DIR"      || PATH_OK=0   # output, with or without input buffer
[ "$P_EN" = "1" ]       || PATH_OK=0
[ "$P_SOURCE" = "RCO" ] || PATH_OK=0
[ "$MCLK_RC" = "0" ]    || PATH_OK=0
[ "$DIV_RC" = "0" ]     || PATH_OK=0

# ----------------------------------------------------------- the retry ------
A_RDAC="n/a"; A_314="n/a"
if [ "$PATH_OK" = "1" ]; then
	echo try > "$PROBE" 2>/dev/null
	A_RDAC=$(rv "$(dst)" rdac_latched)
	echo on > "$PREREQ" 2>/dev/null
	A_314=$(rv "$(dst)" clk_power_0x314)
	[ "$A_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null
fi

# ----------------------------------------------------------- teardown -------
echo off > "$MCLKT" 2>/dev/null
echo off > "$DIVT" 2>/dev/null
echo rx1-off > "$RX1T" 2>/dev/null
echo comp1-off > "$C1T" 2>/dev/null
POST=$(dst); MPOST=$(mst); DPOST=$(divst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

UNLOCKED=0
{ [ "$A_RDAC" = "1" ] || [ "$A_314" = "03" ]; } && UNLOCKED=1

{
	hdr "baseline, before anything was configured"
	say "divider  $(rv "$DPRE" div_ctl1) factor $(rv "$DPRE" factor)   gpio15 mode $(rv "$DPRE" gpio15_mode_ctl) function $(rv "$DPRE" function)"
	say "codec source $(rv "$MPRE" source)"
	say "0x30d[1] $([ "$B_RDAC" = "1" ] && echo LATCHED || echo REFUSED)    0x314 $B_314"

	hdr "the path, as constructed"
	say "DIV_CTL1 factor $A_FACTOR   gpio15 dir $A_DIR function $A_FUNC   enabled $A_EN"

	hdr "AFTER the RPM vote transition -- the values the verdict rests on"
	printf '%s\n' "$POSTVOTE" | sed 's/^/  /'
	say "codec source: $P_SOURCE"
	say ""
	say "clk_get_rate is deliberately not consulted: it reports RPM's fixed"
	say "nominal 19.2 MHz and never reads DIV_CTL1."

	hdr "the retry"
	say "0x30d[1] : $([ "$A_RDAC" = "1" ] && echo LATCHED || echo "$A_RDAC")"
	say "0x314    : $A_314"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "compander came up" "$COMP_RC" "0"
	check "RX1 chain came up" "$RX1_RC" "0"
	check "divider configured" "$DIV_RC" "0"
	check "RPM vote taken" "$MCLK_RC" "0"
	check "mclk refcount held" "$(rv "$MON" refs)" "1"

	say ""
	say "-- the path SURVIVED the RPM vote (the clobber test) --"
	check "divide factor still 2" "$P_FACTOR" "2"
	check "gpio15 still function 2 (func1)" "$P_FUNC" "2"
	check_cond "gpio15 still driven (dir 1 or 2)" \
		"$(pa_driven "$P_DIR" && echo 1 || echo 0)" \
		"dir $P_DIR means the pad is not driven" "dir $P_DIR"
	check "divider still enabled" "$P_EN" "1"
	check "factor unchanged by the vote" "$P_FACTOR" "$A_FACTOR"
	check "mux unchanged by the vote" "$P_FUNC" "$A_FUNC"

	say ""
	say "-- the codec was never switched --"
	check "codec still selects RCO" "$P_SOURCE" "RCO"
	check "CHIP_CTL never moved" "$(rv "$POST" chip_ctl_0x001)" "$(rv "$PRE" chip_ctl_0x001)"

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "$(rv "$PRE" pa_0x1ab)"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "divider restored" "$(rv "$DPOST" factor)" "$(rv "$DPRE" factor)"
	check "mclk released" "$(rv "$MPOST" refs)" "0"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- only the delta is judged"

	hdr "finding"
	if [ "$PATH_OK" != "1" ]; then
		say "M1 -- MCLK_PATH_NOT_ESTABLISHED. No codec conclusion."
		say ""
		say "One of the path facts did not hold after the RPM vote:"
		say "  factor $P_FACTOR (want 2), function $P_FUNC (want 2 = func1),"
		say "  dir $P_DIR (want 1), enabled $P_EN (want 1),"
		say "  codec source $P_SOURCE (want RCO)."
		say ""
		say "If the factor was 2 before the vote and is not now, RPM rewrote"
		say "the peripheral when its vote changed -- which is the ownership"
		say "hazard this run exists to detect, and it means the AP cannot"
		say "hold the divider without cooperating with RPM."
		say ""
		say "THIS IS NOT A RESULT ABOUT THE WCD9320."
	elif [ "$UNLOCKED" = "1" ]; then
		say "M3 -- MCLK_PATH_ESTABLISHED_RDAC_UNLOCKED."
		say ""
		say "THE CLAIM, STATED AS NARROWLY AS THE EVIDENCE ALLOWS:"
		say ""
		say "  Configuring the Lumia's PM8941 DIV_CLK1 /2 path and routing"
		say "  gpio15 as DIV_CLK caused the previously refused WCD9320"
		say "  clock-domain register(s) to become writable, while the codec"
		say "  remained RCO-selected."
		say ""
		say "That is a causal result: DIV_CTL1 = 2 and gpio15 = func1 were"
		say "the only things this run changed on the codec's behalf, both"
		say "verified on the chip after the RPM vote transition, and"
		say "CLK_BUFF_EN1 was never written -- the artefact gate proves the"
		say "driver has no write site for it."
		say ""
		say "WHAT IT DOES NOT CLAIM. Not that 9.6 MHz was measured arriving"
		say "at the codec's MCLK pin. Nothing here observes the pad; that"
		say "would need a scope. What is shown is that the codec's behaviour"
		say "changed when the PMIC path was configured, which is strong"
		say "corroboration and not a waveform."
		say ""
		say "C2b may resume on this configured state."
	else
		say "M2 -- MCLK_PATH_ESTABLISHED_RDAC_STILL_REFUSED."
		say ""
		say "The divider is at /2, gpio15 is muxed to func1 = DIV_CLK as an"
		say "output, the RPM vote is held, and all of that survived the vote"
		say "transition. The codec remains on RCO. The registers still refuse."
		say ""
		say "The software-configurable external MCLK path is therefore"
		say "ESTABLISHED as far as the PMIC pad. func1 on gpio15-18 is"
		say "DIV_CLK in Qualcomm's PM8941 pin definitions -- func2 there is"
		say "SLEEP_CLK, which is what other MSM8974 boards use on gpio16 for"
		say "WLAN -- so this is not a case of possibly having selected the"
		say "wrong alternate function."
		say ""
		say "What remains unmeasured is electrical: that 9.6 MHz actually"
		say "reaches the codec's MCLK pin. Nothing here observes the pad, and"
		say "only a scope or corroborating codec behaviour could settle it."
		say ""
		say "So the defensible reading is: PMIC-side external MCLK"
		say "configuration ALONE is insufficient to make these registers"
		say "writable while the codec is not selecting that clock."
		say ""
		say "Next is r168: the same established clock plus the codec's own"
		say "RCO -> MCLK switch, as one further change. Map"
		say "wcd9xxx_enable_clock_block() before writing it, and note the"
		say "hazard -- if no clock is really arriving, switching away from RCO"
		say "stops the CDC core until it is switched back."
		say ""
		say "Do NOT reach for CHIP_CTL on the way there."
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

sed -n '/=== baseline, before/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$PATH_OK" = "1" ] || exit 2
[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
[ "$UNLOCKED" = "1" ] || exit 1
exit 0

#!/bin/sh
#
# r166: is an external 9.6 MHz MCLK, present and routed, enough to unlock the
# codec's refused clock registers?
#
# THE ONE QUESTION
#
#   With PM8941 DIV_CLK1 configured to 9.6 MHz and muxed onto a pad, and the
#   WCD9320 still running internally from its RC oscillator, do
#   CDC_CLK_POWER_CTL (0x314) and CDC_CLK_RDAC_CLK_EN_CTL (0x30d) bit 1 accept
#   writes?
#
# WHY THE CODEC STAYS ON RCO
#
# Supplying the clock and selecting it are two different changes. If this build
# did both, a positive result could not say which mattered. r166 changes only
# the first. If the answer is no, the source switch becomes its own build with
# the clock already established -- which keeps the causal chain readable:
#
#   r165  no routed MCLK                       -> 0x314 and 0x30d refuse
#   r166  9.6 MHz external MCLK established,   -> measure
#         codec still RCO
#   r167  same MCLK + codec switched to it     -> measure, only if needed
#
# THE PATH IS PROVEN BEFORE THE CODEC IS ASKED ANYTHING
#
# Five facts have to cross before the question is even put, and four of them
# are read from the PMIC's own registers rather than from any driver's opinion:
# the divider rate, its divide factor, its enable bit, the pad's mux, and the
# codec's own source selection. A run where the clock was not actually
# configured must report that, not a negative result.
#
# Exit: 0 the registers now latch, 1 they still refuse, 2 the path did not
#       configure (which is not a negative result about the codec).

set -u

MODE="wcd9320-mclk"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r166-$$"
PMIC="${PMIC:-/sys/kernel/debug/regmap/0-00/registers}"

# PM8941 CLKDIV1 at 0x5b00; DIV_CTL1 = +0x43, EN_CTL = +0x46.
# PM8941 gpio15 at 0xc000 + 14*0x100 = 0xce00; MODE_CTL = +0x40.
CLKDIV_DIV=5b43
CLKDIV_EN=5b46
GPIO15_MODE=ce40

require_module_version
find_devices

MCLKT="$PGD/mclk_test"
MCLKS="$PGD/mclk_state"
PREREQ="$PGD/cdc_clk_prereq"
PROBE="$PGD/rdac_probe"
DACS="$PGD/hphl_dac_state"
C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"

for f in "$MCLKT" "$MCLKS" "$PREREQ" "$PROBE" "$DACS" "$C1T" "$RX1T"; do
	[ -e "$f" ] || {
		say "INVALID RUN: $f does not exist."
		say "  The running codec must be mclk-rc1 or later."
		exit 2
	}
done
[ -r "$PMIC" ] || { say "INVALID RUN: cannot read $PMIC (need root)."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
mst() { cat "$MCLKS" 2>/dev/null; }
dst() { cat "$DACS" 2>/dev/null; }

# One pass over a 65k-line file; grepping it per-register is minutes slower.
PMIC_SNAP="/tmp/.r166-pmic-$$"
grep -iE "^($CLKDIV_DIV|$CLKDIV_EN|$GPIO15_MODE):" "$PMIC" > "$PMIC_SNAP" 2>/dev/null
pm() { sed -n "s/^$1: *//p" "$PMIC_SNAP" | head -n1; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst)
MPRE=$(mst)
BAD=""
[ "$(rv "$MPRE" present)" = "1" ]      || BAD="$BAD no_mclk_in_dt"
[ "$(rv "$MPRE" refs)" = "0" ]         || BAD="$BAD mclk_already_held"
[ "$(rv "$PRE" rdac_probes)" = "0" ]   || BAD="$BAD already_probed"
[ "$(rv "$PRE" prereq_on)" = "0" ]     || BAD="$BAD prereq_already_on"
[ "$(rv "$PRE" guard_tripped)" = "0" ] || BAD="$BAD guard_tripped"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]    || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ] ||
	BAD="$BAD clk_power=$(rv "$PRE" clk_power_0x314)(want 00)"
if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline not as expected:$BAD"
	say "  Cold boot and run this once, before anything else touches the codec."
	exit 2
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-mclk-$STAMP.txt"

# --------------------------------------------------- the five crossing facts --
RATE=$(rv "$MPRE" rate)
SOURCE=$(rv "$MPRE" source)
DIVRAW=$(pm "$CLKDIV_DIV"); ENRAW=$(pm "$CLKDIV_EN"); MODERAW=$(pm "$GPIO15_MODE")

hexand() { printf '%02x' $(( 0x${1:-0} & 0x$2 )); }
# DIV_CTL1_DIV_FACTOR_MASK = GENMASK(2,0); factor 2 => divide by 2 => 9.6 MHz
DIVF=$(( 0x${DIVRAW:-0} & 0x07 ))
ENBIT=$(hexand "${ENRAW:-0}" 80)
# MODE_CTL: [6:4] direction, [3:1] function, [0] output value
GDIR=$(( (0x${MODERAW:-0} >> 4) & 0x07 ))
GFUNC=$(( (0x${MODERAW:-0} >> 1) & 0x07 ))

# pinctrl function index: 0 normal, 1 paired, 2 func1, 3 func2
case "$GFUNC" in
0) GFUNCNAME=normal ;; 1) GFUNCNAME=paired ;;
2) GFUNCNAME=func1 ;;  3) GFUNCNAME=func2 ;;
*) GFUNCNAME="index$GFUNC" ;;
esac

# ------------------------------------------------------------------- the run --
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?
MON=$(mst)

# The probe runs in the same context the DAC path would use it.
echo comp1-on > "$C1T" 2>/dev/null; COMP_RC=$?
echo rx1-on > "$RX1T" 2>/dev/null; RX1_RC=$?

echo try > "$PROBE" 2>/dev/null; PROBE_RC=$?
AFTER_PROBE=$(dst)
RDAC_LATCHED=$(rv "$AFTER_PROBE" rdac_latched)

echo on > "$PREREQ" 2>/dev/null; PREREQ_RC=$?
AFTER_PREREQ=$(dst)
CLKP=$(rv "$AFTER_PREREQ" clk_power_0x314)

# If 0x314 took this time, ask the RDAC bit again with it in place.
if [ "$CLKP" = "03" ]; then
	echo try > "$PROBE" 2>/dev/null
	SECOND=$(dst)
	RDAC_WITH_PREREQ=$(rv "$SECOND" rdac_latched)
else
	RDAC_WITH_PREREQ="n/a"
fi

echo rx1-off > "$RX1T" 2>/dev/null
echo comp1-off > "$C1T" 2>/dev/null
[ "$CLKP" = "03" ] && echo off > "$PREREQ" 2>/dev/null
echo off > "$MCLKT" 2>/dev/null; MCLKOFF_RC=$?
POST=$(dst)
MPOST=$(mst)

snap_dmesg
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
CLKERR=$(dmesg 2>/dev/null | grep -c 'spmi.*clkdiv.*fail\|clkdiv.*error' || true)
for v in WARNS PA_TRIP CLKERR; do eval "[ -n \"\$$v\" ] || $v=0"; done

PATH_OK=1
[ "$RATE" = "9600000" ] || PATH_OK=0
[ "$DIVF" = "2" ] || PATH_OK=0
[ "$ENBIT" = "80" ] || PATH_OK=0
[ "$GDIR" = "1" ] || PATH_OK=0
[ "$GFUNC" = "2" ] || PATH_OK=0
[ "$SOURCE" = "RCO" ] || PATH_OK=0

{
	hdr "the external clock path, read from the PMIC itself"
	say "clk_get_rate()            $RATE Hz            (want 9600000)"
	say "0x5b43 DIV_CTL1           $DIVRAW  -> factor $DIVF   (want 2 = divide by 2)"
	say "0x5b46 EN_CTL             $ENRAW  -> bit7 $ENBIT   (want 80)"
	say "0xce40 gpio15 MODE_CTL    $MODERAW  -> dir $GDIR, function $GFUNCNAME"
	say "codec source selection    $SOURCE            (want RCO -- unchanged)"

	hdr "the codec baseline"
	printf '%s\n' "$PRE" | sed 's/^/  /'

	hdr "with the external MCLK enabled"
	printf '%s\n' "$MON" | sed 's/^/  /'

	hdr "the question"
	say "0x30d[1] with MCLK present, codec on RCO : $([ "$RDAC_LATCHED" = "1" ] && echo LATCHED || echo REFUSED)"
	say "0x314    with MCLK present, codec on RCO : $CLKP"
	say "0x30d[1] again, if 0x314 took            : $RDAC_WITH_PREREQ"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	say ""
	say "-- the path is actually configured (all five must cross) --"
	check "divider rate is 9.6 MHz" "$RATE" "9600000"
	check "divide factor is 2" "$DIVF" "2"
	check "divider is enabled" "$ENBIT" "80"
	check "gpio15 is an output" "$GDIR" "1"
	check "gpio15 function is func1" "$GFUNCNAME" "func1"
	check "codec still selects RCO" "$SOURCE" "RCO"
	check "mclk acquired and enabled" "$MCLK_RC" "0"
	check "mclk refcount taken" "$(rv "$MON" refs)" "1"
	check "no clkdiv error logged" "$CLKERR" "0"

	say ""
	say "-- nothing else moved --"
	check "compander came up" "$COMP_RC" "0"
	check "RX1 chain came up" "$RX1_RC" "0"
	check "probe ran" "$PROBE_RC" "0"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "$(rv "$PRE" pa_0x1ab)"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "CHIP_CTL never moved" "$(rv "$POST" chip_ctl_0x001)" "$(rv "$PRE" chip_ctl_0x001)"
	check "mclk released" "$(rv "$MPOST" refs)" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$PATH_OK" != "1" ]; then
		say "OUTCOME C -- THE CLOCK PATH DID NOT CONFIGURE."
		say ""
		say "One or more of the five facts above did not cross, so the codec"
		say "was never asked the question under the conditions this build"
		say "exists to create. THIS IS NOT A RESULT ABOUT THE WCD9320. It is"
		say "a board-description problem: fix the provider, the rate or the"
		say "pin mux and re-run before drawing any conclusion about 0x314."
		say ""
		say "If gpio15 reports function $GFUNCNAME rather than func1, note"
		say "that nothing in the kernel documents which pmic-gpio function"
		say "carries DIV_CLK. func2 is the only other candidate the hardware"
		say "allows on this pad -- pmic_gpio_set_mux() rejects func3/func4"
		say "on its non-LV/MV subtype -- and it can be selected at runtime"
		say "through the pinctrl debugfs pinmux-select without rebuilding."
	elif [ "$RDAC_LATCHED" = "1" ] || [ "$CLKP" = "03" ]; then
		say "OUTCOME A -- THE EXTERNAL CLOCK WAS THE MISSING PREREQUISITE."
		say ""
		say "With a 9.6 MHz MCLK present and routed, and the codec still"
		say "running internally from its RC oscillator, the registers that"
		say "refused every write in r164 and r165 accept them. That says the"
		say "PRESENCE of the external clock was what mattered, not the"
		say "codec's internal source selection -- which this run never"
		say "touched and which the artefact gate proves the driver cannot"
		say "touch."
		say ""
		say "It also confirms, by the only means available to software, that"
		say "PM8941 DIV_CLK1 on gpio15 reaches this codec: the codec's"
		say "behaviour changed when that pad started carrying a clock."
		say ""
		say "C2b can now resume on this configured state."
	else
		say "OUTCOME B -- MCLK IS PRESENT AND ROUTED, AND NOT SUFFICIENT."
		say ""
		say "All five path facts crossed: a 9.6 MHz divider, enabled, muxed"
		say "onto gpio15 as an output, with the codec still on RCO. The"
		say "registers still refuse."
		say ""
		say "That is a real and useful negative, but read it carefully. It"
		say "says supplying the clock is not enough WHILE THE CODEC IS NOT"
		say "SELECTING IT. It does NOT say the clock is absent or wrong --"
		say "and it does not prove gpio15/func1 is the right pad and"
		say "function, because nothing here can observe the pad."
		say ""
		say "Next is r167: the same established clock, plus the codec's own"
		say "RCO -> MCLK source switch, as a single further change. Map that"
		say "sequence from wcd9xxx_enable_clock_block() before writing it,"
		say "and note the hazard -- if the clock is not really arriving,"
		say "switching away from RCO stops the CDC core until it is switched"
		say "back."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE" "$PMIC_SNAP"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the external clock path/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$PATH_OK" = "1" ] || exit 2
[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
{ [ "$RDAC_LATCHED" = "1" ] || [ "$CLKP" = "03" ]; } || exit 1
exit 0

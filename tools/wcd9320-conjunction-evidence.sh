#!/bin/sh
#
# r173: MCLK SELECTED **AND** THE RATE DECLARED -- the last cell of the matrix.
#
# WHY THIS NEEDS NO NEW BUILD
#
# The driver already does all of it. wcd9320_clk_source_switch() switches the
# codec to the external MCLK and then, if the CDC block is still alive, calls
# wcd9320_chip_ctl_probe(9.6 MHz). Until r170 that probe wrote 0x001, which is
# CHIP_STATUS, so the rate was never actually declared and the conjunction was
# never actually formed. With the address corrected the same code path now
# forms it. This gate simply drives what is already there.
#
# THE MATRIX
#
#   run    MCLK selected   rate declared   0x314
#   r167   no              no              refused
#   r169   YES             no (wrong addr) refused
#   r170   no              YES             refused
#   r173   YES             YES             <- this run
#
# Every previous run moved one half. This is the state downstream is in when
# taiko_reg_defaults[] writes 0x314, and the physical reading is that
# declaring 9.6 MHz while running from the RC oscillator is an INCONSISTENT
# configuration -- the RCO is not that clock -- so a register that powers a
# clock tree may reasonably refuse until the declared rate and the actual
# source agree.
#
# THIS IS NOT A REOPENING OF THE MCLK QUESTIONS. Those are answered and stay
# answered: the divider, the pad mux, RPM ownership, the switch itself, the RC
# oscillator physically off, the CDC positive control surviving, and recovery
# proven three times. The r169 switch is used here as a PRECONDITION for a
# different question.
#
# 0x30d is retried under the FULL C2b prerequisite state, not as a naked probe,
# because r164's negative was obtained that way and a result from a different
# state would not be comparable. The DAC is never powered: prereq-on runs
# stages 3-6 and stops. The PA is never touched.
#
# Exit: 0 = C4 0x314 and 0x30d both latch -- the conjunction was the answer
#       2 = C3 0x314 latches, 0x30d does not -- RDAC has its own condition
#       1 = C2 0x314 still refuses with both halves established -- the matrix
#              is exhausted and the cause is none of them
#       3 = C1 the conjunction was not formed, or a failed check -- no result

set -u

MODE="wcd9320-conjunction"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-r173-$$"
DMESG_MARKER="${DMESG_MARKER:-clk-src: CHIP_CTL measured}"

require_module_version
find_devices

CSRCT="$PGD/clk_source_test"
CSRCS="$PGD/clk_source_state"
MCLKT="$PGD/mclk_test"
PREREQ="$PGD/cdc_clk_prereq"
DACT="$PGD/hphl_dac_test"
DACS="$PGD/hphl_dac_state"
C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"

DIVD=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -d "$d" ] && { DIVD="$d"; break; }
done
[ -n "$DIVD" ] || { say "INVALID RUN: the MCLK divider device did not probe."; exit 3; }
DIVT="$DIVD/mclk_div_test"
DIVS="$DIVD/mclk_div_state"

for f in "$CSRCT" "$CSRCS" "$MCLKT" "$PREREQ" "$DACT" "$DACS" "$C1T" "$RX1T" \
         "$DIVT" "$DIVS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist."; exit 3; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }
cst() { cat "$CSRCS" 2>/dev/null; }
divst() { cat "$DIVS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst); CPRE=$(cst); DPRE=$(divst)
BAD=""
[ "$(rv "$PRE" guard_tripped)" = "0" ]     || BAD="$BAD pa_guard_tripped"
[ "$(rv "$PRE" pa_0x1ab)" = "80" ]         || BAD="$BAD pa_not_at_baseline"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ]        || BAD="$BAD dac_not_idle"
[ "$(rv "$PRE" on)" = "0" ]                || BAD="$BAD c2b_up"
[ "$(rv "$PRE" prereq_on)" = "0" ]         || BAD="$BAD prereq_on"
[ "$(rv "$PRE" clk_power_0x314)" = "00" ]  || BAD="$BAD 0x314_not_at_por"
[ "$(rv "$PRE" rdac_0x30d)" = "00" ]       || BAD="$BAD 0x30d_not_at_por"
[ "$(rv "$CPRE" source)" = "RCO" ]         || BAD="$BAD not_on_rco"
[ "$(rv "$CPRE" on_mclk)" = "0" ]          || BAD="$BAD already_on_mclk"
[ "$(rv "$CPRE" cdc_alive)" = "1" ]        || BAD="$BAD control_not_at_por"
[ "$(rv "$DPRE" applied)" = "0" ]          || BAD="$BAD divider_applied"
CC0=$(rv "$PRE" chip_ctl_0x000)
RATE0=$(( 0x${CC0:-0} & 0x06 ))
[ "$RATE0" = "0" ] || BAD="$BAD rate_already_declared"

if [ -n "$BAD" ]; then
	say "INVALID RUN: baseline is not pristine:$BAD"
	say "  chip_ctl=$CC0 0x314=$(rv "$PRE" clk_power_0x314) 0x30d=$(rv "$PRE" rdac_0x30d)"
	exit 3
fi
WANT_CC=$(printf '%02x' $(( (0x$CC0 & 0xf9) | 0x02 )))

snap_dmesg
open_output "$OUTDIR/wcd9320-conjunction-$STAMP.txt"

WARN_BEFORE=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARN_BEFORE" ] || WARN_BEFORE=0

# ------------------------------------------------- the control, on RCO ------
# Reproduce the refusal in this harness with NEITHER half established, so the
# run carries its own control rather than citing r165's.
echo on > "$PREREQ" 2>/dev/null
B_314=$(rv "$(dst)" clk_power_0x314)
[ "$B_314" = "03" ] && echo off > "$PREREQ" 2>/dev/null

# ------------------------------------- half 1: the frozen r167 PMIC path ----
echo on > "$DIVT" 2>/dev/null; DIV_RC=$?
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?
POSTVOTE=$(divst)
P_FACTOR=$(rv "$POSTVOTE" factor)
P_FUNC=$(rv "$POSTVOTE" function)
P_DIR=$(rv "$POSTVOTE" dir)
P_EN=$(rv "$POSTVOTE" enabled)
pa_driven() { [ "$1" = "1" ] || [ "$1" = "2" ]; }
PATH_OK=1
[ "$P_FACTOR" = "2" ] || PATH_OK=0
[ "$P_FUNC" = "2" ]   || PATH_OK=0
pa_driven "$P_DIR"    || PATH_OK=0
[ "$P_EN" = "1" ]     || PATH_OK=0
[ "$DIV_RC" = "0" ]   || PATH_OK=0
[ "$MCLK_RC" = "0" ]  || PATH_OK=0

# ----------- half 2: the switch, which also declares the rate on MCLK -------
SW_RC="n/a"; S_SOURCE="n/a"; S_ALIVE="n/a"; S_CC="n/a"; S_CCLAT="n/a"
CONJ=0
if [ "$PATH_OK" = "1" ]; then
	echo mclk > "$CSRCT" 2>/dev/null; SW_RC=$?
	SW=$(cst)
	S_SOURCE=$(rv "$SW" source)
	S_ALIVE=$(rv "$SW" cdc_alive)
	S_CC=$(rv "$SW" chip_ctl_0x000)
	S_CCLAT=$(rv "$SW" chip_ctl_latched)
	[ "$SW_RC" = "0" ] && [ "$S_SOURCE" = "EXTERNAL" ] && \
	[ "$S_ALIVE" = "1" ] && [ "$S_CCLAT" = "1" ] && CONJ=1
fi

# ------------------------------------------------- the test, if formed ------
A_314="n/a"; C2B_RC="n/a"; A_30D="n/a"; C1_RC="n/a"; RX1_RC="n/a"
if [ "$CONJ" = "1" ]; then
	echo on > "$PREREQ" 2>/dev/null
	A_314=$(rv "$(dst)" clk_power_0x314)
	if [ "$A_314" = "03" ]; then
		echo comp1-on > "$C1T" 2>/dev/null; C1_RC=$?
		echo rx1-on > "$RX1T" 2>/dev/null; RX1_RC=$?
		echo prereq-on > "$DACT" 2>/dev/null; C2B_RC=$?
		A_30D=$(rv "$(dst)" rdac_0x30d)
	fi
fi

# --------------------------------------- teardown, in dependency order ------
[ "$C2B_RC" = "0" ] && echo prereq-off > "$DACT" 2>/dev/null
[ "$RX1_RC" = "0" ] && echo rx1-off > "$RX1T" 2>/dev/null
[ "$C1_RC" = "0" ] && echo comp1-off > "$C1T" 2>/dev/null
echo off > "$PREREQ" 2>/dev/null
# rco restores CHIP_CTL before leaving MCLK, then brings the RCO back
echo rco > "$CSRCT" 2>/dev/null; RST_RC=$?
echo off > "$MCLKT" 2>/dev/null
echo off > "$DIVT" 2>/dev/null
POST=$(dst); CPOST=$(cst); DPOST=$(divst)

snap_dmesg
WARN_AFTER=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
for v in WARN_AFTER PA_TRIP; do eval "[ -n \"\$$v\" ] || $v=0"; done
WARNS=$((WARN_AFTER - WARN_BEFORE))
[ "$WARNS" -ge 0 ] || WARNS=0

{
	hdr "the control: neither half established"
	say "chip_ctl 0x000 = $CC0 (rate bits clear)   0x314 <- 03 gave $B_314"

	hdr "half 1: the frozen r167 path, after the RPM vote"
	say "DIV_CTL1 factor $P_FACTOR   gpio15 dir $P_DIR function $P_FUNC   enabled $P_EN"

	hdr "half 2: the switch, and the rate declared ON MCLK"
	say "codec source : $S_SOURCE     CDC block: $([ "$S_ALIVE" = "1" ] && echo RESPONDING || echo DARK)"
	say "chip_ctl     : $S_CC (predicted $WANT_CC)   latched=$S_CCLAT"
	say "CONJUNCTION FORMED: $([ "$CONJ" = "1" ] && echo YES || echo NO)"

	hdr "the test"
	say "0x314 <- 03 : $A_314"
	say "0x30d[1] under the full C2b prerequisite state : rc=$C2B_RC  0x30d=$A_30D"
	say "the DAC was NOT powered: 0x1b1 = $(rv "$POST" dac_0x1b1)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "divider configured" "$DIV_RC" "0"
	check "RPM vote taken" "$MCLK_RC" "0"
	check "divide factor still 2" "$P_FACTOR" "2"
	check "gpio15 still func1" "$P_FUNC" "2"
	check "divider still enabled" "$P_EN" "1"

	say ""
	say "-- the conjunction --"
	check "switch returned 0" "$SW_RC" "0"
	check "codec selects EXTERNAL" "$S_SOURCE" "EXTERNAL"
	check "CDC block responding on MCLK" "$S_ALIVE" "1"
	check "rate declared on MCLK" "$S_CCLAT" "1"
	check "chip_ctl reads the prediction" "$S_CC" "$WANT_CC"

	say ""
	say "-- the restore --"
	check "restore returned 0" "$RST_RC" "0"
	check "codec back on RCO" "$(rv "$CPOST" source)" "RCO"
	check "CDC responding after restore" "$(rv "$CPOST" cdc_alive)" "1"
	check "CHIP_CTL restored" "$(rv "$POST" chip_ctl_0x000)" "$CC0"
	check "0x314 back at POR" "$(rv "$POST" clk_power_0x314)" "00"
	check "0x30d back at POR" "$(rv "$POST" rdac_0x30d)" "00"
	check "divider restored" "$(rv "$DPOST" factor)" "$(rv "$DPRE" factor)"
	check "mclk released" "$(rv "$(cat "$PGD/mclk_state")" refs)" "0"

	say ""
	say "-- nothing else disturbed --"
	check "PA still off" "$(rv "$POST" pa_0x1ab)" "80"
	check "PA guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no PA guard message" "$PA_TRIP" "0"
	check "DAC never powered" "$(rv "$POST" dac_0x1b1)" "00"
	check "no NEW kernel WARNING/BUG" "$WARNS" "0"
	note "dmesg warnings" "$WARN_BEFORE before, $WARN_AFTER after -- delta only"

	hdr "finding"
	if [ "$CONJ" != "1" ]; then
		say "C1 -- THE CONJUNCTION WAS NOT FORMED. NO RESULT."
		say ""
		say "  path ok $PATH_OK, switch rc $SW_RC, source $S_SOURCE,"
		say "  CDC alive $S_ALIVE, chip_ctl latched $S_CCLAT."
		say ""
		say "Both halves have worked before -- the switch in r169, the rate"
		say "declaration in r170 -- so this is a harness or state problem and"
		say "NOT a result about 0x314. Re-run from a cold boot."
	elif [ "$A_314" != "03" ]; then
		say "C2 -- BOTH HALVES ESTABLISHED. 0x314 STILL REFUSES."
		say ""
		say "The codec was running from the external MCLK with the RC"
		say "oscillator off, the CDC block was responding, and CHIP_CTL was"
		say "chip-verified at $S_CC declaring 9.6 MHz. In that state -- the"
		say "one downstream is in when taiko_reg_defaults[] writes it --"
		say "0x314 <- 03 read back $A_314."
		say ""
		say "THE MATRIX IS NOW EXHAUSTED. Clock absent, clock present, clock"
		say "selected, rate declared, and both together: all refuse. The cause"
		say "is none of them, in any combination."
		say ""
		say "What survives, from r171 and r172: it is a whole-register"
		say "condition on both 0x314 and 0x30d, identical across every"
		say "documented bit and both channels; it is not an address-block"
		say "condition, since 0x311 in the same block accepts; and write-only"
		say "versus refused was never settled, because the only observable"
		say "tried was one downstream never uses that way."
		say ""
		say "The next question is no longer which prerequisite is missing. It"
		say "is whether the bypassed readback is a valid success criterion for"
		say "these two registers at all -- and answering that needs an"
		say "observable that depends on them WORKING, which means the DAC."
	elif [ "$A_30D" = "02" ] || [ "$C2B_RC" = "0" ]; then
		say "C4 -- BOTH REGISTERS LATCH. THE CONJUNCTION WAS THE ANSWER."
		say ""
		say "0x314 took 03 and the HPHL RDAC clock took, under the full C2b"
		say "prerequisite state, with the codec on the external MCLK and the"
		say "rate declared at $S_CC."
		say ""
		say "So the prerequisite was never a single condition: it is that the"
		say "codec must be RUNNING FROM the external clock AND DECLARING its"
		say "rate. Every earlier run had one half and refused. r169 could not"
		say "have found this, because the rate declaration was going to 0x001."
		say ""
		say "The C2b blocker is very probably gone. The next milestone returns"
		say "to stage 7 -- 0x1b1 <- 0xc0 -- with the codec on MCLK, and the"
		say "codec initialisation needs both halves promoted out of the"
		say "experiment surfaces and into core_init."
	else
		say "C3 -- 0x314 LATCHES. 0x30d STILL REFUSES."
		say ""
		say "The conjunction unlocks CDC_CLK_POWER_CTL: with the codec on the"
		say "external MCLK AND the rate declared, 0x314 took 03 where every"
		say "single-half run refused it. That is a real and large result, and"
		say "it explains why r169 and r170 each failed -- each had one half."
		say ""
		say "0x30d[1] did not take, and it was retried in the state it"
		say "originally failed in, so this is comparable with r164. The RDAC"
		say "clock therefore has its own remaining condition on top of the"
		say "clock configuration."
		say ""
		say "Next: 0x314 should be promoted into codec initialisation, and the"
		say "RDAC condition mapped separately -- the DAC power interlock is"
		say "the remaining candidate."
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

sed -n '/=== the control: neither half/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$CONJ" = "1" ] || exit 3
[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 3
[ "$A_314" = "03" ] || exit 1
{ [ "$A_30D" = "02" ] || [ "$C2B_RC" = "0" ]; } && exit 0
exit 2

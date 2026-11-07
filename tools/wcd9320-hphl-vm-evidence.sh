#!/bin/sh
#
# r178: characterise the on-chip HPHL voltmeter before any DC contract run.
#
# Design: docs/audio/wcd9320-hphl-dc-vm-mapping.md, section 9. The PA is never
# enabled. Five steps, one cold boot:
#
#   5  on the RC oscillator the measurement must REFUSE and write nothing
#   1  repeatability: ten measurements at idle, on MCLK
#   2  restore proof: the mapped write set is identical before and after
#   3  self-consistency: CFILT1 at 1200 mV must give 1200/1800 of the span
#   4  HPHL at idle, then with the C3a DAC path up (PA still off) -- does the
#      reading move, or does it sit pinned at the zero (clipping)?
#   +  one 250 ms window, the mode the contract run will use
#
# Graded: the run's validity and safety -- refusal on RCO, every call rc 0
# with no restore mismatch, a positive span, the write set restored, the
# self-consistency ratio within 5 %, the PA masked 00 at every sample.
# Reported, not graded: the millivolt values themselves. This run asks
# whether the instrument can be trusted; the contract run asks what it reads.
#
# Usage:   sudo sh wcd9320-hphl-vm-evidence.sh
# Exit:    0 PASS, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-hphl-vm"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
REPS="${REPS:-10}"
RATIO_TOL_PERMILLE="${RATIO_TOL_PERMILLE:-50}"	# 5 %
VM_SET="110 128 129 131 133 14e 14f 150 171 174 1fe 3c0 3c1 3c3 3c6 3c7 3c8 3ce 3cf 3dc"

require_module_version
find_devices

VM="$PGD/hphl_vm"
PAS="$PGD/hphl_pa_state"
PAT="$PGD/hphl_pa_test"
DACT="$PGD/hphl_dac_test"
DACS="$PGD/hphl_dac_state"
RX1T="$PGD/rx1_digital_test"
PREREQ="$PGD/cdc_clk_prereq"
CSRC="$PGD/clk_source_test"
CSRS="$PGD/clk_source_state"
MCLKT="$PGD/mclk_test"
FLOG="$PGD/forced_log"
MBHC="$PGD/mbhc_detect"
REGS="/sys/kernel/debug/regmap/$PGD_NAME/registers"
DIVT=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -d "$d" ] && { DIVT="$d/mclk_div_test"; break; }
done

for f in "$VM" "$PAS" "$PAT" "$DACT" "$DACS" "$RX1T" "$PREREQ" "$CSRC" \
	 "$CSRS" "$MCLKT" "$FLOG" "$MBHC" "$REGS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist (vm-rc1 or later, as root)."; exit 2; }
done
[ -n "$DIVT" ] || { say "INVALID RUN: the PM8941 divider device is missing."; exit 2; }
[ "$(id -u)" = "0" ] || { say "INVALID RUN: need root."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
vms() { cat "$VM" 2>/dev/null; }
pa_masked() {
	_pm=$(rv "$(cat "$PAS" 2>/dev/null)" pa_0x1ab)
	[ -n "$_pm" ] || { echo "READ-FAILED"; return; }
	printf '%02x' $(( 0x$_pm & 0x30 ))
}
PA_SAMPLES=""
pa_sample() { PA_SAMPLES="$PA_SAMPLES $1:$(pa_masked)"; }
# set_dump <file> -- the mapped write set, from regmap debugfs
set_dump() {
	for _sd_a in $VM_SET; do
		printf '%s=%s ' "$_sd_a" "$(grep -m1 "^$_sd_a:" "$REGS" 2>/dev/null | cut -d' ' -f2)"
	done > "$1"
}

# ------------------------------------------------------------ preconditions --
BAD=""
PRE_PA=$(cat "$PAS" 2>/dev/null)
[ "$(pa_masked)" = "00" ]                    || BAD="$BAD PA_ON"
[ "$(rv "$PRE_PA" pa_on)" = "0" ]            || BAD="$BAD pa_on"
[ "$(rv "$PRE_PA" prep_on)" = "0" ]          || BAD="$BAD prep_on"
[ "$(rv "$(cat "$DACS")" on)" = "0" ]        || BAD="$BAD dac_on"
[ "$(rv "$(cat "$MBHC")" on)" = "0" ]        || BAD="$BAD insert_detect_on"
[ "$(rv "$(cat "$CSRS")" on_mclk)" = "0" ]   || BAD="$BAD already_on_mclk"
[ "$(rv "$(vms)" runs)" = "0" ]              || BAD="$BAD vm_already_run"
F0=$(rv "$(cat "$FLOG")" forced_n)
[ $(( ${F0:-99} + 4 )) -le 16 ]              || BAD="$BAD forced_journal_full"
if [ -n "$BAD" ]; then
	say "INVALID RUN: the starting state is not clean:$BAD"
	say "  Power cycle and run this once, first thing."
	exit 2
fi

open_output "$OUTDIR/wcd9320-hphl-vm-$STAMP.txt"
T=/tmp/.hphl-vm-$$
mkdir -p "$T"

CLOCK_UP=0
clock_down() {
	[ "$CLOCK_UP" = "1" ] || return 0
	echo rco > "$CSRC" 2>/dev/null
	echo off > "$MCLKT" 2>/dev/null
	echo off > "$DIVT" 2>/dev/null
	CLOCK_UP=0
}
on_signal() {
	echo dac-off-reggain > "$DACT" 2>/dev/null
	echo off > "$PREREQ" 2>/dev/null
	echo rx1-off > "$RX1T" 2>/dev/null
	echo unprep > "$PAT" 2>/dev/null
	clock_down
	exit 2
}
trap on_signal INT TERM HUP

set_dump "$T/set-rco-before"
pa_sample start

# ---- step 5: refusal on the RC oscillator ----
echo measure > "$VM" 2>/dev/null; RCO_RC=$?
RCO_ST=$(vms)
set_dump "$T/set-rco-after-refusal"
pa_sample rco-refusal

# ---- the clock ----
echo on > "$DIVT" 2>/dev/null; DIV_RC=$?
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?
CLOCK_UP=1
echo mclk > "$CSRC" 2>/dev/null; SW_RC=$?
CLK_ST=$(cat "$CSRS" 2>/dev/null)
pa_sample mclk

set_dump "$T/set-mclk-before"

# ---- step 1: repeatability ----
i=1
while [ "$i" -le "$REPS" ]; do
	echo measure > "$VM" 2>/dev/null; eval "M${i}_RC=\$?"
	eval "M${i}=\$(vms)"
	i=$((i + 1))
done
pa_sample reps
set_dump "$T/set-mclk-after-reps"

# ---- step 3: self-consistency at 1200 mV ----
i=1
while [ "$i" -le 3 ]; do
	echo measure-1200 > "$VM" 2>/dev/null; eval "A${i}_RC=\$?"
	eval "A${i}=\$(vms)"
	i=$((i + 1))
done
pa_sample alt
set_dump "$T/set-mclk-after-alt"

# ---- the 250 ms window, at idle ----
echo window > "$VM" 2>/dev/null; WIN_RC=$?
WIN=$(vms)
pa_sample window

# ---- step 4: the DAC path up, PA off ----
echo prep > "$PAT" 2>/dev/null; P1=$?
echo on > "$PREREQ" 2>/dev/null; P2=$?
echo rx1-on > "$RX1T" 2>/dev/null; P3=$?
echo dac-on-reggain > "$DACT" 2>/dev/null; P4=$?
DAC_SETUP_RC=$((P1 + P2 + P3 + P4))
DAC_ST=$(cat "$DACS" 2>/dev/null)
pa_sample dac-up
i=1
while [ "$i" -le 3 ]; do
	echo measure > "$VM" 2>/dev/null; eval "D${i}_RC=\$?"
	eval "D${i}=\$(vms)"
	i=$((i + 1))
done
echo window > "$VM" 2>/dev/null; DWIN_RC=$?
DWIN=$(vms)
pa_sample dac-measured
echo dac-off-reggain > "$DACT" 2>/dev/null
echo off > "$PREREQ" 2>/dev/null
echo rx1-off > "$RX1T" 2>/dev/null
echo unprep > "$PAT" 2>/dev/null
pa_sample dac-down
set_dump "$T/set-mclk-end"

clock_down
trap - INT TERM HUP
set_dump "$T/set-rco-end"
pa_sample end
FLOG_POST=$(cat "$FLOG" 2>/dev/null)

# ------------------------------------------------------------------- report --
# avg <list> / spread <list> -- integer arithmetic in awk
avg() { printf '%s\n' "$@" | awk 'NF{s+=$1;n++} END{if(n) printf "%d", s/n; else print "?"}'; }
spread() { printf '%s\n' "$@" | awk 'NF{if(min==""||$1<min)min=$1; if(max==""||$1>max)max=$1} END{print max-min}'; }

{
	say "WCD9320 r178 on-chip HPHL voltmeter characterisation"
	say "mode              : $MODE"
	say "stamp             : $STAMP"
	say "module            : $RUNNING_VERSION (expect $EXPECT_VERSION, $EXPECT_SOURCE)"
	say "control function  : $PGD_NAME"
	say "design            : docs/audio/wcd9320-hphl-dc-vm-mapping.md section 9"
	say "PA                : never enabled by this run"

	hdr "step 5: on the RC oscillator the voltmeter refuses"
	check "measure on RCO is refused" "$([ "$RCO_RC" -ne 0 ] && echo yes || echo no)" "yes"
	check "nothing ran" "$(rv "$RCO_ST" runs)" "0"
	check "the refusal was counted" "$(rv "$RCO_ST" refusals)" "1"
	check "the write set did not move" \
	      "$(cmp -s "$T/set-rco-before" "$T/set-rco-after-refusal" && echo same || echo MOVED)" "same"

	hdr "the clock"
	check "divider on" "$DIV_RC" "0"
	check "mclk vote" "$MCLK_RC" "0"
	check "switch to MCLK" "$SW_RC" "0"
	check "on_mclk" "$(rv "$CLK_ST" on_mclk)" "1"
	check "cdc_alive" "$(rv "$CLK_ST" cdc_alive)" "1"
	note "CHIP_CTL" "$(rv "$CLK_ST" chip_ctl_0x000)"

	hdr "step 1: repeatability, $REPS measurements at idle"
	say "  run  rc  sta_z   sta_mb  span    mv10_mean  mv10_drift  restore_mismatch"
	ZS=""; MBS=""; SPS=""; MVS=""
	i=1
	while [ "$i" -le "$REPS" ]; do
		eval "_s=\$M$i; _rc=\$M${i}_RC"
		printf '  %-4s %-3s %-7s %-7s %-7s %-10s %-11s %s\n' "$i" "$_rc" \
			"$(rv "$_s" sta_z)" "$(rv "$_s" sta_mb)" "$(rv "$_s" span)" \
			"$(rv "$_s" mv10_mean)" "$(rv "$_s" mv10_drift)" "$(rv "$_s" restore_mismatch)"
		check "run $i rc" "$_rc" "0"
		check "run $i restore mismatches" "$(rv "$_s" restore_mismatch)" "0"
		check_cond "run $i span positive" \
			"$([ "$(rv "$_s" span)" -gt 0 ] 2>/dev/null && echo 1 || echo 0)" \
			"span=$(rv "$_s" span)" "span=$(rv "$_s" span)"
		ZS="$ZS $(rv "$_s" sta_z)"; MBS="$MBS $(rv "$_s" sta_mb)"
		SPS="$SPS $(rv "$_s" span)"; MVS="$MVS $(rv "$_s" mv10_mean)"
		i=$((i + 1))
	done
	note "sta_z  mean / spread" "$(avg $ZS) / $(spread $ZS) counts"
	note "sta_mb mean / spread" "$(avg $MBS) / $(spread $MBS) counts"
	note "span   mean / spread" "$(avg $SPS) / $(spread $SPS) counts"
	note "HPHL mv10 mean / spread" "$(avg $MVS) / $(spread $MVS) (tenths of mV)"
	say "  raw samples, run 1: $(printf '%s' "$M1" | sed -n 's/^raw=//p')"
	say "  fir bank as found:  $(printf '%s' "$M1" | sed -n 's/^fir=//p')"

	hdr "step 2: the mapped write set is restored"
	check "after $REPS measurements" \
	      "$(cmp -s "$T/set-mclk-before" "$T/set-mclk-after-reps" && echo same || echo MOVED)" "same"
	check "after the 1200 mV runs (CFILT1_VAL back to 80)" \
	      "$(cmp -s "$T/set-mclk-before" "$T/set-mclk-after-alt" && echo same || echo MOVED)" "same"
	check "back on RCO at the end, versus the start" \
	      "$(cmp -s "$T/set-rco-before" "$T/set-rco-end" && echo same || echo MOVED)" "same"
	say "  start: $(cat "$T/set-rco-before")"
	say "  end:   $(cat "$T/set-rco-end")"

	hdr "step 3: self-consistency, CFILT1 at 1200 mV"
	ASP=""
	i=1
	while [ "$i" -le 3 ]; do
		eval "_s=\$A$i; _rc=\$A${i}_RC"
		check "1200 run $i rc" "$_rc" "0"
		check "1200 run $i micb_mv" "$(rv "$_s" micb_mv)" "1200"
		say "  run $i: sta_z $(rv "$_s" sta_z) sta_mb $(rv "$_s" sta_mb) span $(rv "$_s" span)"
		ASP="$ASP $(rv "$_s" span)"
		i=$((i + 1))
	done
	S18=$(avg $SPS); S12=$(avg $ASP)
	RATIO=$(awk -v a="$S12" -v b="$S18" 'BEGIN{ if (b>0) printf "%d", 1000*a/b; else print 0 }')
	note "span 1800 mV / 1200 mV" "$S18 / $S12 counts"
	note "ratio (permille)" "$RATIO, expected 667 +/- $RATIO_TOL_PERMILLE"
	check_cond "the span scales with the reference" \
		"$([ "$RATIO" -ge $((667 - RATIO_TOL_PERMILLE)) ] && [ "$RATIO" -le $((667 + RATIO_TOL_PERMILLE)) ] && echo 1 || echo 0)" \
		"ratio $RATIO permille" "ratio $RATIO permille"

	hdr "the 250 ms window at idle (the contract-run mode)"
	check "window rc" "$WIN_RC" "0"
	note "samples / gap" "$(rv "$WIN" n) / $(rv "$WIN" gap_us) us"
	note "mv10 mean / drift" "$(rv "$WIN" mv10_mean) / $(rv "$WIN" mv10_drift)"
	say "  raw: $(printf '%s' "$WIN" | sed -n 's/^raw=//p')"

	hdr "step 4: HPHL with the C3a DAC path up, PA off"
	check "DAC path established" "$DAC_SETUP_RC" "0"
	note "0x1b1 / 0x1ab" "$(rv "$DAC_ST" dac_0x1b1) / $(rv "$DAC_ST" pa_0x1ab)"
	DMV=""
	i=1
	while [ "$i" -le 3 ]; do
		eval "_s=\$D$i; _rc=\$D${i}_RC"
		check "DAC-up run $i rc" "$_rc" "0"
		say "  run $i: sta_z $(rv "$_s" sta_z) span $(rv "$_s" span) mv10 $(rv "$_s" mv10_mean) raw $(printf '%s' "$_s" | sed -n 's/^raw=//p' | cut -c1-60)"
		DMV="$DMV $(rv "$_s" mv10_mean)"
		i=$((i + 1))
	done
	check "DAC-up window rc" "$DWIN_RC" "0"
	note "DAC-up window mv10 mean / drift" "$(rv "$DWIN" mv10_mean) / $(rv "$DWIN" mv10_drift)"
	note "HPHL mv10, idle vs DAC up" "$(avg $MVS) vs $(avg $DMV)"
	# clipping: every raw sample equal to sta_z, at idle and with the DAC up
	Z1=$(rv "$M1" sta_z)
	PIN_IDLE=$(printf '%s' "$M1" | sed -n 's/^raw=//p' | tr ',' '\n' | grep -c -v "^${Z1}$")
	Z2=$(rv "$D1" sta_z)
	PIN_DAC=$(printf '%s' "$D1" | sed -n 's/^raw=//p' | tr ',' '\n' | grep -c -v "^${Z2}$")
	note "samples NOT equal to sta_z (idle / DAC up)" "$PIN_IDLE / $PIN_DAC of 16"
	if [ "${PIN_IDLE:-0}" = "0" ] && [ "${PIN_DAC:-0}" = "0" ]; then
		say "  WARNING: every HPHL sample equals the zero reading, idle and with the DAC up."
		say "  The ADC may be clipping at 0 V. No HPHL number from it can be trusted yet."
	fi

	hdr "safety"
	PA_BAD=$(printf '%s' "$PA_SAMPLES" | tr ' ' '\n' | grep -v ':00$' | grep -c ':' || true)
	check "PA masked 00 at every sample" "${PA_BAD:-0}" "0"
	check "forced journal: this run's entries" \
	      "$(( $(rv "$FLOG_POST" forced_n) - F0 ))" "4"
	say "PA samples:$PA_SAMPLES"
	say ""
	say "-- dmesg, voltmeter lines --"
	dmesg 2>/dev/null | grep -E 'vm: |PA GUARD|WARNING|BUG' | tail -n 40

	emit_verdict
} > "$OUT" 2>&1
RC=$?
rm -rf "$T"
cat "$OUT"
say ""
say "evidence: $OUT"
exit $RC

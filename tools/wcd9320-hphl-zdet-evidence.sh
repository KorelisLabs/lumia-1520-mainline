#!/bin/sh
#
# r179: the HPH channel's scale from downstream impedance detection, and the
# DC contract's answer.
#
# Design: docs/audio/wcd9320-hph-zdet-mapping.md, section 7. Operator
# decision: faithful, both channels -- the static PA turns both HPH PAs on
# inside hphl_zdet only, with a ~50 mV / ~36 ms ramp, as on every headset
# insertion. The HEADSET MUST BE PLUGGED IN (it is the load being measured).
#
#   1  refusals: on RCO, and with the C3a prep up (the analog path not idle)
#   2  repeatability: zdet five times
#   3  the cross-check: Zl, Zr plausible for a headset and close to each other
#   4  sum or mean: (L2 - L0) at navg 16 against (L2' - L0') at navg 4
#   5  restore: both write sets identical before and after, 0x1ab back to 80
#   6  the answer: option 1's PA-on shift times the navg-4 scale, in mV
#
# Graded: validity, safety and the cross-check. The contract figure is
# reported with the cross-check beside it; it counts only if 3 passed.
#
# Usage:   sudo sh wcd9320-hphl-zdet-evidence.sh
# Exit:    0 PASS, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-hphl-zdet"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
REPS="${REPS:-5}"
Z_MIN_MOHM="${Z_MIN_MOHM:-16000}"
Z_MAX_MOHM="${Z_MAX_MOHM:-64000}"
Z_LR_TOL_PERMILLE="${Z_LR_TOL_PERMILLE:-100}"
# option 1 (wcd9320-hphl-pa-onchip-20260831T184924Z): +60.4 and +58.8 counts
OPTION1_COUNTS_X10="${OPTION1_COUNTS_X10:-596}"
CONTRACT_MV=50
VM_SET="110 128 129 131 133 14e 14f 150 171 174 1fe 3c0 3c1 3c3 3c6 3c7 3c8 3ce 3cf 3dc"
Z_SET="1aa 1af 1b5 1a9 1ac 1ad 2b5 30f 1a5 1ae 2bd 1b4 193 18b 1a2 183 184 185 181 192 320 1b1 1b7 361 362 363 364 1ab"

require_module_version
find_devices

ZD="$PGD/hphl_zdet"
PAS="$PGD/hphl_pa_state"
PAT="$PGD/hphl_pa_test"
CSRC="$PGD/clk_source_test"
CSRS="$PGD/clk_source_state"
MCLKT="$PGD/mclk_test"
FLOG="$PGD/forced_log"
MBHC="$PGD/mbhc_detect"
DACS="$PGD/hphl_dac_state"
REGS="/sys/kernel/debug/regmap/$PGD_NAME/registers"
DIVT=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -d "$d" ] && { DIVT="$d/mclk_div_test"; break; }
done

for f in "$ZD" "$PAS" "$PAT" "$CSRC" "$CSRS" "$MCLKT" "$FLOG" "$MBHC" "$DACS" "$REGS"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist (zdet-rc1 or later, as root)."; exit 2; }
done
[ -n "$DIVT" ] || { say "INVALID RUN: the PM8941 divider device is missing."; exit 2; }
[ "$(id -u)" = "0" ] || { say "INVALID RUN: need root."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
zds() { cat "$ZD" 2>/dev/null; }
pa_masked() {
	_pm=$(rv "$(cat "$PAS" 2>/dev/null)" pa_0x1ab)
	[ -n "$_pm" ] || { echo "READ-FAILED"; return; }
	printf '%02x' $(( 0x$_pm & 0x30 ))
}
PA_SAMPLES=""
pa_sample() { PA_SAMPLES="$PA_SAMPLES $1:$(pa_masked)"; }
set_dump() {	# set_dump <file>
	for _sd_a in $VM_SET $Z_SET; do
		_sd_v=$(grep -m1 "^$_sd_a:" "$REGS" 2>/dev/null | cut -d' ' -f2)
		# r180: RX1/RX2_B6 bit 3 is chip-owned status (volatile from r180,
		# so debugfs now shows the chip). Compared with it masked, exactly
		# as the driver's restore check does, and nothing else is masked.
		case "$_sd_a" in
		2b5|2bd) [ -n "$_sd_v" ] && _sd_v=$(printf '%02x' $(( 0x$_sd_v & 0xf7 ))) ;;
		esac
		printf '%s=%s ' "$_sd_a" "$_sd_v"
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
[ "$(rv "$(zds)" runs)" = "0" ]              || BAD="$BAD zdet_already_run"
if [ -n "$BAD" ]; then
	say "INVALID RUN: the starting state is not clean:$BAD"
	say "  Power cycle and run this once, first thing, headset plugged in."
	exit 2
fi
F0=$(rv "$(cat "$FLOG")" forced_n)

open_output "$OUTDIR/wcd9320-hphl-zdet-$STAMP.txt"
T=/tmp/.hphl-zdet-$$
mkdir -p "$T"

CLOCK_UP=0
clock_down() {
	[ "$CLOCK_UP" = "1" ] || return 0
	echo rco > "$CSRC" 2>/dev/null
	echo off > "$MCLKT" 2>/dev/null
	echo off > "$DIVT" 2>/dev/null
	CLOCK_UP=0
}
on_signal() { echo unprep > "$PAT" 2>/dev/null; clock_down; exit 2; }
trap on_signal INT TERM HUP

set_dump "$T/set-start"
pa_sample start

# ---- 1a: refused on the RC oscillator ----
echo measure > "$ZD" 2>/dev/null; RCO_RC=$?
RCO_ST=$(zds)
set_dump "$T/set-after-rco"

# ---- the clock ----
echo on > "$DIVT" 2>/dev/null; DIV_RC=$?
echo on > "$MCLKT" 2>/dev/null; MCLK_RC=$?
CLOCK_UP=1
echo mclk > "$CSRC" 2>/dev/null; SW_RC=$?
CLK_ST=$(cat "$CSRS" 2>/dev/null)
pa_sample mclk

# ---- 1b: refused with the C3a prep up ----
echo prep > "$PAT" 2>/dev/null; PREP_RC=$?
echo measure > "$ZD" 2>/dev/null; BUSY_RC=$?
BUSY_ST=$(zds)
echo unprep > "$PAT" 2>/dev/null
pa_sample prep-refusal

set_dump "$T/set-mclk-before"

# ---- 2: five measurements ----
i=1
while [ "$i" -le "$REPS" ]; do
	echo measure > "$ZD" 2>/dev/null; eval "Z${i}_RC=\$?"
	eval "Z${i}=\$(zds)"
	pa_sample "z$i"
	i=$((i + 1))
done
set_dump "$T/set-mclk-after"

clock_down
trap - INT TERM HUP
set_dump "$T/set-end"
pa_sample end
FLOG_POST=$(cat "$FLOG" 2>/dev/null)

# ------------------------------------------------------------------- report --
avg() { printf '%s\n' "$@" | awk 'NF{s+=$1;n++} END{if(n) printf "%d", s/n; else print "?"}'; }
spread() { printf '%s\n' "$@" | awk 'NF{if(mn==""||$1<mn)mn=$1; if(mx==""||$1>mx)mx=$1} END{print mx-mn}'; }

{
	say "WCD9320 r179 zdet: the HPH channel's scale"
	say "mode              : $MODE"
	say "stamp             : $STAMP"
	say "module            : $RUNNING_VERSION (expect $EXPECT_VERSION, $EXPECT_SOURCE)"
	say "control function  : $PGD_NAME"
	say "design            : docs/audio/wcd9320-hph-zdet-mapping.md section 7"
	say "stimulus          : downstream static PA on BOTH channels, ramp to ~50 mV for ~36 ms, inside hphl_zdet only"

	hdr "1. refusals"
	check "zdet on RCO is refused" "$([ "$RCO_RC" -ne 0 ] && echo yes || echo no)" "yes"
	check "nothing ran on RCO" "$(rv "$RCO_ST" runs)" "0"
	check "the write sets did not move on refusal" \
	      "$(cmp -s "$T/set-start" "$T/set-after-rco" && echo same || echo MOVED)" "same"
	check "C3a prep applied for the test" "$PREP_RC" "0"
	check "zdet with the prep up is refused" "$([ "$BUSY_RC" -ne 0 ] && echo yes || echo no)" "yes"
	check "nothing ran with the prep up" "$(rv "$BUSY_ST" runs)" "0"
	check "both refusals counted" "$(rv "$BUSY_ST" refusals)" "2"

	hdr "the clock"
	check "divider on" "$DIV_RC" "0"
	check "mclk vote" "$MCLK_RC" "0"
	check "switch to MCLK" "$SW_RC" "0"
	check "on_mclk" "$(rv "$CLK_ST" on_mclk)" "1"
	check "cdc_alive" "$(rv "$CLK_ST" cdc_alive)" "1"

	hdr "2. repeatability, $REPS measurements"
	say "  run rc valid  L0     L1     L2     R0     R1     R2     L0'    L2'    Zl_mohm  Zr_mohm  uV/cnt16 uV/cnt4"
	ZLS=""; ZRS=""; S16S=""; S4S=""; RATS=""
	i=1
	while [ "$i" -le "$REPS" ]; do
		eval "_s=\$Z$i; _rc=\$Z${i}_RC"
		printf '  %-3s %-2s %-5s %-6s %-6s %-6s %-6s %-6s %-6s %-6s %-6s %-8s %-8s %-8s %s\n' \
			"$i" "$_rc" "$(rv "$_s" valid)" \
			"$(rv "$_s" l0)" "$(rv "$_s" l1)" "$(rv "$_s" l2)" \
			"$(rv "$_s" r0)" "$(rv "$_s" r1)" "$(rv "$_s" r2)" \
			"$(rv "$_s" l0n4)" "$(rv "$_s" l2n4)" \
			"$(rv "$_s" zl_mohm)" "$(rv "$_s" zr_mohm)" \
			"$(rv "$_s" scale16_uv)" "$(rv "$_s" scale4_uv)"
		check "run $i rc" "$_rc" "0"
		check "run $i valid" "$(rv "$_s" valid)" "1"
		check "run $i restore mismatches" "$(rv "$_s" restore_mismatch)" "0"
		ZLS="$ZLS $(rv "$_s" zl_mohm)"; ZRS="$ZRS $(rv "$_s" zr_mohm)"
		S16S="$S16S $(rv "$_s" scale16_uv)"; S4S="$S4S $(rv "$_s" scale4_uv)"
		RATS="$RATS $(awk -v a="$(rv "$_s" l2)" -v b="$(rv "$_s" l0)" -v c="$(rv "$_s" l2n4)" -v d="$(rv "$_s" l0n4)" \
			'BEGIN{ if (c-d != 0) printf "%d", 1000*(a-b)/(c-d); else print 0 }')"
		i=$((i + 1))
	done
	ZL=$(avg $ZLS); ZR=$(avg $ZRS); S16=$(avg $S16S); S4=$(avg $S4S)
	note "Zl mean / spread (mohm)" "$ZL / $(spread $ZLS)"
	note "Zr mean / spread (mohm)" "$ZR / $(spread $ZRS)"
	note "scale navg16 mean / spread" "$S16 / $(spread $S16S) uV per count"
	note "scale navg4 mean / spread" "$S4 / $(spread $S4S) uV per count"

	hdr "3. the cross-check: a plausible headset"
	ZOK=0
	[ "$ZL" -ge "$Z_MIN_MOHM" ] 2>/dev/null && [ "$ZL" -le "$Z_MAX_MOHM" ] 2>/dev/null &&
	[ "$ZR" -ge "$Z_MIN_MOHM" ] 2>/dev/null && [ "$ZR" -le "$Z_MAX_MOHM" ] 2>/dev/null && ZOK=1
	check_cond "Zl and Zr within $Z_MIN_MOHM..$Z_MAX_MOHM mohm" "$ZOK" \
		"Zl $ZL Zr $ZR mohm" "Zl $ZL Zr $ZR mohm"
	LRD=$(awk -v a="$ZL" -v b="$ZR" 'BEGIN{ m=(a+b)/2; d=a-b; if(d<0)d=-d; if (m>0) printf "%d", 1000*d/m; else print 9999 }')
	check_cond "Zl and Zr within ${Z_LR_TOL_PERMILLE} permille of each other" \
		"$([ "$LRD" -le "$Z_LR_TOL_PERMILLE" ] && echo 1 || echo 0)" \
		"differ by $LRD permille" "differ by $LRD permille"
	XCHK=$([ "$ZOK" = "1" ] && [ "$LRD" -le "$Z_LR_TOL_PERMILLE" ] && echo PASS || echo FAIL)

	hdr "4. sum or mean"
	RAT=$(avg $RATS)
	note "(L2-L0) navg16 / (L2'-L0') navg4" "$RAT permille (~4000 if STA sums, ~1000 if it averages)"

	hdr "5. restore"
	check "both write sets identical across the five runs" \
	      "$(cmp -s "$T/set-mclk-before" "$T/set-mclk-after" && echo same || echo MOVED)" "same"
	check "back on RCO, identical to the start" \
	      "$(cmp -s "$T/set-start" "$T/set-end" && echo same || echo MOVED)" "same"
	check "0x1ab at the end" "$(grep -m1 '^1ab:' "$REGS" | cut -d' ' -f2)" "80"
	# neither the prep (gain and pop/click only) nor the zdet forces anything
	check "no forced write by this run" "$(( $(rv "$FLOG_POST" forced_n) - F0 ))" "0"

	hdr "6. THE ANSWER: option 1's PA-on shift in millivolts"
	MV10=$(awk -v c="$OPTION1_COUNTS_X10" -v s="$S4" 'BEGIN{ printf "%d", c*s/1000 }')
	note "option 1 shift" "$(awk -v c="$OPTION1_COUNTS_X10" 'BEGIN{printf "%.1f", c/10}') counts (navg 4)"
	note "scale (navg 4)" "$S4 uV per count"
	note "PA-on DC offset" "$(awk -v m="$MV10" 'BEGIN{printf "%.1f", m/10}') mV   (contract: <= $CONTRACT_MV mV)"
	note "cross-check" "$XCHK"
	if [ "$XCHK" = "PASS" ]; then
		if [ "$MV10" -le $((CONTRACT_MV * 10)) ] && [ "$MV10" -ge $((-CONTRACT_MV * 10)) ]; then
			say "CONTRACT: |Von - Voff| = $(awk -v m="$MV10" 'BEGIN{printf "%.1f", m/10}') mV <= $CONTRACT_MV mV -- WITHIN, qualified as on-chip"
		else
			say "CONTRACT: |Von - Voff| = $(awk -v m="$MV10" 'BEGIN{printf "%.1f", m/10}') mV > $CONTRACT_MV mV -- OUTSIDE"
		fi
	else
		say "CONTRACT: NOT DECIDED -- the impedance cross-check failed, so the scale is not trusted"
	fi

	hdr "safety"
	PA_BAD=$(printf '%s' "$PA_SAMPLES" | tr ' ' '\n' | grep -v ':00$' | grep -c ':' || true)
	check "PA masked 00 at every sample outside the zdet" "${PA_BAD:-0}" "0"
	say "PA samples:$PA_SAMPLES"
	say ""
	say "-- forced journal --"
	printf '%s\n' "$FLOG_POST" | head -3
	say ""
	say "-- dmesg, zdet lines --"
	dmesg 2>/dev/null | grep -E 'zdet: |c2b: 0x1ab|PA GUARD|WARNING|BUG' | tail -n 40

	emit_verdict
} > "$OUT" 2>&1
RC=$?
rm -rf "$T"
cat "$OUT"
say ""
say "evidence: $OUT"
exit $RC

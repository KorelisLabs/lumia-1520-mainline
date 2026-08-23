#!/bin/sh
#
# C2a: is the HPHL class-H power state reversible?
#
# THE CLAIM UNDER TEST
#
#   The class-H support circuitry -- buck, negative charge pump, class-H block
#   -- can be brought from its pristine idle state into the downstream-required
#   configuration and returned to that state, twice, with the HPHL DAC and the
#   PA held off throughout.
#
# WHY "RETURNS TO POR" IS THE WRONG CRITERION
#
# Downstream's teardown (turnoff_postpa) restores six writes against 46 on the
# way in. It deliberately leaves the configuration programmed, because the next
# enable reprograms it. A gate demanding a POR baseline would fail a correct
# system. So the registers are judged in three buckets:
#
#   POWER STATE       must return exactly to its pre-run value
#   CONFIGURATION     must equal the mapped downstream programmed value
#   OUT OF SCOPE      must not move at all
#
# Every expected value is DERIVED: the measured baseline with the transcribed
# masked writes applied. Only the starting point is observed -- the transforms
# come from the downstream tables. If the hardware disagrees with a transform,
# the mapping is wrong and that matters more than the milestone.
#
# THE SECOND CYCLE IS MANDATORY
#
# Analog rails can have hysteresis digital blocks do not. Cycle 1 converts POR
# configuration into the downstream steady state; cycle 2 must be reversible
# from that steady state. If cycle 2 differs, there is no reusable lifecycle
# and the DAC must not be built on it.
#
#   cycle 1:  E4 -> A7 -> A6
#   cycle 2:  A6 -> A7 -> A6
#
# Exit: 0 reversible, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-clsh-reversibility"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-clsh-$$"

require_module_version
find_devices

CT="$PGD/clsh_test"
CS="$PGD/clsh_state"

[ -e "$CT" ] || {
	say "INVALID RUN: $CT does not exist."
	say "  The running codec must be clsh-rc1 or later."
	exit 2
}

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
st() { cat "$CS" 2>/dev/null; }

# --------------------------------------------------------- the expectations --
#
# Expectations are BASELINE-RELATIVE, not POR-relative.
#
# The first run of this gate refused because 0x183, 0x189 and 0x18c read ce/5b/51
# against header PORs of cc/ab/58. All three are in 0x180-0x1e4, the fuse-loaded
# analog trim range this project already documented as diverging from the
# header. Hardcoding POR was a bug in the gate, not a fault in the silicon.
#
# So each register carries the masked writes the driver applies, and the
# expected value is computed from whatever the device actually reads. Every
# assertion is still derived from the transcribed write tables -- only the
# starting point is measured rather than assumed.
#
# reg_key | enable transforms | teardown transforms   (mask,val pairs)
#
TRANSFORMS="b1_0x320|20,20 02,02 40,00 01,01 02,02 08,00|08,00 10,00 01,00
buck1_0x181|04,04 08,00 80,80|80,00
ncpen_0x192|01,01|01,00
cp_0x30c|01,01|01,00
b2_0x321|03,01 0c,04 f0,30|
b3_0x322|f0,30 0f,0b|
vars_0x323|03,00 0c,04 10,00|
ncps_0x194|10,00 0f,08 20,20|
buck3_0x183|04,00 08,00|
buck4_0x184|ff,ff|
buck5_0x185|02,03|
ccl1_0x189|f0,50|
ccl3_0x18b|03,00 0b,00|
ccl4_0x18c|0b,00|"

# POWER IS PER-BIT, NOT PER-REGISTER.
#
# The first run taught this: b1_0x320 ends at a6 rather than its e4 baseline,
# and buck1_0x181 at 25 rather than 21, because both registers hold
# CONFIGURATION bits alongside their power bits. The enable sets configuration
# the teardown has no reason to undo. A whole-register "returned to base" check
# is therefore wrong, and failed a correct system.
#
# So each power register carries the mask of the bits the teardown actually
# restores, and only those bits must come back.
#
#   b1_0x320  0x19  clsh block (0x01), comp req (0x08), EAR compute (0x10)
#   buck1     0x80  buck enable
#   ncpen     0x01  NCP enable
#   cp        0x01  charge pump
#
POWER_MASKS="b1_0x320:19 buck1_0x181:80 ncpen_0x192:01 cp_0x30c:01"
POWER_KEYS="b1_0x320 buck1_0x181 ncpen_0x192 cp_0x30c"

OFFLIMITS="dac_0x1b1
pa_0x1ab
ear_0x1bc"

# apply <hexbase> <pairs...> -> hex result
apply() {
	_v=$((0x$1))
	shift
	for _p in "$@"; do
		_m=$((0x${_p%%,*}))
		_x=$((0x${_p##*,}))
		_v=$(( (_v & ~_m) | (_x & _m) ))
	done
	printf '%02x' $((_v & 0xff))
}

# ------------------------------------------------------------ preconditions --
PRE=$(st)
BASE_BAD=""
[ "$(rv "$PRE" on)" = "0" ] || BASE_BAD="$BASE_BAD already_on"
[ "$(rv "$PRE" enables)" = "0" ] || BASE_BAD="$BASE_BAD prior_enables"
#
# 0x320 is in the digital block, above the fuse-loaded analog trim range, so
# its POR of e4 IS trustworthy and a deviation means something already touched
# class-H on this boot.
#
[ "$(rv "$PRE" b1_0x320)" = "e4" ] ||
	BASE_BAD="$BASE_BAD b1=$(rv "$PRE" b1_0x320)(want e4)"
if [ -n "$BASE_BAD" ]; then
	say "INVALID RUN: the class-H baseline is not pristine:$BASE_BAD"
	say "  Cold boot and run this once."
	exit 2
fi

#
# Derive every expectation from the measured baseline. Written to a file
# because sh has no arrays and a subshell pipeline would lose the values.
#
EXPFILE="/tmp/.clsh-exp-$$"
: > "$EXPFILE"
printf '%s
' "$TRANSFORMS" | while IFS='|' read -r _k _en _td; do
	[ -n "$_k" ] || continue
	_b=$(rv "$PRE" "$_k")
	_e=$(apply "$_b" $_en)
	_a=$(apply "$_e" $_td)
	echo "$_k $_b $_e $_a" >> "$EXPFILE"
done

snap_dmesg
open_output "$OUTDIR/wcd9320-clsh-reversibility-$STAMP.txt"

# ------------------------------------------------------------------ the run --
OFF_BEFORE=""
for k in $OFFLIMITS; do OFF_BEFORE="$OFF_BEFORE $k=$(rv "$PRE" "$k")"; done

echo clsh-on > "$CT" 2>/dev/null; ON1_RC=$?
EN1=$(st)
echo clsh-off > "$CT" 2>/dev/null; OFF1_RC=$?
AF1=$(st)

echo clsh-on > "$CT" 2>/dev/null; ON2_RC=$?
EN2=$(st)
echo clsh-off > "$CT" 2>/dev/null; OFF2_RC=$?
AF2=$(st)

OFF_AFTER=""
for k in $OFFLIMITS; do OFF_AFTER="$OFF_AFTER $k=$(rv "$AF2" "$k")"; done

snap_dmesg
CP_WARN=$(dmesg 2>/dev/null | grep -ci 'chargepump\|Unbalanced disable' || true)
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
CLSH_ERR=$(dmesg 2>/dev/null | grep -c 'clsh:.*failed' || true)
for v in CP_WARN WARNS CLSH_ERR; do eval "[ -n \"\$$v\" ] || $v=0"; done

{
	hdr "the pristine baseline"
	printf '%s\n' "$PRE" | sed 's/^/  /'

	hdr "cycle 1 enabled"
	printf '%s\n' "$EN1" | sed 's/^/  /'
	hdr "cycle 1 after teardown"
	printf '%s\n' "$AF1" | sed 's/^/  /'
	hdr "cycle 2 enabled"
	printf '%s\n' "$EN2" | sed 's/^/  /'
	hdr "cycle 2 after teardown"
	printf '%s\n' "$AF2" | sed 's/^/  /'

	hdr "the transition the milestone rests on"
	say "predicted   E4 -> A7 -> A6   then   A6 -> A7 -> A6"
	say "observed    $(rv "$PRE" b1_0x320) -> $(rv "$EN1" b1_0x320) -> $(rv "$AF1" b1_0x320)   then   $(rv "$AF1" b1_0x320) -> $(rv "$EN2" b1_0x320) -> $(rv "$AF2" b1_0x320)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "cycle 1 enable accepted" "$ON1_RC" "0"
	check "cycle 1 teardown accepted" "$OFF1_RC" "0"
	check "cycle 2 enable accepted" "$ON2_RC" "0"
	check "cycle 2 teardown accepted" "$OFF2_RC" "0"

	say ""
	say "-- POWER STATE: reaches the derived value, then returns exactly --"
	while read -r k base en af; do
		case " $POWER_KEYS " in *" $k "*) ;; *) continue ;; esac
		note "$k" "base $base -> enabled $en -> after $af (derived)"
		check "c1 on  $k" "$(rv "$EN1" "$k")" "$en"
		check "c1 off $k" "$(rv "$AF1" "$k")" "$af"
		check "c2 on  $k" "$(rv "$EN2" "$k")" "$en"
		check "c2 off $k" "$(rv "$AF2" "$k")" "$af"
		#
		# Only the power BITS must return. The rest of these registers
		# is configuration the teardown deliberately leaves programmed.
		#
		for _pm in $POWER_MASKS; do
			[ "${_pm%%:*}" = "$k" ] || continue
			_m=$((0x${_pm##*:}))
			check "c1 off $k power bits" 				"$(printf '%02x' $(( $((0x$(rv "$AF1" "$k"))) & _m )))" 				"$(printf '%02x' $(( $((0x$base)) & _m )))"
			check "c2 off $k power bits" 				"$(printf '%02x' $(( $((0x$(rv "$AF2" "$k"))) & _m )))" 				"$(printf '%02x' $(( $((0x$base)) & _m )))"
		done
	done < "$EXPFILE"

	say ""
	say "-- CONFIGURATION: reaches the derived value and stays programmed --"
	while read -r k base en af; do
		case " $POWER_KEYS " in *" $k "*) continue ;; esac
		note "$k" "base $base -> enabled $en -> after $af (derived)"
		check "c1 on  $k" "$(rv "$EN1" "$k")" "$en"
		check "c1 off $k" "$(rv "$AF1" "$k")" "$af"
		check "c2 on  $k" "$(rv "$EN2" "$k")" "$en"
		check "c2 off $k" "$(rv "$AF2" "$k")" "$af"
	done < "$EXPFILE"

	say ""
	say "-- OUT OF SCOPE: the DAC, the PA and the earpiece must not move --"
	check_cond "no out-of-scope register moved" \
		"$([ "$OFF_BEFORE" = "$OFF_AFTER" ] && echo 1 || echo 0)" \
		"before:$OFF_BEFORE  after:$OFF_AFTER" "$OFF_AFTER"
	for k in $OFFLIMITS; do
		check "stayed put: $k" "$(rv "$EN2" "$k")" "$(rv "$PRE" "$k")"
	done

	say ""
	say "-- the lifecycle is reusable, not a one-shot --"
	check_cond "cycle 2 enabled == cycle 1 enabled" \
		"$([ "$(printf '%s' "$EN1" | grep -v enables)" = "$(printf '%s' "$EN2" | grep -v enables)" ] && echo 1 || echo 0)" \
		"the second enable produced a different state"
	check_cond "cycle 2 teardown == cycle 1 teardown" \
		"$([ "$(printf '%s' "$AF1" | grep -v enables)" = "$(printf '%s' "$AF2" | grep -v enables)" ] && echo 1 || echo 0)" \
		"the second teardown produced a different state"

	say ""
	say "-- the charge pump was balanced --"
	check "charge-pump refs released" "$(rv "$AF2" cp_refs)" "0"
	check "no chargepump warning" "$CP_WARN" "0"
	check "enables == disables" "$(rv "$AF2" enables)" "$(rv "$AF2" disables)"
	check "two cycles ran" "$(rv "$AF2" enables)" "2"
	check "writes as mapped (46 in + 6 out, twice)" "$(rv "$AF2" writes)" "104"
	check "no clsh failure logged" "$CLSH_ERR" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE CLASS-H POWER STATE IS REVERSIBLE."
		say ""
		say "CDC_CLSH_B1_CTL went E4 -> A7 -> A6, then A6 -> A7 -> A6, exactly"
		say "as derived from the downstream write tables. Every power BIT"
		say "returned to its pre-run value -- per bit, because B1_CTL and"
		say "BUCK_MODE_1 carry configuration alongside their power bits and"
		say "do not return to the baseline as whole registers. Every"
		say "configuration register settled on its mapped programmed value"
		say "and stayed there; the DAC, PA and earpiece did not move."
		say ""
		say "Two cycles produced identical results, so this is a reusable"
		say "lifecycle rather than a one-way transition. The HPHL DAC may now"
		say "be built on it, because its teardown is already proven."
		say ""
		say "WHAT THIS DOES NOT CLAIM. Nothing was converted and nothing was"
		say "audible. The DAC and PA were off throughout, and no audio data"
		say "was streamed. This is a power-state lifecycle result only."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "Do NOT proceed to the DAC. Every expected value here was derived"
		say "from the downstream write tables, so a mismatch means the mapping"
		say "is wrong -- revisit it rather than adjusting the expectation to"
		say "match what the hardware happened to do."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE" "$EXPFILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the pristine baseline/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

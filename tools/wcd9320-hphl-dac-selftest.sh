#!/bin/sh
#
# Offline proof that the C2b derivation is right, and that it can be wrong.
#
# WHY THIS EXISTS
#
# Both C2a gate failures were arithmetic, not silicon: a POR baseline
# hardcoded for three fuse-loaded registers, and a whole-register "returns to
# base" assertion on two registers carrying configuration alongside power. Both
# were found by spending a boot cycle on hardware. Neither needed hardware to
# find.
#
# So this runs the same derivation the gate runs, against synthetic baselines
# chosen to expose exactly those two mistakes, plus the C2b-specific one: a
# compander predicted from taiko_discharge_comp() instead of from the 48 kHz
# operating point that overwrites it.
#
# THE NEGATIVE CASES ARE THE POINT. A gate that cannot fail is worse than no
# gate, so three cases here assert that a WRONG expectation is rejected. If
# those ever start passing, the checker has stopped checking.
#
# No hardware, no root, no kernel:
#   sh tools/wcd9320-hphl-dac-selftest.sh
#
# Exit: 0 all cases pass, 1 otherwise.

set -u

DIR_SELF=$(dirname "$0")
. "$DIR_SELF/wcd9320-hphl-dac-expect.sh"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0

ck() {	# ck <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '    PASS  %-52s %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	else
		printf '    FAIL  %-52s got=[%s] want=[%s]\n' "$1" "$2" "$3"
		FAIL=$((FAIL + 1))
	fi
}

ckno() {	# ckno <label> <actual> <must-not-equal>
	if [ "$2" != "$3" ]; then
		printf '    PASS  %-52s %s != %s\n' "$1" "$2" "$3"
		PASS=$((PASS + 1))
	else
		printf '    FAIL  %-52s wrongly equal: %s\n' "$1" "$2"
		FAIL=$((FAIL + 1))
	fi
}

get() {	# get <file> <key> <col 2..5>
	awk -v k="$2" -v c="$3" '$1 == k { print $c }' "$1"
}

# ---------------------------------------------------------------- 1. apply --
echo "1. c2b_apply folds masked writes the way regmap_update_bits does"
ck "no transform is identity"            "$(c2b_apply e4 -)"            "e4"
ck "single masked write"                 "$(c2b_apply 00 30,10)"        "10"
ck "two writes compose to 0x14"          "$(c2b_apply 00 30,10 0c,04)"  "14"
ck "later write wins within its mask"    "$(c2b_apply 00 f0,50 f0,b0)"  "b0"
ck "disjoint masks both survive"         "$(c2b_apply 00 f0,b0 0f,09)"  "b9"
ck "full-width write replaces"           "$(c2b_apply ff ff,28)"        "28"
ck "clearing a bit leaves the rest"      "$(c2b_apply ff 20,00)"        "df"
ck "value bits outside the mask ignored" "$(c2b_apply 00 01,ff)"        "01"

# ------------------------------------------------------- 2. the real states --
#
# A plausible pristine baseline. The three fuse-range registers are given
# values that are NOT their header PORs, because that is the situation C2a
# actually met.
echo
echo "2. derivation from a pristine baseline"
BASE="on=0 enables=0 disables=0 c2b_writes=0 bias_refs=0 guard_tripped=0
dsm_0x3b0=00 dac_0x1b1=00 rdac_0x30d=00 bias_0x1a2=a5
lgain_0x1ae=1a rgain_0x1b4=1a b4_0x373=3c
compb2_0x371=00 compb3_0x372=00 compfs_0x377=03
guard pa_0x1ab=80 hphr_0x1b7=00 ear_0x1bc=00
guard line1_0x1cf=00 spkren_0x1df=00 spkrgain_0x1e0=00"

c2b_derive "$BASE" "$W/exp"

ck "0x3b0 enabled is 0x14"        "$(get "$W/exp" dsm_0x3b0 4)"  "14"
ck "0x3b0 returns to 00"          "$(get "$W/exp" dsm_0x3b0 5)"  "00"
ck "0x1b1 enabled is 0xc0"        "$(get "$W/exp" dac_0x1b1 4)"  "c0"
ck "0x1b1 returns to 00"          "$(get "$W/exp" dac_0x1b1 5)"  "00"
ck "0x30d bit 1 set at the DAC"   "$(get "$W/exp" rdac_0x30d 4)" "02"
ck "0x30d bit 1 clear after"      "$(get "$W/exp" rdac_0x30d 5)" "00"
ck "RX bias sets bit 7 only"      "$(get "$W/exp" bias_0x1a2 4)" "a5"
ck "RX bias clears bit 7 only"    "$(get "$W/exp" bias_0x1a2 5)" "25"
ck "0x373 bit 7 clear (2.15 V)"   "$(get "$W/exp" b4_0x373 3)"   "3c"
ck "compander B2 at 48 kHz"       "$(get "$W/exp" compb2_0x371 3)" "b9"
ck "compander B3 at 48 kHz"       "$(get "$W/exp" compb3_0x372 3)" "28"
ck "compander rate field 3"       "$(get "$W/exp" compfs_0x377 3)" "03"

# The gain source is the one that does NOT come back.
#
# ASSERT THE BIT, NOT THE BYTE. The first draft of this file hand-wrote 0a and
# 2a here, having silently assumed a baseline with bit 5 already set; the real
# baseline in this fixture is 0x1a, where bit 5 is clear, so the answers are 1a
# and 3a. The derivation was right and the hand-written constant was wrong --
# which is the same mistake, in the same direction, that this whole file exists
# to catch. Whether 0x1ae comes up with bit 5 set is a property of the part we
# have not measured, so nothing here may depend on it.
ck "gain source bit clear while the compander drives" \
   "$(printf '%02x' $(( 0x$(get "$W/exp" lgain_0x1ae 3) & 0x20 )))" "00"
ck "gain source bit set once it is handed back" \
   "$(printf '%02x' $(( 0x$(get "$W/exp" lgain_0x1ae 5) & 0x20 )))" "20"
ck "the other seven bits are untouched throughout" \
   "$(printf '%02x' $(( 0x$(get "$W/exp" lgain_0x1ae 5) & 0xdf )))" \
   "$(printf '%02x' $(( 0x$(get "$W/exp" lgain_0x1ae 2) & 0xdf )))"

# Both polarities, because we do not know which one the silicon will show and
# the gate must be correct either way.
echo
echo "2b. the gain handoff is correct from either starting polarity"
for gb in 00 20 1a 3a ff; do
	ALT=$(printf '%s' "$BASE" | sed "s/lgain_0x1ae=1a/lgain_0x1ae=$gb/")
	c2b_derive "$ALT" "$W/expg"
	ck "base $gb: compander drives (bit 5 clear)" \
	   "$(printf '%02x' $(( 0x$(get "$W/expg" lgain_0x1ae 3) & 0x20 )))" "00"
	ck "base $gb: handed back (bit 5 set)" \
	   "$(printf '%02x' $(( 0x$(get "$W/expg" lgain_0x1ae 5) & 0x20 )))" "20"
	ck "base $gb: rest of the register preserved" \
	   "$(printf '%02x' $(( 0x$(get "$W/expg" lgain_0x1ae 5) & 0xdf )))" \
	   "$(printf '%02x' $(( 0x$gb & 0xdf )))"
done

# ----------------------------------------------- 3. baseline independence ----
#
# The C2a mistake, in its C2b form: a fuse-loaded register whose baseline is
# not the header POR must still land on the right ANSWER, and the answer for
# the trim bits is "unchanged".
echo
echo "3. fuse-loaded baselines change the value, never the bits we assert"
for b in 00 25 a5 ff 5b; do
	ALT=$(printf '%s' "$BASE" | sed "s/bias_0x1a2=a5/bias_0x1a2=$b/")
	c2b_derive "$ALT" "$W/exp2"
	_on=$(get "$W/exp2" bias_0x1a2 4)
	_af=$(get "$W/exp2" bias_0x1a2 5)
	ck "base $b: bit 7 set on"    "$(printf '%02x' $(( 0x$_on & 0x80 )))" "80"
	ck "base $b: bit 7 clear off" "$(printf '%02x' $(( 0x$_af & 0x80 )))" "00"
	ck "base $b: trim bits kept"  "$(printf '%02x' $(( 0x$_af & 0x7f )))" \
	                              "$(printf '%02x' $(( 0x$b  & 0x7f )))"
done

# --------------------------------------------------- 4. cycle 2 idempotence --
#
# Cycle 1 converts a pristine part into the downstream steady state; cycle 2
# must be reversible FROM that steady state and land in the same place. If it
# does not, there is no reusable lifecycle and the milestone is not real.
echo
echo "4. cycle 2 from the post-cycle-1 state reaches the same values"
STEADY=$(printf '%s' "$BASE" |
	sed "s/lgain_0x1ae=1a/lgain_0x1ae=$(get "$W/exp" lgain_0x1ae 5)/;
	     s/rgain_0x1b4=1a/rgain_0x1b4=$(get "$W/exp" rgain_0x1b4 5)/;
	     s/compb2_0x371=00/compb2_0x371=$(get "$W/exp" compb2_0x371 5)/;
	     s/compb3_0x372=00/compb3_0x372=$(get "$W/exp" compb3_0x372 5)/;
	     s/bias_0x1a2=a5/bias_0x1a2=$(get "$W/exp" bias_0x1a2 5)/")
c2b_derive "$STEADY" "$W/exp3"
for k in dsm_0x3b0 dac_0x1b1 rdac_0x30d lgain_0x1ae compb2_0x371 compb3_0x372; do
	ck "cycle 2 enabled matches cycle 1: $k" \
	   "$(get "$W/exp3" "$k" 4)" "$(get "$W/exp" "$k" 4)"
	ck "cycle 2 after matches cycle 1: $k" \
	   "$(get "$W/exp3" "$k" 5)" "$(get "$W/exp" "$k" 5)"
done

# ------------------------------------------------------ 5. the negatives -----
#
# Each of these is a mistake that has actually been made on this project, or
# one step away from it. They must all be REJECTED.
echo
echo "5. wrong expectations are rejected (these must all pass)"

# 5a. C2a's first failure: asserting a header POR for a fuse-loaded register.
ckno "a POR baseline gives a different answer than the measured one" \
     "$(c2b_apply 00 80,80)" "$(c2b_apply a5 80,80)"

# 5b. The C2b-specific one: predicting the compander from the discharge write
#     instead of the operating point that overwrites it.
ckno "discharge-only prediction differs from the 48 kHz value" \
     "$(c2b_apply 00 f0,50)" "$(c2b_apply 00 f0,50 f0,b0 0f,09)"
ck  "the discharge-only answer is the WRONG one people would write" \
     "$(c2b_apply 00 f0,50)" "50"

# 5c. The one-bit DAC: powering the DAC without connecting its input looks
#     like success and proves nothing.
ckno "0x1b1 with only bit 7 is not the enabled value" \
     "$(c2b_apply 00 80,80)" "$(c2b_apply 00 40,40 80,80)"
ck  "bit 7 alone is 80, not c0" "$(c2b_apply 00 80,80)" "80"

# 5d. A ZOH written as a constant rather than derived: right answer for the
#     right source, wrong answer for the speaker, which is the case a constant
#     would silently get wrong.
ck  "derived ZOH for HPHL"  "$(c2b_apply 00 30,10 0c,04)" "14"
ckno "a constant 0x04 ZOH is wrong for the SPKR source" \
     "$(c2b_apply 00 30,20 0c,04)" "$(c2b_apply 00 30,20 0c,08)"

# 5e. A missing key must be visibly missing, not silently zero.
echo
echo "6. a state file missing a register fails loudly"
c2b_derive "dsm_0x3b0=00" "$W/exp4"
ck "absent key reports MISSING" "$(get "$W/exp4" dac_0x1b1 2)" "MISSING"
ck "present key still derives"  "$(get "$W/exp4" dsm_0x3b0 4)" "14"

# ------------------------------------------------------- 7. the constants ----
echo
echo "7. the derived write counts are self-consistent"
ck "33 per cycle (r174 adds the forced 0x314 pair)" \
   "$C2B_WRITES_PER_CYCLE" "33"
ck "66 for two cycles" "$C2B_WRITES_TOTAL" \
   "$((C2B_WRITES_PER_CYCLE * 2))"
# The two extra writes per cycle ARE the paired 0x314 enable and inverse.
ck "the r174 delta is exactly the forced pair" \
   "$((C2B_WRITES_PER_CYCLE - 31))" "2"
ck "class-H total unchanged from C2a" "$C2B_CLSH_TOTAL" "104"
ck "PA mask covers both enables" "$C2B_PA_MASK" "30"

# --------------------------------------------- 8. the forced-write journal ---
#
# r174 cannot verify 0x314 or 0x30d by readback, so the gate's only evidence
# that the required transactions happened -- IN BOTH DIRECTIONS -- is the
# driver's journal. That makes the journal check load-bearing, and a
# load-bearing check has to be shown capable of failing.
#
# fj <blob> -> the verdict the gate's journal logic would reach: OK, or the
# first entry that is wrong. Mirrors the gate exactly.
fj() {
	_blob=$1
	_n=$(printf '%s' "$_blob" | tr ' ' '\n' | sed -n 's/^forced_n=//p' | head -n1)
	[ "$_n" = "8" ] || { echo "count=$_n"; return; }
	_i=0
	while [ "$_i" -lt 8 ]; do
		case $((_i % 4)) in
		0) _wr=314; _wm=ff; _wd=set   ;;
		1) _wr=30d; _wm=02; _wd=set   ;;
		2) _wr=30d; _wm=02; _wd=clear ;;
		3) _wr=314; _wm=ff; _wd=clear ;;
		esac
		for _f in reg:$_wr mask:$_wm dir:$_wd; do
			_k=${_f%%:*}; _v=${_f#*:}
			_g=$(printf '%s' "$_blob" | tr ' ' '\n' |
			     sed -n "s/^f${_i}_${_k}=//p" | head -n1)
			[ "$_g" = "$_v" ] || { echo "f${_i}_${_k}=$_g"; return; }
		done
		_i=$((_i + 1))
	done
	echo OK
}

# One complete, correct run: four operations per cycle, twice.
GOOD="forced_n=8"
_i=0
while [ "$_i" -lt 8 ]; do
	case $((_i % 4)) in
	0) _r=314; _m=ff; _v=03; _d=set   ;;
	1) _r=30d; _m=02; _v=02; _d=set   ;;
	2) _r=30d; _m=02; _v=00; _d=clear ;;
	3) _r=314; _m=ff; _v=00; _d=clear ;;
	esac
	GOOD="$GOOD f${_i}_reg=$_r f${_i}_mask=$_m f${_i}_val=$_v f${_i}_hw=00 f${_i}_dir=$_d"
	_i=$((_i + 1))
done

echo
echo "8. the forced-write journal check accepts a correct run"
ck "eight correct operations" "$(fj "$GOOD")" "OK"

echo
echo "9. and REJECTS every way it can go wrong (these must all pass)"

# 9a. The inverse never issued -- the exact hazard r174 exists to prevent.
#     Six operations: both enables, but only one clear per cycle.
SHORT=$(printf '%s' "$GOOD" | sed -e 's/forced_n=8/forced_n=6/')
ck "missing inverse is caught" "$(fj "$SHORT")" "count=6"

# 9b. A clear issued as a set. The driver derives dir from the value under the
#     mask, so this is what a botched inverse would actually look like.
BADDIR=$(printf '%s' "$GOOD" | sed -e 's/f2_dir=clear/f2_dir=set/')
ck "inverse issued as a set is caught" "$(fj "$BADDIR")" "f2_dir=set"

# 9c. The wrong register -- 0x30d cleared where 0x314 was due.
BADREG=$(printf '%s' "$GOOD" | sed -e 's/f3_reg=314/f3_reg=30d/')
ck "wrong register is caught" "$(fj "$BADREG")" "f3_reg=30d"

# 9d. A masked write where downstream uses a full byte. 0x314 must go out as
#     0xff/0x03, matching snd_soc_write(), not as a read-modify-write.
BADMASK=$(printf '%s' "$GOOD" | sed -e 's/f0_mask=ff/f0_mask=03/')
ck "masked 0x314 write is caught" "$(fj "$BADMASK")" "f0_mask=03"

# 9e. Cycle 2 missing entirely, which a total-only check would miss if the
#     count were fudged. Here the count is right but the entries stop.
HALF="forced_n=8 f0_reg=314 f0_mask=ff f0_dir=set f1_reg=30d f1_mask=02 f1_dir=set f2_reg=30d f2_mask=02 f2_dir=clear f3_reg=314 f3_mask=ff f3_dir=clear"
ck "truncated second cycle is caught" "$(fj "$HALF")" "f4_reg="

# 9f. And a readback of 00 must NOT be treated as a failure: it is the
#     expected phenomenon, and the whole class exists because it means
#     nothing either way.
ALLZERO=$(printf '%s' "$GOOD" | sed -e 's/f1_hw=00/f1_hw=00/')
ck "hw=00 is not a failure" "$(fj "$ALLZERO")" "OK"

echo
printf 'selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

# shellcheck shell=sh
#
# C3a expectations: the transforms, the buckets, and the arithmetic that turns
# a measured baseline into a predicted state.
#
# SOURCED, NOT RUN. Two consumers:
#
#   wcd9320-hphl-pa-evidence.sh   the hardware runner
#   wcd9320-hphl-pa-selftest.sh   an offline proof that this file is right
#
# WHY THIS IS NOT wcd9320-hphl-dac-expect.sh WITH A FEW ROWS ADDED
#
# C3a runs the DAC path with COMPANDER 1 OFF. That removes nine rows from the
# C2b table -- every compander register, and the gain handoff that the
# compander's PRE_PMU performed -- and replaces them with six prep writes the
# compander used to make unnecessary. Sharing one table between the two would
# mean a table where most rows are conditional on a mode, which is how a
# derivation stops being readable and starts being trusted instead of checked.
#
# D1's file stays exactly as it is and keeps describing D1.
#
# EXPECTATIONS ARE BASELINE-RELATIVE, AND HERE THAT IS NOT A FORMALITY
#
# Every register C3a writes except 0x3b0 lives in the fuse-loaded 0x180-0x1e4
# range, where the header PORs are not what the silicon comes up with. The
# measured cold-boot map has 0x1ac/0x1ad/0x1a9 at da/15/2a against a POR table
# that says otherwise, and 0x1a5 with bit 7 SET. A gate built on the PORs
# would fail a correct run on its first line.
#
# THE PART COMES UP IN THE COMPANDER-*ON* POP/CLICK CONFIGURATION, which is
# precisely why C3a has to write all four: running COMP1 off against them
# would be the mismatched pairing section 7 of the mapping warns about.

# pa_apply <hexbase> <hexbaseline> <mask,val | R<mask> | ->... -> hex result
#
# Folds masked writes in order, exactly as regmap_update_bits() would.
#
# "R<mask>" means RESTORE those bits from the MEASURED BASELINE rather than to
# a constant. C3a's teardown puts the prep registers back where it found them,
# and the value it writes is therefore not knowable from the transform alone --
# it is whatever the chip held before the run. Expressing that as a token keeps
# the derivation honest: a gate that predicted a POR here would be predicting a
# value this part never held.
#
# EVERY NAME BELOW IS PREFIXED _ap_, AND THAT IS NOT COSMETIC.
#
# POSIX sh has no locals, so a helper and its caller sharing a name is a silent
# action-at-a-distance bug -- the one that cost this project a hardware run when
# arm_probes() clobbered run_cycle()'s _n. pa_derive() holds the baseline in a
# variable across four calls to this function, so if this function also used
# that name, the second call onwards would receive a decimal baseline and the
# R restore would produce a value the part never held.
#
# It would work today anyway, because every call site wraps this in $( ) and a
# command substitution runs in a subshell. That is correctness by accident of
# the call site, which is exactly what the scope lint exists to refuse.
pa_apply() {
	_ap_v=$((0x$1))
	_ap_b=$((0x$2))
	shift 2
	for _ap_p in "$@"; do
		[ "$_ap_p" = "-" ] && continue
		case "$_ap_p" in
		R*)
			_ap_m=$((0x${_ap_p#R}))
			_ap_v=$(( (_ap_v & ~_ap_m) | (_ap_b & _ap_m) ))
			;;
		*)
			_ap_m=$((0x${_ap_p%%,*}))
			_ap_x=$((0x${_ap_p##*,}))
			_ap_v=$(( (_ap_v & ~_ap_m) | (_ap_x & _ap_m) ))
			;;
		esac
	done
	printf '%02x' $((_ap_v & 0xff))
}

# key | prep | dac | pa | teardown
#
# The four phases the runner drives, in order:
#
#   prep       P5-P7: gain source, minimum mapped gain, the compander-OFF
#              pop/click pairing
#   dac        the D1 DAC path in register-gain mode -- DSM mux, ZOH, RX bias,
#              class-H PRE_DAC, the two forced writes, then 0x1b1
#   pa         steps 9-11: the PA bit, the mapped settle, class-H POST_PA
#   teardown   pa-off, dac-off, prereq-off, unprep, all of it
#
# 0x1ae carries TWO decisions and they are written separately: bit 5 is the
# gain SOURCE and bits [4:0] are the FIELD. The inverted control means the
# field value 0x14 is the user-MINIMUM, and the POR of 0x00 is the user
# maximum -- so the prep is what stands between this run and full output.
# THE GAIN FIELD FOR THIS RUN (r176), hex, 00 (maximum) .. 14 (minimum).
#
# The first acoustic run at the minimum heard nothing, and the only reviewed
# figure for this family (upstream WCD938x: 1.5 dB steps) puts 0x14 about
# 30 dB below the top -- far under what the instrument can hear. So the field
# became a per-run setting. It defaults to the minimum, and every expectation
# that mentions it is derived from it rather than written as a constant.
WCD9320_PA_GAIN_FIELD="${C3A_GAIN_FIELD:-14}"

# pa_gain_ok <hex> -> OK | REFUSE:<why>
#
# Two lowercase hex digits, 00..14. Anything else refuses -- the driver also
# refuses it, but a run should not get as far as asking.
pa_gain_ok() {
	case "$1" in
	[01][0-9a-f]) ;;
	*) echo "REFUSE:not-two-lowercase-hex-digits"; return ;;
	esac
	if [ $((0x$1)) -le $((0x14)) ]; then
		echo OK
	else
		echo "REFUSE:above-0x14"
	fi
}

WCD9320_PA_TRANSFORMS="lgain_0x1ae|20,20 1f,$WCD9320_PA_GAIN_FIELD|-|-|R3f
wgctl_0x1ac|ff,db|-|-|Rff
wgtime_0x1ad|ff,58|-|-|Rff
wgocp_0x1a9|ff,1a|-|-|Rff
chop_0x1a5|80,00|-|-|R80
pa_0x1ab|-|-|20,20|20,00
dac_0x1b1|-|40,40 80,80|-|80,00 40,00
dsm_0x3b0|-|30,10 0c,04|-|0c,00 30,00
bias_0x1a2|-|80,80|-|80,00
buck5_0x185|-|02,02|02,00|-
ncps_0x194|-|10,00 0f,08 20,20|20,00|-
buck3_0x183|-|04,00 08,00|04,04 08,08|-
ocpctl_0x1aa|-|-|-|-"

# RESTORED: the teardown puts these bits back where it FOUND them.
#
# Per BIT, not per register. 0x1ab is checked on the two PA bits only, because
# bit 7 is something else entirely and reads 1 at baseline; 0x1b1 on its top
# two; 0x1ae on source-plus-field and not on the bits above them.
WCD9320_PA_RESTORED="lgain_0x1ae:3f wgctl_0x1ac:ff wgtime_0x1ad:ff
wgocp_0x1a9:ff chop_0x1a5:80 pa_0x1ab:30 dac_0x1b1:c0 dsm_0x3b0:3c
bias_0x1a2:80"

# PROGRAMMED: reaches its mapped value and STAYS there after teardown.
#
# THE POST_PA FOUR, AND THE WHOLE POINT OF SECTION 20.
#
# wcd9xxx_clsh_turnoff_postpa() touches NCP_EN, BUCK_MODE_1 bit 7 and
# B1_CTL bit 4 -- none of these. So they keep their post-PA values through the
# teardown, and no inverse exists for them anywhere in downstream. A gate that
# demanded a return to baseline would fail a correct run, and a driver that
# supplied the inverse would be inventing one.
#
# THE CLASS-H STEP MOVES THEM FIRST, AND SECTION 20 MISSED IT.
#
# Section 20 called three of the four POST_PA writes no-ops, having computed
# them against the COLD map. But the C2a class-H enable runs with the DAC,
# BEFORE the PA, and writes all three registers (wcd9320_clsh_buck_mode[] and
# wcd9320_clsh_ncp[]):
#
#   BUCK_MODE_5  mask 02 <- 03          00 -> 02
#   BUCK_MODE_3  mask 04 <- 0, 08 <- 0  ce -> c2
#   NCP_STATIC   10 <- 0, 0f <- 8, 20 <- 20   28 -> 28
#
# and the class-H teardown (wcd9320_clsh_off[]) touches none of them. So in
# sequence ALL FOUR POST_PA writes move bits -- 02 -> 00, c2 -> ce, 28 -> 08 --
# and the end values merely coincide with the cold ones for the two buck
# registers. Found by the first acoustic CONTROL run, which skips the PA step
# and ended at exactly 02 / c2 / 28: the "dac" column above, unchanged.
WCD9320_PA_PROGRAMMED="buck5_0x185 ncps_0x194 buck3_0x183"

# GUARDED: must not move at all, at any point.
#
# The HPHR PA bit lives in 0x1ab, which C3a writes -- so it is not enough to
# guard the register; the guard is on the MASK, and it is the driver's
# phase-dependent guard that enforces it. What is listed here is everything
# ADJACENT that a wrong index or mask would land on.
#
# 0x1aa is in this list rather than in the transform table for a specific
# reason: RX_HPH_OCP_CTL's current limit comes from board data this port does
# not have, so C3a leaves it at whatever the codec already holds. "Left as
# found" is only a claim if something checks it.
WCD9320_PA_GUARDED="hphr_0x1b7 ear_0x1bc line1_0x1cf spkren_0x1df
spkrgain_0x1e0 ocpctl_0x1aa"

# The PA enables: bit 5 HPHL, bit 4 HPHR.
WCD9320_PA_MASK=30
WCD9320_PA_HPHL=20

# The three legal PA states, and there are exactly three.
#
#   before the deliberate enable   00
#   while HPHL is intentionally on 20   -- bit 5 set AND bit 4 CLEAR
#   after teardown                 00
#
# 0x10 and 0x30 are always violations. A run that enabled both channels would
# read 30 and must fail rather than pass with "the PA is on, as expected".
WCD9320_PA_STATE_OFF=00
WCD9320_PA_STATE_ON=20

# Class-H, asserted rather than derived -- the same treatment D1 gives it.
#
# 0x320 is written by the C2a sequence, which was proven standalone at 82/82
# and is reused unchanged. Re-deriving 52 writes here would be transcribing a
# proven sequence a second time, and the second transcription is the one that
# would be wrong.
#
# ONE THING DIFFERS FROM D1 AND IT MATTERS. In C3a the class-H teardown is run
# by the PA path rather than by the DAC path, because section 8 puts it there.
# Same function, same six writes, same result -- but a gate that assumed the
# DAC teardown had done it would be checking the wrong stage boundary.
WCD9320_PA_CLSH_LIVE=a7
WCD9320_PA_CLSH_AFTER=a6

# Derived write counts, from the driver's sequences.
#
#   prep         6   gain source, gain field, wg ctl, wg time, wg ocp, chopper
#   prereq-on    1   FORCED 0x314 = 0x03
#   dac-on       6   DSM source, ZOH, RX bias, FORCED 0x30d, DAC switch, power
#   pa-on        5   the PA bit, then the four class-H POST_PA writes
#   pa-off       1   the PA bit
#   dac-off      6   the same six, inverted
#   prereq-off   1   FORCED 0x314 = 0x00, mandatory
#   unprep       6   the prep six, restored to their measured baseline
#
# 32 per cycle, 64 for two.
#
# NO COMPANDER WRITES. D1 counted 13 for comp1-on and 6 for comp1-off inside
# the same counter; C3a runs neither, which is most of the difference from
# D1's 33.
#
# The class-H writes are counted separately by the C2a code and are 52 per
# cycle, 104 for two -- identical to C2a and C2b, which is itself a check that
# moving the teardown into the PA path did not change the sequence.
WCD9320_PA_WRITES_PER_CYCLE=32
WCD9320_PA_WRITES_TOTAL=64
WCD9320_PA_CLSH_TOTAL=104

# The forced, write-effect-unverifiable operations, per cycle and in order.
#
#   0x314 set, 0x30d set, 0x30d clear, 0x314 clear
#
# Unchanged from r174, and deliberately so: C3a adds a PA above this path and
# changes nothing about the two registers underneath it. Eight operations
# across two cycles, checked entry by entry so a missing inverse cannot hide
# behind a correct total.
WCD9320_PA_FORCED_PER_CYCLE=4
WCD9320_PA_FORCED_TOTAL=8

# pa_instrument_decision <instrument> <dc-waiver> <control> -> OK | REFUSE:<why>
#
# WHICH INSTRUMENT, AND WHO IS ALLOWED TO GIVE UP THE DC CONTRACT.
#
# C3a was frozen around a scope, and the scope is what makes the DC contract
# measurable: |Voff| <= 100 mV before the first Volume Up, |Von - Voff| <= 50 mV
# before the second. The ACOUSTIC instrument -- an earbud on the PC's USB
# microphone -- cannot see DC at all. So running acoustically means running
# without the contract, and that is a decision only the operator can make.
#
# It is therefore not a default and not a flag that means "yes": the waiver has
# to be the exact token below, typed on purpose. Anything else refuses, which
# is the same polarity as every gate in this run.
#
# CONTROL "pa-off" is the negative control: the identical run and stimulus with
# the PA deliberately never enabled. It must produce no tracking tone, and it is
# what attributes a positive in the real run to the PA rather than to leakage.
pa_instrument_decision() {
	_id_inst=$1
	_id_waive=$2
	_id_ctl=$3
	case "$_id_ctl" in
	""|pa-off) ;;
	*) echo "REFUSE:unknown-control-$_id_ctl"; return ;;
	esac
	case "$_id_inst" in
	scope)
		echo OK ;;
	onchip)
		# r178: DC IS measured, by the codec's own MBHC voltmeter, so there
		# is nothing to waive -- and a waiver given anyway is refused,
		# because it would mean the operator thinks DC is not being taken.
		if [ -z "$_id_waive" ]; then
			echo OK
		else
			echo "REFUSE:onchip-measures-dc-no-waiver-applies"
		fi ;;
	acoustic)
		if [ "$_id_waive" = "operator-waived" ]; then
			echo OK
		else
			echo "REFUSE:acoustic-needs-the-operator-dc-waiver"
		fi ;;
	*)
		echo "REFUSE:unknown-instrument-$_id_inst" ;;
	esac
}

# pa_chat_wait <dir> <label> <timeout-s> <abort-flag> -> APPROVED | ABORT | TIMEOUT
#
# A GATE APPROVED FROM CHAT RATHER THAN BY A BUTTON.
#
# The button gates were designed for a scope run, where USB had to come off and
# the buttons were the only channel left. With the acoustic instrument USB
# stays connected, and the button design caused both of the first real run's
# problems: a burst of presses chained through three gates, and a gate timed
# out while its operator was waiting for a cue. So in acoustic runs the one
# decision that matters -- turn the amplifier on -- is approved in chat and
# delivered as a file, while Volume Down stays the independent physical abort.
#
# Deliberately dumb, so it is hard to misuse:
#   - any approval for this gate that exists BEFORE it opens is deleted, so an
#     early or stale approval never counts;
#   - only a file named for THIS gate and containing THIS gate's name counts;
#   - the abort flag is checked every second, and wins;
#   - silence is a timeout, and a timeout is an abort.
pa_chat_wait() {
	_cw_dir=$1
	_cw_lbl=$2
	_cw_to=$3
	_cw_flag=$4
	rm -f "$_cw_dir/$_cw_lbl" 2>/dev/null
	_cw_n=0
	while [ "$_cw_n" -lt "$_cw_to" ]; do
		if [ -e "$_cw_flag" ]; then
			echo ABORT
			return 1
		fi
		if [ -e "$_cw_dir/$_cw_lbl" ] &&
		   [ "$(cat "$_cw_dir/$_cw_lbl" 2>/dev/null)" = "$_cw_lbl" ]; then
			rm -f "$_cw_dir/$_cw_lbl" 2>/dev/null
			echo APPROVED
			return 0
		fi
		sleep 1
		_cw_n=$((_cw_n + 1))
	done
	echo TIMEOUT
	return 2
}

# pa_derive <state-text> <outfile>
#
# Writes "key baseline after_prep after_dac after_pa after_teardown" per line.
pa_derive() {
	_st=$1
	_out=$2
	: > "$_out"
	printf '%s\n' "$WCD9320_PA_TRANSFORMS" | while IFS='|' read -r _k _p _d _a _t; do
		[ -n "$_k" ] || continue
		_b=$(printf '%s' "$_st" | tr ' ' '\n' | sed -n "s/^$_k=//p" | head -n1)
		if [ -z "$_b" ]; then
			echo "$_k MISSING MISSING MISSING MISSING MISSING" >> "$_out"
			continue
		fi
		# shellcheck disable=SC2086
		_ep=$(pa_apply "$_b" "$_b" $_p)
		# shellcheck disable=SC2086
		_ed=$(pa_apply "$_ep" "$_b" $_d)
		# shellcheck disable=SC2086
		_ea=$(pa_apply "$_ed" "$_b" $_a)
		# shellcheck disable=SC2086
		_et=$(pa_apply "$_ea" "$_b" $_t)
		echo "$_k $_b $_ep $_ed $_ea $_et" >> "$_out"
	done
}

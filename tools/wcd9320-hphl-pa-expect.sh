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
WCD9320_PA_TRANSFORMS="lgain_0x1ae|20,20 1f,14|-|-|R3f
wgctl_0x1ac|ff,db|-|-|Rff
wgtime_0x1ad|ff,58|-|-|Rff
wgocp_0x1a9|ff,1a|-|-|Rff
chop_0x1a5|80,00|-|-|R80
pa_0x1ab|-|-|20,20|20,00
dac_0x1b1|-|40,40 80,80|-|80,00 40,00
dsm_0x3b0|-|30,10 0c,04|-|0c,00 30,00
bias_0x1a2|-|80,80|-|80,00
buck5_0x185|-|-|02,00|-
ncps_0x194|-|-|20,00|-
buck3_0x183|-|-|04,04 08,08|-
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
# On this silicon three of the four are NO-OPS: 0x185 bit 1 is already clear at
# cold boot and 0x183 bits 2 and 3 are already set, so the derivation predicts
# 00 and ce -- unchanged -- and only 0x194 actually moves, 28 -> 08.
#
# regmap_update_bits() elides a write whose value is unchanged, so three of
# these four transactions may never reach the bus at all. That is correct for
# configuration bits and must not be read as a skipped step.
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

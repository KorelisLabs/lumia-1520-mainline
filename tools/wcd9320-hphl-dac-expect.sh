# shellcheck shell=sh
#
# C2b expectations: the transforms, the buckets, and the arithmetic that turns
# a measured baseline into a predicted state.
#
# SOURCED, NOT RUN. Two consumers:
#
#   wcd9320-hphl-dac-evidence.sh   the hardware gate
#   wcd9320-hphl-dac-selftest.sh   an offline proof that this file is right
#
# WHY THIS IS A SEPARATE FILE
#
# Both C2a failures were in the gate, not the driver -- a POR baseline
# hardcoded for three fuse-loaded registers, and a whole-register "returns to
# base" check on two registers that carry configuration alongside power. Each
# cost a boot cycle to discover. None of that arithmetic was reachable without
# hardware, so none of it was ever tested before it was trusted.
#
# Splitting it out makes the derivation runnable on a workstation against
# synthetic baselines, including baselines chosen to break it.
#
# EXPECTATIONS ARE BASELINE-RELATIVE
#
# 0x180-0x1e4 is fuse-loaded analog trim and does NOT reset to the header POR:
# C2a measured ce/5b/51 against cc/ab/58. Three of C2b's registers live in that
# range -- RX_COM_BIAS 0x1a2, RX_HPH_L_GAIN 0x1ae, RX_HPH_R_GAIN 0x1b4 -- so
# every expectation here is the measured baseline with the transcribed masked
# writes applied. The transforms come from the downstream sequences; only the
# starting point is observed.

# c2b_apply <hexbase> <mask,val>... -> hex result
#
# Folds masked writes in order, exactly as regmap_update_bits() would. "-" is
# an empty transform list and folds to the input unchanged.
c2b_apply() {
	_v=$((0x$1))
	shift
	for _p in "$@"; do
		[ "$_p" = "-" ] && continue
		_m=$((0x${_p%%,*}))
		_x=$((0x${_p##*,}))
		_v=$(( (_v & ~_m) | (_x & _m) ))
	done
	printf '%02x' $((_v & 0xff))
}

# key | comp1-on | dac-on | teardown (dac-off then comp1-off)
#
# Every entry is transcribed from the driver's own write sequence, which is
# itself transcribed from taiko_config_compander(), taiko_codec_dsm_mux_event(),
# taiko_codec_enable_rx_bias(), taiko_hphl_dac_event() and the HPHL DAC widget.
#
# Two of these are worth reading twice:
#
#   compb2_0x371 and compb3_0x372 are written TWICE on the way up. The first
#   pair is taiko_discharge_comp() -- level meter div 5, RMS 1 -- and the
#   second is the 48 kHz operating point from comp_samp_params[], which
#   OVERWRITES it. Folding only the discharge write, as the comp1-rc1 driver
#   effectively did, predicts a compander parked on a transient.
#
#   lgain_0x1ae and rgain_0x1b4 do NOT return to their baseline. Bit 5 is the
#   gain source: clear means the compander drives the headphone stage, set
#   means the register does. taiko_config_gain_compander(false) SETS it on the
#   way down regardless of what it was before, so the post-run state is bit 5
#   set even on a part that came up with it clear.
C2B_TRANSFORMS="dsm_0x3b0|-|30,10 0c,04|0c,00 30,00
dac_0x1b1|-|40,40 80,80|80,00 40,00
rdac_0x30d|-|02,02|02,00
bias_0x1a2|-|80,80|80,00
lgain_0x1ae|20,00|-|20,20
rgain_0x1b4|20,00|-|20,20
b4_0x373|80,00|-|-
compb2_0x371|f0,50 f0,b0 0f,09|-|-
compb3_0x372|ff,01 ff,28|-|-
compfs_0x377|07,03|-|-"

# RESTORED: the teardown puts these bits back where it found them.
#
# Per BIT, not per register -- the C2a lesson. 0x3b0 is fully undone because it
# is pure routing; 0x1b1 only in its top two bits; 0x30d only bit 1, because
# bits 2 and up belong to HPHR and the line-outs and this run never touches
# them.
C2B_RESTORED="dsm_0x3b0:3c dac_0x1b1:c0 rdac_0x30d:02 bias_0x1a2:80"

# PROGRAMMED: reaches its mapped value and STAYS there after teardown.
#
# Downstream deliberately leaves compander configuration programmed, the same
# way class-H leaves its own. A gate demanding a return to baseline here would
# fail a correct system.
C2B_PROGRAMMED="lgain_0x1ae rgain_0x1b4 b4_0x373 compb2_0x371 compb3_0x372 compfs_0x377"

# GUARDED: must not move at all, at any point.
#
# The PA leads. The rest is everything an adjacent path would disturb if a mask
# or an index were wrong: the HPHR DAC, the earpiece, a line-out, and the
# speaker driver. spkrgain_0x1e0 earns its place specifically because
# taiko_config_gain_compander(COMPANDER_0) writes bit 2 of it -- so a compander
# index off by one lands exactly there.
C2B_GUARDED="pa_0x1ab hphr_0x1b7 ear_0x1bc line1_0x1cf spkren_0x1df spkrgain_0x1e0"

# The PA enables: bit 5 HPHL, bit 4 HPHR.
C2B_PA_MASK=30

# Derived write counts, from the driver's sequences.
#
#   comp1-on  13   rate, gain offset, clocks, reset x2, gain source x2,
#                  enable, discharge x2, operating point x3
#   prereq-on  1   FORCED 0x314 = 0x03            (r174)
#   dac-on     6   DSM source, ZOH, RX bias, RDAC clock, DAC switch, DAC power
#   dac-off    6   the same six, inverted
#   prereq-off 1   FORCED 0x314 = 0x00, mandatory (r174)
#   comp1-off  6   disable, reset x2, clocks, gain source x2
#
# 33 per cycle, 66 for two.
#
# WAS 31/62 BEFORE r174, and the change is not a fudge. The 0x314 pair moved
# INSIDE the cycle: it used to be applied once before both cycles and its
# inverse was never issued at all, which is precisely the teardown hazard r174
# exists to close. Pairing the enable and its inverse within one cycle costs
# two writes per cycle and is what makes the forced-write journal come to
# eight operations rather than six.
#
# wcd9320_forced_write() increments c2b_writes exactly once per call, on the
# same line as the other verified helpers, so a forced write counts the same
# as any other -- what differs is whether its RESULT can be checked, not
# whether it happened.
#
# The class-H writes are counted separately by the C2a code and are 52 per
# cycle, 104 for two -- unchanged from C2a, which is itself a check that
# reusing it did not alter it.
C2B_WRITES_PER_CYCLE=33
C2B_WRITES_TOTAL=66
C2B_CLSH_TOTAL=104

# c2b_derive <state-text> <outfile>
#
# Writes "key baseline after_comp after_dac after_teardown" per line.
c2b_derive() {
	_st=$1
	_out=$2
	: > "$_out"
	printf '%s\n' "$C2B_TRANSFORMS" | while IFS='|' read -r _k _c _d _t; do
		[ -n "$_k" ] || continue
		_b=$(printf '%s' "$_st" | tr ' ' '\n' | sed -n "s/^$_k=//p" | head -n1)
		if [ -z "$_b" ]; then
			echo "$_k MISSING MISSING MISSING MISSING" >> "$_out"
			continue
		fi
		# shellcheck disable=SC2086
		_ec=$(c2b_apply "$_b" $_c)
		# shellcheck disable=SC2086
		_ed=$(c2b_apply "$_ec" $_d)
		# shellcheck disable=SC2086
		_ea=$(c2b_apply "$_ed" $_t)
		echo "$_k $_b $_ec $_ed $_ea" >> "$_out"
	done
}

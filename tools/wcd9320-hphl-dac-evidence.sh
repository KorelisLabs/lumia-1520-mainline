#!/bin/sh
#
# C2b: does the RX1 chain reach the HPHL DAC, and come back?
#
# THE CLAIM UNDER TEST
#
#   The proven RX1 digital chain can be routed through the compander/HPH gain
#   interface and the class-H support into the HPHL DAC -- powered AND with its
#   input connected -- and returned cleanly to the pre-DAC state, twice, with
#   the PA physically disabled and verified disabled throughout.
#
# WHAT IT DOES NOT CLAIM
#
# Nothing audible. The PA is never enabled, so no signal reaches the jack.
# This is a conversion and routing result: the DAC is powered, its input is
# connected to the class-H DSM mux, and the mux is fed by RX1. Whether samples
# are actually being converted cannot be shown from here -- Branch B's
# byte-arrival gap is still open and this does not close it.
#
# THE READBACKS COME FROM THE CHIP, NOT THE CACHE
#
# Every register in this run is non-volatile in the driver's regmap. A cached
# readback would confirm 0x1b1 = c0 for a write that never left the SoC, and
# the evidence file would look perfect. The driver's hphl_dac_state uses
# regmap_read_bypassed() for all of it, which is what makes this gate worth
# running at all.
#
# THREE BUCKETS, PER BIT
#
#   RESTORED    the teardown puts these bits back where it found them
#   PROGRAMMED  reaches its mapped value and STAYS, as downstream intends
#   GUARDED     must not move at all
#
# Every expectation is DERIVED in wcd9320-hphl-dac-expect.sh from the measured
# baseline plus the transcribed masked writes, and that derivation has its own
# offline selftest. If the hardware disagrees with a transform, the mapping is
# wrong and that matters more than the milestone.
#
# THE PA GUARD IS CONTINUOUS
#
# 0x1ab mask 0x30 is checked inside the driver before and after every stage,
# and again from here at every snapshot. A run that enabled the PA and dropped
# it again between two snapshots would otherwise be indistinguishable from one
# that never touched it.
#
# Exit: 0 proven, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-hphl-dac"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-hphl-dac-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-c2b-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
PERIOD="${PERIOD:-960}"
NPERIODS="${NPERIODS:-4}"
SECS="${SECS:-3}"

RUNNER=""
for c in "${PCM_RUNNER:-}" "$DIR/pcm-run-measured" /tmp/pcm-run-measured; do
	[ -n "$c" ] && [ -x "$c" ] && { RUNNER="$c"; break; }
done
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

require_module_version
find_devices

C1T="$PGD/comp1_test"
RX1T="$PGD/rx1_digital_test"
RX1S="$PGD/rx1_digital_state"
DACT="$PGD/hphl_dac_test"
DACS="$PGD/hphl_dac_state"
CLSHS="$PGD/clsh_state"
PREREQ="$PGD/cdc_clk_prereq"

for f in "$C1T" "$RX1T" "$RX1S" "$DACT" "$DACS" "$CLSHS" "$PREREQ"; do
	[ -e "$f" ] || {
		say "INVALID RUN: $f does not exist."
		say "  The running codec must be rdac-clk-rc1 or later."
		exit 2
	}
done
for f in "$RUNNER" "$SETCTL"; do
	[ -n "$f" ] || {
		say "INVALID RUN: a required PCM helper is missing."
		say "  Stage pcm-run-measured and alsa-setctl next to this script."
		exit 2
	}
done
[ -w "$TRACE/kprobe_events" ] || { say "INVALID RUN: need root."; exit 2; }
grep -q '^ *0 ' /proc/asound/cards 2>/dev/null || {
	say "INVALID RUN: no sound card."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
dst() { cat "$DACS" 2>/dev/null; }
cst() { cat "$CLSHS" 2>/dev/null; }

# ------------------------------------------------------------ preconditions --
PRE=$(dst)
PRE_CLSH=$(cst)
BAD=""
[ "$(rv "$PRE" on)" = "0" ]            || BAD="$BAD dac_already_on"
[ "$(rv "$PRE" enables)" = "0" ]       || BAD="$BAD prior_enables"
[ "$(rv "$PRE" bias_refs)" = "0" ]     || BAD="$BAD bias_refs"
[ "$(rv "$PRE" guard_tripped)" = "0" ] || BAD="$BAD guard_tripped"
#
# 0x3b0 and 0x1b1 are digital-side and above the fuse-loaded analog trim range,
# so their PORs of 00 ARE trustworthy. A deviation means something already
# touched the DAC path on this boot and phase A cannot be clean.
#
[ "$(rv "$PRE" dsm_0x3b0)" = "00" ] || BAD="$BAD dsm=$(rv "$PRE" dsm_0x3b0)"
[ "$(rv "$PRE" dac_0x1b1)" = "00" ] || BAD="$BAD dac=$(rv "$PRE" dac_0x1b1)"
[ "$(rv "$PRE_CLSH" b1_0x320)" = "e4" ] ||
	BAD="$BAD clsh_b1=$(rv "$PRE_CLSH" b1_0x320)"
#
# And the PA must already be off. If it is not, nothing below is safe to run.
#
PA_PRE=$(rv "$PRE" pa_0x1ab)
[ "$(printf '%02x' $(( 0x${PA_PRE:-ff} & 0x$C2B_PA_MASK )))" = "00" ] ||
	BAD="$BAD PA_ALREADY_ON=$PA_PRE"

if [ -n "$BAD" ]; then
	say "INVALID RUN: the analog baseline is not pristine:$BAD"
	say "  Cold boot and run this once."
	exit 2
fi

# -------------------------------------------------- the RDAC prerequisite --
#
# CDC_CLK_POWER_CTL = 0x03 is applied HERE, explicitly, and recorded in the
# evidence -- not buried in codec initialisation.
#
# r164 proved on hardware that the HPHL RDAC clock bit does not latch without
# it, and the r165 gate established the causal link with one variable moved.
# Until that is old news, the DAC milestone should show the prerequisite being
# applied and verified as part of its own record, so a reader can see exactly
# what state the DAC was proven in. Promoting it into normal codec init is a
# later cleanup, once the behaviour it enables is already established.
CLKP_BEFORE=$(rv "$PRE" clk_power_0x314)
RDAC_BEFORE=$(rv "$PRE" rdac_0x30d)
CHIPCTL_OBS=$(rv "$PRE" chip_ctl_0x001)
echo on > "$PREREQ" 2>/dev/null; PREREQ_RC=$?
PRE=$(dst)
CLKP_AFTER=$(rv "$PRE" clk_power_0x314)
if [ "$CLKP_AFTER" != "03" ]; then
	say "INVALID RUN: the RDAC prerequisite did not take."
	say "  0x314 reads $CLKP_AFTER on the chip, wanted 03 (exit $PREREQ_RC)."
	say "  Run wcd9320-rdac-prereq-evidence.sh first; without this the DAC"
	say "  sequence cannot reach its RDAC clock and will refuse by name."
	exit 2
fi

EXPFILE="/tmp/.c2b-exp-$$"
c2b_derive "$PRE" "$EXPFILE"
if grep -q MISSING "$EXPFILE"; then
	say "INVALID RUN: hphl_dac_state did not report every register:"
	grep MISSING "$EXPFILE" | sed 's/^/  /'
	exit 2
fi

GUARD_PRE=""
for k in $C2B_GUARDED; do GUARD_PRE="$GUARD_PRE $k=$(rv "$PRE" "$k")"; done

snap_dmesg
open_output "$OUTDIR/wcd9320-hphl-dac-$STAMP.txt"

# -------------------------------------------------------------- observation --
PROBES="c2b_run:q6asm_run_nowait
c2b_elapsed:snd_pcm_period_elapsed
c2b_slimen:slim_stream_enable"

# NOTE ON VARIABLE NAMES IN THESE HELPERS.
#
# POSIX sh has no local variables, so every name a helper assigns is global.
# arm_probes() used to use _n as its loop variable, which silently overwrote
# run_cycle()'s cycle number: after the first arm_probes() call, "$_n" was
# "c2b_slimen" (the last probe name), so every eval after it assigned
# Cc2b_slimen_AFTER instead of C1_AFTER. The register sequence ran correctly
# and the gate then graded unset variables. The tell in the evidence file was
# a PA sample labelled "cc2b_slimen-stream".
#
# Every helper below therefore uses names prefixed _pr_, which nothing else
# in this script touches.
clear_probes() {
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	for _pr_p in $PROBES; do
		_pr_e="$TRACE/events/kprobes/${_pr_p%%:*}/enable"
		[ -e "$_pr_e" ] && echo 0 2>/dev/null > "$_pr_e"
	done
	printf "" 2>/dev/null > "$TRACE/kprobe_events"
	true
}
arm_probes() {
	printf "" 2>/dev/null > "$TRACE/trace"
	for _pr_p in $PROBES; do
		_pr_n=${_pr_p%%:*}; _pr_s=${_pr_p#*:}
		printf 'p:%s %s\n' "$_pr_n" "$_pr_s" >> "$TRACE/kprobe_events" 2>/dev/null &&
			echo 1 2>/dev/null > "$TRACE/events/kprobes/$_pr_n/enable"
	done
	echo 1 2>/dev/null > "$TRACE/tracing_on"
}
cnt() { _pr_c=$(grep -c "$1:" "$TRACE/trace" 2>/dev/null) || _pr_c=0; echo "${_pr_c:-0}"; }

# pa_now -- the PA mask, read live from the state file
pa_now() {
	_pr_pa=$(rv "$(dst)" pa_0x1ab)
	# An empty read would make the arithmetic below a syntax error and the
	# sample would silently vanish; report it loudly instead.
	[ -n "$_pr_pa" ] || { echo "READ-FAILED"; return; }
	printf '%02x' $(( 0x$_pr_pa & 0x$C2B_PA_MASK ))
}

PA_SAMPLES=""
pa_sample() { PA_SAMPLES="$PA_SAMPLES $1:$(pa_now)"; }

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1

# ------------------------------------------------------------------ a cycle --
#
# Enable source-to-sink, tear down sink-to-source. The compander goes first
# because the gain handoff lives in ITS PRE_PMU, not the DAC's; the driver
# refuses a DAC enable without it rather than supplying it silently.
run_cycle() {	# run_cycle <n>
	_cyc=$1

	pa_sample "c${_cyc}-start"
	echo comp1-on > "$C1T" 2>/dev/null; eval "C${_cyc}_COMP_RC=\$?"
	pa_sample "c${_cyc}-comp"
	eval "C${_cyc}_COMP=\$(dst)"

	echo rx1-on > "$RX1T" 2>/dev/null; eval "C${_cyc}_RX1_RC=\$?"
	pa_sample "c${_cyc}-rx1"

	echo dac-on > "$DACT" 2>/dev/null; eval "C${_cyc}_DAC_RC=\$?"
	pa_sample "c${_cyc}-dac"
	eval "C${_cyc}_DAC=\$(dst)"
	eval "C${_cyc}_CLSH=\$(cst)"

	# The QDSP6 loop and the SLIMbus stream must stay healthy underneath.
	arm_probes
	"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p "$PERIOD" -n "$NPERIODS" \
		  -t "$SECS" >/dev/null 2>&1
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	eval "C${_cyc}_RUN=\$(cnt c2b_run)"
	eval "C${_cyc}_ELAPSED=\$(cnt c2b_elapsed)"
	eval "C${_cyc}_SLIMEN=\$(cnt c2b_slimen)"
	pa_sample "c${_cyc}-stream"
	eval "C${_cyc}_STREAM=\$(dst)"

	echo dac-off > "$DACT" 2>/dev/null; eval "C${_cyc}_DACOFF_RC=\$?"
	pa_sample "c${_cyc}-dacoff"
	echo rx1-off > "$RX1T" 2>/dev/null; eval "C${_cyc}_RX1OFF_RC=\$?"
	echo comp1-off > "$C1T" 2>/dev/null; eval "C${_cyc}_COMPOFF_RC=\$?"
	pa_sample "c${_cyc}-end"
	eval "C${_cyc}_AFTER=\$(dst)"
	eval "C${_cyc}_AFTERCLSH=\$(cst)"
}

run_cycle 1
run_cycle 2

GUARD_POST=""
for k in $C2B_GUARDED; do GUARD_POST="$GUARD_POST $k=$(rv "$C2_AFTER" "$k")"; done

clear_probes
snap_dmesg

WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
C2B_ERR=$(dmesg 2>/dev/null | grep -c 'c2b:.*failed' || true)
PA_TRIP=$(dmesg 2>/dev/null | grep -c 'PA GUARD TRIPPED' || true)
CP_WARN=$(dmesg 2>/dev/null | grep -ci 'Unbalanced disable' || true)
BIAS_WARN=$(dmesg 2>/dev/null | grep -c 'RX bias released without' || true)
for v in WARNS C2B_ERR PA_TRIP CP_WARN BIAS_WARN; do
	eval "[ -n \"\$$v\" ] || $v=0"
done

# any PA sample that is not 00
PA_BAD=$(printf '%s' "$PA_SAMPLES" | tr ' ' '\n' | grep -v ':00$' | grep -c ':' || true)
[ -n "$PA_BAD" ] || PA_BAD=0

{
	hdr "the RDAC clock prerequisite, applied explicitly"
	say "0x314 CDC_CLK_POWER_CTL   $CLKP_BEFORE -> $CLKP_AFTER   [chip-verified]"
	say "0x30d RDAC clock, before  $RDAC_BEFORE"
	say "0x001 CHIP_CTL, observed  $CHIPCTL_OBS   -- read, never written"

	hdr "the baseline, with the prerequisite in place"
	printf '%s\n' "$PRE" | sed 's/^/  /'

	hdr "cycle 1: compander on"
	printf '%s\n' "$C1_COMP" | sed 's/^/  /'
	hdr "cycle 1: DAC on"
	printf '%s\n' "$C1_DAC" | sed 's/^/  /'
	hdr "cycle 1: after teardown"
	printf '%s\n' "$C1_AFTER" | sed 's/^/  /'
	hdr "cycle 2: DAC on"
	printf '%s\n' "$C2_DAC" | sed 's/^/  /'
	hdr "cycle 2: after teardown"
	printf '%s\n' "$C2_AFTER" | sed 's/^/  /'

	hdr "the PA, sampled at every stage boundary"
	say "mask $C2B_PA_MASK of 0x1ab, which must read 00 every time:"
	printf '%s\n' "$PA_SAMPLES" | tr ' ' '\n' | sed '/^$/d;s/^/  /'

	hdr "the transition the milestone rests on"
	say "predicted   0x1b1  00 -> c0 -> 00   and   0x3b0  00 -> 14 -> 00"
	say "observed    0x1b1  $(rv "$PRE" dac_0x1b1) -> $(rv "$C1_DAC" dac_0x1b1) -> $(rv "$C1_AFTER" dac_0x1b1)   and   0x3b0  $(rv "$PRE" dsm_0x3b0) -> $(rv "$C1_DAC" dsm_0x3b0) -> $(rv "$C1_AFTER" dsm_0x3b0)"
	say "cycle 2     0x1b1  $(rv "$C1_AFTER" dac_0x1b1) -> $(rv "$C2_DAC" dac_0x1b1) -> $(rv "$C2_AFTER" dac_0x1b1)   and   0x3b0  $(rv "$C1_AFTER" dsm_0x3b0) -> $(rv "$C2_DAC" dsm_0x3b0) -> $(rv "$C2_AFTER" dsm_0x3b0)"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	say ""
	say "-- the RDAC prerequisite is in place, and visible --"
	check "prerequisite applied" "$PREREQ_RC" "0"
	check "0x314 reads 03 on the chip" "$CLKP_AFTER" "03"
	check "0x30d was idle before the run" "$RDAC_BEFORE" "00"
	check "CHIP_CTL unchanged by this run" \
	      "$(rv "$C2_AFTER" chip_ctl_0x001)" "$CHIPCTL_OBS"

	say ""
	say "-- every stage was accepted --"
	for c in 1 2; do
		eval "_a=\$C${c}_COMP_RC"; check "c$c comp1-on"  "$_a" "0"
		eval "_a=\$C${c}_RX1_RC";  check "c$c rx1-on"    "$_a" "0"
		eval "_a=\$C${c}_DAC_RC";  check "c$c dac-on"    "$_a" "0"
		eval "_a=\$C${c}_DACOFF_RC"; check "c$c dac-off" "$_a" "0"
		eval "_a=\$C${c}_RX1OFF_RC"; check "c$c rx1-off" "$_a" "0"
		eval "_a=\$C${c}_COMPOFF_RC"; check "c$c comp1-off" "$_a" "0"
	done

	say ""
	say "-- THE PA WAS OFF AT EVERY SAMPLE, ON THE CHIP --"
	check "no PA sample was non-zero" "$PA_BAD" "0"
	check "driver PA guard never tripped" "$(rv "$C2_AFTER" guard_tripped)" "0"
	check "no PA guard message in dmesg" "$PA_TRIP" "0"
	check "0x1ab unchanged end to end" "$(rv "$C2_AFTER" pa_0x1ab)" "$PA_PRE"

	say ""
	say "-- RESTORED: reaches the derived value, then returns per BIT --"
	while read -r k base ecomp edac eafter; do
		_m=""
		for _r in $C2B_RESTORED; do
			[ "${_r%%:*}" = "$k" ] && _m=${_r##*:}
		done
		[ -n "$_m" ] || continue
		note "$k" "base $base -> comp $ecomp -> dac $edac -> after $eafter (derived)"
		check "c1 dac   $k" "$(rv "$C1_DAC" "$k")" "$edac"
		check "c1 after $k" "$(rv "$C1_AFTER" "$k")" "$eafter"
		check "c2 dac   $k" "$(rv "$C2_DAC" "$k")" "$edac"
		check "c2 after $k" "$(rv "$C2_AFTER" "$k")" "$eafter"
		check "c1 after $k restored bits" \
		      "$(printf '%02x' $(( 0x$(rv "$C1_AFTER" "$k") & 0x$_m )))" \
		      "$(printf '%02x' $(( 0x$base & 0x$_m )))"
		check "c2 after $k restored bits" \
		      "$(printf '%02x' $(( 0x$(rv "$C2_AFTER" "$k") & 0x$_m )))" \
		      "$(printf '%02x' $(( 0x$base & 0x$_m )))"
	done < "$EXPFILE"

	say ""
	say "-- PROGRAMMED: reaches its mapped value and stays there --"
	while read -r k base ecomp edac eafter; do
		case " $C2B_PROGRAMMED " in *" $k "*) ;; *) continue ;; esac
		note "$k" "base $base -> comp $ecomp -> dac $edac -> after $eafter (derived)"
		check "c1 comp  $k" "$(rv "$C1_COMP" "$k")" "$ecomp"
		check "c1 dac   $k" "$(rv "$C1_DAC" "$k")" "$edac"
		check "c1 after $k" "$(rv "$C1_AFTER" "$k")" "$eafter"
		check "c2 dac   $k" "$(rv "$C2_DAC" "$k")" "$edac"
		check "c2 after $k" "$(rv "$C2_AFTER" "$k")" "$eafter"
	done < "$EXPFILE"

	say ""
	say "-- the two bits that would have been missed --"
	check "0x1b1 bit 7, DAC powered" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_DAC" dac_0x1b1) & 0x80 )))" "80"
	check "0x1b1 bit 6, DAC input connected" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_DAC" dac_0x1b1) & 0x40 )))" "40"
	check "0x3b0 source = DSM_HPHL_RX1" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_DAC" dsm_0x3b0) & 0x30 )))" "10"
	check "0x3b0 ZOH derived to match" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_DAC" dsm_0x3b0) & 0x0c )))" "04"
	check "0x373 bit 7 clear, the buck is 2.15 V" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_COMP" b4_0x373) & 0x80 )))" "00"
	check "gain source handed to the compander" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_COMP" lgain_0x1ae) & 0x20 )))" "00"
	check "gain source handed back on teardown" \
	      "$(printf '%02x' $(( 0x$(rv "$C1_AFTER" lgain_0x1ae) & 0x20 )))" "20"

	say ""
	say "-- GUARDED: nothing outside the HPHL path moved --"
	check_cond "no guarded register moved" \
		"$([ "$GUARD_PRE" = "$GUARD_POST" ] && echo 1 || echo 0)" \
		"before:$GUARD_PRE  after:$GUARD_POST" "$GUARD_POST"
	for k in $C2B_GUARDED; do
		check "stayed put while live: $k" "$(rv "$C1_DAC" "$k")" "$(rv "$PRE" "$k")"
	done

	say ""
	say "-- the class-H stage behaved exactly as C2a proved it does --"
	check "c1 class-H enabled" "$(rv "$C1_CLSH" b1_0x320)" "a7"
	check "c1 class-H after" "$(rv "$C1_AFTERCLSH" b1_0x320)" "a6"
	check "c2 class-H enabled" "$(rv "$C2_CLSH" b1_0x320)" "a7"
	check "c2 class-H after" "$(rv "$C2_AFTERCLSH" b1_0x320)" "a6"
	check "charge-pump refs released" "$(rv "$C2_AFTERCLSH" cp_refs)" "0"
	check "class-H writes as mapped" "$(rv "$C2_AFTERCLSH" writes)" "$C2B_CLSH_TOTAL"
	check "no unbalanced charge pump" "$CP_WARN" "0"

	say ""
	say "-- the shared RX bias refcount came back --"
	check "bias refs released" "$(rv "$C2_AFTER" bias_refs)" "0"
	check "no unbalanced bias release" "$BIAS_WARN" "0"

	say ""
	say "-- the QDSP6 loop and the SLIMbus stream stayed healthy --"
	for c in 1 2; do
		eval "_r=\$C${c}_RUN"; eval "_e=\$C${c}_ELAPSED"; eval "_s=\$C${c}_SLIMEN"
		note "cycle $c" "ASM RUN $_r   completions $_e   slim_stream_enable $_s"
		check "c$c one ASM RUN" "$_r" "1"
		check_cond "c$c periods completed" \
			"$([ "$(num "$_e" 0)" -gt 100 ] && echo 1 || echo 0)" \
			"only $_e completions" "$_e"
		check_cond "c$c codec stream enabled" \
			"$([ "$(num "$_s" 0)" -ge 1 ] && echo 1 || echo 0)" \
			"slim_stream_enable never called" "$_s"
	done

	say ""
	say "-- the lifecycle is reusable, not a one-shot --"
	check_cond "cycle 2 enabled == cycle 1 enabled" \
		"$([ "$(printf '%s' "$C1_DAC" | grep -v '^on=')" = "$(printf '%s' "$C2_DAC" | grep -v '^on=')" ] && echo 1 || echo 0)" \
		"the second enable produced a different state"
	check_cond "cycle 2 teardown == cycle 1 teardown" \
		"$([ "$(printf '%s' "$C1_AFTER" | grep -v '^on=')" = "$(printf '%s' "$C2_AFTER" | grep -v '^on=')" ] && echo 1 || echo 0)" \
		"the second teardown produced a different state"

	say ""
	say "-- the writes are the writes that were mapped --"
	check "two DAC enables" "$(rv "$C2_AFTER" enables)" "2"
	check "enables == disables" "$(rv "$C2_AFTER" enables)" "$(rv "$C2_AFTER" disables)"
	check "chip-verified writes as derived" "$(rv "$C2_AFTER" c2b_writes)" "$C2B_WRITES_TOTAL"
	check "no c2b failure logged" "$C2B_ERR" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE RX1 CHAIN REACHES THE HPHL DAC, AND COMES BACK."
		say ""
		say "0x1b1 went 00 -> c0 -> 00 twice: bit 7 powering the DAC and bit"
		say "6 connecting its input, both verified on the chip rather than in"
		say "the cache. 0x3b0 went 00 -> 14 -> 00, the ZOH derived from the"
		say "source select rather than assumed. The class-H stage reproduced"
		say "C2a exactly -- a7 while live, a6 after -- which is the teardown"
		say "this milestone inherited rather than invented."
		say ""
		say "The compander now runs at its 48 kHz operating point instead of"
		say "the discharge transient it was left on, its static gain offset"
		say "matches this board's 2.15 V buck, and the gain source moved to"
		say "the compander and back. Everything outside the HPHL path --"
		say "the HPHR DAC, the earpiece, a line-out and the speaker driver --"
		say "did not move."
		say ""
		say "The RDAC clock prerequisite -- CDC_CLK_POWER_CTL = 0x03 -- was"
		say "applied explicitly before the run and is recorded above. Without"
		say "it 0x30d bit 1 does not latch on this part: r164 found that on"
		say "hardware and r165 established it causally with one variable"
		say "moved. This milestone is therefore proven WITH that prerequisite"
		say "in place, and claims nothing about a codec that has not had it"
		say "applied. CHIP_CTL was observed and never written."
		say ""
		say "THE PA WAS OFF AT EVERY SAMPLE, read bypassed from the chip, and"
		say "the driver's own per-stage guard never tripped."
		say ""
		say "WHAT THIS DOES NOT CLAIM. Nothing was audible: without the PA no"
		say "signal reaches the jack. Byte arrival at the codec remains"
		say "unproven, exactly as it was after Branch B -- a powered DAC with"
		say "a connected input is a routing result, not a conversion one."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "Every expected value here was derived from the downstream write"
		say "sequences, and that derivation passes its own offline selftest."
		say "So a mismatch means the mapping is wrong -- revisit it rather"
		say "than adjusting the expectation to match what the hardware"
		say "happened to do. Do NOT tag on this run."
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

#!/bin/sh
#
# Branch C, first milestone: does the RX1 digital chain configure and operate?
#
# TWO QUESTIONS, KEPT APART
#
#   1. Can the five-register RX1 digital path be programmed on hardware, while
#      the proven QDSP6 loop and SLIMbus stream run underneath it?
#   2. Does CDC_COMP1_SHUT_DOWN_STATUS (0x376) behave differently with the
#      chain on than with it off?
#
# The first is about this implementation. The second is a hypothesis about the
# hardware that this gate exists to test, and it decides the milestone's NAME:
# a reproducible difference earns a receiver-side-activity claim, no difference
# earns only "the chain can be configured and operated".
#
# So the 0x376 result is REPORTED and judged separately. It does not fail the
# implementation checks, because "the register did not move" is a finding about
# the part, not a defect in the code.
#
# WHY A CONTROL PHASE
#
# 0x376 != 0x03 on its own proves nothing: the compander might sit at some other
# value whenever the codec is merely clocked. So the run is two phases with
# everything upstream held constant -- same RUN, same SLIMbus stream, same
# geometry -- differing only in whether the five registers are programmed. This
# is the same shape as Branch B's codec-absent control, which is what turned an
# assumed chain into a measured one.
#
# SCOPE
#
# Nothing here touches CLASS_H, the HPHL DAC (0x1b1), the PA (0x1ab), the
# earpiece (0x1bc) or RX bias. Those are snapshotted before and after and
# asserted UNCHANGED -- analog power sequencing is a different failure class and
# is deliberately absent.
#
# Exit: 0 the implementation works, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-rx1-digital"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-rx1-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
EV="/tmp/.rx1-events-$$"
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
PERIOD="${PERIOD:-960}"
NPERIODS="${NPERIODS:-4}"
SECS="${SECS:-3}"
SAMPLES="${SAMPLES:-24}"

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

RX1T="$PGD/rx1_digital_test"
RX1S="$PGD/rx1_digital_state"

# ------------------------------------------------------------ preconditions --
[ -n "$RUNNER" ] || { say "INVALID RUN: pcm-run-measured not found."; exit 2; }
[ -n "$SETCTL" ] || { say "INVALID RUN: alsa-setctl not found."; exit 2; }
[ -e "$RX1T" ] || {
	say "INVALID RUN: $RX1T does not exist."
	say "  The running codec has no RX1 digital hook; it must be"
	say "  rx1-digital-rc1 or later."
	exit 2
}
[ -w "$TRACE/kprobe_events" ] || { say "INVALID RUN: need root for kprobes."; exit 2; }
grep -q '^ *0 ' /proc/asound/cards 2>/dev/null || {
	say "INVALID RUN: no sound card."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

PRE=$(cat "$RX1S" 2>/dev/null)
P_ON=$(rv "$PRE" on)
P_ENAB=$(rv "$PRE" enables)
P_MUX=$(rv "$PRE" mux_0x380)
P_RST=$(rv "$PRE" reset_0x301)
P_CLK=$(rv "$PRE" clk_0x30f)
P_CHAIN=$(rv "$PRE" chain_0x2b5)
P_RATE=$(rv "$PRE" rate_0x2b4)
P_COMP=$(rv "$PRE" comp1_status_0x376)

#
# The frozen idle baseline, measured on r160 before any of this existed. A boot
# where any of it has already moved cannot produce a clean control phase, so it
# is INVALID SETUP rather than a failure -- the same distinction B1 draws.
#
BASE_BAD=""
[ "$P_ON" = "0" ]      || BASE_BAD="$BASE_BAD on=$P_ON"
[ "$P_ENAB" = "0" ]    || BASE_BAD="$BASE_BAD enables=$P_ENAB"
[ "$P_MUX" = "00" ]    || BASE_BAD="$BASE_BAD mux=$P_MUX"
[ "$P_RST" = "00" ]    || BASE_BAD="$BASE_BAD reset=$P_RST"
[ "$P_CLK" = "00" ]    || BASE_BAD="$BASE_BAD clk=$P_CLK"
[ "$P_CHAIN" = "80" ]  || BASE_BAD="$BASE_BAD chain=$P_CHAIN"
[ "$P_COMP" = "03" ]   || BASE_BAD="$BASE_BAD comp1=$P_COMP"
if [ -n "$BASE_BAD" ]; then
	say "INVALID RUN: the RX1 idle baseline is not intact:$BASE_BAD"
	say "  Expected on=0 enables=0 mux=00 reset=00 clk=00 chain=80 comp1=03,"
	say "  which is what a clean boot reads. Cold boot and run this once."
	exit 2
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-rx1-digital-$STAMP.txt"

# ------------------------------------------------------------- observation --
PROBES="rx_run:q6asm_run_nowait
rx_elapsed:snd_pcm_period_elapsed
rx_slimen:slim_stream_enable"

clear_probes() {
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	for _p in $PROBES; do
		_e="$TRACE/events/kprobes/${_p%%:*}/enable"
		[ -e "$_e" ] && echo 0 2>/dev/null > "$_e"
	done
	printf "" 2>/dev/null > "$TRACE/kprobe_events"
	true
}
arm_probes() {
	printf "" 2>/dev/null > "$TRACE/trace"
	for _p in $PROBES; do
		_n=${_p%%:*}; _s=${_p#*:}
		printf 'p:%s %s\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null &&
			echo 1 2>/dev/null > "$TRACE/events/kprobes/$_n/enable"
	done
	echo 1 2>/dev/null > "$TRACE/tracing_on"
}
cnt() { grep -c "$1:" "$TRACE/trace" 2>/dev/null || true; }

# Analog registers that must not move. Read through the state file's siblings
# via debugfs, because the driver deliberately exposes no way to write them.
REGDUMP=/sys/kernel/debug/regmap/$PGD_NAME/registers
analog_snap() {
	[ -r "$REGDUMP" ] || { echo "unreadable"; return; }
	grep -iE '^(1ab|1b1|1bc|320|1b3|1c5):' "$REGDUMP" 2>/dev/null | tr '\n' ' '
}

ANALOG_BEFORE=$(analog_snap)

# ------------------------------------------------------------- the phases --
"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
MIXER_VAL=$("$SETCTL" -D "$CTLDEV" --get "$MIXER" 2>/dev/null |
	sed -n 's/^readback=//p' | head -n1 | cut -d, -f1)

# phase <label> -> sets PH_SAMPLES, PH_RUN, PH_ELAPSED, PH_SLIMEN
phase() {
	arm_probes
	"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p "$PERIOD" -n "$NPERIODS" \
		  -t "$SECS" > "/tmp/.rx1-run-$1" 2>&1 &
	_pid=$!
	PH_SAMPLES=""
	_i=0
	while [ "$_i" -lt "$SAMPLES" ]; do
		_v=$(rv "$(cat "$RX1S" 2>/dev/null)" comp1_status_0x376)
		PH_SAMPLES="$PH_SAMPLES ${_v:-??}"
		_i=$((_i + 1))
		sleep 0.1
	done
	wait "$_pid" 2>/dev/null
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	PH_RUN=$(cnt rx_run)
	PH_ELAPSED=$(cnt rx_elapsed)
	PH_SLIMEN=$(cnt rx_slimen)
	[ -n "$PH_RUN" ] || PH_RUN=0
	[ -n "$PH_ELAPSED" ] || PH_ELAPSED=0
	[ -n "$PH_SLIMEN" ] || PH_SLIMEN=0
}

# --- CONTROL: chain OFF ---
phase control
CTL_SAMPLES="$PH_SAMPLES"; CTL_RUN="$PH_RUN"
CTL_ELAPSED="$PH_ELAPSED"; CTL_SLIMEN="$PH_SLIMEN"
CTL_UNIQ=$(printf '%s\n' $CTL_SAMPLES | sort -u | tr '\n' ' ')

# --- enable the five registers ---
echo rx1-on > "$RX1T" 2>/dev/null
RX1_ON_RC=$?
ON=$(cat "$RX1S" 2>/dev/null)
O_MUX=$(rv "$ON" mux_0x380);   O_CLK=$(rv "$ON" clk_0x30f)
O_CHAIN=$(rv "$ON" chain_0x2b5); O_GAIN=$(rv "$ON" gain_0x2b7)
O_RATE=$(rv "$ON" rate_0x2b4);  O_ON=$(rv "$ON" on)
O_WRITES=$(rv "$ON" writes)

# --- TREATMENT: chain ON ---
phase treat
TRT_SAMPLES="$PH_SAMPLES"; TRT_RUN="$PH_RUN"
TRT_ELAPSED="$PH_ELAPSED"; TRT_SLIMEN="$PH_SLIMEN"
TRT_UNIQ=$(printf '%s\n' $TRT_SAMPLES | sort -u | tr '\n' ' ')

echo rx1-off > "$RX1T" 2>/dev/null
RX1_OFF_RC=$?
POST=$(cat "$RX1S" 2>/dev/null)
Q_MUX=$(rv "$POST" mux_0x380);   Q_CLK=$(rv "$POST" clk_0x30f)
Q_CHAIN=$(rv "$POST" chain_0x2b5); Q_ON=$(rv "$POST" on)
Q_COMP=$(rv "$POST" comp1_status_0x376)

ANALOG_AFTER=$(analog_snap)
clear_probes
snap_dmesg

COMP_DIFFERS=$([ "$CTL_UNIQ" != "$TRT_UNIQ" ] && echo 1 || echo 0)
ERRS=$(dmesg 2>/dev/null | grep -c 'rx1-digital:.*\(failed\|did not take\)' || true)
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$ERRS" ] || ERRS=0
[ -n "$WARNS" ] || WARNS=0

{
	hdr "the frozen idle baseline, as found"
	printf '%s\n' "$PRE" | sed 's/^/  /'

	hdr "the route"
	say "mixer value          : ${MIXER_VAL:-unknown}"

	hdr "CONTROL phase -- chain OFF, QDSP6 running"
	say "ASM RUN              : $CTL_RUN"
	say "period completions   : $CTL_ELAPSED"
	say "slim_stream_enable   : $CTL_SLIMEN"
	say "0x376 samples        :$CTL_SAMPLES"
	say "0x376 distinct values: $CTL_UNIQ"

	hdr "the five registers, after rx1-on"
	say "rx1-on exit          : $RX1_ON_RC"
	printf '%s\n' "$ON" | sed 's/^/  /'

	hdr "TREATMENT phase -- chain ON, QDSP6 running"
	say "ASM RUN              : $TRT_RUN"
	say "period completions   : $TRT_ELAPSED"
	say "slim_stream_enable   : $TRT_SLIMEN"
	say "0x376 samples        :$TRT_SAMPLES"
	say "0x376 distinct values: $TRT_UNIQ"

	hdr "the observable"
	say "control  distinct    : $CTL_UNIQ"
	say "treatment distinct   : $TRT_UNIQ"
	say "differ?              : $COMP_DIFFERS"
	say ""
	say "This is REPORTED, not required. 0x376 not moving is a fact about"
	say "the part, not a defect in the implementation -- but it decides"
	say "whether this milestone may claim receiver-side activity."

	hdr "after teardown"
	printf '%s\n' "$POST" | sed 's/^/  /'

	hdr "analog registers must not have moved"
	say "before : $ANALOG_BEFORE"
	say "after  : $ANALOG_AFTER"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "the route is enabled" "$(num "$MIXER_VAL" 0)" "1"

	# --- the implementation ---
	check "rx1-on accepted" "$RX1_ON_RC" "0"
	check "0x380 selects RX1" "$O_MUX" "05"
	check "0x30f interpolator clock on" "$O_CLK" "01"
	check "0x2b5 chain enabled" "$O_CHAIN" "a0"
	check "0x2b4 rate still 48 kHz" "$O_RATE" "78"
	check "state: path on" "$O_ON" "1"
	check_cond "five writes were made" \
		"$([ "$(num "$O_WRITES" 0)" -ge 5 ] && echo 1 || echo 0)" \
		"only $O_WRITES writes recorded" "$O_WRITES"
	check "no rx1-digital failure logged" "$ERRS" "0"

	# --- the upstream stayed healthy in BOTH phases ---
	check "control: one ASM RUN" "$CTL_RUN" "1"
	check "treatment: one ASM RUN" "$TRT_RUN" "1"
	check_cond "control: periods completed" \
		"$([ "$CTL_ELAPSED" -ge 100 ] 2>/dev/null && echo 1 || echo 0)" \
		"only $CTL_ELAPSED completions" "$CTL_ELAPSED"
	check_cond "treatment: periods completed" \
		"$([ "$TRT_ELAPSED" -ge 100 ] 2>/dev/null && echo 1 || echo 0)" \
		"only $TRT_ELAPSED completions -- the RX chain disturbed the DSP loop" \
		"$TRT_ELAPSED"
	check "control: SLIMbus stream came up" "$CTL_SLIMEN" "1"
	check "treatment: SLIMbus stream came up" "$TRT_SLIMEN" "1"

	# --- scope and teardown ---
	check_cond "no analog register moved" \
		"$([ "$ANALOG_BEFORE" = "$ANALOG_AFTER" ] && echo 1 || echo 0)" \
		"an analog register changed -- this milestone must not touch them"
	check "rx1-off accepted" "$RX1_OFF_RC" "0"
	check "teardown: 0x380 back to 00" "$Q_MUX" "00"
	check "teardown: 0x30f back to 00" "$Q_CLK" "00"
	check "teardown: 0x2b5 back to 80" "$Q_CHAIN" "80"
	check "teardown: path off" "$Q_ON" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$FAIL_N" -ne 0 ]; then
		say "NOT PROVEN. $FAIL_N check(s) failed above."
	elif [ "$COMP_DIFFERS" = "1" ]; then
		say "THE RX1 DIGITAL CHAIN OPERATES, AND 0x376 RESPONDS TO IT."
		say ""
		say "All five registers took their intended values with the QDSP6 loop"
		say "and the SLIMbus stream running underneath, and the chain tore"
		say "down to the frozen idle baseline afterwards."
		say ""
		say "0x376 read $CTL_UNIQ with the chain off and $TRT_UNIQ with it on,"
		say "everything upstream held constant. That is a real, chain-dependent"
		say "difference in a receiver-side register."
		say ""
		say "WHAT IT STILL DOES NOT SETTLE. A chain-dependent register is not"
		say "yet a sample-arrival indicator: it may track only that the"
		say "compander block is clocked and powered. Establishing that it"
		say "follows signal PRESENCE needs a further experiment -- same chain,"
		say "differing data -- before it can close Branch B's byte-arrival gap."
	else
		say "THE RX1 DIGITAL CHAIN OPERATES. 0x376 IS UNRESOLVED."
		say ""
		say "All five registers took their intended values with the QDSP6 loop"
		say "and the SLIMbus stream running underneath, and the chain tore"
		say "down to the frozen idle baseline. That is the milestone, and it"
		say "stands on its own."
		say ""
		say "0x376 read $CTL_UNIQ in both phases -- but the COMPANDER WAS"
		say "NEVER ENABLED. COMP1_B1_CTL stayed at its POR value throughout,"
		say "because enabling it is outside this milestone's frozen scope."
		say ""
		say "A DISABLED BLOCK REPORTING ITS RESET STATUS IS EXPECTED. This run"
		say "therefore does NOT show that 0x376 is useless as an observable; it"
		say "shows that the RX1 chain alone does not move it. The hypothesis is"
		say "untested, not refuted, and the two must not be confused."
		say ""
		say "Testing it properly needs the compander enabled -- 0x370 plus its"
		say "clock and reset bits -- and the same control/treatment shape."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE" "$EV" /tmp/.rx1-run-control /tmp/.rx1-run-treat

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the frozen idle baseline/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

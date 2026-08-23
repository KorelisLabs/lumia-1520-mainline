#!/bin/sh
#
# Characterising 0x376: is CDC_COMP1_SHUT_DOWN_STATUS a receiver-side
# activity indicator, or merely a "the block is switched on" flag?
#
# WHY FOUR PHASES AND NOT TWO
#
# compander-off -> compander-on would be useless: any change could just mean
# the block was enabled. The question is whether 0x376 says anything about what
# the block is RECEIVING. So everything is held constant except one thing at a
# time:
#
#   A  baseline      chain OFF, COMP1 OFF, nothing streaming
#   B  enable-only   COMP1 ON,  chain OFF, nothing streaming
#   C  treatment     COMP1 ON,  chain ON,  QDSP6 RUN + SLIMbus stream active
#   D  transport off COMP1 ON,  chain ON,  QDSP6 RUN, codec stream SUPPRESSED
#
# The comparisons, and what each would mean:
#
#   A -> B   the register tracks compander enable state. Expected, uninteresting.
#   B -> C   it changes when a chain and a stream appear underneath it. THIS is
#            the interesting one -- it is the first evidence the register knows
#            anything beyond its own power state.
#   C -> D   it changes when the codec's SLIMbus stream is removed while the
#            DSP keeps running. That would tie it to the PHYSICAL TRANSPORT and
#            could close the byte-arrival gap Branch B deliberately left open.
#
# Phase D reuses the slim_transport suppression built for Branch B's negative
# control, which is why that toggle exists.
#
# WHAT THIS GATE DOES NOT DO
#
# It does not fail because 0x376 stays put. An inert register is a fact about
# the part. The implementation checks -- compander enables, chain enables, DSP
# stays healthy, nothing analog moves, teardown is clean -- are the pass/fail
# criteria. The observable's behaviour is measured and interpreted separately.
#
# Exit: 0 the experiment ran cleanly, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-comp1-observable"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-c1-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
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
C1T="$PGD/comp1_test"
TRANSPORT="$PGD/slim_transport"

# ------------------------------------------------------------ preconditions --
for f in "$RUNNER" "$SETCTL"; do
	[ -n "$f" ] || { say "INVALID RUN: a required helper is missing."; exit 2; }
done
for f in "$RX1T" "$RX1S" "$C1T" "$TRANSPORT"; do
	[ -e "$f" ] || {
		say "INVALID RUN: $f does not exist."
		say "  The running codec must be comp1-rc1 or later."
		exit 2
	}
done
[ -w "$TRACE/kprobe_events" ] || { say "INVALID RUN: need root."; exit 2; }
grep -q '^ *0 ' /proc/asound/cards 2>/dev/null || {
	say "INVALID RUN: no sound card."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
state() { cat "$RX1S" 2>/dev/null; }

PRE=$(state)
BASE_BAD=""
[ "$(rv "$PRE" on)" = "0" ]           || BASE_BAD="$BASE_BAD chain_on"
[ "$(rv "$PRE" mux_0x380)" = "00" ]   || BASE_BAD="$BASE_BAD mux"
[ "$(rv "$PRE" clk_0x30f)" = "00" ]   || BASE_BAD="$BASE_BAD interp_clk"
[ "$(rv "$PRE" chain_0x2b5)" = "80" ] || BASE_BAD="$BASE_BAD chain"
[ "$(rv "$PRE" ctl_0x370)" = "30" ]   || BASE_BAD="$BASE_BAD comp1_ctl"
[ "$(rv "$PRE" clk_0x310)" = "00" ]   || BASE_BAD="$BASE_BAD comp1_clk"
[ "$(rv "$PRE" comp1_status_0x376)" = "03" ] || BASE_BAD="$BASE_BAD comp1_status"
if [ -n "$BASE_BAD" ]; then
	say "INVALID RUN: the idle baseline is not intact:$BASE_BAD"
	say "  A boot where any of this has moved cannot give a clean phase A."
	exit 2
fi

snap_dmesg
open_output "$OUTDIR/wcd9320-comp1-observable-$STAMP.txt"

# ------------------------------------------------------------- observation --
PROBES="c1_run:q6asm_run_nowait
c1_elapsed:snd_pcm_period_elapsed
c1_slimen:slim_stream_enable"

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
cnt() { _c=$(grep -c "$1:" "$TRACE/trace" 2>/dev/null) || _c=0; echo "${_c:-0}"; }

REGDUMP=/sys/kernel/debug/regmap/$PGD_NAME/registers
# 1ae and 1b4 are the HPH gain registers taiko_config_gain_compander would
# write and we deliberately do not; 373 is the buck-derived static gain offset.
analog_snap() {
	[ -r "$REGDUMP" ] || { echo unreadable; return; }
	grep -iE '^(1ab|1ae|1b1|1b4|1bc|373|320):' "$REGDUMP" 2>/dev/null | tr '\n' ' '
}
ANALOG_BEFORE=$(analog_snap)

# sample_idle <n> -- just read the register, nothing running
sample_idle() {
	_o=""; _i=0
	while [ "$_i" -lt "$1" ]; do
		_o="$_o $(rv "$(state)" comp1_status_0x376)"
		_i=$((_i + 1))
		sleep 0.1
	done
	echo "$_o"
}

# sample_streaming -- run the PCM and sample across it
sample_streaming() {
	arm_probes
	"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p "$PERIOD" -n "$NPERIODS" \
		  -t "$SECS" >/dev/null 2>&1 &
	_pid=$!
	PH_SAMPLES=""; _i=0
	while [ "$_i" -lt "$SAMPLES" ]; do
		PH_SAMPLES="$PH_SAMPLES $(rv "$(state)" comp1_status_0x376)"
		_i=$((_i + 1))
		sleep 0.1
	done
	wait "$_pid" 2>/dev/null
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	PH_RUN=$(cnt c1_run)
	PH_ELAPSED=$(cnt c1_elapsed)
	PH_SLIMEN=$(cnt c1_slimen)
}

uniq_of() { printf '%s\n' $1 | sort -u | tr '\n' ' '; }

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1

# --- A: baseline -------------------------------------------------------
A_SAMPLES=$(sample_idle "$SAMPLES")
A_UNIQ=$(uniq_of "$A_SAMPLES")

# --- B: compander on, nothing else -------------------------------------
echo comp1-on > "$C1T" 2>/dev/null; C1_ON_RC=$?
B_STATE=$(state)
B_CTL=$(rv "$B_STATE" ctl_0x370); B_CLK=$(rv "$B_STATE" clk_0x310)
B_SAMPLES=$(sample_idle "$SAMPLES")
B_UNIQ=$(uniq_of "$B_SAMPLES")

# --- C: chain on, streaming --------------------------------------------
echo rx1-on > "$RX1T" 2>/dev/null; RX1_ON_RC=$?
C_STATE=$(state)
C_MUX=$(rv "$C_STATE" mux_0x380); C_ICLK=$(rv "$C_STATE" clk_0x30f)
C_CHAIN=$(rv "$C_STATE" chain_0x2b5)
sample_streaming
C_SAMPLES="$PH_SAMPLES"; C_RUN="$PH_RUN"
C_ELAPSED="$PH_ELAPSED"; C_SLIMEN="$PH_SLIMEN"
C_UNIQ=$(uniq_of "$C_SAMPLES")

# --- D: same, but the codec's SLIMbus stream suppressed ----------------
echo off > "$TRANSPORT" 2>/dev/null
sample_streaming
D_SAMPLES="$PH_SAMPLES"; D_RUN="$PH_RUN"
D_ELAPSED="$PH_ELAPSED"; D_SLIMEN="$PH_SLIMEN"
D_UNIQ=$(uniq_of "$D_SAMPLES")
echo on > "$TRANSPORT" 2>/dev/null

# --- teardown -----------------------------------------------------------
echo rx1-off > "$RX1T" 2>/dev/null; RX1_OFF_RC=$?
echo comp1-off > "$C1T" 2>/dev/null; C1_OFF_RC=$?
POST=$(state)
ANALOG_AFTER=$(analog_snap)
clear_probes
snap_dmesg

AB=$([ "$A_UNIQ" != "$B_UNIQ" ] && echo 1 || echo 0)
BC=$([ "$B_UNIQ" != "$C_UNIQ" ] && echo 1 || echo 0)
CD=$([ "$C_UNIQ" != "$D_UNIQ" ] && echo 1 || echo 0)

WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
[ -n "$WARNS" ] || WARNS=0

{
	hdr "phase A -- baseline (chain off, compander off, idle)"
	say "0x376 :$A_SAMPLES"
	say "distinct: $A_UNIQ"

	hdr "phase B -- compander ON only, still idle"
	say "comp1-on exit : $C1_ON_RC"
	say "0x370 = $B_CTL   0x310 = $B_CLK"
	say "0x376 :$B_SAMPLES"
	say "distinct: $B_UNIQ"

	hdr "phase C -- compander + chain + QDSP6 streaming"
	say "rx1-on exit   : $RX1_ON_RC"
	say "0x380 = $C_MUX   0x30f = $C_ICLK   0x2b5 = $C_CHAIN"
	say "ASM RUN $C_RUN   completions $C_ELAPSED   slim_stream_enable $C_SLIMEN"
	say "0x376 :$C_SAMPLES"
	say "distinct: $C_UNIQ"

	hdr "phase D -- same, codec SLIMbus stream SUPPRESSED"
	say "ASM RUN $D_RUN   completions $D_ELAPSED   slim_stream_enable $D_SLIMEN"
	say "0x376 :$D_SAMPLES"
	say "distinct: $D_UNIQ"

	hdr "the three comparisons"
	say "A -> B  (enable state)      differ: $AB"
	say "B -> C  (chain + stream)    differ: $BC   <- the interesting one"
	say "C -> D  (physical transport) differ: $CD   <- the decisive one"

	hdr "analog registers must not have moved"
	say "before : $ANALOG_BEFORE"
	say "after  : $ANALOG_AFTER"

	hdr "after teardown"
	printf '%s\n' "$POST" | sed 's/^/  /'

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "comp1-on accepted" "$C1_ON_RC" "0"
	check "0x370 compander enabled" "$B_CTL" "33"
	check "0x310 compander clocks on" "$B_CLK" "03"
	check "rx1-on accepted" "$RX1_ON_RC" "0"
	check "0x380 selects RX1" "$C_MUX" "05"
	check "0x30f interpolator on" "$C_ICLK" "01"
	check "0x2b5 chain enabled" "$C_CHAIN" "a0"
	check "C: one ASM RUN" "$C_RUN" "1"
	check "D: one ASM RUN" "$D_RUN" "1"
	check_cond "C: periods completed" \
		"$([ "$C_ELAPSED" -ge 100 ] 2>/dev/null && echo 1 || echo 0)" \
		"only $C_ELAPSED" "$C_ELAPSED"
	check_cond "D: periods completed" \
		"$([ "$D_ELAPSED" -ge 100 ] 2>/dev/null && echo 1 || echo 0)" \
		"only $D_ELAPSED" "$D_ELAPSED"
	check "C: codec stream came up" "$C_SLIMEN" "1"
	check "D: codec stream suppressed" "$D_SLIMEN" "0"
	check_cond "no analog register moved" \
		"$([ "$ANALOG_BEFORE" = "$ANALOG_AFTER" ] && echo 1 || echo 0)" \
		"an analog register changed"
	check "rx1-off accepted" "$RX1_OFF_RC" "0"
	check "comp1-off accepted" "$C1_OFF_RC" "0"
	check "teardown: chain off" "$(rv "$POST" chain_0x2b5)" "80"
	check "teardown: interpolator off" "$(rv "$POST" clk_0x30f)" "00"
	check "teardown: compander off" "$(rv "$POST" ctl_0x370)" "30"
	check "teardown: compander clocks off" "$(rv "$POST" clk_0x310)" "00"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$FAIL_N" -ne 0 ]; then
		say "EXPERIMENT INVALID. $FAIL_N check(s) failed above; the phases"
		say "cannot be compared if the setup did not hold."
	elif [ "$BC" = "0" ] && [ "$AB" = "0" ]; then
		say "0x376 IS INERT. The observable is refuted."
		say ""
		say "It did not move when the compander was ENABLED, nor when a chain"
		say "and a live stream were added underneath it. The compander was"
		say "genuinely running this time -- 0x370 read $B_CTL and its clocks"
		say "read $B_CLK -- so unlike the previous attempt this is a real"
		say "negative, not an untested hypothesis."
		say ""
		say "No receiver-side digital observable has been found on this part."
		say "Byte arrival at the codec cannot be proven without the analog"
		say "path, and that is now a measured conclusion."
	elif [ "$BC" = "0" ]; then
		say "0x376 TRACKS ENABLE STATE ONLY."
		say ""
		say "It changed from $A_UNIQ to $B_UNIQ when the compander was switched"
		say "on, and then did NOT change when a chain and a live stream were"
		say "added: still $C_UNIQ."
		say ""
		say "So it reports whether the block is powered, not what it is"
		say "receiving. It cannot serve as a receiver-side activity indicator,"
		say "and Branch B's byte-arrival gap stays open."
	elif [ "$CD" = "1" ]; then
		say "0x376 FOLLOWS THE PHYSICAL TRANSPORT."
		say ""
		say "B -> C moved it from $B_UNIQ to $C_UNIQ when a chain and a live"
		say "stream appeared, and C -> D moved it again to $D_UNIQ when the"
		say "codec's SLIMbus stream was suppressed while the DSP kept running"
		say "identically -- $D_ELAPSED completions against $C_ELAPSED."
		say ""
		say "That is the first evidence tying a codec-side register to data"
		say "arriving over the bus, rather than to the DSP merely running. It"
		say "is a candidate for closing the gap Branch B left open, and it"
		say "deserves its own milestone and its own repeat runs before the"
		say "claim is made."
	else
		say "0x376 RESPONDS TO THE CHAIN, BUT NOT TO THE TRANSPORT."
		say ""
		say "B -> C moved it from $B_UNIQ to $C_UNIQ, so it knows something"
		say "beyond its own power state. But C -> D left it at $D_UNIQ with the"
		say "codec's SLIMbus stream suppressed, so what it reflects is the"
		say "local chain being clocked and running -- not data arriving from"
		say "the bus."
		say ""
		say "Interesting, but it does NOT close Branch B's gap: it cannot"
		say "distinguish a codec receiving samples from a codec whose"
		say "interpolator is simply running."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== phase A/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

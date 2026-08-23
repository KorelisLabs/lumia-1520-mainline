#!/bin/sh
#
# Branch B2: does the QDSP6 actually consume periods, at rate?
#
# THE CLAIM UNDER TEST
#
#   An ordinary PCM open/write/START on the QDSP6 front end drives ASM RUN, the
#   DSP acknowledges it, and the WRITE / WRITE_DONE loop then runs at real time
#   -- roughly 48000 frames per second -- with the WCD9320's SLIMbus RX stream
#   active throughout, and everything tears down cleanly afterwards.
#
# WHAT IT CANNOT CLAIM, AND WHY
#
# The driver issues q6asm_write_async() from its event handler whether or not
# userspace supplied anything. So progression proves the DSP is CONSUMING the
# mapped buffer. It does not prove the bytes this run wrote are the bytes
# consumed, and there is no receiver-side counter or loopback on this hardware
# to close that gap. Whether progression even depends on the physical sink is a
# separate question, answered by the codec-absent negative control -- until that
# runs, "the DSP consumed" and "SLIMbus carried it" are concurrent facts, not a
# proven chain.
#
# Nothing here is audible. The codec has no RX interpolator and no output path.
#
# WHY hw_ptr IS GOOD EVIDENCE HERE
#
# q6asm_dai_pointer() returns pcm_irq_pos, incremented in exactly one place: the
# ASM_CLIENT_EVENT_DATA_WRITE_DONE handler. hw_ptr is therefore a count of DSP
# acknowledgements rather than a timer estimate.
#
# The authoritative rate comes from KERNEL timestamps on snd_pcm_period_elapsed,
# not from the helper's userspace polling. Polling adds scheduling jitter to
# both ends of the interval, which would force a looser tolerance and blunt the
# measurement. The helper's own figure is printed alongside as corroboration.
#
# RUN THIS AFTER THE B1 GATE, ON THE SAME BOOT
#
# B1 exercises the debugfs hook and logs origin=manual; this run drives the DAI
# and logs "ASoC" lines the hook cannot produce, so the two are distinguishable
# in one dmesg. The trace is cleared here, so all kprobe counts are this run's.
# The control-plane gate must NOT be run on this boot -- it asserts its codec
# delta counts equal exactly 1, and this run adds to them.
#
# Exit: 0 proven, 1 checks failed, 2 invalid setup.

set -u

MODE="q6-data-plane"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-b2-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
EV="/tmp/.b2-events-$$"
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"

PERIOD="${PERIOD:-960}"		# 20 ms at 48 kHz
NPERIODS="${NPERIODS:-4}"
SECS="${SECS:-3}"
WANT_RATE="${WANT_RATE:-48000}"
TOL_PCT="${TOL_PCT:-2}"		# kernel timestamps justify 2%; userspace would not
MIN_PERIODS="${MIN_PERIODS:-100}"

# NEGATIVE=1 runs the codec-absent control: the identical FE/ASM/ADM/AFE path,
# the same AFE port and channel, the same geometry -- with the codec doing no
# slim_stream_prepare() and no slim_stream_enable(). Exactly one variable
# changes, so the comparison isolates whether progression depends on the
# physical sink at all.
NEG="${NEGATIVE:-0}"
if [ "$NEG" = "1" ]; then
	MODE="q6-data-plane-negative"
fi

RUNNER=""
for c in "${PCM_RUNNER:-}" "$DIR/pcm-run-measured" /tmp/pcm-run-measured \
         "$HOME/pcm-run-measured"; do
	[ -n "$c" ] && [ -x "$c" ] && { RUNNER="$c"; break; }
done
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl \
         "$HOME/alsa-setctl"; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

require_module_version
find_devices

# ------------------------------------------------------------ preconditions --
[ -n "$RUNNER" ] || {
	say "INVALID RUN: pcm-run-measured was not found."
	say "  This gate must not fall back to aplay: the measurement depends on"
	say "  an explicit START and a known period size."
	exit 2
}
[ -n "$SETCTL" ] || {
	say "INVALID RUN: alsa-setctl was not found, so the route cannot be set."
	exit 2
}
[ -w "$TRACE/kprobe_events" ] || {
	say "INVALID RUN: $TRACE/kprobe_events is not writable (need root)."
	exit 2
}
grep -q '^ *0 ' /proc/asound/cards 2>/dev/null || {
	say "INVALID RUN: no sound card. The QDSP6 card did not bind."
	exit 2
}
if lsmod 2>/dev/null | grep -q '^wcd9320_lumia_card '; then
	say "INVALID RUN: the frozen minimal card is loaded; it owns the codec."
	exit 2
fi

TRANSPORT="$PGD/slim_transport"
if [ "$NEG" = "1" ]; then
	[ -e "$TRANSPORT" ] || {
		say "INVALID RUN: $TRANSPORT does not exist."
		say "  The running codec has no negative-control toggle; it must be"
		say "  dataplane-rc2 or later."
		exit 2
	}
fi

snap_dmesg
DMESG_LINES_BEFORE=$(wc -l < "$DMESG_FILE" 2>/dev/null || echo 0)
open_output "$OUTDIR/msm8974-q6-data-plane-$STAMP.txt"

# ------------------------------------------------------------- observation --
PROBES="d2_run:q6asm_run_nowait
d2_write:q6asm_write_async
d2_elapsed:snd_pcm_period_elapsed
d2_prepare:slim_stream_prepare
d2_enable:slim_stream_enable
d2_disable:slim_stream_disable
d2_unprepare:slim_stream_unprepare
d2_ngd:qcom_slim_ngd_enable_stream
d2_eos:q6asm_cmd_nowait"
RETPROBES="d2_ngd_ret:qcom_slim_ngd_enable_stream"

clear_probes() {
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	for _p in $PROBES $RETPROBES; do
		_e="$TRACE/events/kprobes/${_p%%:*}/enable"
		[ -e "$_e" ] && echo 0 2>/dev/null > "$_e"
	done
	printf "" 2>/dev/null > "$TRACE/kprobe_events"
	true
}

clear_probes
printf "" 2>/dev/null > "$TRACE/trace"
# The trace must hold ~150 period events plus the writes; the default ring is
# ample, but a too-small buffer would silently truncate the measurement.
echo 4096 2>/dev/null > "$TRACE/buffer_size_kb"

PROBE_OK=""
PROBE_BAD=""
for _p in $PROBES; do
	_n=${_p%%:*}; _s=${_p#*:}
	if printf 'p:%s %s\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null; then
		PROBE_OK="$PROBE_OK $_n"
		echo 1 2>/dev/null > "$TRACE/events/kprobes/$_n/enable"
	else
		PROBE_BAD="$PROBE_BAD $_n"
	fi
done
for _p in $RETPROBES; do
	_n=${_p%%:*}; _s=${_p#*:}
	if printf 'r:%s %s ret=$retval:s32\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null; then
		PROBE_OK="$PROBE_OK $_n"
		echo 1 2>/dev/null > "$TRACE/events/kprobes/$_n/enable"
	else
		PROBE_BAD="$PROBE_BAD $_n"
	fi
done
echo 1 2>/dev/null > "$TRACE/tracing_on"

# -------------------------------------------------------------- the sequence --
if [ "$NEG" = "1" ]; then
	echo off > "$TRANSPORT" 2>/dev/null
	TRANSPORT_STATE=$(cat "$TRANSPORT" 2>/dev/null)
else
	TRANSPORT_STATE=$(cat "$TRANSPORT" 2>/dev/null)
fi

MIXER_OUT=$("$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 2>&1)
MIXER_RC=$?
MIXER_VAL=$(printf "%s" "$MIXER_OUT" | sed -n "s/^readback=//p" | head -n1 | cut -d, -f1)

RUN_OUT=$("$RUNNER" -D "$PCMDEV" -r "$WANT_RATE" -c 1 -p "$PERIOD" \
                    -n "$NPERIODS" -t "$SECS" 2>&1)
RUN_RC=$?
sleep 1

# Restore immediately, so a crashed run cannot leave the control armed and
# silently poison the next positive measurement.
if [ "$NEG" = "1" ]; then
	echo on > "$TRANSPORT" 2>/dev/null
fi
echo 0 2>/dev/null > "$TRACE/tracing_on"
snap_dmesg

h() { printf '%s' "$RUN_OUT" | sed -n "s/^$1=//p" | head -n1; }

ACT_PERIOD=$(num "$(h actual_period_frames)" 0)
HW_ADV=$(num "$(h hw_ptr_advance)" 0)
US_RATE=$(h userspace_rate_fps)
HELPER_XRUNS=$(num "$(h xruns)" 0)
STATE_FINAL=$(h state_final)
START_RC=$(num "$(h start_rc)" 1)
FRAMES_WRITTEN=$(num "$(h frames_written)" 0)

# --------------------------------------------------------------- the windows --
awk '{
	for (i = 1; i <= NF; i++)
		if ($i ~ /^[0-9]+\.[0-9]+:$/) {
			ts = substr($i, 1, length($i) - 1)
			nm = $(i + 1)
			sub(/:$/, "", nm)
			print ts, nm
			break
		}
}' "$TRACE/trace" > "$EV" 2>/dev/null

first_ts() { awk -v n="$1" '$2 == n { print $1; exit }' "$EV"; }
last_ts()  { awk -v n="$1" '$2 == n { t = $1 } END { if (t != "") print t }' "$EV"; }
cnt()      { awk -v n="$1" '$2 == n { c++ } END { print c + 0 }' "$EV"; }

N_RUN=$(cnt d2_run);         N_WRITE=$(cnt d2_write)
N_ELAPSED=$(cnt d2_elapsed); N_PREP=$(cnt d2_prepare)
N_EN=$(cnt d2_enable);       N_DIS=$(cnt d2_disable)
N_UNP=$(cnt d2_unprepare);   N_NGD=$(cnt d2_ngd)
N_EOS=$(cnt d2_eos)

T_RUN=$(first_ts d2_run);       T_W1=$(first_ts d2_write)
T_E1=$(first_ts d2_elapsed);    T_EN=$(last_ts d2_elapsed)
T_ENABLE=$(first_ts d2_enable); T_DISABLE=$(first_ts d2_disable)
T_EOS=$(first_ts d2_eos)

NGD_RET=$(grep -m1 "d2_ngd_ret" "$TRACE/trace" 2>/dev/null |
	sed -n "s/.*ret=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p")
[ -n "${NGD_RET:-}" ] || NGD_RET=absent

# Rate from kernel timestamps: (completions - 1) periods between the first and
# last WRITE_DONE-driven period_elapsed.
RATE=$(awk -v n="$N_ELAPSED" -v a="${T_E1:-0}" -v b="${T_EN:-0}" -v p="$ACT_PERIOD" \
	'BEGIN { d = b - a; if (n > 1 && d > 0) printf "%.1f", (n - 1) * p / d; else print "0" }')
MEASURED_SPAN=$(awk -v a="${T_E1:-0}" -v b="${T_EN:-0}" \
	'BEGIN { d = b - a; if (d > 0) printf "%.4f", d; else print "0" }')
RATE_OK=$(awk -v r="$RATE" -v w="$WANT_RATE" -v t="$TOL_PCT" \
	'BEGIN { lo = w * (1 - t/100); hi = w * (1 + t/100);
	         print (r >= lo && r <= hi) ? 1 : 0 }')
RATE_LO=$(awk -v w="$WANT_RATE" -v t="$TOL_PCT" 'BEGIN { printf "%.0f", w*(1-t/100) }')
RATE_HI=$(awk -v w="$WANT_RATE" -v t="$TOL_PCT" 'BEGIN { printf "%.0f", w*(1+t/100) }')

# Ordering. Each is a separate fact and each can fail alone.
ORDER_RUN_FIRST=$(awk -v a="${T_RUN:-0}" -v b="${T_W1:-0}" \
	'BEGIN { print (a > 0 && b > a) ? 1 : 0 }')
STREAM_BEFORE=$(awk -v a="${T_ENABLE:-0}" -v b="${T_E1:-0}" \
	'BEGIN { print (a > 0 && b > a) ? 1 : 0 }')
# THE TAIL IS NOT SYMMETRIC WITH THE HEAD.
#
# A completion before the sink is connected means the DSP pushed data at a
# channel nobody was listening to -- a real defect, and TRIGGER_POST fixed it.
#
# A completion AFTER the sink is disconnected does not mean the same thing.
# snd_pcm_period_elapsed is an ACKNOWLEDGEMENT, and the FE stop is
# q6asm_cmd_nowait(CMD_EOS) -- asynchronous. The state goes to STOPPED so no
# further write is issued, but a WRITE_DONE already in flight still lands, and
# the transfer it acknowledges happened BEFORE the disconnect. Exactly one
# such ack is unavoidable; no driver change removes it.
#
# So the tail asserts the ordering of the REQUESTS, which is the real
# property: the source was told to stop before the sink was torn down. The
# trailing ack is bounded rather than forbidden.
STOP_ORDER=$(awk -v e="${T_EOS:-0}" -v d="${T_DISABLE:-0}" 'BEGIN { print (e > 0 && d > e) ? 1 : 0 }')
STREAM_AFTER=$STOP_ORDER

# How BADLY, not just whether. ASoC reverses the order for STOP, so the
# default TRIGGER_PRE gets a playback FE wrong at BOTH ends: RUN before the
# sink is connected, and the sink disconnected before the source stops. The
# severity is the number of periods that completed outside that window.
LEAK_PRE=$(awk -v a="${T_ENABLE:-0}" '$2 == "d2_elapsed" && a > 0 && $1 < a { c++ } END { print c + 0 }' "$EV")
LEAK_POST=$(awk -v b="${T_DISABLE:-0}" '$2 == "d2_elapsed" && b > 0 && $1 > b { c++ } END { print c + 0 }' "$EV")
LEAK_POST_OK=$([ "${LEAK_POST:-9}" -le 1 ] 2>/dev/null && echo 1 || echo 0)

# writes and completions should track one-for-one, the extra write being the
# first one, issued from RUN_DONE.
WRITE_MATCH=$(awk -v w="$N_WRITE" -v e="$N_ELAPSED" \
	'BEGIN { d = w - e; if (d < 0) d = -d; print (d <= 2) ? 1 : 0 }')
# hw_ptr must have advanced by the completions, not by a timer.
# The helper's first hw_ptr sample lands after a completion or two, so the
# counts legitimately differ by a few periods. 10 periods of slack (200 ms of
# 3 s) still rejects the failure this guards against: a pointer driven by
# something other than WRITE_DONE, which would drift by far more than that.
HWPTR_MATCH=$(awk -v h="$HW_ADV" -v e="$N_ELAPSED" -v p="$ACT_PERIOD" \
	'BEGIN { if (e < 2 || p == 0) { print 0; exit }
	         x = e * p; d = h - x; if (d < 0) d = -d;
	         print (d <= 10 * p) ? 1 : 0 }')

# --------------------------------------------------- what the DAI path logged --
d() { grep -c -- "$1" "$DMESG_FILE" 2>/dev/null || true; }
L_ASOC_START=$(d 'slim-stream: ASoC trigger START')
L_ASOC_STOP=$(d 'slim-stream: ASoC trigger STOP')
L_ASOC_STARTUP=$(d 'slim-stream: ASoC startup')
L_ASOC_SHUTDOWN=$(d 'slim-stream: ASoC shutdown')
L_ASOC_HWP=$(d 'RX path invocation: ASoC hw_params')
L_RELAY=$(d 'reported by the codec')
L_SUPPRESSED=$(d 'SUPPRESSED by the negative control')
ERRS=$(dmesg 2>/dev/null | grep -c 'slim-stream:.*failed' || true)
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)
for v in L_ASOC_START L_ASOC_STOP L_ASOC_STARTUP L_ASOC_SHUTDOWN L_ASOC_HWP \
         L_RELAY ERRS WARNS; do
	eval "[ -n \"\$$v\" ] || $v=0"
done

STATE_AFTER=$(cat "$PGD/slim_stream_state" 2>/dev/null)
S_UP=$(printf '%s' "$STATE_AFTER" | sed -n 's/^up=\([0-9]*\).*/\1/p' | head -n1)
S_ALLOC=$(printf '%s' "$STATE_AFTER" | sed -n 's/^allocated=//p' | head -n1)

{
	hdr "the route"
	say "codec transport      : ${TRANSPORT_STATE:-unknown}"
	if [ "$NEG" = "1" ]; then
		say "  NEGATIVE CONTROL: the codec set up no SLIMbus stream."
		say "  Everything else is held fixed."
	fi
	say "mixer                : $MIXER"
	say "set rc               : $MIXER_RC   value read back: ${MIXER_VAL:-unknown}"

	hdr "the measured run"
	printf '%s\n' "${RUN_OUT:-  (not run)}" | sed 's/^/  /'
	say "helper exit          : $RUN_RC"

	hdr "observed calls (this run only -- the trace was cleared)"
	say "probes registered    :${PROBE_OK:- none}"
	[ -n "$PROBE_BAD" ] && say "probes FAILED        :$PROBE_BAD"
	say ""
	say "  q6asm_run_nowait          : $N_RUN"
	say "  q6asm_write_async         : $N_WRITE"
	say "  snd_pcm_period_elapsed    : $N_ELAPSED"
	say "  q6asm_cmd_nowait (EOS)    : $N_EOS"
	say "  slim_stream_prepare       : $N_PREP"
	say "  slim_stream_enable        : $N_EN"
	say "  qcom_slim_ngd_enable_stream: $N_NGD  (returned $NGD_RET)"
	say "  slim_stream_disable       : $N_DIS"
	say "  slim_stream_unprepare     : $N_UNP"

	hdr "the rate, from kernel timestamps"
	say "period frames        : $ACT_PERIOD"
	say "completions          : $N_ELAPSED   (minimum $MIN_PERIODS)"
	say "measured span        : ${MEASURED_SPAN}s  (first to last completion)"
	say "measured rate        : $RATE frames/s"
	say "accepted band        : $RATE_LO .. $RATE_HI  (${TOL_PCT}% of $WANT_RATE)"
	say ""
	say "userspace rate       : ${US_RATE:-0}  (corroboration only; polling"
	say "                       adds jitter at both ends of the interval)"
	say "hw_ptr advance       : $HW_ADV frames"

	hdr "ordering"
	say "RUN before first WRITE       : $ORDER_RUN_FIRST   (RUN ack drove the first write)"
	say "SLIM stream up before periods: $STREAM_BEFORE"
	say "SLIM stream down after them  : $STREAM_AFTER"
	say ""
	say "periods before the stream was up : $LEAK_PRE"
	say "acks after the stream came down  : $LEAK_POST   (<=1 is inherent)"
	say "EOS requested before disconnect  : $STOP_ORDER"
	say "  (the head leak is data pushed at nothing; the tail is an"
	say "   in-flight acknowledgement of a transfer already done)"
	hdr "the DAI path drove it, not the research hook"
	say "ASoC startup         : $L_ASOC_STARTUP"
	say "ASoC hw_params       : $L_ASOC_HWP"
	say "ASoC trigger START   : $L_ASOC_START"
	say "ASoC trigger STOP    : $L_ASOC_STOP"
	say "ASoC shutdown        : $L_ASOC_SHUTDOWN"
	say "channel map relayed  : $L_RELAY"

	hdr "residue"
	printf '%s\n' "${STATE_AFTER:-  (unreadable)}" | sed 's/^/  /'

	hdr "the ladder"
	L() { printf '  %-4s %-5s %s\n' "$1" "$2" "$3"; }
	ge() { [ "${1:-0}" -ge "${2:-1}" ] 2>/dev/null && echo PASS || echo FAIL; }
	is() { [ "${1:-x}" = "$2" ] && echo PASS || echo FAIL; }

	L D0 "$(is "$MIXER_VAL" 1)" "route enabled"
	L D1 "$(ge "$N_PREP" 1)" "B1 transport: prepare"
	L D2 "$(ge "$N_EN" 1)" "B1 transport: enable"
	L D3 "$(is "$NGD_RET" 0)" "ADSP accepted DEF_ACT_CHAN"
	L D4 "$(is "$N_RUN" 1)" "exactly one ASM RUN"
	L D5 "$(is "$ORDER_RUN_FIRST" 1)" "first WRITE followed the RUN ack"
	L D6 "$(ge "$N_WRITE" "$MIN_PERIODS")" "many WRITEs issued"
	L D7 "$(ge "$N_ELAPSED" "$MIN_PERIODS")" "at least $MIN_PERIODS completions"
	L D8 "$(is "$WRITE_MATCH" 1)" "WRITEs and completions track 1:1"
	L D9 "$(is "$HWPTR_MATCH" 1)" "hw_ptr advanced by completions"
	L D10 "$(is "$RATE_OK" 1)" "sustained $RATE fps"
	L D11 "$(is "$HELPER_XRUNS" 0)" "no xrun"
	L D12 "$(is "$STREAM_BEFORE" 1)" "stream up first (leaked $LEAK_PRE)"
	L D13 "$(is "$STOP_ORDER" 1)" "source stopped first (trailing acks $LEAK_POST)"
	L D14 "$(ge "$N_UNP" 1)" "clean SLIMbus teardown"
	L D15 "$(is "$S_ALLOC" 0)" "no residue"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "every kprobe registered" \
		"$([ -z "$PROBE_BAD" ] && echo 1 || echo 0)" \
		"these did not register:$PROBE_BAD" "all"
	check "the route is enabled" "$(num "$MIXER_VAL" 0)" "1"
	check "helper started the stream" "$START_RC" "0"

	# --- the B1 transport, re-proven inside this run -----------------
	if [ "$NEG" = "1" ]; then
		#
		# The control is only valid if the transport really was absent. A
		# run where the codec quietly set its stream up anyway would look
		# like a negative control and be a second positive one.
		#
		check "NO slim_stream_prepare" "$N_PREP" "0"
		check "NO slim_stream_enable" "$N_EN" "0"
		check "NO DEF_ACT_CHAN" "$N_NGD" "0"
		check_cond "the suppression was logged" \
			"$([ "$L_SUPPRESSED" -ge 1 ] && echo 1 || echo 0)" \
			"the driver never reported suppressing the transport"
	else
		check "slim_stream_prepare called" "$N_PREP" "1"
		check "slim_stream_enable called" "$N_EN" "1"
		check "the ADSP accepted DEF_ACT_CHAN" "$NGD_RET" "0"
	fi

	# --- RUN, and the acknowledgement --------------------------------
	check "exactly one ASM RUN" "$N_RUN" "1"
	check_cond "the first WRITE followed RUN" "$ORDER_RUN_FIRST" \
		"no WRITE was seen after RUN -- the DSP never acknowledged it"

	# --- the loop ----------------------------------------------------
	check_cond "WRITEs issued" \
		"$([ "$N_WRITE" -ge "$MIN_PERIODS" ] 2>/dev/null && echo 1 || echo 0)" \
		"only $N_WRITE writes; wanted at least $MIN_PERIODS" "$N_WRITE"
	check_cond "period completions" \
		"$([ "$N_ELAPSED" -ge "$MIN_PERIODS" ] 2>/dev/null && echo 1 || echo 0)" \
		"only $N_ELAPSED completions; a short interval can fake a plausible rate" \
		"$N_ELAPSED"
	check_cond "WRITEs and completions track" "$WRITE_MATCH" \
		"writes=$N_WRITE completions=$N_ELAPSED -- they should differ by at most the first write"
	check_cond "hw_ptr advanced by completions, not a timer" "$HWPTR_MATCH" \
		"hw_ptr moved $HW_ADV frames but $N_ELAPSED completions x $ACT_PERIOD frames were expected"
	check_cond "sustained rate within ${TOL_PCT}%" "$RATE_OK" \
		"$RATE fps is outside $RATE_LO..$RATE_HI" "$RATE fps"

	# --- the transport was live while it happened --------------------
	if [ "$NEG" = "1" ]; then
		note "ordering checks" "skipped: no stream to order against"
	else
		check_cond "the SLIM stream was up before the first period" "$STREAM_BEFORE" \
			"$LEAK_PRE period(s) completed before the codec stream was enabled"
		check_cond "the source was stopped before the sink" "$STOP_ORDER" \
			"disable ran before the EOS request"
		check_cond "trailing acknowledgements bounded" "$LEAK_POST_OK" \
			"$LEAK_POST acks after disconnect; at most 1 is inherent" \
			"$LEAK_POST"
	fi

	# --- the DAI drove it, not the hook ------------------------------
	check_cond "ASoC drove startup" \
		"$([ "$L_ASOC_STARTUP" -ge 1 ] && echo 1 || echo 0)" "no ASoC startup line"
	check_cond "ASoC drove hw_params" \
		"$([ "$L_ASOC_HWP" -ge 1 ] && echo 1 || echo 0)" "no ASoC hw_params line"
	check_cond "ASoC drove trigger START" \
		"$([ "$L_ASOC_START" -ge 1 ] && echo 1 || echo 0)" "no ASoC trigger START line"
	check_cond "the codec's channel map was relayed" \
		"$([ "$L_RELAY" -ge 1 ] && echo 1 || echo 0)" \
		"the machine driver did not log a codec-reported map"

	# --- teardown and residue ----------------------------------------
	check "no xrun" "$HELPER_XRUNS" "0"
	[ "$NEG" = "1" ] || check "slim_stream_disable called" "$N_DIS" "1"
	[ "$NEG" = "1" ] || check "slim_stream_unprepare called" "$N_UNP" "1"
	check_cond "ASoC drove trigger STOP" \
		"$([ "$L_ASOC_STOP" -ge 1 ] && echo 1 || echo 0)" "no ASoC trigger STOP line"
	check "no residue: stream down" "$(num "$S_UP" 1)" "0"
	check "no residue: runtime freed" "$(num "$S_ALLOC" 1)" "0"
	check "no slim-stream failure logged" "$ERRS" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$NEG" = "1" ] && [ "$FAIL_N" -eq 0 ]; then
		say "NEGATIVE CONTROL COMPLETED."
		say ""
		say "The codec set up NO SLIMbus stream: no prepare, no enable, no"
		say "DEF_ACT_CHAN. Everything else was identical -- same front end,"
		say "same ASM session, same AFE port 0x4000, same channel 144, same"
		say "period geometry."
		say ""
		say "Result: $N_ELAPSED completions at $RATE frames/s."
		say ""
		say "READ IT LIKE THIS. If that rate matches the positive run, then"
		say "period progression is a property of the DSP consuming its own"
		say "mapped buffer and says NOTHING about the bus -- so the data-plane"
		say "milestone may claim concurrent DSP progression and active SLIMbus"
		say "transport, but NOT that those bytes reached the WCD9320."
		say ""
		say "If instead it stalled, errored, or ran at a different rate, the"
		say "loop depends on the physical sink, which is stronger evidence --"
		say "though still short of byte-for-byte integrity, which needs a"
		say "receiver-side counter this hardware does not have."
		say ""
		say "This run does not decide that on its own. Compare it with the"
		say "positive run from the same boot."
	elif [ "$FAIL_N" -eq 0 ]; then
		say "THE QDSP6 CONSUMES PERIODS AT REAL TIME."
		say ""
		say "One ASM RUN was issued and acknowledged -- the first WRITE followed"
		say "it, which is the acknowledgement made visible. $N_ELAPSED period"
		say "completions then arrived over ${MEASURED_SPAN}s, a sustained"
		say "$RATE frames/s against a target of $WANT_RATE."
		say ""
		say "hw_ptr advanced by $HW_ADV frames, matching the completion count"
		say "times the period size. On this platform that is not a coincidence:"
		say "pcm_irq_pos is incremented only in the WRITE_DONE handler, so the"
		say "pointer IS the DSP's acknowledgement count."
		say ""
		say "The WCD9320's SLIMbus RX stream was enabled before the first period"
		say "and torn down after the last, and ASoC drove all of it -- the"
		say "research hook was not involved."
		say ""
		say "WHAT THIS DOES NOT CLAIM. The driver writes to the DSP whether or"
		say "not userspace supplied data, and there is no receiver-side counter"
		say "on this hardware, so this does not prove the bytes written here"
		say "reached the codec. Until the codec-absent negative control runs,"
		say "'the DSP consumed' and 'SLIMbus carried it' are concurrent facts,"
		say "not a proven chain. Nothing was audible: there is no output path."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "Read the ladder. D0-D3 are the transport, D4-D5 the RUN handshake,"
		say "D6-D10 the loop and its rate, D11-D15 teardown. A rate failure with"
		say "D0-D9 passing means the path works but is not running at real time,"
		say "which is a different problem from a path that never started."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

clear_probes
rm -f "$DMESG_FILE" "$EV"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the route ===/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

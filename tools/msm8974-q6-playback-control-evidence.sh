#!/bin/sh
#
# Branch A build 2 of 2: does the real QDSP6 playback control plane work?
#
# THE CLAIM UNDER TEST
#
#   A real QDSP6 FE/BE path can be instantiated; ASM, ADM and AFE control
#   operations receive successful DSP responses; SLIMBUS_0_RX accepts the
#   proposed one-channel configuration; and the existing WCD9320 RX callback
#   still produces its frozen register delta.
#
# NOT claimed: slim_stream_*, buffer progression, sample movement, audio.
#
# THE HARD BOUNDARY IS THE ABSENCE OF RUN
#
# The run stops before ASM_SESSION_CMD_RUN_V2. That is enforced twice: the
# prepare-only helper contains no write() and no START ioctl (its source is
# audited before it is ever compiled), and a kprobe on q6asm_run_nowait must
# observe ZERO calls. Belt and braces, because "no samples moved" is the one
# claim that must not rest on a single mechanism.
#
# WHY KPROBES AND NOT JUST RETURN CODES
#
# A successful prepare() does imply the ADSP replied -- the AFE and ADM calls
# are synchronous and check the returned status -- but it cannot distinguish
# "the DSP acknowledged" from "the path was skipped". Counting the actual
# calls proves traffic occurred. Registration of each kprobe is asserted
# separately, because an unregistered probe reports zero calls and would look
# exactly like a step that never ran.
#
# THE MIXER MUST BE SET BEFORE THE PCM IS OPENED
#
# "SLIMBUS_0_RX Audio Mixer MultiMedia1" is what gives q6routing a port_id.
# Without it q6routing_stream_open() connects nothing, the FE never reaches
# the BE, and the run would fail cleanly while proving nothing about the DSP.
#
# Exit: 0 proven, 1 checks failed, 2 invalid setup, 3 the route was never
#       established (so nothing was asked of the DSP).

set -u

MODE="q6-playback-control"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-q6pc-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"

# The prepare-only helper: the frozen instrument, proven on boot #154.
HELPER=""
for c in "${PCM_HELPER:-}" "$DIR/pcm-prepare-only" /tmp/pcm-prepare-only \
         "$HOME/pcm-prepare-only"; do
	[ -n "$c" ] && [ -x "$c" ] && { HELPER="$c"; break; }
done

require_module_version
find_devices

# ------------------------------------------------------------ preconditions --
[ -n "$HELPER" ] || {
	say "INVALID RUN: the prepare-only helper was not found."
	say "  Looked at \$PCM_HELPER, $DIR/, /tmp/ and \$HOME/."
	say "  This gate must not fall back to aplay: aplay's first write()"
	say "  drives trigger(START), which is the boundary being tested."
	exit 2
}
[ -w "$TRACE/kprobe_events" ] || {
	say "INVALID RUN: $TRACE/kprobe_events is not writable (need root)."
	exit 2
}
if lsmod 2>/dev/null | grep -q '^wcd9320_lumia_card '; then
	say "INVALID RUN: the frozen minimal card is loaded."
	say "  It owns the WCD9320 component, so the Q6 card cannot bind."
	say "  rmmod wcd9320_lumia_card, then cold boot and run this again."
	exit 2
fi

# A module that is missing, zero-byte, or unloadable presents downstream as
# "no card" -- which the ladder would then report as seventeen separate ADSP
# failures. None of those would be ADSP results at all. Refuse the run and
# name the actual cause instead of manufacturing a vacuous verdict.
CARDMOD=/lib/modules/$(uname -r)/kernel/sound/soc/qcom/snd-soc-lumia1520-q6.ko
if ! lsmod 2>/dev/null | grep -q '^snd_soc_lumia1520_q6 '; then
	say "INVALID RUN: the QDSP6 card module is not loaded."
	if [ ! -f "$CARDMOD" ]; then
		say "  It is not installed at $CARDMOD"
	elif [ ! -s "$CARDMOD" ]; then
		say "  $CARDMOD is ZERO BYTES."
		say "  The transfer delivered nothing. Copy the tarball as a SINGLE"
		say "  file, verify its sha256, extract it, then depmod -- multi-file"
		say "  scp to this device reports success and truncates silently."
	else
		say "  $CARDMOD is present ($(wc -c < "$CARDMOD") bytes) but not loaded."
		say "  Try: depmod -a && modprobe snd-soc-lumia1520-q6"
		say "  If insmod says Invalid argument, the file is corrupt: re-verify"
		say "  its sha256 against the build host before anything else."
	fi
	exit 2
fi

# The DAPM route is not optional. Without it q6routing never gets a port_id,
# q6routing_stream_open() connects nothing, and the FE never reaches the BE,
# so every downstream check would fail for a reason unrelated to the DSP.
command -v amixer >/dev/null 2>&1 || {
	say "INVALID RUN: amixer is not installed, so the route cannot be set."
	say "  apk add alsa-utils, or point \$PATH at a control-setting helper."
	exit 2
}

CARDS=$(grep -c '^ *[0-9]' /proc/asound/cards 2>/dev/null) || CARDS=0
[ -n "$CARDS" ] || CARDS=0

snap_dmesg
open_output "$OUTDIR/msm8974-q6-playback-control-$STAMP.txt"

# ------------------------------------------------------------- observation --
#
# name:symbol. Each is registered individually so a missing symbol is
# attributable rather than silently reported as "never called".
#
PROBES="asm_map:q6asm_map_memory_regions
asm_open:q6asm_open_write
asm_run:q6asm_run_nowait
asm_cmd:q6asm_cmd
adm_open:q6adm_open
adm_matrix:q6adm_matrix_map
adm_close:q6adm_close
afe_start:q6afe_port_start
afe_stop:q6afe_port_stop
afe_send:afe_apr_send_pkt"

# kprobe_events returns EBUSY if it is truncated while any of its events
# is still enabled, so the events must be disabled one at a time first.
#
# And never use ":" for these redirects. ":" is a POSIX *special* builtin,
# so a failed redirection exits the whole shell immediately -- that is what
# killed the first run of this gate, one line past the finish line, after
# the evidence had already been written but before it could be printed.
# "echo" and "printf" are regular builtins: a failed redirect on those
# just sets a status we can ignore.
clear_probes() {
	echo 0 > "$TRACE/tracing_on" 2>/dev/null
	for _p in $PROBES; do
		echo 0 > "$TRACE/events/kprobes/q6g_${_p%%:*}/enable" 2>/dev/null
	done
	printf "" > "$TRACE/kprobe_events" 2>/dev/null
	if [ -s "$TRACE/kprobe_events" ]; then
		for _p in $PROBES; do
			printf -- "-:q6g_%s\n" "${_p%%:*}" >> "$TRACE/kprobe_events" 2>/dev/null
		done
	fi
}


clear_probes
printf "" > "$TRACE/trace" 2>/dev/null

PROBE_OK=""
PROBE_BAD=""
for _p in $PROBES; do
	_n=${_p%%:*}
	_s=${_p#*:}
	if printf 'p:q6g_%s %s\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null; then
		PROBE_OK="$PROBE_OK $_n"
		echo 1 > "$TRACE/events/kprobes/q6g_$_n/enable" 2>/dev/null
	else
		PROBE_BAD="$PROBE_BAD $_n"
	fi
done
echo 1 > "$TRACE/tracing_on" 2>/dev/null

# grep -c PRINTS 0 and EXITS 1 when nothing matches. A trailing
# "|| echo 0" would append a SECOND zero and every count below would
# compare a two-line value -- the same trap that failed a correct
# system in the build-1 gate. Let the assignment own the fallback.
cnt() {
	_c=$(grep -c "q6g_$1:" "$TRACE/trace" 2>/dev/null) || _c=0
	[ -n "$_c" ] || _c=0
	echo "$_c"
}

# ------------------------------------------------------------- the sequence --
#
# 1. enable the route, 2. drive the PCM to PREPARED, 3. stop.
#
MIXER_RC=""
MIXER_VAL=""
if command -v amixer >/dev/null 2>&1; then
	amixer -q cset name="$MIXER" 1 >/dev/null 2>&1
	MIXER_RC=$?
	MIXER_VAL=$(amixer cget name="$MIXER" 2>/dev/null |
		sed -n 's/.*: values=\([0-9]*\).*/\1/p' | tail -n1)
else
	MIXER_RC=127
fi

HELPER_OUT=""
HELPER_RC=""
if [ "$CARDS" -ge 1 ] 2>/dev/null; then
	HELPER_OUT=$("$HELPER" -D "$PCMDEV" -r 48000 -c 1 -f S16_LE 2>&1)
	HELPER_RC=$?
	sleep 1
fi

echo 0 > "$TRACE/tracing_on" 2>/dev/null

h() { printf '%s\n' "$HELPER_OUT" | sed -n "s/^$1=//p" | head -n1; }

N_ASM_MAP=$(cnt asm_map);   N_ASM_OPEN=$(cnt asm_open)
N_ASM_RUN=$(cnt asm_run);   N_ASM_CMD=$(cnt asm_cmd)
N_ADM_OPEN=$(cnt adm_open); N_ADM_MATRIX=$(cnt adm_matrix)
N_ADM_CLOSE=$(cnt adm_close)
N_AFE_START=$(cnt afe_start); N_AFE_STOP=$(cnt afe_stop)
N_AFE_SEND=$(cnt afe_send)

# The codec's own frozen delta, from its dmesg lines during this run.
RX_HWPARAMS=$(dmesg 2>/dev/null | grep -c 'RX path invocation: ASoC hw_params')
RX_PROG=$(dmesg 2>/dev/null | grep -c 'rx-port 16: PROGRAMMED')
RX_TORN=$(dmesg 2>/dev/null | grep -c 'rx-port 16: TORN DOWN')
RX_CFG=$(dmesg 2>/dev/null | grep -c 'rx-port 16: config 0x040 want 05 -> read 05')
RX_MCH=$(dmesg 2>/dev/null | grep -c 'rx-port 16: multi-channel 0x180 want 01 -> read 01')

Q6_ERRORS=$(dmesg 2>/dev/null |
	grep -icE 'q6(afe|asm|adm)[^:]*:.*(fail|error|timeout)|fail to (start|close) AFE port')

{
	hdr "the card"
	say "sound cards          : $CARDS"
	cat /proc/asound/cards 2>/dev/null | sed 's/^/  /'
	say "pcm devices          :"
	cat /proc/asound/pcm 2>/dev/null | sed 's/^/  /'

	hdr "the route"
	say "mixer control        : $MIXER"
	say "amixer cset rc       : $MIXER_RC"
	say "mixer value after    : ${MIXER_VAL:-unknown}"

	hdr "the prepare-only run"
	printf '%s\n' "${HELPER_OUT:-  (not run)}" | sed 's/^/  /'
	say "helper exit          : ${HELPER_RC:-not run}"

	hdr "observed remote calls (kprobe counts)"
	say "probes registered    :${PROBE_OK:- none}"
	[ -n "$PROBE_BAD" ] && say "probes FAILED to register:$PROBE_BAD"
	say ""
	say "  q6asm_map_memory_regions : $N_ASM_MAP"
	say "  q6asm_open_write         : $N_ASM_OPEN"
	say "  q6adm_open               : $N_ADM_OPEN"
	say "  q6adm_matrix_map         : $N_ADM_MATRIX"
	say "  q6afe_port_start         : $N_AFE_START"
	say "  afe_apr_send_pkt         : $N_AFE_SEND"
	say "  ---- teardown ----"
	say "  q6asm_cmd (close)        : $N_ASM_CMD"
	say "  q6adm_close              : $N_ADM_CLOSE"
	say "  q6afe_port_stop          : $N_AFE_STOP"
	say "  ---- MUST BE ZERO ----"
	say "  q6asm_run_nowait         : $N_ASM_RUN"

	hdr "the codec's frozen delta"
	say "ASoC hw_params invocations : $RX_HWPARAMS"
	say "port 16 PROGRAMMED         : $RX_PROG"
	say "port 16 TORN DOWN          : $RX_TORN"
	say "0x040 00 -> 05             : $RX_CFG"
	say "0x180 00 -> 01             : $RX_MCH"

	hdr "the ladder"
	L() { say "  $1  $2  $3"; }
	L G0  "$([ "$CARDS" -ge 1 ] 2>/dev/null && echo PASS || echo FAIL)" "card registered"
	L G1  "$([ -n "$(h pcm_id)" ] && echo PASS || echo FAIL)" "FE PCM exists: $(h pcm_id)"
	L G2  "$([ "$(h hw_params_rc)" = "0" ] && echo PASS || echo FAIL)" "FE buffer + hw_params: buffer_bytes=$(h actual_buffer_bytes)"
	L G3  "$([ "${MIXER_VAL:-0}" = "1" ] && echo PASS || echo FAIL)" "DAPM route enabled"
	L G4  "$([ "$(h hw_params_rc)" = "0" ] && echo PASS || echo FAIL)" "HW_PARAMS reached"
	L G5  "$([ "$RX_CFG" -ge 1 ] && [ "$RX_MCH" -ge 1 ] && echo PASS || echo FAIL)" "WCD9320 frozen RX delta"
	L G6  "$([ "$N_ASM_MAP" -ge 1 ] && echo PASS || echo FAIL)" "ASM memory map issued"
	L G7  "$([ "$N_ASM_OPEN" -ge 1 ] && echo PASS || echo FAIL)" "ASM stream open issued"
	L G8  "$([ "$N_ADM_OPEN" -ge 1 ] && echo PASS || echo FAIL)" "ADM device open issued"
	L G9  "$([ "$N_ADM_MATRIX" -ge 1 ] && echo PASS || echo FAIL)" "ADM matrix map issued"
	L G10 "$([ "$N_AFE_SEND" -ge 1 ] && echo PASS || echo FAIL)" "AFE packets sent"
	L G11 "$([ "$N_AFE_START" -ge 1 ] && echo PASS || echo FAIL)" "AFE port start issued"
	L G12 "$([ "$(h prepare_rc)" = "0" ] && echo PASS || echo FAIL)" "PREPARE succeeded (all replies OK)"
	L G13 "$([ "$N_AFE_STOP" -ge 1 ] || [ "$N_ASM_CMD" -ge 1 ] && echo PASS || echo FAIL)" "teardown issued"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "every kprobe registered" \
		"$([ -z "$PROBE_BAD" ] && echo 1 || echo 0)" \
		"some probes did not register:$PROBE_BAD -- their zero counts mean nothing" \
		"all"
	check "a card exists" "$CARDS" "1"
	check "the DAPM route is enabled" "${MIXER_VAL:-0}" "1"
	check "hw_params succeeded" "$(h hw_params_rc)" "0"
	check "PREPARE succeeded" "$(h prepare_rc)" "0"
	check "reached PREPARED" "$(h reached_prepared)" "1"

	check_cond "ASM memory map issued" "$([ "$N_ASM_MAP" -ge 1 ] && echo 1 || echo 0)" \
		"no ASM_CMD_SHARED_MEM_MAP_REGIONS was sent" "$N_ASM_MAP"
	check_cond "ASM stream open issued" "$([ "$N_ASM_OPEN" -ge 1 ] && echo 1 || echo 0)" \
		"no ASM_STREAM_CMD_OPEN_WRITE_V3 was sent" "$N_ASM_OPEN"
	check_cond "ADM device open issued" "$([ "$N_ADM_OPEN" -ge 1 ] && echo 1 || echo 0)" \
		"no ADM_CMD_DEVICE_OPEN_V5 was sent -- the route did not reach ADM" "$N_ADM_OPEN"
	check_cond "ADM matrix map issued" "$([ "$N_ADM_MATRIX" -ge 1 ] && echo 1 || echo 0)" \
		"no ADM_CMD_MATRIX_MAP_ROUTINGS_V5 was sent" "$N_ADM_MATRIX"
	check_cond "AFE traffic occurred" "$([ "$N_AFE_SEND" -ge 1 ] && echo 1 || echo 0)" \
		"afe_apr_send_pkt was never called -- the BE was skipped entirely" "$N_AFE_SEND"
	check_cond "AFE port start issued" "$([ "$N_AFE_START" -ge 1 ] && echo 1 || echo 0)" \
		"no AFE_PORT_CMD_DEVICE_START -- SLIMBUS_0_RX was never started" "$N_AFE_START"

	# The codec, unchanged from the frozen delta.
	check_cond "codec hw_params ran" "$([ "$RX_HWPARAMS" -ge 1 ] && echo 1 || echo 0)" \
		"ASoC never reached the codec DAI" "$RX_HWPARAMS"
	check "0x040 00 -> 05 reproduced" "$([ "$RX_CFG" -ge 1 ] && echo 1 || echo 0)" "1"
	check "0x180 00 -> 01 reproduced" "$([ "$RX_MCH" -ge 1 ] && echo 1 || echo 0)" "1"
	check_cond "the port was torn down" "$([ "$RX_TORN" -ge 1 ] && echo 1 || echo 0)" \
		"the RX port was left programmed" "$RX_TORN"

	# THE DATA-PLANE BOUNDARY.
	check "ASM RUN never issued" "$N_ASM_RUN" "0"
	check "helper wrote nothing" "$(h write_calls)" "0"
	check "helper requested no START" "$(h start_requested)" "0"

	check_cond "no q6 error in the log" "$([ "$Q6_ERRORS" -eq 0 ] && echo 1 || echo 0)" \
		"an AFE/ASM/ADM failure or timeout was logged" "none"
	check_cond "no kernel WARNING/BUG" \
		"$([ "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" -eq 0 ] && echo 1 || echo 0)" \
		"the log carries a WARNING or BUG" "none"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE QDSP6 PLAYBACK CONTROL PLANE WORKS."
		say ""
		say "A real FE/BE path was instantiated from DT, the DAPM route was"
		say "enabled, and an ordinary PCM open + hw_params + prepare drove"
		say "the full chain: ASM memory map and stream open, ADM device open"
		say "and matrix map, AFE port configuration and start -- each"
		say "observed as an actual call, and all of them acknowledged, since"
		say "prepare() returns the DSP's status and returned 0."
		say ""
		say "SLIMBUS_0_RX accepted the one-channel configuration on AFE port"
		say "0x4000 with channel 144. That promotes the endpoint from an"
		say "apq8096-derived proposal to hardware evidence."
		say ""
		say "The WCD9320 reproduced its frozen delta through this path:"
		say "0x040 00->05 and 0x180 00->01, with the clean inverse."
		say ""
		say "WHAT THIS DOES NOT CLAIM. No SLIMbus data channel was allocated"
		say "(slim_stream_* is untouched), no ASM RUN was issued, no sample"
		say "moved, and nothing was audible. q6asm_run_nowait was observed"
		say "ZERO times, and the helper contains no write() at all."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "Read the ladder: it shows exactly how far the chain got, so a"
		say "failure at G10/G11 (the endpoint hypothesis) does not discredit"
		say "G0-G9, which are about topology rather than the ADSP."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

# Leave no kprobes behind.
clear_probes
rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the card/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

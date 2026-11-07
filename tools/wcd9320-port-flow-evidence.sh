#!/bin/sh
#
# r177: does the codec CONSUME the samples that reach its SLIMbus RX port?
#
# Design, predictions and the meaning of every outcome are frozen in
# docs/audio/wcd9320-rx-port-flow-mapping.md, written before this file.
#
# THE OBSERVABLE
#
# RX port 16's status bit (interface 0x034 bit 0) and its source register
# (interface 0x060: bit 0 OVERFLOW, bit 1 UNDERFLOW, bit 2 PORT_CLOSED). They
# latch with every interrupt enable at 00, so the driver's slim_port_status
# polls them and "clear" writes the one clear register. Nothing else changes.
#
# SIX ROWS, ONE COLD BOOT, PA NEVER ENABLED
#
#   A   data, RX path off
#   B0  no data, RX path off      (stream-on with no PCM: channel up, AFE idle)
#   B   no data, RX path on
#   C   data, RX path on
#   D   data, RX path on, forced 0x314 = 03
#   E   data, the full C3a analog prep minus the PA write
#
# A data row starts pcm-run-measured for $SECS s, waits $SETTLE s for steady
# state, clears port 16, reads straight away (s0), waits $WATCH s and reads
# again (s1). The answer is s1, from the steady window, which contains neither
# start nor stop. A no-data row brings the stream up with slim_stream_test.
#
# WHAT IS GRADED, AND WHAT IS NOT
#
# PASS/FAIL checks are about the run being valid and safe: the module version,
# the clear working, the stream really up during the window, the helper
# really consuming, the PA masked to 00 at every sample, and every row torn
# back down. The port-16 observations are the RESULT and are reported, not
# graded -- this gate cannot know the answer in advance, only whether the
# question was asked properly. The outcome (1-5 in the mapping) is printed
# with the table.
#
# The headset must be UNPLUGGED. Nothing here enables the PA, the driver's
# guard refuses it outside the mapped PA step, and this gate checks 0x1ab at
# every sample anyway.
#
# Usage:   sudo sh wcd9320-port-flow-evidence.sh
# Exit:    0 valid run, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-port-flow"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
SECS="${SECS:-6}"
SETTLE="${SETTLE:-2}"
WATCH="${WATCH:-2}"
# forced entries this run issues: D = 0x314 on/off, E = 0x314 on/off + 0x30d on/off
FORCED_THIS_RUN=6
PA_MASK=30

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

PS="$PGD/slim_port_status"
SST="$PGD/slim_stream_test"
SSS="$PGD/slim_stream_state"
STR="$PGD/slim_transport"
RX1T="$PGD/rx1_digital_test"
RX1S="$PGD/rx1_digital_state"
PREREQ="$PGD/cdc_clk_prereq"
DACT="$PGD/hphl_dac_test"
DACS="$PGD/hphl_dac_state"
PAT="$PGD/hphl_pa_test"
PAS="$PGD/hphl_pa_state"
FLOG="$PGD/forced_log"

for f in "$PS" "$SST" "$SSS" "$STR" "$RX1T" "$RX1S" "$PREREQ" "$DACT" \
	 "$DACS" "$PAT" "$PAS" "$FLOG"; do
	[ -e "$f" ] || {
		say "INVALID RUN: $f does not exist."
		say "  The running codec must be port-flow-rc1 or later."
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
[ "$(id -u)" = "0" ] || { say "INVALID RUN: need root."; exit 2; }
grep -q '^ *0 ' /proc/asound/cards 2>/dev/null || {
	say "INVALID RUN: no sound card."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
pss() { cat "$PS" 2>/dev/null; }

# pa_masked -- 0x1ab & 0x30 from the chip, or READ-FAILED
pa_masked() {
	_pm=$(rv "$(cat "$PAS" 2>/dev/null)" pa_0x1ab)
	[ -n "$_pm" ] || { echo "READ-FAILED"; return; }
	printf '%02x' $(( 0x$_pm & 0x$PA_MASK ))
}
PA_SAMPLES=""
pa_sample() { PA_SAMPLES="$PA_SAMPLES $1:$(pa_masked)"; }

# ------------------------------------------------------------ preconditions --
BAD=""
PRE_PS=$(pss)
PRE_SSS=$(cat "$SSS" 2>/dev/null)
PRE_PA=$(cat "$PAS" 2>/dev/null)
[ "$(rv "$PRE_PS" read_rc)" = "0" ]       || BAD="$BAD port_status_unreadable"
[ "$(rv "$PRE_PS" clears)" = "0" ]        || BAD="$BAD already_cleared_this_boot"
[ "$(rv "$PRE_SSS" up)" = "0" ]           || BAD="$BAD stream_up"
[ "$(rv "$(cat "$RX1S")" on)" = "0" ]     || BAD="$BAD rx1_on"
[ "$(rv "$(cat "$DACS")" on)" = "0" ]     || BAD="$BAD dac_on"
[ "$(rv "$PRE_PA" pa_on)" = "0" ]         || BAD="$BAD pa_on"
[ "$(rv "$PRE_PA" prep_on)" = "0" ]       || BAD="$BAD prep_on"
[ "$(pa_masked)" = "00" ]                 || BAD="$BAD PA_ALREADY_ON=$(pa_masked)"
[ "$(rv "$(cat "$STR")" transport)" = "on" ] || BAD="$BAD transport_off"
FORCED_START=$(rv "$(cat "$FLOG" 2>/dev/null)" forced_n)
FORCED_RING=$(sed -n 's/.*ring=\([0-9]*\).*/\1/p' "$FLOG" 2>/dev/null | head -n1)
FORCED_START=${FORCED_START:-99}
FORCED_RING=${FORCED_RING:-16}
[ $(( FORCED_START + FORCED_THIS_RUN )) -le "$FORCED_RING" ] ||
	BAD="$BAD forced_journal_full=$FORCED_START/$FORCED_RING"

if [ -n "$BAD" ]; then
	say "INVALID RUN: the starting state is not clean:$BAD"
	say "  Cold boot (power cycle) and run this once, first thing."
	exit 2
fi

open_output "$OUTDIR/wcd9320-port-flow-$STAMP.txt"

# --------------------------------------------------------- emergency cleanup --
#
# Idempotent and best-effort, in the C3a runner's teardown order. The PA is
# never enabled here; "abort" is included anyway because it is the one
# driver-side operation that is safe from any state.
cleanup() {
	echo dac-off-reggain > "$DACT" 2>/dev/null
	echo off > "$PREREQ" 2>/dev/null
	echo rx1-off > "$RX1T" 2>/dev/null
	echo unprep > "$PAT" 2>/dev/null
	echo stream-off > "$SST" 2>/dev/null
	true
}
on_signal() { cleanup; echo abort > "$PAT" 2>/dev/null; exit 2; }
trap on_signal INT TERM HUP

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
MIXER_RC=$?

# ------------------------------------------------------------------ one row --
#
# row <id> <data:0|1> <setup words...>
#
# Setup words, applied in order, undone in reverse C3a order afterwards:
#   prep  -> hphl_pa_test prep          (C3a gain + pop/click, PA stays off)
#   clk   -> cdc_clk_prereq on          (forced 0x314 = 03)
#   rx1   -> rx1_digital_test rx1-on
#   dac   -> hphl_dac_test dac-on-reggain
#
# Results land in R_<id>_<field> variables for the report.
ROWS=""
row() {
	_id=$1; _data=$2; shift 2
	ROWS="$ROWS $_id"
	eval "R_${_id}_DATA=$_data"
	eval "R_${_id}_SETUP=\"\$*\""
	_rc_setup=0

	# idle clear: proves the clear works before the row relies on it, and
	# wipes the PORT_CLOSED the previous row's teardown latched
	echo clear > "$PS" 2>/dev/null; _c=$?
	_st=$(pss)
	eval "R_${_id}_IDLE_RC=$_c"
	eval "R_${_id}_IDLE_PEND=$(rv "$_st" pending)"
	eval "R_${_id}_IDLE_SRC=$(rv "$_st" src)"
	# Graded on OVERFLOW/UNDERFLOW only. MEASURED at r177: PORT_CLOSED can
	# latch again a few ms AFTER the clear, from the previous row's stream
	# teardown completing late on the bus -- the driver's own readback
	# inside the clear said 00 while this read, moments later, saw 04.
	_isrc=$(rv "$_st" src)
	# an empty read becomes ff, which fails the check rather than the shell
	_ou=$(( 0x${_isrc:-ff} & 0x03 ))
	eval "R_${_id}_IDLE_OU=$_ou"
	pa_sample "$_id-idle"

	for _w in "$@"; do
		case "$_w" in
		prep) echo prep > "$PAT" 2>/dev/null ;;
		clk)  echo on > "$PREREQ" 2>/dev/null ;;
		rx1)  echo rx1-on > "$RX1T" 2>/dev/null ;;
		dac)  echo dac-on-reggain > "$DACT" 2>/dev/null ;;
		esac
		[ $? -eq 0 ] || _rc_setup=1
		pa_sample "$_id-$_w"
	done
	eval "R_${_id}_SETUP_RC=$_rc_setup"

	_out="/tmp/.port-flow-$_id-$$"
	if [ "$_data" = "1" ]; then
		"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p 960 -n 4 -t "$SECS" \
			> "$_out" 2>&1 &
		_pid=$!
	else
		echo stream-on > "$SST" 2>/dev/null
		eval "R_${_id}_STREAMON_RC=$?"
		_pid=""
	fi

	sleep "$SETTLE"
	eval "R_${_id}_UP0=$(rv "$(cat "$SSS")" up)"
	echo clear > "$PS" 2>/dev/null; _c=$?
	_s0=$(pss)
	eval "R_${_id}_CLR_RC=$_c"
	pa_sample "$_id-s0"
	sleep "$WATCH"
	_s1=$(pss)
	eval "R_${_id}_UP1=$(rv "$(cat "$SSS")" up)"
	pa_sample "$_id-s1"

	for _k in pending src overflow underflow closed read_rc; do
		eval "R_${_id}_S0_$_k=$(rv "$_s0" $_k)"
		eval "R_${_id}_S1_$_k=$(rv "$_s1" $_k)"
	done

	if [ -n "$_pid" ]; then
		wait "$_pid"
		eval "R_${_id}_RUN_RC=$?"
		for _k in start_rc saw_running hw_ptr_advance xruns final_rc; do
			eval "R_${_id}_$_k=$(sed -n "s/^$_k=//p" "$_out" | head -n1)"
		done
	else
		echo stream-off > "$SST" 2>/dev/null
		eval "R_${_id}_STREAMOFF_RC=$?"
	fi
	rm -f "$_out"

	# Teardown in the C3a order, and ONLY of what this row set up. dac-off is
	# not a no-op when the DAC was never on: it runs the whole best-effort
	# teardown, including the forced 0x30d inverse, which would put an entry
	# in the forced journal for every row.
	case " $* " in *" dac "*) echo dac-off-reggain > "$DACT" 2>/dev/null ;; esac
	case " $* " in *" clk "*) echo off > "$PREREQ" 2>/dev/null ;; esac
	case " $* " in *" rx1 "*) echo rx1-off > "$RX1T" 2>/dev/null ;; esac
	case " $* " in *" prep "*) echo unprep > "$PAT" 2>/dev/null ;; esac
	pa_sample "$_id-down"

	eval "R_${_id}_DOWN_UP=$(rv "$(cat "$SSS")" up)"
	eval "R_${_id}_DOWN_RX1=$(rv "$(cat "$RX1S")" on)"
	eval "R_${_id}_DOWN_DAC=$(rv "$(cat "$DACS")" on)"
	eval "R_${_id}_DOWN_PREP=$(rv "$(cat "$PAS")" prep_on)"
}

row A  1
row B0 0
row B  0 rx1
row C  1 rx1
row D  1 clk rx1
row E  1 prep clk rx1 dac

trap - INT TERM HUP
FLOG_POST=$(cat "$FLOG" 2>/dev/null)
POST_PS=$(pss)

# ------------------------------------------------------------------- report --
{
	say "WCD9320 r177 port-flow evidence"
	say "mode              : $MODE"
	say "stamp             : $STAMP"
	say "module            : $RUNNING_VERSION (expect $EXPECT_VERSION, $EXPECT_SOURCE)"
	say "control function  : $PGD_NAME"
	say "interface function: $IFD_NAME"
	say "runner            : $RUNNER -t $SECS, settle $SETTLE s, watch $WATCH s"
	say "design            : docs/audio/wcd9320-rx-port-flow-mapping.md"
	say ""
	say "port 16 at the start of the run (before any clear):"
	say "  $PRE_PS"

	hdr "validity and safety (graded)"
	check "mixer route set" "$MIXER_RC" "0"
	check "forced journal: this run's entries" \
	      "$(( $(rv "$FLOG_POST" forced_n) - FORCED_START ))" "$FORCED_THIS_RUN"
	PA_BAD=$(printf '%s' "$PA_SAMPLES" | tr ' ' '\n' | grep -v ':00$' | grep -c ':' || true)
	check "PA masked 00 at every sample" "${PA_BAD:-0}" "0"
	for _id in $ROWS; do
		eval "_d=\$R_${_id}_DATA"
		say ""
		say "-- row $_id --"
		eval "check \"$_id idle clear rc\"        \"\$R_${_id}_IDLE_RC\" 0"
		eval "check \"$_id idle: no over/underflow\" \"\$R_${_id}_IDLE_OU\" 0"
		eval "check \"$_id setup\"                \"\$R_${_id}_SETUP_RC\" 0"
		eval "check \"$_id stream up at s0\"      \"\$R_${_id}_UP0\" 1"
		eval "check \"$_id stream up at s1\"      \"\$R_${_id}_UP1\" 1"
		eval "check \"$_id window clear rc\"      \"\$R_${_id}_CLR_RC\" 0"
		eval "check \"$_id s1 read rc\"           \"\$R_${_id}_S1_read_rc\" 0"
		if [ "$_d" = "1" ]; then
			eval "check \"$_id helper start\"     \"\$R_${_id}_start_rc\" 0"
			eval "check \"$_id helper ran\"       \"\$R_${_id}_saw_running\" 1"
			eval "check \"$_id helper final\"     \"\$R_${_id}_final_rc\" 0"
			eval "_adv=\${R_${_id}_hw_ptr_advance:-0}"
			check_cond "$_id DSP consumed frames" \
				"$([ "$_adv" -gt 0 ] 2>/dev/null && echo 1 || echo 0)" \
				"hw_ptr_advance=$_adv" "hw_ptr_advance=$_adv"
		else
			eval "check \"$_id stream-on rc\"     \"\$R_${_id}_STREAMON_RC\" 0"
			eval "check \"$_id stream-off rc\"    \"\$R_${_id}_STREAMOFF_RC\" 0"
		fi
		eval "check \"$_id torn down: stream\" \"\$R_${_id}_DOWN_UP\" 0"
		eval "check \"$_id torn down: rx1\"    \"\$R_${_id}_DOWN_RX1\" 0"
		eval "check \"$_id torn down: dac\"    \"\$R_${_id}_DOWN_DAC\" 0"
		eval "check \"$_id torn down: prep\"   \"\$R_${_id}_DOWN_PREP\" 0"
	done

	hdr "port 16 observations (the result -- reported, not graded)"
	say "row  data  setup               idle-src  s0:pend/src  s1:pend/src  s1 events"
	for _id in $ROWS; do
		eval "_d=\$R_${_id}_DATA; _su=\"\$R_${_id}_SETUP\"; _is=\$R_${_id}_IDLE_SRC"
		eval "_p0=\$R_${_id}_S0_pending; _r0=\$R_${_id}_S0_src"
		eval "_p1=\$R_${_id}_S1_pending; _r1=\$R_${_id}_S1_src"
		eval "_o=\$R_${_id}_S1_overflow; _u=\$R_${_id}_S1_underflow; _cl=\$R_${_id}_S1_closed"
		_ev=""
		[ "$_p1" = "1" ] && [ "$_o" = "1" ] && _ev="$_ev OVERFLOW"
		[ "$_p1" = "1" ] && [ "$_u" = "1" ] && _ev="$_ev UNDERFLOW"
		[ "$_p1" = "1" ] && [ "$_cl" = "1" ] && _ev="$_ev CLOSED"
		[ -n "$_ev" ] || _ev=" clean"
		printf '%-4s %-5s %-19s %-9s %s/%-10s %s/%-10s%s\n' \
			"$_id" "$_d" "${_su:-(none)}" "$_is" "$_p0" "$_r0" "$_p1" "$_r1" "$_ev"
		eval "OBS_$_id=\"\$_ev\""
	done

	# ---- the outcome, keyed to the mapping's frozen list ----
	ovf() { eval "case \"\$OBS_$1\" in *OVERFLOW*) echo 1 ;; *) echo 0 ;; esac"; }
	S0BAD=""
	for _id in $ROWS; do
		eval "[ \"\$R_${_id}_S0_pending\" = 1 ] && [ \"\$R_${_id}_S1_pending\" = 1 ] && S0BAD=\"\$S0BAD $_id\""
	done
	say ""
	if [ "$(ovf A)" = "0" ]; then
		OUTCOME="4: A is clean -- OVERFLOW does not mean what the mapping assumes, or the bytes never arrive. INCONCLUSIVE about consumption."
	elif [ "$(ovf C)$(ovf D)$(ovf E)" = "111" ]; then
		OUTCOME="1: A overflows and C, D, E all overflow -- bytes reach the codec and the RX path never reads them. The silence is upstream of the DAC."
	elif [ "$(ovf C)" = "0" ] || [ "$(ovf D)" = "0" ]; then
		if [ "$(ovf E)" = "1" ]; then
			OUTCOME="3: consumption works in C/D and fails under the full prep (E) -- bisect the prep."
		else
			OUTCOME="2: A overflows, C/D clean -- consumption works (C vs D says whether 0x314 matters). The silence is downstream of the interpolator."
		fi
	else
		OUTCOME="unclassified -- read the table"
	fi
	say "OUTCOME $OUTCOME"
	say "CAUTION one steady window per row. MEASURED at r177: with RX1 on, a"
	say "  stream is either clean throughout or overflowing throughout, and"
	say "  which one is not decided by 0x314 (6 clean of 15). A single window"
	say "  cannot tell a cause from that coin flip -- repeat before concluding."
	if [ -n "$S0BAD" ]; then
		say "NOTE rows with s0 AND s1 pending:$S0BAD -- the condition re-latched within the read latency (it is continuous) or the window clear did not take. The idle clear check above says which."
	fi
	say ""
	say "port 16 at the end of the run: $POST_PS"
	say ""
	say "PA samples:$PA_SAMPLES"
	say ""
	say "-- forced journal --"
	printf '%s\n' "$FLOG_POST"
	say ""
	say "-- dmesg, port-status and stream lines --"
	dmesg 2>/dev/null | grep -E 'port-status|slim-stream: (UP|DOWN)|PA GUARD|WARNING|BUG' | tail -n 60

	emit_verdict
} > "$OUT" 2>&1
RC=$?
cat "$OUT"
say ""
say "evidence: $OUT"
exit $RC

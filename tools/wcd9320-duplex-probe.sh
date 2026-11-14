#!/bin/sh
#
# DUPLEX PROBE: the mic records while an output plays.
# docs/audio/wcd9320-duplex-mapping.md, sections 6-8.
#
# OUTPUT=i2s (probe 0, r200): the loudspeaker -- the card's own I2S output
#   (SEC_MI2S -> TAS2552), which holds nothing in the codec. Speakerphone.
# OUTPUT=hph (r201): the headphones -- a codec output. Both paths share the
#   codec's MCLK (counted, r182) and the 0x314 prereq (owners, r201): live,
#   mclk_users is 2 and the prereq owners are 3 (output | capture).
#
# ORDER=cap-first: capture comes up, then the output plays PLAYS stimuli
#   (1 s apart); the driver counts the output starting beside capture.
# ORDER=out-first: the output starts, and capture comes up while it plays
#   (PLAYS stimuli back to back); the driver counts capture starting beside
#   the output.
#
# The capture runner records in the background with DUPLEX=1 (its checks
# accept exactly one output beside it); this runner checks both paths live
# at once, the driver's duplex counters, no refusals, everything down after
# and every control as found.
#
# SAFETY: -60, -50 or -40 dBFS only -- no escalation path here. HPH_VOL is the
# HPHL/HPHR Volume (0..20, the r186 runs used 20 at -40 dBFS), RX1/RX2 at
# 0 dB digital. A transient systemd timer runs wcd9320-dapm-teardown.sh
# (every pin off, the player killed, the VISA amplifier to standby, the C3
# abort -- which since r201 leaves capture's prereq alone) unless the run
# disarms it after the output is verified down; a signal does the same.
#
# Usage (as root on the phone):
# r202: WCD_TRACE=0 is the quiet check -- the codec's debug messages stay off
#   (the capture runner inherits it) and the run must add no codec lines to
#   the kernel log. By default they are switched on for the run and back after.
#
#   env EXPECT_VERSION=quietlog-rc1 OUTPUT=hph ORDER=cap-first CAP_DMIC=1 \
#       CAP_GAIN=114 DBFS=-50 HPH_VOL=20 sh wcd9320-duplex-probe.sh <tag>
# Output: /var/log/wcd9320-duplex-<stamp>-<tag>.txt, and the capture runner's
#         /var/log/wcd9320-capture-<stamp>-<tag>.{wav,txt}
# Exit: 0 PASS, 1 FAIL, 2 refused before anything changed, 3 aborted.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
PGD=/sys/bus/slimbus/devices/217:a0:1:0
CTLDEV=/dev/snd/controlC0
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
TAG="${1:-duplex}"
OUT="$OUTDIR/wcd9320-duplex-$STAMP-$TAG.txt"
CAPLOG="/tmp/wcd9320-duplex-$STAMP.capture"
EXPECT_VERSION="${EXPECT_VERSION:-quietlog-rc1}"
CARD_VERSION="${CARD_VERSION:-q6-card-rc12}"
OUTPUT="${OUTPUT:-i2s}"
ORDER="${ORDER:-cap-first}"
CAPN="${CAP_DMIC:-4}"
CAPG="${CAP_GAIN:-114}"			# +30 dB, the r199 level
CAPS="${CAP_SECONDS:-8}"
DBFS="${DBFS:--40}"
PLAYS="${PLAYS:-2}"
SPK_GAIN_RAW="${SPK_GAIN_RAW:-22}"	# Loudspeaker Volume, the r193 runs' level
HPH_VOL="${HPH_VOL:-20}"
HPH_DIG=84				# RX1/RX2 Digital Volume, 0 dB
PCMDEV_P="${PCMDEV_P:-/dev/snd/pcmC0D0p}"
FAILSAFE="${DUPLEX_FAILSAFE:-wcd9320-duplex-failsafe}"
FAILSAFE_S="${FAILSAFE_S:-30}"
TEARDOWN="$DIR/wcd9320-dapm-teardown.sh"
I2S_MIXER="SEC_MI2S_RX Audio Mixer MultiMedia1"
SLIM_MIXER="SLIMBUS_0_RX Audio Mixer MultiMedia1"

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl"; do [ -n "$c" ] && [ -x "$c" ] && { SETCTL=$c; break; }; done
TONE=""
for c in "${PCM_TONE:-}" "$DIR/pcm-tone"; do [ -n "$c" ] && [ -x "$c" ] && { TONE=$c; break; }; done
ctl_get() { "$SETCTL" -D "$CTLDEV" --get "$1" 2>/dev/null | sed -n 's/^readback=//p' | head -n1; }
ctl_set() { [ "$("$SETCTL" -D "$CTLDEV" --set "$1" "$2" 2>/dev/null | sed -n 's/^readback=//p' | head -n1)" = "$2" ]; }
i2s_state() { _f=$(ls /sys/bus/platform/drivers/lumia1520-i2s-spk/*/i2s_spk_state 2>/dev/null | head -n1); [ -n "$_f" ] && cat "$_f" 2>/dev/null; }
cap_state() { cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' '; }
up() { cut -d' ' -f1 /proc/uptime; }
held4() { printf '%s%s%s%s' "$(rv "$1" held)" "$(rv "$1" spk_held)" "$(rv "$1" ear_held)" "$(rv "$1" lo_held)"; }

PASS=0; FAIL=0
check() {	# check <name> <got> <want>
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  PASS  %-60s %s\n' "$1" "$2"
	else FAIL=$((FAIL + 1)); printf '  FAIL  %-60s %s (want %s)\n' "$1" "$2" "$3"; fi
}

# the output: its mixer, pin, volume controls and what "up" means
case "$OUTPUT" in
i2s)	MIXER="$I2S_MIXER"; OTHER_MIXER="$SLIM_MIXER"; OUT_PIN="Loudspeaker Switch"
	VOLS="Loudspeaker Volume"; VOLV="$SPK_GAIN_RAW" ;;
hph)	MIXER="$SLIM_MIXER"; OTHER_MIXER="$I2S_MIXER"; OUT_PIN="Headphones Switch"
	VOLS="HPHL Volume|HPHR Volume|RX1 Digital Volume|RX2 Digital Volume"
	VOLV="$HPH_VOL|$HPH_VOL|$HPH_DIG|$HPH_DIG" ;;
*)	echo "INVALID SETUP: OUTPUT=$OUTPUT (i2s or hph) -- nothing changed"; exit 2 ;;
esac
out_up() {	# out_up <dapm_state> -> 0 when the output's whole path is up
	if [ "$OUTPUT" = i2s ]; then
		_o=$(i2s_state)
		[ "$(rv "$_o" supply_on) $(rv "$_o" pins_active) $(rv "$_o" bclk_on)" = "1 1 1" ]
	else
		[ "$(rv "$1" held) $(rv "$1" pa_on) $(rv "$1" pa_r_on)" = "1ff 1 1" ]
	fi
}
out_down() {	# out_down <dapm_state> -> 0 when the output's path is down
	if [ "$OUTPUT" = i2s ]; then
		_o=$(i2s_state)
		[ "$(rv "$_o" supply_on) $(rv "$_o" bclk_on)" = "0 0" ]
	else
		[ "$(rv "$1" held) $(rv "$1" pa_on) $(rv "$1" pa_r_on)" = "000 0 0" ]
	fi
}

# ------------------------------------------------------------- preflight --
bad=""
case "$DBFS" in -60|-50|-40) ;; *) bad="$bad dbfs=$DBFS(-60/-50/-40-only)" ;; esac
case "$ORDER" in cap-first|out-first) ;; *) bad="$bad order=$ORDER" ;; esac
case "$PLAYS" in 1|2|3) ;; *) bad="$bad plays=$PLAYS" ;; esac
case "$CAPN" in 1|2|3|4) ;; *) bad="$bad cap-dmic=$CAPN" ;; esac
case "$CAPS" in ''|*[!0-9]*) bad="$bad seconds" ;; *) [ "$CAPS" -ge 4 ] && [ "$CAPS" -le 20 ] || bad="$bad seconds" ;; esac
case "$SPK_GAIN_RAW" in ''|*[!0-9]*) bad="$bad spk-gain" ;; *) [ "$SPK_GAIN_RAW" -le 22 ] || bad="$bad spk-gain" ;; esac
case "$HPH_VOL" in ''|*[!0-9]*) bad="$bad hph-vol" ;; *) [ "$HPH_VOL" -le 20 ] || bad="$bad hph-vol" ;; esac
[ -n "$SETCTL" ] || bad="$bad no-alsa-setctl"
[ -n "$TONE" ] || bad="$bad no-pcm-tone"
[ -x "$DIR/pcm-capture" ] || bad="$bad no-pcm-capture"
[ -f "$DIR/wcd9320-capture.sh" ] || bad="$bad no-capture-runner"
[ -f "$TEARDOWN" ] || bad="$bad no-teardown"
[ -e "$PCMDEV_P" ] || bad="$bad no-$PCMDEV_P"
CODECV=$(cat /sys/module/wcd9320/version 2>/dev/null)
CARDV=$(cat /sys/module/snd_soc_lumia1520_q6/version 2>/dev/null)
[ "$CODECV" = "$EXPECT_VERSION" ] || bad="$bad codec=$CODECV"
[ "$CARDV" = "$CARD_VERSION" ] || bad="$bad card=$CARDV"
DPRE=$(cat "$PGD/dapm_state" 2>/dev/null)
CPRE=$(cap_state)
IPRE=$(i2s_state)
[ "$(held4 "$DPRE")" = "000000000" ] || bad="$bad outputs-held"
[ "$(rv "$DPRE" mclk_users)" = "0" ] || bad="$bad mclk-users"
[ "$(rv "$CPRE" cap_held)" = "00" ] || bad="$bad capture-held"
[ -n "$(rv "$CPRE" prereq_owners)" ] || bad="$bad no-prereq-owners(not-r201)"
[ "$(rv "$CPRE" prereq_owners)" = "0" ] || bad="$bad prereq-owned"
[ -n "$IPRE" ] || bad="$bad no-i2s_spk_state"
[ "$(rv "$IPRE" supply_on) $(rv "$IPRE" bclk_on)" = "0 0" ] || bad="$bad i2s-up"
# r185: jack detection may hold the Headphones pin on; this run takes it
HP_PIN_PRE=$(ctl_get "Headphones Switch")
for _p in "Loudspeaker Switch" "Speaker Switch" "Earpiece Switch" "Lineout Switch" "Handset Mic Switch"; do
	[ "$(ctl_get "$_p")" = "0" ] || bad="$bad pin-on:$(printf '%s' "$_p" | tr ' ' '_')"
done
pgrep -x pcm-tone >/dev/null 2>&1 && bad="$bad pcm-tone-running"
pgrep -x pcm-capture >/dev/null 2>&1 && bad="$bad pcm-capture-running"
systemctl is-active --quiet "$FAILSAFE.timer" 2>/dev/null && bad="$bad failsafe-already-armed"
MIX_PRE=$(ctl_get "$MIXER"); OMIX_PRE=$(ctl_get "$OTHER_MIXER")
[ -n "$MIX_PRE" ] && [ -n "$OMIX_PRE" ] || bad="$bad mixers-missing"
VOL_PRE=""
_ifs=$IFS; IFS='|'
for _v in $VOLS; do
	_g=$(ctl_get "$_v"); [ -n "$_g" ] || bad="$bad no-control:$(printf '%s' "$_v" | tr ' ' '_')"
	VOL_PRE="$VOL_PRE${VOL_PRE:+|}$_g"
done
IFS=$_ifs
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

vols_set() {	# vols_set "<v1|v2|...>" -> 0 when every control read back
	_ok=0; _vals="$1"; _ifs=$IFS; IFS='|'
	set -- $_vals
	for _v in $VOLS; do
		ctl_set "$_v" "$1" || { echo "$_v did not read back $1"; _ok=1; }
		shift
	done
	IFS=$_ifs
	return $_ok
}
vols_get() { _r=""; _ifs=$IFS; IFS='|'; for _v in $VOLS; do _r="$_r${_r:+|}$(ctl_get "$_v")"; done; IFS=$_ifs; printf '%s' "$_r"; }

# ---------------------------------------------------------- the fail-safe --
failsafe_disarm() {
	systemctl stop "$FAILSAFE.timer" >/dev/null 2>&1
	systemctl stop "$FAILSAFE.service" >/dev/null 2>&1
	systemctl reset-failed "$FAILSAFE.service" >/dev/null 2>&1
	return 0
}
failsafe_arm() {
	failsafe_disarm
	systemd-run --unit="$FAILSAFE" --collect --on-active="$FAILSAFE_S" \
		sh "$TEARDOWN" "duplex-failsafe" >/dev/null 2>&1
}
# r202: the codec's normal-path messages are dev_dbg
[ -f "$DIR/wcd9320-trace-lib.sh" ] && . "$DIR/wcd9320-trace-lib.sh"
command -v wcd_trace_on >/dev/null 2>&1 && wcd_trace_on
# by TIMESTAMP, not line count: once the ring buffer is full a line-count
# delta goes negative as old lines scroll out (r187's lesson, r202's quiet run)
DMESG_T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
dmesg_since() {
	dmesg | awk -v t="${1:-0}" 'match($0, /^\[ *[0-9.]+\]/) {
		if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }'
}
ABORTED=0
CAPPID=""; TPID=""
dp_abort() {	# dp_abort <reason>
	[ "$ABORTED" = "1" ] && return 0
	ABORTED=1
	echo "ABORT: $1"
	[ -n "$TPID" ] && kill "$TPID" 2>/dev/null
	sh "$TEARDOWN" "duplex-$1" >/dev/null 2>&1
	failsafe_disarm
}
trap 'dp_abort signal; exit 3' INT TERM HUP

start_capture() {
	env EXPECT_VERSION="$EXPECT_VERSION" CARD_VERSION="$CARD_VERSION" CAP_DMIC="$CAPN" \
		CAP_GAIN="$CAPG" CAP_SECONDS="$CAPS" DUPLEX=1 \
		CAP_PERIOD="${CAP_PERIOD:-}" CAP_PERIODS="${CAP_PERIODS:-}" \
		sh "$DIR/wcd9320-capture.sh" "$TAG" > "$CAPLOG" 2>&1 &
	CAPPID=$!
}
wait_capture_up() {	# up to 6 s for all six stages, the stream and the HPF settle
	_w=0
	while [ "$_w" -lt 60 ]; do
		CUP=$(cap_state)
		[ "$(rv "$CUP" cap_held) $(rv "$CUP" tx_up) $(rv "$CUP" hpf_armed)" = "3f 1 0" ] && return 0
		kill -0 "$CAPPID" 2>/dev/null || return 1
		sleep 0.1
		_w=$((_w + 1))
	done
	return 1
}
sample_live() {
	DLIVE=$(cat "$PGD/dapm_state" 2>/dev/null)
	CLIVE=$(cap_state)
	ILIVE=$(i2s_state)
}
play_one() {	# play_one <n> -- in the background, TPID set
	echo "play $1: start at uptime $(up)"
	"$TONE" -D "$PCMDEV_P" --dbfs "$DBFS" --side B > "/tmp/wcd9320-duplex-$STAMP.tone$1" 2>&1 &
	TPID=$!
}
play_wait() {	# play_wait <n>
	wait "$TPID"; TONE_RCS="$TONE_RCS$?"; TPID=""
	echo "play $1: end at uptime $(up)"
}

# ------------------------------------------------------------------ run --
{
echo "================ wcd9320 duplex probe $STAMP ($TAG) ================"
echo "codec $CODECV, card $CARDV; output $OUTPUT, order $ORDER"
echo "capture: DMIC$CAPN at Capture Digital Volume $CAPG ($((CAPG - 84)) dB), $CAPS s"
echo "output: $VOLS = $VOLV; 1 kHz stimulus at $DBFS dBFS x $PLAYS"
echo "pre dapm: $DPRE"
echo "pre cap:  $CPRE"
echo "pre i2s:  $IPRE"
echo "Headphones pin as found: $HP_PIN_PRE (jack: $(cat "$PGD/jack_detect" 2>/dev/null | cut -c1-60))"
RUN_OK=1
TONE_RCS=""
DLIVE=""; CLIVE=""; ILIVE=""
DREF0=$(rv "$DPRE" refusals); CREF0=$(rv "$CPRE" refusals)
OBC0=$(rv "$CPRE" out_beside_cap); CBO0=$(rv "$CPRE" cap_beside_out)

ctl_set "Headphones Switch" 0 || { echo "the Headphones pin would not go off"; RUN_OK=0; }
[ "$RUN_OK" = 1 ] && { ctl_set "$OTHER_MIXER" 0 || { echo "$OTHER_MIXER would not go off"; RUN_OK=0; }; }
[ "$RUN_OK" = 1 ] && { ctl_set "$MIXER" 1 || { echo "$MIXER would not go on"; RUN_OK=0; }; }
[ "$RUN_OK" = 1 ] && { vols_set "$VOLV" || RUN_OK=0; }
if [ "$RUN_OK" = 1 ]; then
	if failsafe_arm; then echo "fail-safe armed: $FAILSAFE_S s"; else echo "the fail-safe could not be armed"; RUN_OK=0; fi
fi

if [ "$RUN_OK" = 1 ] && [ "$ORDER" = cap-first ]; then
	start_capture
	if wait_capture_up; then
		echo "capture path up and settled at uptime $(up)"
		sleep 0.5		# a stretch of floor before the first tone
		if ctl_set "$OUT_PIN" 1; then
			_i=1
			while [ "$_i" -le "$PLAYS" ]; do
				play_one "$_i"
				if [ "$_i" = 1 ]; then
					# poll, don't sleep: the HPH PAs ramp; up to 1 s for the whole path
					_w=0
					while [ "$_w" -lt 20 ]; do
						out_up "$(cat "$PGD/dapm_state" 2>/dev/null)" && break
						sleep 0.05
						_w=$((_w + 1))
					done
					echo "output up after ~$((_w * 50)) ms beside capture"
					sample_live
				fi
				play_wait "$_i"
				_i=$((_i + 1))
				[ "$_i" -le "$PLAYS" ] && sleep 1
			done
		else
			echo "the $OUT_PIN pin did not read back 1"; RUN_OK=0
		fi
	else
		echo "the capture path never came up -- no playback"; RUN_OK=0
	fi
elif [ "$RUN_OK" = 1 ]; then
	# out-first: the output up, then capture beside it; the stimuli back to back
	if ctl_set "$OUT_PIN" 1; then
		play_one 1
		_w=0
		while [ "$_w" -lt 20 ]; do
			out_up "$(cat "$PGD/dapm_state" 2>/dev/null)" && break
			sleep 0.05
			_w=$((_w + 1))
		done
		echo "output up after ~$((_w * 50)) ms; capture starts beside it at uptime $(up)"
		start_capture
		_i=1
		while :; do
			play_wait "$_i"
			_i=$((_i + 1))
			[ "$_i" -le "$PLAYS" ] || break
			play_one "$_i"
			if [ -z "$CLIVE" ] && wait_capture_up; then
				echo "capture path up and settled at uptime $(up)"
				# the snapshot only once this play's output is up: the plays
				# are back to back, but each one powers the path up again
				_w=0
				while [ "$_w" -lt 60 ]; do
					out_up "$(cat "$PGD/dapm_state" 2>/dev/null)" && break
					sleep 0.05
					_w=$((_w + 1))
				done
				echo "output up again ~$((_w * 50)) ms after that"
				sample_live
			fi
		done
		[ -z "$CLIVE" ] && echo "capture was not up and settled while the output played"
	else
		echo "the $OUT_PIN pin did not read back 1"; RUN_OK=0
	fi
fi

if [ "$RUN_OK" = 1 ] || [ -n "$TONE_RCS" ]; then
	ctl_set "$OUT_PIN" 0 || echo "the $OUT_PIN pin did not read back 0"
	_d=0
	while [ "$_d" -lt 20 ]; do
		DPOST=$(cat "$PGD/dapm_state" 2>/dev/null)
		out_down "$DPOST" && break
		sleep 0.1
		_d=$((_d + 1))
	done
	if out_down "$DPOST"; then
		failsafe_disarm
		echo "output down after ~$((_d * 100)) ms; fail-safe disarmed"
	else
		echo "THE OUTPUT IS NOT DOWN -- teardown"
		dp_abort output-not-down
	fi
else
	failsafe_disarm
fi

# the capture runner finishes on its own clock
if [ -n "$CAPPID" ]; then wait "$CAPPID"; CAPRC=$?; else CAPRC=skipped; fi
echo "---- capture runner (exit $CAPRC)"
cat "$CAPLOG" 2>/dev/null
CAPTXT=$(ls -t "$OUTDIR"/wcd9320-capture-*-"$TAG".txt 2>/dev/null | head -n1)
CAPWAV=$(ls -t "$OUTDIR"/wcd9320-capture-*-"$TAG".wav 2>/dev/null | head -n1)

# every control back as found (the Headphones pin last, after the checks)
vols_set "$VOL_PRE" >/dev/null || echo "an output volume did not go back"
ctl_set "$MIXER" "$MIX_PRE" || echo "$MIXER did not go back to $MIX_PRE"
ctl_set "$OTHER_MIXER" "$OMIX_PRE" || echo "$OTHER_MIXER did not go back to $OMIX_PRE"
DEND=$(cat "$PGD/dapm_state" 2>/dev/null)
CEND=$(cap_state)
IEND=$(i2s_state)
echo "live dapm: $DLIVE"
echo "live cap:  $CLIVE"
echo "live i2s:  $ILIVE"
echo "end dapm:  $DEND"
echo "end cap:   $CEND"
echo "end i2s:   $IEND"
for _n in 1 2 3; do [ -f "/tmp/wcd9320-duplex-$STAMP.tone$_n" ] && { echo "---- pcm-tone play $_n"; cat "/tmp/wcd9320-duplex-$STAMP.tone$_n"; }; done
echo "---- dmesg (duplex)"
dmesg | grep -E 'beside|clk-prereq|REFUSED|capture: cap mclk|dapm: mclk|mclk: get|mclk: put' | tail -n 24

echo "---- checks"
ZEROS=""; _z=0; while [ "$_z" -lt "$PLAYS" ]; do ZEROS="${ZEROS}0"; _z=$((_z + 1)); done
check "the run was not aborted" "$ABORTED$RUN_OK" "01"
check "every stimulus played (pcm-tone exit 0 each)" "$TONE_RCS" "$ZEROS"
if [ "$OUTPUT" = i2s ]; then
	check "live: the loudspeaker path up (rail, pins, BCLK)" \
		"$(rv "$ILIVE" supply_on) $(rv "$ILIVE" pins_active) $(rv "$ILIVE" bclk_on)" "1 1 1"
	check "live: the codec holds no output; MCLK and prereq capture's alone" \
		"$(held4 "$DLIVE") $(rv "$CLIVE" mclk_users) $(rv "$CLIVE" prereq_owners)" "000000000 1 2"
else
	check "live: the headphones path up (nine stages, both PAs)" \
		"$(rv "$DLIVE" held) $(rv "$DLIVE" pa_on) $(rv "$DLIVE" pa_r_on)" "1ff 1 1"
	check "live: MCLK shared (2 users), prereq owners output | capture" \
		"$(rv "$CLIVE" mclk_users) $(rv "$CLIVE" prereq_owners)" "2 3"
fi
check "live: capture holds all six stages, its stream up, DMIC$CAPN" \
	"$(rv "$CLIVE" cap_held) $(rv "$CLIVE" tx_up) $(rv "$CLIVE" cap_dmic)" "3f 1 $CAPN"
OBC=$(( $(rv "$CEND" out_beside_cap) - ${OBC0:-0} )); CBO=$(( $(rv "$CEND" cap_beside_out) - ${CBO0:-0} ))
if [ "$OUTPUT" = i2s ]; then
	check "duplex counters: none (the loudspeaker is not a codec output)" "$OBC $CBO" "0 0"
elif [ "$ORDER" = cap-first ]; then
	check "duplex counters: the output started beside capture" "$([ "$OBC" -ge 1 ] && [ "$CBO" = 0 ] && echo ok)" "ok"
else
	check "duplex counters: capture started beside the output" "$CBO" "1"
fi
check "no refusals this run (outputs, capture)" \
	"$(( $(rv "$DEND" refusals) - ${DREF0:-0} )) $(( $(rv "$CEND" refusals) - ${CREF0:-0} ))" "0 0"
check "capture runner: exit 0" "$CAPRC" "0"
check "capture runner: verdict" "$(grep -c '^VERDICT: PASS (wcd9320-capture)' "$CAPLOG" 2>/dev/null)" "1"
check "capture runner: a WAV for this tag" "$([ -n "$CAPWAV" ] && [ -s "$CAPWAV" ] && echo yes)" "yes"
check "after: the output down" "$(out_down "$DEND" && echo down)" "down"
check "after: the codec holds nothing (outputs, MCLK, capture, prereq)" \
	"$(held4 "$DEND") $(rv "$DEND" mclk_users) $(rv "$CEND" cap_held) $(rv "$CEND" prereq_owners)" "000000000 0 00 0"
check "after: the output and mic pins off" "$(ctl_get "$OUT_PIN")$(ctl_get "Handset Mic Switch")" "00"
check "after: the playback mixers as found" "$(ctl_get "$MIXER") $(ctl_get "$OTHER_MIXER")" "$MIX_PRE $OMIX_PRE"
check "after: the output volumes as found" "$(vols_get)" "$VOL_PRE"
check "after: the fail-safe is not armed" "$(systemctl is-active "$FAILSAFE.timer" 2>/dev/null || true)" "inactive"
ctl_set "Headphones Switch" "$HP_PIN_PRE" || echo "the Headphones pin did not go back to $HP_PIN_PRE"
check "after: the Headphones pin as found" "$(ctl_get "Headphones Switch")" "$HP_PIN_PRE"
# r202: what the run wrote to the kernel log from the codec
CODEC_LINES=$(dmesg_since "$DMESG_T0" | grep -c 'wcd9320 217:')
CARD_LINES=$(dmesg_since "$DMESG_T0" | grep -c 'wcd9320-lumia-q6 ')
echo "codec lines added to the kernel log this run: $CODEC_LINES since $DMESG_T0 s (debug messages: run found them ${WCD_TRACE_WAS:-?}); card lines: $CARD_LINES (not in r202's scope)"
if [ "${WCD_TRACE:-1}" = 0 ]; then
	check "quiet: the run added no codec lines to the kernel log (WCD_TRACE=0)" "$CODEC_LINES" "0"
fi
echo "checks : $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && echo "VERDICT: PASS (wcd9320-duplex-probe)" || echo "VERDICT: FAIL (wcd9320-duplex-probe)"
echo "wav: $CAPWAV"
echo "capture evidence: $CAPTXT"
} > "$OUT" 2>&1
command -v wcd_trace_restore >/dev/null 2>&1 && wcd_trace_restore
rm -f "$CAPLOG" /tmp/wcd9320-duplex-"$STAMP".tone*
trap - INT TERM HUP
grep -E '^(  FAIL|checks :|VERDICT|wav:|play [0-9]|capture path up|output (up|down)|ABORT|THE OUTPUT|capture was not)' "$OUT"
echo "evidence: $OUT"
[ "$ABORTED" = 1 ] && exit 3
grep -q '^VERDICT: PASS (wcd9320-duplex-probe)' "$OUT" && exit 0 || exit 1

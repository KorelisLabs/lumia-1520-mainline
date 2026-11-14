#!/bin/sh
#
# DUPLEX PROBE 0: the mic records while the loudspeaker plays -- the
# speakerphone case, with no codec output involved.
# docs/audio/wcd9320-duplex-mapping.md, sections 6 and 7.
#
# The loudspeaker is the card's own I2S output (SEC_MI2S -> TAS2552). It
# holds no codec MCLK and no prereq, so on r200 the codec holds capture and
# nothing else for the whole run. This checks that two Q6 streams run at once
# (MultiMedia1 -> SEC_MI2S_RX, SLIMBUS_0_TX -> MultiMedia2) and gives the mic
# a known acoustic source -- the PC speakers were too quiet at the phone.
#
# One run:
#   preflight (everything idle, versions, tools) -> the I2S route and the
#   Loudspeaker Volume set -> the capture runner records in the background
#   -> once its path is up and the HPF has settled: the fail-safe armed, the
#   Loudspeaker pin on, the 1 kHz stimulus played PLAYS times (tone/silence/
#   tone/silence, ~1.1 s each, 1 s apart) -> pin off, the I2S path verified
#   down, the fail-safe disarmed -> the capture runner's own checks, then
#   this runner's -> every control back as found.
#
# SAFETY: the level is -60, -50 or -40 dBFS only -- there is no escalation
# path here. A transient systemd timer runs wcd9320-dapm-teardown.sh (every
# pin off, the player killed, the VISA amplifier to standby, the C3 abort) if
# the run does not disarm it; a signal does the same at once. NOTE: the
# teardown's C3 abort also drops the codec prereq that capture holds (the
# mapping's section 4) -- on an abort the capture runner's checks will fail,
# which is the right outcome for an aborted run.
#
# Usage (as root on the phone):
#   env EXPECT_VERSION=hpfsettle-rc1 CAP_DMIC=4 CAP_GAIN=114 DBFS=-40 \
#       sh wcd9320-duplex-probe.sh <tag>
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
EXPECT_VERSION="${EXPECT_VERSION:-hpfsettle-rc1}"
CARD_VERSION="${CARD_VERSION:-q6-card-rc12}"
CAPN="${CAP_DMIC:-4}"			# Windows' speakerphone mic
CAPG="${CAP_GAIN:-114}"			# +30 dB, the r199 level
CAPS="${CAP_SECONDS:-8}"
DBFS="${DBFS:--40}"
PLAYS="${PLAYS:-2}"
SPK_GAIN_RAW="${SPK_GAIN_RAW:-22}"	# Loudspeaker Volume, the r193 runs' level
PCMDEV_P="${PCMDEV_P:-/dev/snd/pcmC0D0p}"
FAILSAFE="${DUPLEX_FAILSAFE:-wcd9320-duplex-failsafe}"
FAILSAFE_S="${FAILSAFE_S:-30}"
TEARDOWN="$DIR/wcd9320-dapm-teardown.sh"
I2S_MIXER="SEC_MI2S_RX Audio Mixer MultiMedia1"
SLIM_MIXER="SLIMBUS_0_RX Audio Mixer MultiMedia1"
SPK_PIN="Loudspeaker Switch"
SPK_VOL="Loudspeaker Volume"

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl"; do [ -n "$c" ] && [ -x "$c" ] && { SETCTL=$c; break; }; done
TONE=""
for c in "${PCM_TONE:-}" "$DIR/pcm-tone"; do [ -n "$c" ] && [ -x "$c" ] && { TONE=$c; break; }; done
ctl_get() { "$SETCTL" -D "$CTLDEV" --get "$1" 2>/dev/null | sed -n 's/^readback=//p' | head -n1; }
ctl_set() { [ "$("$SETCTL" -D "$CTLDEV" --set "$1" "$2" 2>/dev/null | sed -n 's/^readback=//p' | head -n1)" = "$2" ]; }
i2s_state() { _f=$(ls /sys/bus/platform/drivers/lumia1520-i2s-spk/*/i2s_spk_state 2>/dev/null | head -n1); [ -n "$_f" ] && cat "$_f" 2>/dev/null; }
up() { cut -d' ' -f1 /proc/uptime; }

PASS=0; FAIL=0
check() {	# check <name> <got> <want>
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  PASS  %-56s %s\n' "$1" "$2"
	else FAIL=$((FAIL + 1)); printf '  FAIL  %-56s %s (want %s)\n' "$1" "$2" "$3"; fi
}

# ------------------------------------------------------------- preflight --
bad=""
case "$DBFS" in -60|-50|-40) ;; *) bad="$bad dbfs=$DBFS(-60/-50/-40-only)" ;; esac
case "$PLAYS" in 1|2|3) ;; *) bad="$bad plays=$PLAYS" ;; esac
case "$CAPS" in ''|*[!0-9]*) bad="$bad seconds" ;; *) [ "$CAPS" -ge 4 ] && [ "$CAPS" -le 20 ] || bad="$bad seconds" ;; esac
case "$SPK_GAIN_RAW" in ''|*[!0-9]*) bad="$bad spk-gain" ;; *) [ "$SPK_GAIN_RAW" -le 22 ] || bad="$bad spk-gain" ;; esac
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
CPRE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
IPRE=$(i2s_state)
[ "$(rv "$DPRE" held)$(rv "$DPRE" spk_held)$(rv "$DPRE" ear_held)$(rv "$DPRE" lo_held)" = "000000000" ] || bad="$bad outputs-held"
[ "$(rv "$DPRE" mclk_users)" = "0" ] || bad="$bad mclk-users"
[ "$(rv "$CPRE" cap_held)" = "00" ] || bad="$bad capture-held"
[ -n "$IPRE" ] || bad="$bad no-i2s_spk_state"
[ "$(rv "$IPRE" supply_on) $(rv "$IPRE" bclk_on)" = "0 0" ] || bad="$bad i2s-up"
for _p in "$SPK_PIN" "Headphones Switch" "Speaker Switch" "Earpiece Switch" "Lineout Switch" "Handset Mic Switch"; do
	[ "$(ctl_get "$_p")" = "0" ] || bad="$bad pin-on:$(printf '%s' "$_p" | tr ' ' '_')"
done
pgrep -x pcm-tone >/dev/null 2>&1 && bad="$bad pcm-tone-running"
pgrep -x pcm-capture >/dev/null 2>&1 && bad="$bad pcm-capture-running"
systemctl is-active --quiet "$FAILSAFE.timer" 2>/dev/null && bad="$bad failsafe-already-armed"
I2S_MIX_PRE=$(ctl_get "$I2S_MIXER"); SLIM_MIX_PRE=$(ctl_get "$SLIM_MIXER"); SPK_VOL_PRE=$(ctl_get "$SPK_VOL")
[ -n "$I2S_MIX_PRE" ] && [ -n "$SLIM_MIX_PRE" ] && [ -n "$SPK_VOL_PRE" ] || bad="$bad controls-missing"
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

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

# ------------------------------------------------------------------ run --
{
echo "================ wcd9320 duplex probe 0 $STAMP ($TAG) ================"
echo "codec $CODECV, card $CARDV; DMIC$CAPN at Capture Digital Volume $CAPG ($((CAPG - 84)) dB), $CAPS s;"
echo "loudspeaker: Loudspeaker Volume $SPK_GAIN_RAW ($((SPK_GAIN_RAW - 7)) dB), 1 kHz stimulus at $DBFS dBFS x $PLAYS"
echo "pre i2s:  $IPRE"
echo "pre cap:  $CPRE"
RUN_OK=1
TONE_RCS=""
# the playback route: the I2S mixer only (r189: one front-end route at a time)
ctl_set "$SLIM_MIXER" 0 || { echo "the SLIMbus playback mixer would not go off"; RUN_OK=0; }
[ "$RUN_OK" = 1 ] && { ctl_set "$I2S_MIXER" 1 || { echo "the I2S mixer would not go on"; RUN_OK=0; }; }
[ "$RUN_OK" = 1 ] && { ctl_set "$SPK_VOL" "$SPK_GAIN_RAW" || { echo "Loudspeaker Volume would not read back $SPK_GAIN_RAW"; RUN_OK=0; }; }

if [ "$RUN_OK" = 1 ]; then
	T0=$(up)
	env EXPECT_VERSION="$EXPECT_VERSION" CARD_VERSION="$CARD_VERSION" CAP_DMIC="$CAPN" \
		CAP_GAIN="$CAPG" CAP_SECONDS="$CAPS" sh "$DIR/wcd9320-capture.sh" "$TAG" > "$CAPLOG" 2>&1 &
	CAPPID=$!
	# the capture path up and the HPF settled (r200), up to 6 s
	_w=0
	while [ "$_w" -lt 60 ]; do
		CUP=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
		[ "$(rv "$CUP" cap_held) $(rv "$CUP" tx_up) $(rv "$CUP" hpf_armed)" = "3f 1 0" ] && break
		kill -0 "$CAPPID" 2>/dev/null || break
		sleep 0.1
		_w=$((_w + 1))
	done
	T1=$(up)
	echo "capture path up and settled after ~$((_w * 100)) ms (uptime $T0 -> $T1)"
	[ "$(rv "$CUP" cap_held) $(rv "$CUP" tx_up) $(rv "$CUP" hpf_armed)" = "3f 1 0" ] ||
		{ echo "the capture path never came up -- no playback"; RUN_OK=0; }
fi

ILIVE=""; CLIVE=""; DLIVE=""
if [ "$RUN_OK" = 1 ]; then
	sleep 0.5			# a stretch of floor before the first tone
	if failsafe_arm; then
		echo "fail-safe armed: $FAILSAFE_S s"
	else
		echo "the fail-safe could not be armed -- no playback"; RUN_OK=0
	fi
fi
if [ "$RUN_OK" = 1 ]; then
	if ctl_set "$SPK_PIN" 1; then
		_i=1
		while [ "$_i" -le "$PLAYS" ]; do
			echo "play $_i: start at uptime $(up)"
			"$TONE" -D "$PCMDEV_P" --dbfs "$DBFS" --side B > "/tmp/wcd9320-duplex-$STAMP.tone$_i" 2>&1 &
			TPID=$!
			sleep 0.4
			# live, mid-stimulus: both paths up at once
			if [ "$_i" = 1 ]; then
				ILIVE=$(i2s_state)
				CLIVE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
				DLIVE=$(cat "$PGD/dapm_state" 2>/dev/null)
			fi
			wait "$TPID"; TONE_RCS="$TONE_RCS$?"; TPID=""
			echo "play $_i: end at uptime $(up)"
			_i=$((_i + 1))
			[ "$_i" -le "$PLAYS" ] && sleep 1
		done
	else
		echo "the Loudspeaker pin did not read back 1"; RUN_OK=0
	fi
	ctl_set "$SPK_PIN" 0 || echo "the Loudspeaker pin did not read back 0"
	# the I2S path down (pin off takes the rail; the stream end takes BCLK)
	_d=0
	while [ "$_d" -lt 20 ]; do
		IPOST=$(i2s_state)
		[ "$(rv "$IPOST" supply_on) $(rv "$IPOST" bclk_on)" = "0 0" ] && break
		sleep 0.1
		_d=$((_d + 1))
	done
	if [ "$(rv "$IPOST" supply_on) $(rv "$IPOST" bclk_on)" = "0 0" ]; then
		failsafe_disarm
		echo "I2S path down after ~$((_d * 100)) ms; fail-safe disarmed"
	else
		echo "THE I2S PATH IS NOT DOWN -- teardown"
		dp_abort i2s-not-down
	fi
fi

# the capture runner finishes on its own clock
if [ -n "$CAPPID" ]; then
	wait "$CAPPID"; CAPRC=$?
else
	CAPRC=skipped
fi
echo "---- capture runner (exit $CAPRC)"
cat "$CAPLOG" 2>/dev/null
CAPTXT=$(ls -t "$OUTDIR"/wcd9320-capture-*-"$TAG".txt 2>/dev/null | head -n1)
CAPWAV=$(ls -t "$OUTDIR"/wcd9320-capture-*-"$TAG".wav 2>/dev/null | head -n1)

# every control back as found
ctl_set "$SPK_VOL" "$SPK_VOL_PRE" || echo "Loudspeaker Volume did not go back to $SPK_VOL_PRE"
ctl_set "$I2S_MIXER" "$I2S_MIX_PRE" || echo "the I2S mixer did not go back to $I2S_MIX_PRE"
ctl_set "$SLIM_MIXER" "$SLIM_MIX_PRE" || echo "the SLIMbus mixer did not go back to $SLIM_MIX_PRE"
IEND=$(i2s_state)
DEND=$(cat "$PGD/dapm_state" 2>/dev/null)
CEND=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
echo "live i2s: $ILIVE"
echo "live cap: $CLIVE"
echo "live dapm: $DLIVE"
echo "end i2s:  $IEND"
echo "end cap:  $CEND"
for _n in 1 2 3; do [ -f "/tmp/wcd9320-duplex-$STAMP.tone$_n" ] && { echo "---- pcm-tone play $_n"; cat "/tmp/wcd9320-duplex-$STAMP.tone$_n"; }; done

echo "---- checks"
check "the run was not aborted" "$ABORTED$RUN_OK" "01"
ZEROS=""; _z=0; while [ "$_z" -lt "$PLAYS" ]; do ZEROS="${ZEROS}0"; _z=$((_z + 1)); done
check "every stimulus played (pcm-tone exit 0 each)" "$TONE_RCS" "$ZEROS"
check "live: the loudspeaker path up (rail, pins, BCLK)" \
	"$(rv "$ILIVE" supply_on) $(rv "$ILIVE" pins_active) $(rv "$ILIVE" bclk_on)" "1 1 1"
check "live: capture holds all six stages, its stream up" "$(rv "$CLIVE" cap_held) $(rv "$CLIVE" tx_up)" "3f 1"
check "live: the codec holds no output, one MCLK user (capture)" \
	"$(rv "$DLIVE" held)$(rv "$DLIVE" spk_held)$(rv "$DLIVE" ear_held)$(rv "$DLIVE" lo_held) $(rv "$DLIVE" mclk_users)" "000000000 1"
check "live: capture is recording DMIC$CAPN" "$(rv "$CLIVE" cap_dmic)" "$CAPN"
check "capture runner: exit 0" "$CAPRC" "0"
check "capture runner: verdict" "$(grep -c '^VERDICT: PASS (wcd9320-capture)' "$CAPLOG" 2>/dev/null)" "1"
check "capture runner: a WAV for this tag" "$([ -n "$CAPWAV" ] && [ -s "$CAPWAV" ] && echo yes)" "yes"
check "after: the loudspeaker path down" "$(rv "$IEND" supply_on) $(rv "$IEND" bclk_on)" "0 0"
check "after: the codec holds nothing" \
	"$(rv "$DEND" held)$(rv "$DEND" spk_held)$(rv "$DEND" ear_held)$(rv "$DEND" lo_held) $(rv "$DEND" mclk_users) $(rv "$CEND" cap_held)" "000000000 0 00"
check "after: every pin off" \
	"$(ctl_get "$SPK_PIN")$(ctl_get "Handset Mic Switch")$(ctl_get "Headphones Switch")" "000"
check "after: the playback mixers as found" "$(ctl_get "$I2S_MIXER") $(ctl_get "$SLIM_MIXER")" "$I2S_MIX_PRE $SLIM_MIX_PRE"
check "after: Loudspeaker Volume as found" "$(ctl_get "$SPK_VOL")" "$SPK_VOL_PRE"
check "after: the fail-safe is not armed" \
	"$(systemctl is-active "$FAILSAFE.timer" 2>/dev/null || true)" "inactive"
echo "checks : $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && echo "VERDICT: PASS (wcd9320-duplex-probe)" || echo "VERDICT: FAIL (wcd9320-duplex-probe)"
echo "wav: $CAPWAV"
echo "capture evidence: $CAPTXT"
} > "$OUT" 2>&1
rm -f "$CAPLOG" /tmp/wcd9320-duplex-"$STAMP".tone*
trap - INT TERM HUP
grep -E '^(  FAIL|checks :|VERDICT|wav:|play [0-9]|capture path up|I2S path down|ABORT|THE I2S)' "$OUT"
echo "evidence: $OUT"
[ "$ABORTED" = 1 ] && exit 3
grep -q '^VERDICT: PASS' "$OUT" && exit 0 || exit 1

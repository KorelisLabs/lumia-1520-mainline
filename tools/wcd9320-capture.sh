#!/bin/sh
#
# r197 CAPTURE RUNNER: record the call mic (DMIC1) through the codec's
# capture path -- MIC BIAS1 (1.8 V), the DMIC1 clock (2.4 MHz), DEC1, SLIM
# TX1, SLIMBUS_0_TX, MultiMedia2 -- into a WAV, and prove the path's state
# live and its restore after. docs/audio/wcd9320-mic-mapping.md.
#
# Nothing here drives a transducer: the run switches the capture mixer and
# the "Handset Mic" pin on, records, and switches both off. The PC plays the
# stimulus (or nothing, for the floor) and analyses the WAV afterwards.
#
# Usage (as root on the phone):
#   EXPECT_VERSION=hpfsettle-rc1 CAP_DMIC=1..4 CAP_SECONDS=5 sh wcd9320-capture.sh <tag>
# Output: /var/log/wcd9320-capture-<stamp>-<tag>.wav and .txt
# Exit: 0 PASS, 1 FAIL, 2 refused before anything changed.

DIR=$(cd "$(dirname "$0")" && pwd)
PGD=/sys/bus/slimbus/devices/217:a0:1:0
CTLDEV=/dev/snd/controlC0
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
TAG="${1:-run}"
SECS="${CAP_SECONDS:-5}"
EXPECT_VERSION="${EXPECT_VERSION:-hpfsettle-rc1}"
# r199: CAP_GAIN=0..124 -- "Capture Digital Volume" for the run (-84..+40 dB,
# 84 = 0 dB); unset leaves the control as found
CAPG="${CAP_GAIN:-}"
GAINCTL="Capture Digital Volume"
# r198: CAP_DMIC=1..4 -- which DMIC the run records (cap_dmic in the codec);
# DMIC n goes through decimator n, SLIM TXn, TX port n-1, channel 128+n-1,
# on MICBIAS1 (1/2) or MICBIAS3 (3/4)
CAPN="${CAP_DMIC:-1}"
CARD_VERSION="${CARD_VERSION:-q6-card-rc12}"
WAV="$OUTDIR/wcd9320-capture-$STAMP-$TAG.wav"
OUT="$OUTDIR/wcd9320-capture-$STAMP-$TAG.txt"
TLOG="/tmp/wcd9320-capture-$STAMP.tool"
PIN="Handset Mic Switch"
MIXER="MultiMedia2 Mixer SLIMBUS_0_TX"

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
hexand() { printf '%02x' $(( 0x${1:-00} & $2 )); }
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl"; do [ -n "$c" ] && [ -x "$c" ] && { SETCTL=$c; break; }; done
CAP=""
for c in "${PCM_CAPTURE:-}" "$DIR/pcm-capture"; do [ -n "$c" ] && [ -x "$c" ] && { CAP=$c; break; }; done
ctl_get() { "$SETCTL" -D "$CTLDEV" --get "$1" 2>/dev/null | sed -n 's/^readback=//p' | head -n1; }
ctl_set() { [ "$("$SETCTL" -D "$CTLDEV" --set "$1" "$2" 2>/dev/null | sed -n 's/^readback=//p' | head -n1)" = "$2" ]; }

PASS=0; FAIL=0
check() {	# check <name> <got> <want>
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  PASS  %-52s %s\n' "$1" "$2"
	else FAIL=$((FAIL + 1)); printf '  FAIL  %-52s %s (want %s)\n' "$1" "$2" "$3"; fi
}

# ------------------------------------------------------------- preflight --
bad=""
case "$SECS" in ''|*[!0-9]*) bad="$bad seconds" ;; *) [ "$SECS" -ge 1 ] && [ "$SECS" -le 30 ] || bad="$bad seconds" ;; esac
[ -n "$SETCTL" ] || bad="$bad no-alsa-setctl"
[ -n "$CAP" ] || bad="$bad no-pcm-capture"
CODECV=$(cat /sys/module/wcd9320/version 2>/dev/null)
CARDV=$(cat /sys/module/snd_soc_lumia1520_q6/version 2>/dev/null)
[ "$CODECV" = "$EXPECT_VERSION" ] || bad="$bad codec=$CODECV"
[ "$CARDV" = "$CARD_VERSION" ] || bad="$bad card=$CARDV"
DPRE=$(cat "$PGD/dapm_state" 2>/dev/null)
CPRE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
[ "$(rv "$DPRE" held)$(rv "$DPRE" spk_held)$(rv "$DPRE" ear_held)$(rv "$DPRE" lo_held)" = "000000000" ] || bad="$bad outputs-held"
[ "$(rv "$DPRE" mclk_users)" = "0" ] || bad="$bad mclk-users"
[ "$(rv "$CPRE" cap_held)" = "00" ] || bad="$bad capture-held"
[ "$(rv "$CPRE" tx_port_on)" = "0" ] || bad="$bad tx-port-on"
[ "$(ctl_get "$PIN")" = "0" ] || bad="$bad pin-not-off"
[ "$(ctl_get "$MIXER")" = "0" ] || bad="$bad mixer-not-off"
case "$CAPN" in 1|2|3|4) ;; *) bad="$bad cap-dmic=$CAPN" ;; esac
GPRE=$(ctl_get "$GAINCTL")
[ -n "$GPRE" ] || bad="$bad no-capture-volume"
case "$CAPG" in '') ;; *[!0-9]*) bad="$bad cap-gain=$CAPG" ;; *) [ "$CAPG" -le 124 ] || bad="$bad cap-gain=$CAPG" ;; esac
[ -e "$PGD/cap_dmic" ] || bad="$bad no-cap_dmic"
DMPRE=$(rv "$(cat "$PGD/cap_dmic" 2>/dev/null)" dmic)
PCMDEV=$(ls /dev/snd/pcmC0D*c 2>/dev/null)
[ "$(printf '%s\n' $PCMDEV | grep -c .)" = "1" ] || bad="$bad capture-pcm='$PCMDEV'"
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

abort() {
	echo "ABORT: $1"
	[ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
	ctl_set "$PIN" 0; ctl_set "$MIXER" 0
}

# ------------------------------------------------------------------ run --
{
echo "================ wcd9320 capture run $STAMP ($TAG) ================"
echo "codec $CODECV, card $CARDV, device $PCMDEV, $SECS s, S16_LE mono 48 kHz"
RUN_OK=1
# r198: select the DMIC while everything is idle, then re-read the baseline
echo "$CAPN" > "$PGD/cap_dmic" 2>/dev/null
[ "$(rv "$(cat "$PGD/cap_dmic" 2>/dev/null)" dmic)" = "$CAPN" ] || { echo "ABORT: cap_dmic did not read back $CAPN"; RUN_OK=0; }
echo "route: $(cat "$PGD/cap_dmic" 2>/dev/null)"
# r199: the gain for this run, set while capture is idle
if [ -n "$CAPG" ]; then
	ctl_set "$GAINCTL" "$CAPG" || { echo "ABORT: $GAINCTL did not read back $CAPG"; RUN_OK=0; }
fi
GRUN=$(ctl_get "$GAINCTL")
echo "capture gain: control $GRUN = $(( ${GRUN:-84} - 84 )) dB"
CPRE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
echo "pre:  $CPRE"
[ "$RUN_OK" = 1 ] && { ctl_set "$MIXER" 1 || { abort "the capture mixer did not read back 1"; RUN_OK=0; }; }
[ "$RUN_OK" = 1 ] && { ctl_set "$PIN" 1 || { abort "the Handset Mic pin did not read back 1"; RUN_OK=0; }; }
if [ "$RUN_OK" = 1 ]; then
	"$CAP" -D "$PCMDEV" -s "$SECS" -o "$WAV" > "$TLOG" 2>&1 &
	CPID=$!
	# poll, don't sleep: the path takes ~1 s to come up (MCLK switch,
	# LDO_H, the 20 ms bias settle), and a fixed 1 s sample caught it at
	# 1f on the first r197 run. Up to 4 s for all six stages and the stream.
	_w=0
	while [ "$_w" -lt 40 ]; do
		CLIVE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
		[ "$(rv "$CLIVE" cap_held) $(rv "$CLIVE" tx_up)" = "3f 1" ] && break
		kill -0 "$CPID" 2>/dev/null || break
		sleep 0.1
		_w=$((_w + 1))
	done
	echo "path up after ~$((_w * 100)) ms"
	# r200: the HPF settle ends 300 ms after the decimator is up; wait it out
	_h=0
	while [ "$_h" -lt 10 ]; do
		[ "$(rv "$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')" hpf_armed)" = "0" ] && break
		sleep 0.1
		_h=$((_h + 1))
	done
	echo "HPF settle done ~$((_h * 100)) ms after that"
	sleep 0.2
	CLIVE=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
	DLIVE=$(cat "$PGD/dapm_state" 2>/dev/null)
	echo "live: $CLIVE"
	wait "$CPID"; TRC=$?; CPID=""
	ctl_set "$PIN" 0 || echo "the Handset Mic pin did not read back 0"
	ctl_set "$MIXER" 0 || echo "the capture mixer did not read back 0"
	sleep 0.3
fi
CPOST=$(cat "$PGD/capture_state" 2>/dev/null | tr '\n' ' ')
DPOST=$(cat "$PGD/dapm_state" 2>/dev/null)
echo "post: $CPOST"
echo "---- pcm-capture"; cat "$TLOG" 2>/dev/null
T=$(tr '\n' ' ' < "$TLOG" 2>/dev/null)

echo "---- checks"
check "codec version" "$CODECV" "$EXPECT_VERSION"
check "card version" "$CARDV" "$CARD_VERSION"
check "the run was not aborted" "$RUN_OK" "1"
check "pcm-capture exit" "${TRC:-?}" "0"
check "every frame read" "$(rv "$T" frames_read)" "$(rv "$T" frames_wanted)"
check "no overruns" "$(rv "$T" xruns)" "0"
check "geometry 48000 Hz mono" "$(rv "$T" actual_rate) $(rv "$T" actual_channels)" "48000 1"
# live: the six stages, the TX port and stream, and every field as mapped
check "live: capture holds all six stages" "$(rv "$CLIVE" cap_held)" "3f"
check "live: no output held" "$(rv "$DLIVE" held)$(rv "$DLIVE" ear_held)" "00000"
check "live: one MCLK user, prereq on" "$(rv "$CLIVE" mclk_users) $(rv "$CLIVE" prereq)" "1 1"
check "live: TX port 0 on, SLIMbus TX stream up" "$(rv "$CLIVE" tx_port_on) $(rv "$CLIVE" tx_up)" "1 1"
check "live: LDO_H on at 3.0 V (0x110 & 8c)" "$(hexand "$(rv "$CLIVE" ldoh_0x110)" 0x8c)" "8c"
check "live: CFILT1 k 24 = 1.8 V (0x129 & fc)" "$(hexand "$(rv "$CLIVE" cfiltk_0x129)" 0xfc)" "60"
check "live: CFILT1 on (0x128 b7)" "$(hexand "$(rv "$CLIVE" cfilt1_0x128)" 0x80)" "80"
# r198: DMIC n's own bits -- the pair's clock field, decimator n, SLIM TXn
if [ "$CAPN" -gt 2 ]; then CKM=0xf0; CKW=50; MBN=3; else CKM=0x0f; CKW=05; MBN=1; fi
FSH=$(( 2 * (CAPN - 1) )); DBIT=$(( 1 << (CAPN - 1) ))
check "live: the route is DMIC$CAPN on TX port $((CAPN - 1))" "$(rv "$CLIVE" cap_dmic) $(rv "$CLIVE" tx_port)" "$CAPN $((CAPN - 1))"
check "live: MICBIAS$MBN on, on CFILT1 (& e0)" "$(hexand "$(rv "$CLIVE" micb)" 0xe0)" "80"
check "live: the pair's clock DIV_4 and on (0x304 & ${CKM#0x})" "$(hexand "$(rv "$CLIVE" dmicclk_0x304)" $CKM)" "$CKW"
check "live: DEC$CAPN DMIC rate DIV_4 (& 07)" "$(hexand "$(rv "$CLIVE" txdmic)" 0x07)" "02"
check "live: DEC$CAPN input DMIC$CAPN (0x393 field)" "$(( (0x$(rv "$CLIVE" conntx_0x393) >> FSH) & 3 ))" "1"
check "live: DEC$CAPN DMIC sel, HPF on (& 09)" "$(hexand "$(rv "$CLIVE" mux)" 0x09)" "01"
# r200: 150 Hz (0x20) only while the decimator settles, then the cut-off the
# run found; r197-r199 wrote 0x10 (75 Hz) here and called it 150 Hz
HPFPRE=$(hexand "$(rv "$CPRE" mux)" 0x30)
check "live: DEC$CAPN HPF cut-off back as found after the settle (& 30)" "$(hexand "$(rv "$CLIVE" mux)" 0x30)" "$HPFPRE"
if [ "$HPFPRE" = "20" ]; then HPFN=0; else HPFN=1; fi
HS0=$(rv "$CPRE" hpf_settles); HS1=$(rv "$CLIVE" hpf_settles)
HE0=$(rv "$CPRE" hpf_errors); HE1=$(rv "$CLIVE" hpf_errors)
check "live: the HPF settle ran $HPFN time(s), disarmed, no errors" \
	"$(( ${HS1:-0} - ${HS0:-0} )) $(rv "$CLIVE" hpf_armed) $(( ${HE1:-0} - ${HE0:-0} ))" "$HPFN 0 0"
check "live: DEC$CAPN unmuted (b0)" "$(hexand "$(rv "$CLIVE" volcfg)" 0x01)" "00"
check "live: DEC$CAPN gain = Capture Digital Volume ($(( ${GRUN:-84} - 84 )) dB)" "$(rv "$CLIVE" gain)" "$(printf '%02x' $(( (${GRUN:-84} - 84) & 0xff )))"
check "live: DEC$CAPN clock on (0x30a bit $((CAPN - 1)))" "$(( (0x$(rv "$CLIVE" txclk_0x30a) >> (CAPN - 1)) & 1 ))" "1"
check "live: CDC_CONN on (0x30c b2)" "$(hexand "$(rv "$CLIVE" othr_0x30c)" 0x04)" "04"
check "live: SLIM TX$CAPN = DEC$CAPN (& 0f)" "$(hexand "$(rv "$CLIVE" sbtx)" 0x0f)" "08"
# after: everything down and every register as found
check "after: capture holds nothing" "$(rv "$CPOST" cap_held)" "00"
check "after: TX port off, stream down" "$(rv "$CPOST" tx_port_on) $(rv "$CPOST" tx_up)" "0 0"
check "after: no MCLK user" "$(rv "$DPOST" mclk_users)" "0"
for k in ldoh_0x110 cfilt1_0x128 cfiltk_0x129 micb gain mux txdmic dmicclk_0x304 txclk_0x30a othr_0x30c conntx_0x393 sbtx; do
	check "after: $k as found" "$(rv "$CPOST" "$k")" "$(rv "$CPRE" "$k")"
done
# volcfg: the driver owns bit 0 (mute) only; the first r197 run saw the chip
# set bit 3 itself during the stream, so only bit 0 is compared
check "after: volcfg bit 0 as found" "$(hexand "$(rv "$CPOST" volcfg)" 0x01)" "$(hexand "$(rv "$CPRE" volcfg)" 0x01)"
echo "volcfg: before $(rv "$CPRE" volcfg), live $(rv "$CLIVE" volcfg), after $(rv "$CPOST" volcfg) (bit 3 is the chip's)"
# r198: the route back to what the run found
[ -n "$DMPRE" ] && echo "$DMPRE" > "$PGD/cap_dmic" 2>/dev/null
check "cap_dmic as found" "$(rv "$(cat "$PGD/cap_dmic" 2>/dev/null)" dmic)" "${DMPRE:-?}"
# r199: the gain control back to what the run found
[ -n "$CAPG" ] && [ -n "$GPRE" ] && ctl_set "$GAINCTL" "$GPRE"
check "Capture Digital Volume as found" "$(ctl_get "$GAINCTL")" "${GPRE:-?}"
for k in refusals failures; do
	check "capture $k this run" "$(( $(rv "$CPOST" "$k") - $(rv "$CPRE" "$k") ))" "0"
done
check "one TX stream up and down this run" \
	"$(( $(rv "$CPOST" tx_ups) - $(rv "$CPRE" tx_ups) )) $(( $(rv "$CPOST" tx_downs) - $(rv "$CPRE" tx_downs) ))" "1 1"
check "pin and mixer off at the end" "$(ctl_get "$PIN") $(ctl_get "$MIXER")" "0 0"
echo "signal: peak $(rv "$T" peak) of 32767, mean square $(rv "$T" mean_square)"
echo "---- dmesg (capture)"
dmesg | grep -E 'capture:|tx-port|tx-stream|BE hw_params \(capture\)' | tail -n 30
echo "checks : $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && echo "VERDICT: PASS (wcd9320-capture)" || echo "VERDICT: FAIL (wcd9320-capture)"
echo "wav: $WAV"
} > "$OUT" 2>&1
rm -f "$TLOG"
grep -E 'FAIL|VERDICT|checks :|signal:|ABORT|INVALID|^wav:' "$OUT"
echo "evidence: $OUT"
grep -q 'VERDICT: PASS' "$OUT"

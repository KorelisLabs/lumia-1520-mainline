#!/bin/sh
#
# r184 ACOUSTIC GATE: ordinary playback, powered by DAPM, is heard on HPHL.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md, sections 3c and 4. Per stream:
#
#   approval in chat -> fail-safe armed -> Headphones pin ON
#   -> the plain tone helper plays (DAPM powers MCLK, prep, prereq, RX1, DAC,
#      PA at prepare; tears them down at stream stop)
#   -> pin OFF -> PA chip-verified off -> fail-safe disarmed
#
# No research attribute powers anything in this run. The runner only switches
# the pin, plays, and reads state. That is the claim: the C3a path, driven by
# ASoC alone.
#
# SAFETY, the C3a model kept whole:
#   - the abort path is proven by a live Volume Down press before anything
#     arms, and an independent watcher stays up for the whole run;
#   - a transient systemd fail-safe timer is armed before the pin goes on and
#     cancelled only on a chip-verified PA-off;
#   - every abort runs wcd9320-dapm-teardown.sh: pin off, player killed, then
#     the driver's C3 abort regardless;
#   - one approval per stream, delivered by tools/c3a-approve.sh. This runs as
#     the same unit, journal and drop-box as C3a so that tool works unchanged.
#
# r185: STEREO. DAPM powers nine stages (both channels, both PAs) for every
# stream, and each stream is a spec "side:hph:dig" -- the tone on the left,
# the right or both, the HPHL/HPHR Volume (0..20) and the RX1/RX2 Digital
# Volume (0..84 = -84..0 dB), set through the ALSA controls while the path is
# down. The default plan is the mapping's section 7, step 5:
#
#   L:20:84   the left alone, mic on the left earcup
#   R:20:84   the right alone, mic on the right earcup
#   R:16:84   the right, 4 analog steps down: the analyser measures the step
#   R:20:78   the right, -6 dB digital: the analyser confirms it
#
# The journal names the side before every approval. Jack detection stays on;
# the runner takes the pin with the manual override, as before. At the end
# every volume goes back to its boot value (analog minimum, digital 0 dB).
#
# r187: OUTPUT=hph (default), spk or ear. The speaker and earpiece probes
# use the same arming, approval, fail-safe and teardown; their spec is
# side:vol:dig with vol the output's own control (Speaker Volume 0..8,
# Earpiece Volume 0..6, 0 = minimum) and dig the RX7 (speaker) or RX1
# (earpiece) digital volume. Default plan for both: one stream, B:0:84 --
# the minimum gain, the probe of docs/audio/wcd9320-r187-speaker-earpiece-mapping.md.
#
# Usage (one line):
#   sudo env EXPECT_VERSION=outputs-rc1 sh wcd9320-dapm-listen.sh launch
#   sudo env EXPECT_VERSION=outputs-rc1 OUTPUT=spk sh wcd9320-dapm-listen.sh launch
#   (SPECS=L:20:84,R:20:84 to override the plan)
# Exit:   0 pass, 1 checks failed, 2 invalid setup, 3 aborted.

set -u

MODE="wcd9320-dapm-listen"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-hphl-pa-expect.sh"
. "$DIR/wcd9320-dapm-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
JOURNAL="${C3A_JOURNAL:-$OUTDIR/wcd9320-c3a-journal.txt}"
export C3A_JOURNAL="$JOURNAL"
FLAG="${C3A_FLAG:-/run/wcd9320-c3a.abort}"
RUNLOCK="${C3A_LOCK:-/run/wcd9320-c3a.lock}"
GATELOCK="${C3A_GATELOCK:-/run/wcd9320-c3a-gate.lock}"
FAILSAFE="${C3A_FAILSAFE:-wcd9320-c3a-failsafe}"
UNIT="${C3A_UNIT:-wcd9320-c3a}"
APPROVE_DIR="${C3A_APPROVE_DIR:-/run/wcd9320-c3a-approve}"
TEARDOWN="$DIR/wcd9320-dapm-teardown.sh"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
DBFS="${DBFS:--40}"
# r187: Section 23's declared escalation. -40 is the default and needs
# nothing. -30 and -20 (pcm-tone's compiled ceiling) are allowed only with
# ESCALATE=declared on the command line, which the operator gives in chat for
# that run; then, and only then, pcm-tone gets --armed-escalation. Any other
# level is refused here, before anything is armed.
ESCALATE="${ESCALATE:-}"
TONE_ARM=""
case "$DBFS" in
-40) ;;
-30|-20)
	[ "$ESCALATE" = "declared" ] ||
		{ echo "INVALID SETUP: DBFS=$DBFS is an escalation -- it needs ESCALATE=declared"; exit 2; }
	TONE_ARM="--armed-escalation" ;;
*)	echo "INVALID SETUP: DBFS=$DBFS (allowed: -40, or -30/-20 with ESCALATE=declared)"; exit 2 ;;
esac
OUTPUT="${OUTPUT:-hph}"
dapm_out "$OUTPUT" || { echo "INVALID SETUP: OUTPUT=$OUTPUT (hph, spk or ear)"; exit 2; }
if [ "$OUTPUT" = "hph" ]; then
	SPECS="${SPECS:-L:20:84,R:20:84,R:16:84,R:20:78}"	# commas: it survives --setenv
else
	SPECS="${SPECS:-B:0:84}"
fi
SPEC_LIST=$(printf '%s' "$SPECS" | tr ',' ' ')
CYCLES=$(printf '%s\n' $SPEC_LIST | grep -c .)
HOLD_ARM="${HOLD_ARM:-300}"
HOLD_GO="${HOLD_GO:-600}"		# waiting for "go", everything OFF
FAILSAFE_S="${FAILSAFE_S:-30}"		# covers pin on, ~1.1 s stream, pin off

GATE=""
for c in "${INPUT_GATE:-}" "$DIR/input-gate" /tmp/input-gate; do
	[ -n "$c" ] && [ -x "$c" ] && { GATE="$c"; break; }
done
TONE=""
for c in "${PCM_TONE:-}" "$DIR/pcm-tone" /tmp/pcm-tone; do
	[ -n "$c" ] && [ -x "$c" ] && { TONE="$c"; break; }
done
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

jrn() {
	printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"
	printf '%s %s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$*" >> "$JOURNAL" 2>/dev/null
	sync 2>/dev/null
}
rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
pa_masked() { printf '%02x' $(( 0x${1:-ff} & 0x$WCD9320_PA_MASK )); }
hph_status() {
	grep -m2 -E '^(1b3|1b9):' "/sys/kernel/debug/regmap/${PGD_NAME:-none}/registers" \
		2>/dev/null | tr -d ' ' | tr '\n' ' ' | sed 's/:/=/g; s/ *$//'
}
pin_set() {	# pin_set 0|1 -> 0 when THIS output's pin reads back as asked
	[ "$(dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --set "$OUT_PIN" "$1" 2>/dev/null)")" = "$1" ]
}
pin_get() { dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "$OUT_PIN" 2>/dev/null)"; }
# r187: every output pin off (the others must stay off for a single-output run)
pins_all_off() {
	for _po in "Headphones Switch" "Speaker Switch" "Earpiece Switch"; do
		"$SETCTL" -D "$CTLDEV" --set "$_po" 0 >/dev/null 2>&1
	done
}
# r187: 0 when every PA is chip-verified off -- HPH, speaker, earpiece
all_pa_off() {
	_ap=$(rv "$(cat "${PGD:-/nonexistent}/hphl_pa_state" 2>/dev/null)" pa_0x1ab)
	_ao=$(cat "${PGD:-/nonexistent}/out_state" 2>/dev/null)
	[ -n "$_ap" ] && [ "$(pa_masked "$_ap")" = "00" ] || return 1
	[ -n "$_ao" ] || return 0
	[ $(( 0x$(rv "$_ao" spken_0x1df) & 0x80 )) -eq 0 ] &&
	[ $(( 0x$(rv "$_ao" ear_0x1bc) & 0x10 )) -eq 0 ]
}
# r185: ctl_set <control> <value> -> 0 when it reads back as asked
ctl_set() {
	[ "$("$SETCTL" -D "$CTLDEV" --set "$1" "$2" 2>/dev/null |
	     sed -n 's/^readback=//p' | head -n1)" = "$2" ]
}
# vol_set <vol> <dig> -> this output's volume and digital controls
vol_set() {
	case "$OUTPUT" in
	hph) ctl_set "HPHL Volume" "$1" && ctl_set "HPHR Volume" "$1" &&
	     ctl_set "RX1 Digital Volume" "$2" && ctl_set "RX2 Digital Volume" "$2" ;;
	spk) ctl_set "Speaker Volume" "$1" && ctl_set "RX7 Digital Volume" "$2" ;;
	ear) ctl_set "Earpiece Volume" "$1" && ctl_set "RX1 Digital Volume" "$2" ;;
	esac
}
# r187: every output back to its boot value
vol_restore() {
	ctl_set "HPHL Volume" 0 && ctl_set "HPHR Volume" 0 &&
	ctl_set "RX1 Digital Volume" 84 && ctl_set "RX2 Digital Volume" 84 &&
	ctl_set "Speaker Volume" 0 && ctl_set "Earpiece Volume" 0 &&
	ctl_set "RX7 Digital Volume" 78
}

# ------------------------------------------------------------------- abort --
ABORTED=0
ABORT_WHY=""
WATCH_PID=""
TPID=""
failsafe_disarm() {
	systemctl stop "$FAILSAFE.timer" >/dev/null 2>&1
	systemctl stop "$FAILSAFE.service" >/dev/null 2>&1
	systemctl reset-failed "$FAILSAFE.service" >/dev/null 2>&1
	return 0
}
failsafe_arm() {	# failsafe_arm <phase>
	failsafe_disarm
	systemd-run --unit="$FAILSAFE" --collect --on-active="$FAILSAFE_S" \
		sh "$TEARDOWN" "failsafe-$1" >/dev/null 2>&1 ||
		{ jrn "FAIL-SAFE COULD NOT BE ARMED for $1"; return 1; }
	jrn "fail-safe armed: $FAILSAFE_S s, phase $1"
}
watch_stop() { [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }

dl_abort() {	# dl_abort <reason>
	[ "$ABORTED" = "1" ] && return 0
	ABORTED=1
	ABORT_WHY="$1"
	jrn "ABORT reason=$1"
	[ -n "$TPID" ] && kill "$TPID" 2>/dev/null
	sh "$TEARDOWN" "$1" 2>&1 | while read -r _l; do jrn "  $_l"; done
	if all_pa_off; then
		failsafe_disarm
		jrn "every PA chip-verified off after the abort; fail-safe disarmed"
	else
		jrn "A PA IS NOT VERIFIED OFF AFTER THE ABORT -- fail-safe LEFT ARMED"
	fi
	watch_stop
	jrn "ABORT complete"
}
flag_ok() {	# flag_ok <where> -> 1 after aborting on Volume Down
	[ -e "$FLAG" ] || return 0
	jrn "abort flag present at $1 -- the watcher saw Volume Down"
	dl_abort "volume-down at $1"
	return 1
}

# --------------------------------------------------------------- preflight --
preflight() {
	_bad=""
	[ -n "$GATE" ] || _bad="$_bad no-input-gate"
	[ -n "$TONE" ] || _bad="$_bad no-pcm-tone"
	[ -n "$SETCTL" ] || _bad="$_bad no-alsa-setctl"
	[ -f "$TEARDOWN" ] && [ -f "$DIR/wcd9320-hphl-pa-teardown.sh" ] || _bad="$_bad no-teardown"
	[ -n "$_bad" ] && { say "INVALID SETUP:$_bad"; return 1; }

	require_module_version
	find_devices
	[ -e "$PGD/dapm_state" ] || { say "INVALID SETUP: no dapm_state -- not r184"; return 1; }
	jrn "module $RUNNING_VERSION, codec $PGD"

	"$GATE" --resolve >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: the approve and abort devices did not resolve"; return 1; }
	"$TONE" --dbfs "$DBFS" $TONE_ARM --side B --dry-run >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: the tone helper refused $DBFS dBFS stereo (r185 pcm-tone?)"; return 1; }
	for _sp in $SPEC_LIST; do
		_ok=$(dapm_spec_ok_out "$OUTPUT" "$_sp")
		[ "$_ok" = "OK" ] || { say "INVALID SETUP: stream spec $_sp: ${_ok#REFUSE:}"; return 1; }
	done
	[ -e "$PGD/hphr_state" ] || { say "INVALID SETUP: no hphr_state -- not r185"; return 1; }
	[ "$OUTPUT" = "hph" ] || [ -e "$PGD/out_state" ] ||
		{ say "INVALID SETUP: no out_state -- not r187"; return 1; }

	# r185: jack detection may hold the pin on for a plugged headset. The
	# manual override takes it off; the run owns the pin from here.
	JACK_PRE=$(cat "$PGD/jack_detect" 2>/dev/null)
	jrn "jack: $JACK_PRE"
	pins_all_off
	pin_set 0 || { say "INVALID SETUP: the $OUT_PIN pin would not go off"; return 1; }
	jrn "output $OUTPUT: pin $OUT_PIN, $OUT_KEY full $OUT_ALL"

	D_PRE=$(cat "$PGD/dapm_state" 2>/dev/null)
	PRE=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	DPRE=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
	RPRE=$(cat "$PGD/hphr_state" 2>/dev/null)
	_cs=$(cat "$PGD/clk_source_state" 2>/dev/null)
	[ "$(dapm_held_is "$D_PRE" "$DAPM_HELD_NONE")" = "OK" ] || _bad="$_bad dapm-held=$(dapm_kv "$D_PRE" held)"
	CARDV=$(cat "$DAPM_CARD_VERSION_PATH" 2>/dev/null)
	_cok=$(dapm_card_ok "$CARDV" "$(pin_get)")
	[ "$_cok" = "OK" ] || _bad="$_bad ${_cok#REFUSE:}"
	[ "$(rv "$_cs" mclk_users)" = "0" ] || _bad="$_bad mclk-held"
	[ "$(rv "$_cs" on_mclk)" = "0" ] || _bad="$_bad not-on-rco"
	[ "$(pa_masked "$(rv "$PRE" pa_0x1ab)")" = "00" ] || _bad="$_bad pa-on"
	[ "$(rv "$PRE" guard_tripped)" = "0" ] || _bad="$_bad guard-tripped"
	[ "$(rv "$PRE" prep_on)" = "0" ] || _bad="$_bad prep-on"
	[ "$(rv "$DPRE" on)" = "0" ] || _bad="$_bad dac-on"
	[ "$(rv "$DPRE" dac_0x1b1)" = "00" ] || _bad="$_bad dac-dirty"
	[ "$(rv "$RPRE" dac_on)" = "0" ] || _bad="$_bad hphr-dac-on"
	[ "$(rv "$RPRE" pa_on)" = "0" ] || _bad="$_bad hphr-pa-on"
	[ "$(rv "$RPRE" rdac_0x1b7)" = "00" ] || _bad="$_bad hphr-dac-dirty"
	OPRE=$(cat "$PGD/out_state" 2>/dev/null)
	if [ -n "$OPRE" ]; then
		[ "$(rv "$OPRE" spk_pa)" = "0" ] || _bad="$_bad spk-pa-on"
		[ "$(rv "$OPRE" ear_pa)" = "0" ] || _bad="$_bad ear-pa-on"
		[ "$(rv "$OPRE" ear_0x1bc)" = "00" ] || _bad="$_bad ear-dirty"
		[ $(( 0x$(rv "$OPRE" spken_0x1df) & 0x80 )) -eq 0 ] || _bad="$_bad spk-en-set"
		[ "$(dapm_kv "$D_PRE" "$OUT_KEY")" = "$OUT_NONE" ] || _bad="$_bad $OUT_KEY=$(dapm_kv "$D_PRE" "$OUT_KEY")"
	fi
	[ -n "$_bad" ] && { say "INVALID SETUP: not idle:$_bad"; return 1; }
	jrn "baseline idle: dapm held $DAPM_HELD_NONE, pin off, RCO, both PAs off"

	[ "${1:-}" = "arm" ] || return 0
	say ""
	say "  ==> PRESS VOLUME DOWN NOW to prove the abort path. ${HOLD_ARM} s."
	jrn "awaiting the arm-time Volume Down press, up to $HOLD_ARM s"
	"$GATE" --selftest-abort --timeout "$HOLD_ARM" --label armtime >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: no Volume Down press seen. Nothing armed."; return 1; }
	jrn "ABORT PATH PROVEN ON HARDWARE at arm time"
}

# ------------------------------------------------------------------ stream --
stream() {	# stream <n> <spec>
	_n=$1
	_spec=$2
	_side=$(printf '%s' "$_spec" | cut -d: -f1)
	_hv=$(printf '%s' "$_spec" | cut -d: -f2)
	_dv=$(printf '%s' "$_spec" | cut -d: -f3)
	eval "S${_n}_SPEC=\$_spec"
	jrn "=== stream $_n: begin -- spec $_spec ==="
	flag_ok "stream-$_n-start" || return 1

	# r185: the volumes, while the path is down (the controls hold them)
	if ! vol_set "$_hv" "$_dv"; then
		jrn "the volume controls did not read back $_hv / $_dv -- abort"
		dl_abort "volume-c$_n"
		return 1
	fi
	case "$OUTPUT" in
	hph) jrn "volumes: HPHL/HPHR $_hv (field $(dapm_spec_field "$_hv")), RX1/RX2 digital $_dv (0x$(dapm_spec_dig "$_dv"))" ;;
	spk) jrn "volumes: Speaker Volume $_hv (field $((8 - _hv))), RX7 digital $_dv (0x$(dapm_spec_dig "$_dv"))" ;;
	ear) jrn "volumes: Earpiece Volume $_hv, RX1 digital $_dv (0x$(dapm_spec_dig "$_dv"))" ;;
	esac
	case "$OUTPUT:$_side" in
	hph:L) jrn "stream $_n: tone on the LEFT only -- the mic on the LEFT earcup" ;;
	hph:R) jrn "stream $_n: tone on the RIGHT only -- the mic on the RIGHT earcup" ;;
	hph:B) jrn "stream $_n: tone on BOTH channels" ;;
	spk:*) jrn "stream $_n: SPEAKER, Speaker Volume $_hv -- the mic at its fixed spot over the grille" ;;
	ear:*) jrn "stream $_n: EARPIECE, Earpiece Volume $_hv -- the mic at its fixed spot over the earpiece slot" ;;
	esac

	jrn "GATE dapm-c$_n: waiting up to $HOLD_GO s for the approval in chat -- Volume Down aborts"
	pa_chat_wait "$APPROVE_DIR" "dapm-c$_n" "$HOLD_GO" "$FLAG" >/dev/null
	_rc=$?
	if [ "$_rc" != "0" ]; then
		jrn "GATE dapm-c$_n: not approved (rc $_rc) -- abort"
		dl_abort "gate-dapm-c$_n-rc$_rc"
		return 1
	fi
	jrn "GATE dapm-c$_n: APPROVED (chat)"
	flag_ok "gate-dapm-c$_n" || return 1

	failsafe_arm "stream-c$_n" || { dl_abort "failsafe-unavailable"; return 1; }

	pin_set 1 || { jrn "pin ON did not read back"; dl_abort "pin-on"; return 1; }
	_s=$(cat "$PGD/dapm_state" 2>/dev/null)
	eval "S${_n}_PINON=\$_s"
	jrn "pin ON; with no stream: $_s"
	if [ "$(dapm_held_key_is "$_s" "$OUT_KEY" "$OUT_NONE")" != "OK" ] ||
	   [ "$(dapm_held_is "$_s" "$DAPM_HELD_NONE")" != "OK" ]; then
		jrn "the pin alone powered something -- abort"
		dl_abort "pin-alone-powered"
		return 1
	fi
	flag_ok "pin-on-c$_n" || return 1

	jrn "tone: 1 kHz, $DBFS dBFS, side $_side, 250 ms tone/silence/tone/silence, one stream, DAPM-powered"
	"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" $TONE_ARM --side "$_side" >>"$JOURNAL" 2>&1 &
	TPID=$!
	#
	# WAIT FOR THE PATH, DON'T ASSUME IT. DAPM powers the whole chain inside
	# PCM prepare -- measured 1.2 s on the first r184 stream, because every
	# write is chip-verified -- and the SLIMbus channel only comes up in the
	# trigger after that. The first run sampled at a fixed 0.3 s like C3a (whose
	# path was up before the tone), saw held=03, and aborted a stream that was
	# still coming up. Its chip reads also landed on top of the channel setup.
	#
	# So: poll only cheap, lock-light state (dapm_state, slim_stream_state, no
	# chip reads) until DAPM holds all six stages AND the channel is up, then
	# take the chip-read sample inside the tone. Not there within the limit is
	# an abort, as before.
	#
	_w=0; _l=""; _up=0
	while [ "$_w" -lt "${LIVE_WAIT_DS:-50}" ]; do
		_l=$(cat "$PGD/dapm_state" 2>/dev/null)
		_up=$(rv "$(cat "$PGD/slim_stream_state" 2>/dev/null)" up)
		[ "$(dapm_held_key_is "$_l" "$OUT_KEY" "$OUT_ALL")" = "OK" ] && [ "$_up" = "1" ] && break
		kill -0 "$TPID" 2>/dev/null || break
		[ -e "$FLAG" ] && break
		sleep 0.1
		_w=$((_w + 1))
	done
	eval "S${_n}_UP_MS=$((_w * 100))"
	jrn "path wait: ~$((_w * 100)) ms, $OUT_KEY=$(dapm_kv "$_l" "$OUT_KEY") slim_up=$_up"
	flag_ok "path-wait-c$_n" || return 1
	sleep 0.1
	_l=$(cat "$PGD/dapm_state" 2>/dev/null)
	_p=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	_r=$(cat "$PGD/hphr_state" 2>/dev/null)
	_r1=$(cat "$PGD/rx1_digital_state" 2>/dev/null)
	_o=$(cat "$PGD/out_state" 2>/dev/null)
	eval "S${_n}_O=\$_o"
	_hs=$(hph_status)
	_cs=$(cat "$PGD/clk_source_state" 2>/dev/null)
	eval "S${_n}_LIVE=\$_l; S${_n}_PA=\$_p; S${_n}_HS=\$_hs; S${_n}_CS=\$_cs; S${_n}_R=\$_r; S${_n}_R1=\$_r1"
	jrn "live: $_l | 0x1ab=$(rv "$_p" pa_0x1ab) ocp=$(rv "$_p" ocp_seen) | 0x1b1=$(rv "$_p" dac_0x1b1) 0x1b7=$(rv "$_r" rdac_0x1b7) | 0x1ae=$(rv "$_p" lgain_0x1ae) 0x1b4=$(rv "$_r" rgain_0x1b4) | mclk_users=$(rv "$_cs" mclk_users) on_mclk=$(rv "$_cs" on_mclk) | $_hs"
	_bad=""
	[ "$(dapm_held_key_is "$_l" "$OUT_KEY" "$OUT_ALL")" = "OK" ] || _bad="$_bad $OUT_KEY=$(dapm_kv "$_l" "$OUT_KEY")"
	case "$OUTPUT" in
	hph) [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "$DAPM_PA_LIVE" ] || _bad="$_bad pa=$(rv "$_p" pa_0x1ab)" ;;
	spk) [ "$(rv "$_o" spk_pa)" = "1" ] || _bad="$_bad spk_pa=$(rv "$_o" spk_pa)"
	     [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] || _bad="$_bad hph-pa=$(rv "$_p" pa_0x1ab)" ;;
	ear) [ "$(rv "$_o" ear_pa)" = "1" ] || _bad="$_bad ear_pa=$(rv "$_o" ear_pa)"
	     [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] || _bad="$_bad hph-pa=$(rv "$_p" pa_0x1ab)" ;;
	esac
	[ "$(rv "$_p" ocp_seen)" = "0" ] || _bad="$_bad ocp"
	if [ -n "$_bad" ]; then
		jrn "THE PATH IS NOT IN ITS ONE LEGAL LIVE STATE:$_bad"
		dl_abort "live-state"
		return 1
	fi
	wait "$TPID"
	_t=$?
	TPID=""
	eval "S${_n}_TRC=\$_t"
	jrn "tone finished rc=$_t"
	flag_ok "after-tone-c$_n" || return 1

	# The stream has stopped; DAPM powers down at once (no pmdown delay on
	# this card). Polled, not assumed, for up to 3 s.
	_w=0
	while [ "$_w" -lt 30 ]; do
		[ "$(dapm_held_key_is "$(cat "$PGD/dapm_state" 2>/dev/null)" "$OUT_KEY" "$OUT_NONE")" = "OK" ] && break
		sleep 0.1
		_w=$((_w + 1))
	done
	_a=$(cat "$PGD/dapm_state" 2>/dev/null)
	_p=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	eval "S${_n}_DOWN_MS=$((_w * 100)); S${_n}_AFTER=\$_a; S${_n}_PAOFF=\$_p"
	jrn "after the stream (~$((_w * 100)) ms): $_a | 0x1ab=$(rv "$_p" pa_0x1ab)"

	pin_set 0 || jrn "pin OFF did not read back"
	_pin=$(pin_get)
	eval "S${_n}_PIN=\$_pin"

	eval "S${_n}_OAFTER=\$(cat \"\$PGD/out_state\" 2>/dev/null)"
	if all_pa_off &&
	   [ "$(dapm_held_key_is "$_a" "$OUT_KEY" "$OUT_NONE")" = "OK" ]; then
		failsafe_disarm
		jrn "fail-safe disarmed: the PA is chip-verified off and DAPM holds nothing"
	else
		jrn "THE PATH DID NOT COME DOWN WITH THE STREAM -- abort"
		dl_abort "not-down-c$_n"
		return 1
	fi
	jrn "=== stream $_n: complete ==="
	return 0
}

# -------------------------------------------------------------------- main --
case "${1:-}" in
check)
	resolve_expectations
	preflight noarm && { say "READY. Next: $0 launch"; exit 0; }
	exit 2 ;;
launch)
	CMD="systemd-run --unit=$UNIT --collect --setenv=OUTDIR=$OUTDIR"
	CMD="$CMD --setenv=DBFS=$DBFS --setenv=SPECS=$SPECS --setenv=HOLD_ARM=$HOLD_ARM"
	CMD="$CMD --setenv=OUTPUT=$OUTPUT --setenv=ESCALATE=$ESCALATE"
	CMD="$CMD --setenv=EXPECT_VERSION=${EXPECT_VERSION:-} sh $DIR/$(basename "$0") detached"
	say "  $CMD"
	exec $CMD ;;
detached) ;;
*)
	say "usage: $0 check|launch"
	exit 2 ;;
esac

resolve_expectations
if command -v flock >/dev/null 2>&1; then
	exec 9>"$RUNLOCK"
	flock -n 9 || { say "INVALID SETUP: another run holds $RUNLOCK"; exit 2; }
fi
jrn "================ DAPM listen run $STAMP ================"
jrn "stimulus $DBFS dBFS, $CYCLES stream(s): $SPEC_LIST"

trap 'jrn "SIGNAL -- running the teardown"; dl_abort signal; exit 3' INT TERM HUP

preflight arm || { jrn "preflight refused -- nothing armed, nothing written"; exit 2; }

FORCED_START=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
FORCED_START=${FORCED_START:-0}
FORCED_RING=$(sed -n 's/.*ring=\([0-9]*\).*/\1/p' "$PGD/forced_log" 2>/dev/null | head -n1)
FORCED_RING=${FORCED_RING:-16}
if [ $(( FORCED_START + OUT_FORCED * CYCLES )) -gt "$FORCED_RING" ]; then
	jrn "the forced-write journal holds $FORCED_START of $FORCED_RING -- this run would not fit; power cycle. Nothing armed."
	exit 2
fi
jrn "forced-write journal starts this run at $FORCED_START of $FORCED_RING"

mkdir -p "$APPROVE_DIR" && rm -f "$APPROVE_DIR"/* 2>/dev/null
rm -f "$FLAG" 2>/dev/null
"$GATE" --watch --flag "$FLAG" --lock "$GATELOCK" >>"$JOURNAL" 2>&1 &
WATCH_PID=$!
sleep 1
kill -0 "$WATCH_PID" 2>/dev/null || { jrn "THE ABORT WATCHER DID NOT STAY UP"; exit 2; }
jrn "abort watcher armed, pid $WATCH_PID"

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
jrn "front-end mixer enabled"

RC=0
n=1
for _sp in $SPEC_LIST; do
	stream "$n" "$_sp" || { RC=3; break; }
	n=$((n + 1))
done

failsafe_disarm
watch_stop
[ "$(pin_get)" = "0" ] || { pin_set 0; jrn "pin forced OFF at the end"; }
pins_all_off
# r185/r187: every volume back to its boot value
if vol_restore; then
	jrn "volumes restored: HPH, speaker, earpiece at their minimum; RX1/RX2 0 dB, RX7 -6 dB"
else
	jrn "THE VOLUMES DID NOT RESTORE -- check HPHL/HPHR Volume by hand"
fi
# r187: read AFTER the restore -- the "at their minimum" check is about the
# state the run leaves behind, and a run whose last stream was at full gain
# (Speaker Volume 8, field 0) failed it when this was read before.
OPOST=$(cat "$PGD/out_state" 2>/dev/null)
RPOST=$(cat "$PGD/hphr_state" 2>/dev/null)

D_POST=$(cat "$PGD/dapm_state" 2>/dev/null)
POST=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
DPOST=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
CPOST=$(cat "$PGD/clk_source_state" 2>/dev/null)
FLOG=$(cat "$PGD/forced_log" 2>/dev/null)
DMESG_FILE="/tmp/.wcd9320-dmesg-dapm-listen-$$"
snap_dmesg

open_output "$OUTDIR/wcd9320-dapm-listen-$STAMP.txt"
{
	hdr "what this run can and cannot establish"
	say "That plain stereo playback, with the Headphones pin on, powers the"
	say "proven path on both channels through DAPM in the mapped order, at the"
	say "volumes the controls set, and takes it down when the stream stops."
	say "WHETHER EACH SIDE WAS HEARD, and how loud, is decided by"
	say "tools/c3a-capture.py on the PC recording and by the operator."

	hdr "the run"
	say "aborted     : $ABORTED $ABORT_WHY"
	say "streams run : $((n - 1)) of $CYCLES"
	say "stimulus    : $DBFS dBFS, 1 kHz, tone/silence/tone/silence"
	say "output      : $OUTPUT (pin $OUT_PIN)"
	say "plan        : $SPEC_LIST"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_pi=\${S${c}_PINON:-}; _l=\${S${c}_LIVE:-}; _a=\${S${c}_AFTER:-}; _ms=\${S${c}_DOWN_MS:-?}; _hs=\${S${c}_HS:-?}"
		eval "_ums=\${S${c}_UP_MS:-?}; _sp=\${S${c}_SPEC:-?}"
		say "stream $c [$_sp]: held pin-on $(dapm_kv "$_pi" held) live $(dapm_kv "$_l" held) (~$_ums ms up) after $(dapm_kv "$_a" held) (~$_ms ms down) | hph $_hs"
		c=$((c + 1))
	done

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "card module version" "${CARDV:-}" "$DAPM_CARD_VERSION"
	check "the run was not aborted" "$ABORTED" "0"
	check "streams completed" "$((n - 1))" "$CYCLES"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_pi=\${S${c}_PINON:-}; _l=\${S${c}_LIVE:-}; _a=\${S${c}_AFTER:-}; _p=\${S${c}_PA:-}; _f=\${S${c}_PAOFF:-}; _cs=\${S${c}_CS:-}; _hs=\${S${c}_HS:-}; _t=\${S${c}_TRC:-}; _pin=\${S${c}_PIN:-}"
		eval "_r=\${S${c}_R:-}; _r1=\${S${c}_R1:-}; _sp=\${S${c}_SPEC:-::}"
		_hv=$(printf '%s' "$_sp" | cut -d: -f2)
		_dv=$(printf '%s' "$_sp" | cut -d: -f3)
		say ""
		say "-- stream $c [$_sp] --"
		check "s$c pin alone powers nothing" "$(dapm_kv "$_pi" "$OUT_KEY")" "$OUT_NONE"
		check "s$c DAPM holds the whole path live" "$(dapm_kv "$_l" "$OUT_KEY")" "$OUT_ALL"
		eval "_o=\${S${c}_O:-}; _oa=\${S${c}_OAFTER:-}"
		if [ "$OUTPUT" != "hph" ]; then
			check "s$c no HPH PA live" "$(pa_masked "$(rv "$_p" pa_0x1ab)")" "00"
			check "s$c headphone path untouched" "$(dapm_kv "$_l" held)" "$DAPM_HELD_NONE"
			check "s$c one MCLK user live" "$(rv "$_cs" mclk_users)" "1"
			check "s$c codec on MCLK live" "$(rv "$_cs" on_mclk)" "1"
			check "s$c tone played" "$_t" "0"
			if [ "$OUTPUT" = "spk" ]; then
				check "s$c speaker PA live (0x1df bit 7)" "$(printf '%02x' $(( 0x$(rv "$_o" spken_0x1df) & 0x80 )))" "80"
				check "s$c speaker gain = 8 - $_hv, register source" \
				      "$(printf '%02x' $(( 0x$(rv "$_o" spkgain_0x1e0) & 0x7c )))" \
				      "$(printf '%02x' $(( 0x04 | ((8 - ${_hv:-0}) << 3) )))"
				check "s$c power stage 24" "$(printf '%02x' $(( 0x$(rv "$_o" pwrstg_0x1e7) & 0x24 )))" "24"
				check "s$c RX7 mux L+R" "$(rv "$_o" mux_0x38e)" "65"
				check "s$c RX7 interpolator on" "$(printf '%02x' $(( 0x$(rv "$_o" rxclk_0x30f) & 0x40 )))" "40"
				check "s$c no speaker clip" "$(printf '%02x' $(( 0x$(rv "$_o" intr3_0x09b) & 0x08 )))" "00"
				check "s$c speaker PA off after" "$(printf '%02x' $(( 0x$(rv "$_oa" spken_0x1df) & 0x80 )))" "00"
			else
				check "s$c earpiece live (0x1bc DAC1 + switch + PA)" "$(rv "$_o" ear_0x1bc)" "70"
				check "s$c class-H in EAR mode" "$(rv "$_o" clsh_ear)" "1"
				check "s$c earpiece off after" "$(rv "$_oa" ear_0x1bc)" "00"
			fi
			check "s$c DAPM holds nothing after" "$(dapm_kv "$_a" "$OUT_KEY")" "$OUT_NONE"
			check "s$c pin OFF after" "$_pin" "0"
			c=$((c + 1))
			continue
		fi
		check "s$c both PAs live (0x1ab masked)" "$(pa_masked "$(rv "$_p" pa_0x1ab)")" "$DAPM_PA_LIVE"
		check "s$c HPHL DAC live (0x1b1)" "$(rv "$_p" dac_0x1b1)" "c0"
		check "s$c HPHR DAC live (0x1b7)" "$(rv "$_r" rdac_0x1b7)" "c0"
		_x=$(rv "$_p" lgain_0x1ae)
		check "s$c HPHL field live = 20 - $_hv" "$(printf '%02x' $(( 0x${_x:-ff} & 0x1f )))" "$(dapm_spec_field "${_hv:-0}")"
		_x=$(rv "$_r" rgain_0x1b4)
		check "s$c HPHR field live = 20 - $_hv" "$(printf '%02x' $(( 0x${_x:-ff} & 0x1f )))" "$(dapm_spec_field "${_hv:-0}")"
		check "s$c RX1 digital live" "$(rv "$_r1" gain_0x2b7)" "$(dapm_spec_dig "${_dv:-84}")"
		check "s$c RX2 digital live" "$(rv "$_r" vol_0x2bf)" "$(dapm_spec_dig "${_dv:-84}")"
		check "s$c RX2 chain live (0x2bd bit 5)" "$(printf '%02x' $(( 0x$(rv "$_r" chain_0x2bd) & 0x20 )))" "20"
		check "s$c one MCLK user live" "$(rv "$_cs" mclk_users)" "1"
		check "s$c codec on MCLK live" "$(rv "$_cs" on_mclk)" "1"
		check "s$c 0x1b3 clocked live" "$(printf '%s' "$_hs" | sed -n 's/.*1b3=\([0-9a-f]*\).*/\1/p')" "08"
		check "s$c tone played" "$_t" "0"
		check "s$c DAPM holds nothing after" "$(dapm_kv "$_a" held)" "$DAPM_HELD_NONE"
		check "s$c PA off after" "$(pa_masked "$(rv "$_f" pa_0x1ab)")" "00"
		check "s$c pin OFF after" "$_pin" "0"
		# r184: this increment was missing on the first full run, and the
		# report wrote stream 1's checks to /var/log until it was killed.
		c=$((c + 1))
	done

	say ""
	say "-- DAPM's own accounting --"
	check "DAPM ups this run" "$(dapm_delta "$D_PRE" "$D_POST" ups)" "$((OUT_STAGES * (n - 1)))"
	check "DAPM downs this run" "$(dapm_delta "$D_PRE" "$D_POST" downs)" "$((OUT_STAGES * (n - 1)))"
	check "DAPM refusals this run" "$(dapm_delta "$D_PRE" "$D_POST" refusals)" "0"
	check "DAPM failures this run" "$(dapm_delta "$D_PRE" "$D_POST" failures)" "0"
	check "DAPM holds nothing at the end" "$(dapm_kv "$D_POST" held) $(dapm_kv "$D_POST" spk_held) $(dapm_kv "$D_POST" ear_held)" "000 00 00"
	check "nobody holds MCLK at the end" "$(rv "$CPOST" mclk_users)" "0"
	check "codec back on RCO" "$(rv "$CPOST" on_mclk)" "0"
	check "guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no OCP fault" "$(rv "$POST" ocp_seen)" "0"
	check "PA enables == disables" "$(rv "$POST" enables)" "$(rv "$POST" disables)"

	say ""
	say "-- the forced writes, per stream ($OUT_FORCED for $OUTPUT) --"
	check "forced operations this run" "$(( $(rv "$FLOG" forced_n) - FORCED_START ))" \
	      "$(( OUT_FORCED * (n - 1) ))"
	_i=0
	while [ "$_i" -lt "$(( OUT_FORCED * (n - 1) ))" ]; do
		set -- $(dapm_forced_want_out "$OUTPUT" "$_i")
		_j=$(( FORCED_START + _i ))
		check "f$_j register" "$(rv "$FLOG" "f${_j}_reg")" "$1"
		check "f$_j mask" "$(rv "$FLOG" "f${_j}_mask")" "$2"
		check "f$_j direction" "$(rv "$FLOG" "f${_j}_dir")" "$3"
		_i=$((_i + 1))
	done

	say ""
	say "-- the teardown restored what it found --"
	check "gain restored" "$(rv "$POST" lgain_0x1ae)" "$(rv "$PRE" lgain_0x1ae)"
	check "wg ctl restored" "$(rv "$POST" wgctl_0x1ac)" "$(rv "$PRE" wgctl_0x1ac)"
	check "wg time restored" "$(rv "$POST" wgtime_0x1ad)" "$(rv "$PRE" wgtime_0x1ad)"
	check "wg ocp restored" "$(rv "$POST" wgocp_0x1a9)" "$(rv "$PRE" wgocp_0x1a9)"
	check "chopper restored" "$(rv "$POST" chop_0x1a5)" "$(rv "$PRE" chop_0x1a5)"
	check "DAC off" "$(rv "$DPOST" dac_0x1b1)" "00"
	check "DSM mux cleared" "$(rv "$DPOST" dsm_0x3b0)" "00"
	check "RX bias released" "$(rv "$DPOST" bias_refs)" "0"
	check "HPHR gain restored" "$(rv "$RPOST" rgain_0x1b4)" "$(rv "$RPRE" rgain_0x1b4)"
	check "HPHR DAC off" "$(rv "$RPOST" rdac_0x1b7)" "00"
	check "HPHR PA off, enables == disables" \
	      "$(rv "$RPOST" pa_on) $(rv "$RPOST" pa_enables)" "0 $(rv "$RPOST" pa_disables)"
	check "RX2 chain off" "$(printf '%02x' $(( 0x$(rv "$RPOST" chain_0x2bd) & 0x20 )))" "00"
	check "RDAC clocks clear (0x30d bits 1-2)" \
	      "$(printf '%02x' $(( 0x$(rv "$RPOST" rdacclk_0x30d) & 0x06 )))" "00"
	check "volumes back to boot values" \
	      "$(rv "$RPOST" gain_field_r) $(rv "$POST" gain_field) $(rv "$RPOST" vol_0x2bf)" "14 14 00"
	if [ -n "${OPOST:-}" ]; then
		check "speaker and earpiece at their minimum, PAs off" \
		      "$(rv "$OPOST" spk_field) $(rv "$OPOST" ear_field) $(rv "$OPOST" spk_pa) $(rv "$OPOST" ear_pa)" "8 7 0 0"
		check "speaker gain restored" "$(rv "$OPOST" spkgain_0x1e0)" "$(rv "$OPRE" spkgain_0x1e0)"
		check "earpiece gain restored" "$(rv "$OPOST" eargain_0x1bd)" "$(rv "$OPRE" eargain_0x1bd)"
		check "earpiece fully off" "$(rv "$OPOST" ear_0x1bc)" "00"
		check "RX7 off" "$(rv "$OPOST" rx7_on)" "0"
	fi

	hdr "dapm events (dmesg)"
	dmesg | grep -E 'dapm: |mclk: (get|put)' | tail -n 40

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1
rm -f "$DMESG_FILE"
sync
jrn "evidence written to $OUT"

[ "$ABORTED" = "0" ] || exit 3
[ "$FAIL_N" -eq 0 ] || exit 1
exit "$RC"

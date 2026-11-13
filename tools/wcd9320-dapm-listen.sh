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
# r188: OUTPUT=lo, all four line outputs as one output (LO_OUT, the "Lineout"
# pin). vol is Lineout Volume 0..20 (0 = minimum), dig the RX3 and RX5 digital
# volume. LO_SELECT (1..15, default 15) is the Lineout Select mask, for
# bisecting which LINEOUTs matter. docs/audio/wcd9320-r188-lineout-mapping.md.
#
# r189: OUTPUT=i2s, the loudspeaker on Secondary MI2S (the "Loudspeaker" pin,
# docs/audio/r189-sec-mi2s-speaker-mapping.md). The route is the SEC_MI2S mixer
# with the SLIMbus mixer OFF; there is no analog or digital gain (spec
# B:0:84), so the level is the tone's alone, from -60 dBFS. The live state is
# the amplifier's i2s_spk_state, cross-checked against the regulator class
# and the pinmux; the codec must hold nothing throughout.
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
MIXER="${MIXER:-}"
DBFS="${DBFS:--40}"
# r187: Section 23's declared escalation. -40 is the default and needs
# nothing. -30 and -20 (pcm-tone's compiled ceiling) are allowed only with
# ESCALATE=declared on the command line, which the operator gives in chat for
# that run; then, and only then, pcm-tone gets --armed-escalation. Any other
# level is refused here, before anything is armed.
ESCALATE="${ESCALATE:-}"
TONE_ARM=""
case "$DBFS" in
-60|-50|-40) ;;
-30|-20)
	[ "$ESCALATE" = "declared" ] ||
		{ echo "INVALID SETUP: DBFS=$DBFS is an escalation -- it needs ESCALATE=declared"; exit 2; }
	TONE_ARM="--armed-escalation" ;;
*)	echo "INVALID SETUP: DBFS=$DBFS (allowed: -60, -50, -40, or -30/-20 with ESCALATE=declared)"; exit 2 ;;
esac
OUTPUT="${OUTPUT:-hph}"
dapm_out "$OUTPUT" || { echo "INVALID SETUP: OUTPUT=$OUTPUT (hph, spk, ear, lo or i2s)"; exit 2; }
# r190: HOLD_5V=i2s plays a CODEC output (lo or ear) with the PM8941 5 V rail
# held up for the whole stream by the I2S back end alongside it: one stream,
# both routes, the Loudspeaker pin on with the output's own pin. It answers
# "is the loudspeaker an analog amp on a codec output, powered from the boost?"
# without a rebuild. The I2S side carries the same tone to TLMM 79-82.
HOLD_5V="${HOLD_5V:-}"
# Step 2 (after r192): RAIL5V=off asks "does the loudspeaker need the 5 V
# rail?". It is for an image whose I2S component has no real vdd (vdd-supply
# patched to phandle 0 -> the regulator core's dummy), so the PM8941 5 V boost
# must stay DISABLED through the whole stream; everything else as r192.
RAIL5V="${RAIL5V:-auto}"	# r193: auto = from the component's vdd_present
case "$RAIL5V:$OUTPUT" in
on:*|auto:*|off:i2s) ;;
*) echo "INVALID SETUP: RAIL5V=$RAIL5V with OUTPUT=$OUTPUT (RAIL5V=off is for i2s)"; exit 2 ;;
esac
RAIL_LIVE=enabled; [ "$RAIL5V" = "off" ] && RAIL_LIVE=disabled
# r193: the speaker gain the I2S streams expect (the Loudspeaker Volume default)
SPK_GAIN_RAW="${SPK_GAIN_RAW:-22}"
case "$SPK_GAIN_RAW" in
''|*[!0-9]*) echo "INVALID SETUP: SPK_GAIN_RAW=$SPK_GAIN_RAW (0..22)"; exit 2 ;;
esac
[ "$SPK_GAIN_RAW" -le 22 ] || { echo "INVALID SETUP: SPK_GAIN_RAW=$SPK_GAIN_RAW above 22 (+15 dB)"; exit 2; }
# r191: AMP=visa powers the VISA speaker amplifier (Windows' power-on script)
# around each stream of a codec output, and standby + GPIO20 low after it;
# every abort and teardown powers it off too. The amplifier's input is
# unknown, so this is how each codec output -- and r189's I2S port -- is probed
# with it on.
AMP="${AMP:-}"
case "$AMP:$OUTPUT" in
:*|visa:spk|visa:ear|visa:lo|visa:hph) ;;
# r192: on the I2S path the card's DAPM owns the amplifier; the runner must not
*) echo "INVALID SETUP: AMP=$AMP with OUTPUT=$OUTPUT (AMP=visa is for spk, ear, lo or hph; i2s powers it through DAPM)"; exit 2 ;;
esac
# r194: EAR_CMBUFF=clear|keep[,...] -- RX_EAR_CMBUFF bit 0 per earpiece
# stream, written through the codec's ear_cmbuff before each stream: clear is
# Windows' ADIE (bit 0 cleared at DAC1 on), keep is r187 (never written). One
# value for every stream, or one per stream with the last repeating. Unset:
# the driver's mode is used and only recorded.
EAR_CMBUFF="${EAR_CMBUFF:-}"
case "$EAR_CMBUFF:$OUTPUT" in
:*) ;;
*:ear) ear_cmbuff_list_ok "$EAR_CMBUFF" ||
	{ echo "INVALID SETUP: EAR_CMBUFF=$EAR_CMBUFF (clear or keep, comma-separated per stream)"; exit 2; } ;;
*) echo "INVALID SETUP: EAR_CMBUFF=$EAR_CMBUFF with OUTPUT=$OUTPUT (it is for ear)"; exit 2 ;;
esac
# r195: EAR_ORDER=downstream|windows[,...] -- the earpiece power-up order per
# stream, through the codec's ear_order: downstream is class-H EAR then DAC1
# (r187-r194), windows is DAC1 then class-H (qcauddev8974.sys). Unset: the
# driver's order is used and recorded.
EAR_ORDER="${EAR_ORDER:-}"
case "$EAR_ORDER:$OUTPUT" in
:*) ;;
*:ear) ear_order_list_ok "$EAR_ORDER" ||
	{ echo "INVALID SETUP: EAR_ORDER=$EAR_ORDER (downstream or windows, comma-separated per stream)"; exit 2; } ;;
*) echo "INVALID SETUP: EAR_ORDER=$EAR_ORDER with OUTPUT=$OUTPUT (it is for ear)"; exit 2 ;;
esac
# r195: SNAP=1 -- the codec reads the chip once at each stream's PA on
# (reg_snap; read only), for the EAR-vs-HPH register diff. hph or ear.
SNAP="${SNAP:-0}"
case "$SNAP:$OUTPUT" in
0:*)   SNAP_LABEL="" ;;
1:ear) SNAP_LABEL=ear ;;
1:hph) SNAP_LABEL=hph ;;
*) echo "INVALID SETUP: SNAP=$SNAP with OUTPUT=$OUTPUT (SNAP=1 is for hph or ear)"; exit 2 ;;
esac
case "$HOLD_5V:$OUTPUT" in
:*|i2s:lo|i2s:ear) ;;
*) echo "INVALID SETUP: HOLD_5V=$HOLD_5V with OUTPUT=$OUTPUT (HOLD_5V=i2s is for lo or ear)"; exit 2 ;;
esac
# r189: one front-end route at a time -- this output's mixer on, the other off
if [ "$OUTPUT" = "i2s" ]; then
	MIXER="${MIXER:-$I2S_MIXER}"; OTHER_MIXER="$SLIM_MIXER"
else
	MIXER="${MIXER:-$SLIM_MIXER}"; OTHER_MIXER="$I2S_MIXER"
fi
LO_SELECT="${LO_SELECT:-15}"
case "$LO_SELECT" in
1|2|3|4|5|6|7|8|9|10|11|12|13|14|15) ;;
*) echo "INVALID SETUP: LO_SELECT=$LO_SELECT (1..15)"; exit 2 ;;
esac
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
	for _po in "Headphones Switch" "Speaker Switch" "Earpiece Switch" "Lineout Switch" "Loudspeaker Switch"; do
		"$SETCTL" -D "$CTLDEV" --set "$_po" 0 >/dev/null 2>&1
	done
}
# r187/r188: 0 when every PA is chip-verified off -- HPH, speaker, earpiece, line outs
# r189: and the I2S amplifier unpowered -- its component AND the regulator class
all_pa_off() {
	_ap=$(rv "$(cat "${PGD:-/nonexistent}/hphl_pa_state" 2>/dev/null)" pa_0x1ab)
	_ao=$(cat "${PGD:-/nonexistent}/out_state" 2>/dev/null)
	[ -n "$_ap" ] && [ "$(pa_masked "$_ap")" = "00" ] || return 1
	_ai=$(i2s_state)
	if [ -n "$_ai" ]; then
		[ "$(rv "$_ai" supply_on)" = "0" ] || return 1
		[ "$(vreg_5v | cut -d' ' -f1)" = "disabled" ] || return 1
	fi
	# r191: the VISA amplifier in standby, GPIO20 low
	_av=$(visa_state)
	if [ -n "$_av" ]; then
		[ "$(rv "$_av" powered) $(rv "$_av" gpio)" = "0 0" ] || return 1
	fi
	[ -n "$_ao" ] || return 0
	[ $(( 0x$(rv "$_ao" spken_0x1df) & 0x80 )) -eq 0 ] &&
	[ $(( 0x$(rv "$_ao" ear_0x1bc) & 0x10 )) -eq 0 ] &&
	[ $(( 0x$(rv "$_ao" locnp_0x1ca) & 0x0f )) -eq 0 ]
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
	lo)  ctl_set "Lineout Volume" "$1" && ctl_set "RX3 Digital Volume" "$2" &&
	     ctl_set "RX5 Digital Volume" "$2" && ctl_set "Lineout Select" "$LO_SELECT" ;;
	# r193: the Loudspeaker Volume control (TAS2552 PGA_GAIN), 0..22 = -7..+15 dB
	i2s) ctl_set "Loudspeaker Volume" "$SPK_GAIN_RAW" ;;
	esac
}
# r189: the output's whole path is up (the wait) / down (after the stream)
path_ready() {	# path_ready <dapm_state>
	case "$OUTPUT" in
	i2s) _pr=$(i2s_state)
	     [ "$(rv "$_pr" supply_on)" = "1" ] && [ "$(rv "$_pr" pins_active)" = "1" ] &&
	     [ "$(rv "$_pr" bclk_on)" = "1" ] ;;
	*)   [ "$(dapm_held_key_is "$1" "$OUT_KEY" "$OUT_ALL")" = "OK" ] &&
	     [ "$(rv "$(cat "$PGD/slim_stream_state" 2>/dev/null)" up)" = "1" ] ;;
	esac
}
path_down() {	# path_down <dapm_state>
	[ "$(dapm_held_key_is "$1" "$OUT_KEY" "$OUT_NONE")" = "OK" ] || return 1
	[ "$OUTPUT" = "i2s" ] || [ -n "$HOLD_5V" ] || return 0
	_pd=$(i2s_state)
	[ "$(rv "$_pd" supply_on)" = "0" ] && [ "$(rv "$_pd" bclk_on)" = "0" ]
}
# r187: every output back to its boot value
vol_restore() {
	ctl_set "HPHL Volume" 0 && ctl_set "HPHR Volume" 0 &&
	ctl_set "RX1 Digital Volume" 84 && ctl_set "RX2 Digital Volume" 84 &&
	ctl_set "Speaker Volume" 0 && ctl_set "Earpiece Volume" 0 &&
	ctl_set "RX7 Digital Volume" 78 &&
	ctl_set "Lineout Volume" 0 && ctl_set "Lineout Select" 15 &&
	ctl_set "RX3 Digital Volume" 84 && ctl_set "RX5 Digital Volume" 84
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
	[ "$OUTPUT" != "i2s" ] || [ -n "$(i2s_state_file)" ] ||
		{ say "INVALID SETUP: no i2s_spk_state -- not r189"; return 1; }

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
		# r194: no CMBUFF inverse owed, and the switch present when asked for
		[ "$(rv "$OPRE" ear_cmbuff_cleared)" != "1" ] || _bad="$_bad ear-cmbuff-owed"
		CMPRE=$(rv "$(cat "$PGD/ear_cmbuff" 2>/dev/null)" mode)
		[ -z "$EAR_CMBUFF" ] || [ -n "$CMPRE" ] || _bad="$_bad no-ear_cmbuff"
		# r195: the order switch present when asked for; the snapshot present and idle
		ORPRE=$(rv "$(cat "$PGD/ear_order" 2>/dev/null)" order)
		[ -z "$EAR_ORDER" ] || [ -n "$ORPRE" ] || _bad="$_bad no-ear_order"
		if [ "$SNAP" = "1" ]; then
			_sp=$(head -n1 "$PGD/reg_snap" 2>/dev/null)
			[ -n "$_sp" ] || _bad="$_bad no-reg_snap"
			[ "$(rv "$_sp" armed)" != "1" ] || _bad="$_bad reg-snap-armed"
		fi
		[ $(( 0x$(rv "$OPRE" spken_0x1df) & 0x80 )) -eq 0 ] || _bad="$_bad spk-en-set"
		[ "$(rv "$OPRE" lo_pa)" = "0" ] || _bad="$_bad lo-pa-on"
		[ "$(rv "$OPRE" locnp_0x1ca)" = "00" ] || _bad="$_bad lo-cnp-set"
		[ "$(rv "$OPRE" clsh_lo)" = "0" ] || _bad="$_bad clsh-lo-on"
		[ "$(dapm_kv "$D_PRE" "$OUT_KEY")" = "$OUT_NONE" ] || _bad="$_bad $OUT_KEY=$(dapm_kv "$D_PRE" "$OUT_KEY")"
	fi
	# r191: the VISA amplifier off -- whatever this run's output is
	APRE=$(visa_state)
	[ -z "$AMP" ] || [ -n "$APRE" ] || _bad="$_bad no-visa-amp"
	[ -z "$APRE" ] || [ "$(rv "$APRE" powered) $(rv "$APRE" gpio)" = "0 0" ] || _bad="$_bad visa-on"
	# r189: the I2S amplifier idle -- whatever this run's output is
	IPRE=$(i2s_state)
	# r193: no vdd in DT (vdd_present=0) means the rail must stay off
	if [ "$RAIL5V" = "auto" ]; then
		if [ -n "$IPRE" ] && [ "$(rv "$IPRE" vdd_present)" = "0" ]; then
			RAIL5V=off; RAIL_LIVE=disabled
		else
			RAIL5V=on; RAIL_LIVE=enabled
		fi
	fi
	VPRE=$(vreg_5v)
	MPRE=$(mi2s_mux)
	if [ -n "$IPRE" ]; then
		[ "$(rv "$IPRE" supply_on) $(rv "$IPRE" pins_active) $(rv "$IPRE" bclk_on)" = "0 0 0" ] ||
			_bad="$_bad i2s-not-idle"
		[ "$(printf '%s' "$VPRE" | cut -d' ' -f1)" = "disabled" ] || _bad="$_bad 5v-rail-on($VPRE)"
		[ "$MPRE" = "gpio gpio gpio gpio" ] || _bad="$_bad mi2s-pins=$MPRE"
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
	lo)  jrn "volumes: Lineout Volume $_hv (field $(dapm_spec_field "$_hv")), RX3/RX5 digital $_dv (0x$(dapm_spec_dig "$_dv")), Lineout Select $LO_SELECT" ;;
	i2s) jrn "volumes: Loudspeaker Volume $SPK_GAIN_RAW ($((SPK_GAIN_RAW - 7)) dB), tone $DBFS dBFS" ;;
	esac
	case "$OUTPUT:$_side" in
	hph:L) jrn "stream $_n: tone on the LEFT only -- the mic on the LEFT earcup" ;;
	hph:R) jrn "stream $_n: tone on the RIGHT only -- the mic on the RIGHT earcup" ;;
	hph:B) jrn "stream $_n: tone on BOTH channels" ;;
	spk:*) jrn "stream $_n: SPEAKER, Speaker Volume $_hv -- the mic at its fixed spot over the grille" ;;
	ear:*) jrn "stream $_n: EARPIECE, Earpiece Volume $_hv -- the mic at its fixed spot over the earpiece slot" ;;
	lo:*)  jrn "stream $_n: LINE OUTS (select $LO_SELECT), Lineout Volume $_hv -- the mic at its fixed spot" ;;
	i2s:*) jrn "stream $_n: LOUDSPEAKER on Secondary MI2S, $DBFS dBFS, side $_side, 5 V rail $RAIL5V -- the mic at the grille" ;;
	esac

	# r194: this stream's RX_EAR_CMBUFF mode, written while the path is down
	_cm=""
	if [ "$OUTPUT" = "ear" ]; then
		if [ -n "$EAR_CMBUFF" ]; then
			_cm=$(ear_cmbuff_for "$EAR_CMBUFF" "$_n")
			echo "$_cm" > "$PGD/ear_cmbuff" 2>/dev/null
		fi
		_cmr=$(rv "$(cat "$PGD/ear_cmbuff" 2>/dev/null)" mode)
		if [ -n "$_cm" ] && [ "$_cmr" != "$_cm" ]; then
			jrn "RX_EAR_CMBUFF mode did not read back $_cm (got '$_cmr') -- abort"
			dl_abort "ear-cmbuff-c$_n"
			return 1
		fi
		_cm=$_cmr
		eval "S${_n}_CMB=\$_cm"
		case "$_cm" in
		clear) jrn "RX_EAR_CMBUFF: clear (Windows: bit 0 cleared at DAC1 on, restored after)" ;;
		keep)  jrn "RX_EAR_CMBUFF: keep (r187: never written)" ;;
		*)     jrn "RX_EAR_CMBUFF: no switch on this module" ;;
		esac
	fi

	# r195: this stream's earpiece order, written while the path is down
	if [ "$OUTPUT" = "ear" ] && [ -n "$EAR_ORDER" ]; then
		_eo=$(ear_cmbuff_for "$EAR_ORDER" "$_n")
		echo "$_eo" > "$PGD/ear_order" 2>/dev/null
		_eor=$(cat "$PGD/ear_order" 2>/dev/null)
		if [ "$(rv "$_eor" order)" != "$_eo" ]; then
			jrn "EAR order did not read back $_eo (got '$_eor') -- abort"
			dl_abort "ear-order-c$_n"
			return 1
		fi
		eval "S${_n}_ORD=\$_eo; S${_n}_ORU0=$(rv "$_eor" windows_ups)"
		case "$_eo" in
		windows)    jrn "EAR ORDER: windows (DAC1 switch + power + CMBUFF, THEN class-H EAR)" ;;
		downstream) jrn "EAR ORDER: downstream (class-H EAR PRE_DAC, then DAC1)" ;;
		esac
	fi
	# r195: SNAP=1 -- arm the one-shot snapshot for this stream's PA on
	if [ "$SNAP" = "1" ]; then
		eval "S${_n}_SNT0=$(rv "$(head -n1 "$PGD/reg_snap" 2>/dev/null)" takes)"
		echo arm > "$PGD/reg_snap" 2>/dev/null
		if [ "$(rv "$(head -n1 "$PGD/reg_snap" 2>/dev/null)" armed)" != "1" ]; then
			jrn "register snapshot did not arm -- abort"
			dl_abort "reg-snap-c$_n"
			return 1
		fi
		jrn "register snapshot armed: the codec reads the chip once, at this stream's PA on"
	fi

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

	# r191: the VISA amplifier on BEFORE the pin -- Windows' script, read back
	if [ -n "$AMP" ]; then
		_a0=$(visa_state)
		visa_power 1
		_a1=$(visa_state)
		eval "S${_n}_VISAON=\$_a1"
		jrn "visa power on: $_a1"
		if [ "$(rv "$_a1" powered) $(rv "$_a1" gpio)" != "1 1" ] ||
		   [ "$(rv "$_a1" i2c_errors)" != "$(rv "$_a0" i2c_errors)" ]; then
			jrn "THE VISA AMPLIFIER DID NOT POWER ON CLEANLY -- abort"
			dl_abort "visa-on-c$_n"
			return 1
		fi
		_mm=$(( $(rv "$_a1" verify_mismatches) - $(rv "$_a0" verify_mismatches) ))
		eval "S${_n}_VISAMM=\$_mm"
		jrn "visa: $_mm read-back mismatch(es) in the script (last $(rv "$_a1" last_mismatch) reg:want:got)"
		flag_ok "visa-on-c$_n" || return 1
	fi

	pin_set 1 || { jrn "pin ON did not read back"; dl_abort "pin-on"; return 1; }
	if [ -n "$HOLD_5V" ]; then
		ctl_set "Loudspeaker Switch" 1 || { jrn "Loudspeaker pin ON did not read back"; dl_abort "hold-pin-on"; return 1; }
	fi
	_s=$(cat "$PGD/dapm_state" 2>/dev/null)
	eval "S${_n}_PINON=\$_s"
	jrn "pin ON; with no stream: $_s"
	_is=$(i2s_state)
	eval "S${_n}_I2SPIN=\$_is"
	if [ "$(dapm_held_key_is "$_s" "$OUT_KEY" "$OUT_NONE")" != "OK" ] ||
	   [ "$(dapm_held_is "$_s" "$DAPM_HELD_NONE")" != "OK" ] ||
	   { [ -n "$_is" ] && [ "$(rv "$_is" supply_on)" != "0" ]; }; then
		jrn "the pin alone powered something -- abort"
		dl_abort "pin-alone-powered"
		return 1
	fi
	flag_ok "pin-on-c$_n" || return 1

	jrn "tone: 1 kHz, $DBFS dBFS, side $_side, 250 ms tone/silence/tone/silence, one stream, DAPM-powered"
	"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" $TONE_ARM --side "$_side" >>"$JOURNAL" 2>&1 &
	TPID=$!
	# r195b: INTR_STATUS2 through the tone -- bit 2 EAR_PA_OCPL_FAULT, bit 5
	# EAR_PA_STARTUP (0/1 HPH OCP, 3/4 HPH start-up), all masked as irqs and
	# never sampled live before. Read only (irq_live), in the background, so
	# nothing else waits on it; it ends by itself after ~3 s.
	OCPW_PID=""
	if [ "$OUTPUT" = "ear" ] || [ "$OUTPUT" = "hph" ]; then
		_ocf="$OUTDIR/wcd9320-intr2-$STAMP-s$_n.txt"
		( _k=0
		  while [ "$_k" -lt 80 ]; do
			sed -n 's/^status=[0-9a-f]* [0-9a-f]* \([0-9a-f]*\) .*/\1/p' "$PGD/irq_live" 2>/dev/null
			_k=$((_k + 1))
			sleep 0.025
		  done ) > "$_ocf" 2>&1 &
		OCPW_PID=$!
	fi
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
		path_ready "$_l" && break
		kill -0 "$TPID" 2>/dev/null || break
		[ -e "$FLAG" ] && break
		sleep 0.1
		_w=$((_w + 1))
	done
	eval "S${_n}_UP_MS=$((_w * 100))"
	# r189: the I2S amplifier and its two oracles, sampled ONCE, here, the
	# moment the path is up -- the tone lasts ~1 s, and the first r189 stream's
	# later re-sample read the pins after they had gone back to sleep.
	_i=$(i2s_state); _v=$(vreg_5v); _m=$(mi2s_mux)
	# step 4: the amplifier too, in the same early snapshot -- sampled late, the
	# right-only stream read it after its 1 s tone had ended (visa=00)
	_vl=$(visa_state)
	_su=$(rv "$(cat "$PGD/slim_stream_state" 2>/dev/null)" up)
	jrn "path wait: ~$((_w * 100)) ms, $OUT_KEY=$(dapm_kv "$_l" "$OUT_KEY") slim_up=$_up"
	[ "$OUTPUT" != "i2s" ] || jrn "i2s: $_i | 5V $_v | mux $_m"
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
	eval "S${_n}_I2S=\$_i; S${_n}_V5=\$_v; S${_n}_MUX=\$_m; S${_n}_SLIM=\$_su"
	eval "S${_n}_VISALIVE=\$_vl"
	jrn "live: $_l | 0x1ab=$(rv "$_p" pa_0x1ab) ocp=$(rv "$_p" ocp_seen) | 0x1b1=$(rv "$_p" dac_0x1b1) 0x1b7=$(rv "$_r" rdac_0x1b7) | 0x1ae=$(rv "$_p" lgain_0x1ae) 0x1b4=$(rv "$_r" rgain_0x1b4) | mclk_users=$(rv "$_cs" mclk_users) on_mclk=$(rv "$_cs" on_mclk) | $_hs"
	_bad=""
	[ "$(dapm_held_key_is "$_l" "$OUT_KEY" "$OUT_ALL")" = "OK" ] || _bad="$_bad $OUT_KEY=$(dapm_kv "$_l" "$OUT_KEY")"
	case "$OUTPUT" in
	hph) [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "$DAPM_PA_LIVE" ] || _bad="$_bad pa=$(rv "$_p" pa_0x1ab)" ;;
	spk) [ "$(rv "$_o" spk_pa)" = "1" ] || _bad="$_bad spk_pa=$(rv "$_o" spk_pa)"
	     [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] || _bad="$_bad hph-pa=$(rv "$_p" pa_0x1ab)"
	     # r190: the class-D powered -- the driver's view and the regulator class
	     if [ "$(rv "$_o" spkdrv_present)" = "1" ]; then
		[ "$(rv "$_o" spkdrv)" = "1" ] || _bad="$_bad spkdrv=$(rv "$_o" spkdrv)"
		[ "$(printf '%s' "$_v" | cut -d' ' -f1)" = "enabled" ] || _bad="$_bad 5v=$_v"
	     fi ;;
	ear) [ -z "$HOLD_5V" ] || [ "$(printf '%s' "$_v" | cut -d' ' -f1)" = "enabled" ] || _bad="$_bad held-5v=$_v"
	     [ "$(rv "$_o" ear_pa)" = "1" ] || _bad="$_bad ear_pa=$(rv "$_o" ear_pa)"
	     # r194: CMBUFF as this stream asked -- cleared live, or untouched
	     _cb=$(rv "$_o" cmbuff_0x1be)
	     jrn "ear live: mode ${_cm:-?} cmbuff_0x1be=${_cb:-?} cleared=$(rv "$_o" ear_cmbuff_cleared) earstat_0x1c5=$(rv "$_o" earstat_0x1c5)"
	     case "$_cm" in
	     clear) [ "$(( 0x${_cb:-ff} & 1 )) $(rv "$_o" ear_cmbuff_cleared)" = "0 1" ] || _bad="$_bad cmbuff=$_cb" ;;
	     keep)  [ "$_cb $(rv "$_o" ear_cmbuff_cleared)" = "$(rv "$OPRE" cmbuff_0x1be) 0" ] || _bad="$_bad cmbuff=$_cb" ;;
	     esac
	     [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] || _bad="$_bad hph-pa=$(rv "$_p" pa_0x1ab)" ;;
	lo)  [ -z "$HOLD_5V" ] || [ "$(printf '%s' "$_v" | cut -d' ' -f1)" = "enabled" ] || _bad="$_bad held-5v=$_v"
	     [ "$(rv "$_o" lo_pa)" = "1" ] || _bad="$_bad lo_pa=$(rv "$_o" lo_pa)"
	     [ $(( 0x$(rv "$_o" locnp_0x1ca) )) -eq "$LO_SELECT" ] || _bad="$_bad cnp=$(rv "$_o" locnp_0x1ca)"
	     [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] || _bad="$_bad hph-pa=$(rv "$_p" pa_0x1ab)" ;;
	i2s) [ "$(rv "$_i" supply_on) $(rv "$_i" pins_active) $(rv "$_i" bclk_on)" = "1 1 1" ] ||
	         _bad="$_bad i2s=$(rv "$_i" supply_on)$(rv "$_i" pins_active)$(rv "$_i" bclk_on)"
	     [ "$(rv "$_i" errors)" = "$(rv "$IPRE" errors)" ] || _bad="$_bad i2s-errors=$(rv "$_i" errors)"
	     [ "$(printf '%s' "$_v" | cut -d' ' -f1)" = "$RAIL_LIVE" ] || _bad="$_bad 5v=$_v(want $RAIL_LIVE)"
	     [ "$_m" = "sec_mi2s sec_mi2s sec_mi2s sec_mi2s" ] || _bad="$_bad mux=$_m"
	     [ "$_su" = "0" ] || _bad="$_bad slim-up"
	     # r192: the amplifier powered by DAPM with the path
	     [ -z "$_vl" ] || [ "$(rv "$_vl" powered) $(rv "$_vl" dapm_held)" = "1 1" ] ||
	         _bad="$_bad visa=$(rv "$_vl" powered)$(rv "$_vl" dapm_held)"
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
	if [ -n "$OCPW_PID" ]; then
		wait "$OCPW_PID" 2>/dev/null
		OCPW_PID=""
		_os=$(intr2_summary "$_ocf")
		eval "S${_n}_INTR2=\$_os"
		jrn "INTR_STATUS2 through the tone: $_os -> $_ocf"
	fi
	flag_ok "after-tone-c$_n" || return 1

	# The stream has stopped; DAPM powers down at once (no pmdown delay on
	# this card). Polled, not assumed, for up to 3 s.
	_w=0
	while [ "$_w" -lt 30 ]; do
		path_down "$(cat "$PGD/dapm_state" 2>/dev/null)" && break
		sleep 0.1
		_w=$((_w + 1))
	done
	_a=$(cat "$PGD/dapm_state" 2>/dev/null)
	_p=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	eval "S${_n}_DOWN_MS=$((_w * 100)); S${_n}_AFTER=\$_a; S${_n}_PAOFF=\$_p"
	jrn "after the stream (~$((_w * 100)) ms): $_a | 0x1ab=$(rv "$_p" pa_0x1ab)"
	# r195: the snapshot and the order counter, read once the path is down
	if [ "$SNAP" = "1" ]; then
		_sf="$OUTDIR/wcd9320-regsnap-$STAMP-s$_n.txt"
		cat "$PGD/reg_snap" > "$_sf" 2>/dev/null
		_sh=$(head -n1 "$_sf" 2>/dev/null)
		echo disarm > "$PGD/reg_snap" 2>/dev/null
		eval "S${_n}_SNH=\$_sh; S${_n}_SNF=\$_sf"
		jrn "register snapshot: $_sh -> $_sf"
	fi
	if [ "$OUTPUT" = "ear" ] && [ -n "$EAR_ORDER" ]; then
		eval "S${_n}_ORU1=$(rv "$(cat "$PGD/ear_order" 2>/dev/null)" windows_ups)"
	fi

	pin_set 0 || jrn "pin OFF did not read back"
	[ -z "$HOLD_5V" ] || ctl_set "Loudspeaker Switch" 0 || jrn "Loudspeaker pin OFF did not read back"
	# r191: the VISA amplifier to standby, GPIO20 low, after the pin
	if [ -n "$AMP" ]; then
		visa_power 0
		_a2=$(visa_state)
		eval "S${_n}_VISAOFF=\$_a2"
		jrn "visa power off: $_a2"
	fi
	_pin=$(pin_get)
	eval "S${_n}_PIN=\$_pin"

	eval "S${_n}_OAFTER=\$(cat \"\$PGD/out_state\" 2>/dev/null)"
	_ia=$(i2s_state); _va=$(vreg_5v); _ma=$(mi2s_mux)
	_vaf=$(visa_state); eval "S${_n}_VISAAFTER=\$_vaf"
	eval "S${_n}_I2SA=\$_ia; S${_n}_V5A=\$_va; S${_n}_MUXA=\$_ma"
	[ "$OUTPUT" != "i2s" ] || jrn "i2s after: $_ia | 5V $_va | mux $_ma"
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
	CMD="$CMD --setenv=OUTPUT=$OUTPUT --setenv=ESCALATE=$ESCALATE --setenv=LO_SELECT=$LO_SELECT"
	[ -z "$HOLD_5V" ] || CMD="$CMD --setenv=HOLD_5V=$HOLD_5V"
	[ -z "$AMP" ] || CMD="$CMD --setenv=AMP=$AMP"
	[ "$RAIL5V" = "auto" ] || CMD="$CMD --setenv=RAIL5V=$RAIL5V"
	[ "$SPK_GAIN_RAW" = "22" ] || CMD="$CMD --setenv=SPK_GAIN_RAW=$SPK_GAIN_RAW"
	[ -z "$EAR_CMBUFF" ] || CMD="$CMD --setenv=EAR_CMBUFF=$EAR_CMBUFF"
	[ -z "$EAR_ORDER" ] || CMD="$CMD --setenv=EAR_ORDER=$EAR_ORDER"
	[ "$SNAP" = "0" ] || CMD="$CMD --setenv=SNAP=$SNAP"
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

# r189: the other route OFF first, so one stream reaches one back end
ctl_set "$OTHER_MIXER" 0 || { jrn "$OTHER_MIXER would not go off -- nothing armed"; exit 2; }
ctl_set "$MIXER" 1 || { jrn "$MIXER would not go on -- nothing armed"; exit 2; }
jrn "front-end mixer enabled: $MIXER (and $OTHER_MIXER off)"
if [ -n "$HOLD_5V" ]; then
	ctl_set "$I2S_MIXER" 1 || { jrn "$I2S_MIXER would not go on -- nothing armed"; exit 2; }
	jrn "HOLD_5V=i2s: $I2S_MIXER ON too -- the 5 V rail rides the I2S back end for each stream"
fi

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
# r189: an I2S run leaves its route off, so later playback cannot start the
# MI2S back end by inheritance
[ "$OUTPUT" != "i2s" ] || { ctl_set "$MIXER" 0 && jrn "$MIXER off at the end"; }
[ -z "$HOLD_5V" ] || { ctl_set "$I2S_MIXER" 0 && jrn "HOLD_5V: $I2S_MIXER off at the end"; }
# r185/r187: every volume back to its boot value
# r193: the speaker volume back to its default (+15 dB) -- separate, so an
# older card without the control does not fail the codec restore
if [ "$OUTPUT" = "i2s" ]; then
	ctl_set "Loudspeaker Volume" 22 && jrn "Loudspeaker Volume restored to 22 (+15 dB)" ||
		jrn "LOUDSPEAKER VOLUME DID NOT RESTORE"
fi
if vol_restore; then
	jrn "volumes restored: HPH, speaker, earpiece, line outs at their minimum; RX1/RX2/RX3/RX5 0 dB, RX7 -6 dB; Lineout Select 15"
else
	jrn "THE VOLUMES DID NOT RESTORE -- check HPHL/HPHR Volume by hand"
fi
# r194: the RX_EAR_CMBUFF mode back to what the run found
if [ -n "$EAR_CMBUFF" ] && [ -n "${CMPRE:-}" ]; then
	echo "$CMPRE" > "$PGD/ear_cmbuff" 2>/dev/null
	[ "$(rv "$(cat "$PGD/ear_cmbuff" 2>/dev/null)" mode)" = "$CMPRE" ] &&
		jrn "RX_EAR_CMBUFF mode restored to $CMPRE" || jrn "RX_EAR_CMBUFF MODE DID NOT RESTORE"
fi
# r195: the earpiece order back to what the run found; the snapshot disarmed
if [ -n "$EAR_ORDER" ] && [ -n "${ORPRE:-}" ]; then
	echo "$ORPRE" > "$PGD/ear_order" 2>/dev/null
	[ "$(rv "$(cat "$PGD/ear_order" 2>/dev/null)" order)" = "$ORPRE" ] &&
		jrn "EAR order restored to $ORPRE" || jrn "EAR ORDER DID NOT RESTORE"
fi
[ "$SNAP" != "1" ] || echo disarm > "$PGD/reg_snap" 2>/dev/null
# r187: read AFTER the restore -- the "at their minimum" check is about the
# state the run leaves behind, and a run whose last stream was at full gain
# (Speaker Volume 8, field 0) failed it when this was read before.
OPOST=$(cat "$PGD/out_state" 2>/dev/null)
RPOST=$(cat "$PGD/hphr_state" 2>/dev/null)
IPOST=$(i2s_state); VPOST=$(vreg_5v); MPOST=$(mi2s_mux)
APOST=$(visa_state)

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
	[ "$SNAP" != "1" ] || check "register snapshot left disarmed" \
		"$(rv "$(head -n1 "$PGD/reg_snap" 2>/dev/null)" armed)" "0"
	[ -z "$EAR_ORDER" ] || check "EAR order as found" \
		"$(rv "$(cat "$PGD/ear_order" 2>/dev/null)" order)" "${ORPRE:-?}"
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
		# r195: the live register snapshot, taken once at this stream's PA on
		if [ "$SNAP" = "1" ]; then
			eval "_sh=\${S${c}_SNH:-}; _st0=\${S${c}_SNT0:-0}; _sf=\${S${c}_SNF:-}"
			_st1=$(rv "$_sh" takes)
			check "s$c register snapshot taken once, at the $SNAP_LABEL PA on" \
			      "$(( ${_st1:-0} - ${_st0:-0} )) $(rv "$_sh" label) $(rv "$_sh" armed) $(rv "$_sh" valid)" \
			      "1 $SNAP_LABEL 0 1"
			say "        s$c snapshot: $_sh -> $_sf"
		fi
		eval "_i2=\${S${c}_INTR2:-}"
		[ -z "$_i2" ] || say "        s$c INTR_STATUS2 through the tone: $_i2"
		eval "_o=\${S${c}_O:-}; _oa=\${S${c}_OAFTER:-}"
		if [ "$OUTPUT" = "i2s" ]; then
			eval "_i=\${S${c}_I2S:-}; _ia=\${S${c}_I2SA:-}; _v=\${S${c}_V5:-}; _va=\${S${c}_V5A:-}"
			eval "_m=\${S${c}_MUX:-}; _ma=\${S${c}_MUXA:-}; _su=\${S${c}_SLIM:-}; _ip=\${S${c}_I2SPIN:-}"
			check "s$c the pin alone powers no amplifier" "$(rv "$_ip" supply_on)" "0"
			check "s$c the codec untouched live" "$(dapm_kv "$_l" held)" "$DAPM_HELD_NONE"
			check "s$c no HPH PA live" "$(pa_masked "$(rv "$_p" pa_0x1ab)")" "00"
			check "s$c no SLIMbus stream" "$_su" "0"
			check "s$c no MCLK user (the codec is not on this path)" "$(rv "$_cs" mclk_users)" "0"
			check "s$c tone played" "$_t" "0"
			check "s$c amplifier live: 5 V, pins, bit clock" \
			      "$(rv "$_i" supply_on) $(rv "$_i" pins_active) $(rv "$_i" bclk_on)" "1 1 1"
			if [ "$RAIL5V" = "off" ]; then
				check "s$c the component's vdd is NOT the 5 V rail (dummy)" \
				      "$([ "$(rv "$_i" vdd_uV)" = "5000000" ] && echo 5V || echo dummy)" "dummy"
			else
				check "s$c the component reads the rail at 5 V" "$(rv "$_i" vdd_enabled) $(rv "$_i" vdd_uV)" "1 5000000"
			fi
			check "s$c regulator class: s4 $RAIL_LIVE live" "$(printf '%s' "$_v" | cut -d' ' -f1)" "$RAIL_LIVE"
			check "s$c pins 79-82 muxed sec_mi2s live" "$_m" "sec_mi2s sec_mi2s sec_mi2s sec_mi2s"
			check "s$c amplifier off after: 5 V, pins, bit clock" \
			      "$(rv "$_ia" supply_on) $(rv "$_ia" pins_active) $(rv "$_ia" bclk_on)" "0 0 0"
			check "s$c regulator class: s4 disabled after" "$(printf '%s' "$_va" | cut -d' ' -f1)" "disabled"
			check "s$c pins 79-82 back to GPIO after" "$_ma" "gpio gpio gpio gpio"
			# r192: the VISA amplifier, powered by DAPM with the path
			eval "_vli=\${S${c}_VISALIVE:-}; _vaf=\${S${c}_VISAAFTER:-}"
			if [ -n "$_vli" ]; then
				check "s$c speaker gain at the expected Loudspeaker Volume (gain_raw)" "$(rv "$_vli" gain_raw)" "$SPK_GAIN_RAW"
				check "s$c VISA powered by DAPM live (powered, dapm_held, GPIO20)" \
				      "$(rv "$_vli" powered) $(rv "$_vli" dapm_held) $(rv "$_vli" gpio)" "1 1 1"
				check "s$c VISA standby after (powered, dapm_held, GPIO20)" \
				      "$(rv "$_vaf" powered) $(rv "$_vaf" dapm_held) $(rv "$_vaf" gpio)" "0 0 0"
			fi
			check "s$c DAPM holds nothing after" "$(dapm_kv "$_a" held)" "$DAPM_HELD_NONE"
			check "s$c pin OFF after" "$_pin" "0"
			c=$((c + 1))
			continue
		fi
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
				# r190: VDD_SPKDRV, live and after
				eval "_v=\${S${c}_V5:-}; _va=\${S${c}_V5A:-}"
				check "s$c VDD_SPKDRV present (vdd-spkdrv)" "$(rv "$_o" spkdrv_present)" "1"
				check "s$c VDD_SPKDRV on live (driver)" "$(rv "$_o" spkdrv)" "1"
				check "s$c the 5 V rail enabled live (regulator class)" "$(printf '%s' "$_v" | cut -d' ' -f1)" "enabled"
				check "s$c VDD_SPKDRV off after (driver)" "$(rv "$_oa" spkdrv)" "0"
				check "s$c the 5 V rail disabled after (regulator class)" "$(printf '%s' "$_va" | cut -d' ' -f1)" "disabled"
			elif [ "$OUTPUT" = "lo" ]; then
				_sel=$(printf '%02x' "$LO_SELECT")
				check "s$c line-out PAs live = select (0x1ca)" "$(rv "$_o" locnp_0x1ca)" "$_sel"
				if [ -n "$HOLD_5V" ]; then
					eval "_v=\${S${c}_V5:-}; _va=\${S${c}_V5A:-}"
					check "s$c HOLD_5V: the 5 V rail enabled live" "$(printf '%s' "$_v" | cut -d' ' -f1)" "enabled"
					check "s$c HOLD_5V: the 5 V rail disabled after" "$(printf '%s' "$_va" | cut -d' ' -f1)" "disabled"
				fi
				_lf=$(dapm_spec_field "${_hv:-0}")
				for _g in logain_0x1cd logain_0x1d1 logain_0x1d5 logain_0x1d9; do
					_x=$(rv "$_o" "$_g")
					check "s$c $_g register source, field = 20 - $_hv" \
					      "$(printf '%02x' $(( 0x${_x:-ff} & 0x3f )))" "$(printf '%02x' $(( 0x20 | 0x$_lf )))"
				done
				check "s$c RDAC5/RDAC7 inverted pairs (0x3b1)" \
				      "$(printf '%02x' $(( 0x$(rv "$_o" misc_0x3b1) & 0x06 )))" "06"
				check "s$c class-H in LO mode" "$(rv "$_o" clsh_lo)" "1"
				check "s$c RX3 and RX5 on" "$(rv "$_o" rx3_on) $(rv "$_o" rx5_on)" "1 1"
				check "s$c line-out PAs off after" "$(rv "$_oa" locnp_0x1ca)" "00"
				check "s$c line-out DACs off after" \
				      "$(rv "$_oa" lodac_0x1cf)$(rv "$_oa" lodac_0x1d3)$(rv "$_oa" lodac_0x1d7)$(rv "$_oa" lodac_0x1db)" "00000000"
				check "s$c class-H LO off after" "$(rv "$_oa" clsh_lo)" "0"
			else
				check "s$c earpiece live (0x1bc DAC1 + switch + PA)" "$(rv "$_o" ear_0x1bc)" "70"
				if [ -n "$HOLD_5V" ]; then
					eval "_v=\${S${c}_V5:-}; _va=\${S${c}_V5A:-}"
					check "s$c HOLD_5V: the 5 V rail enabled live" "$(printf '%s' "$_v" | cut -d' ' -f1)" "enabled"
					check "s$c HOLD_5V: the 5 V rail disabled after" "$(printf '%s' "$_va" | cut -d' ' -f1)" "disabled"
				fi
				check "s$c class-H in EAR mode" "$(rv "$_o" clsh_ear)" "1"
				check "s$c earpiece off after" "$(rv "$_oa" ear_0x1bc)" "00"
				# r195b: the EAR PA's own fault and start-up flags through the tone
				eval "_i2=\${S${c}_INTR2:-}"
				_i2n=$(rv "$_i2" n)
				check "s$c INTR_STATUS2 sampled through the tone" \
				      "$([ "${_i2n:-0}" -ge 10 ] && echo yes || echo "no (${_i2n:-0})")" "yes"
				check "s$c EAR PA OCP fault (INTR_STATUS2 bit 2) never set" "$(rv "$_i2" ocp_ear)" "0"
				say "        s$c EAR PA start-up flag (bit 5) in $(rv "$_i2" start_ear) of ${_i2n:-0} samples"
				# r194: the CMBUFF mode, live and after
				eval "_cm=\${S${c}_CMB:-}"
				_cb=$(rv "$_o" cmbuff_0x1be)
				case "$_cm" in
				clear) check "s$c RX_EAR_CMBUFF bit 0 clear live (Windows)" \
				             "$(( 0x${_cb:-ff} & 1 )) $(rv "$_o" ear_cmbuff_cleared)" "0 1" ;;
				keep)  check "s$c RX_EAR_CMBUFF untouched live (r187)" \
				             "$_cb $(rv "$_o" ear_cmbuff_cleared)" "$(rv "$OPRE" cmbuff_0x1be) 0" ;;
				esac
				if [ -n "$_cm" ]; then
					check "s$c RX_EAR_CMBUFF restored after" \
					      "$(rv "$_oa" cmbuff_0x1be) $(rv "$_oa" ear_cmbuff_cleared)" "$(rv "$OPRE" cmbuff_0x1be) 0"
					say "        s$c EAR_STATUS 0x1c5 live $(rv "$_o" earstat_0x1c5), after $(rv "$_oa" earstat_0x1c5)"
				fi
				# r195: the order this stream ran, by the driver's own counter
				eval "_eo=\${S${c}_ORD:-}; _u0=\${S${c}_ORU0:-0}; _u1=\${S${c}_ORU1:-0}"
				case "$_eo" in
				windows)    check "s$c EAR order windows: class-H after DAC1 (windows_ups +1)" "$((_u1 - _u0))" "1" ;;
				downstream) check "s$c EAR order downstream (windows_ups +0)" "$((_u1 - _u0))" "0" ;;
				esac
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
	check "DAPM holds nothing at the end" "$(dapm_kv "$D_POST" held) $(dapm_kv "$D_POST" spk_held) $(dapm_kv "$D_POST" ear_held) $(dapm_kv "$D_POST" lo_held)" "000 00 00 00"
	check "nobody holds MCLK at the end" "$(rv "$CPOST" mclk_users)" "0"
	check "codec back on RCO" "$(rv "$CPOST" on_mclk)" "0"
	check "guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no OCP fault" "$(rv "$POST" ocp_seen)" "0"
	check "PA enables == disables" "$(rv "$POST" enables)" "$(rv "$POST" disables)"

	# r191: the VISA amplifier, per stream and for the run
	if [ -n "${APRE:-}" ]; then
		say ""
		say "-- the VISA amplifier --"
		_ns=0; { [ -n "$AMP" ] || [ "$OUTPUT" = "i2s" ]; } && _ns=$((n - 1))
		c=1
		while [ -n "$AMP" ] && [ "$c" -lt "$n" ]; do
			eval "_von=\${S${c}_VISAON:-}; _vli=\${S${c}_VISALIVE:-}; _vof=\${S${c}_VISAOFF:-}; _vmm=\${S${c}_VISAMM:-?}"
			check "s$c visa powered, GPIO20 high, before the stream" "$(rv "$_von" powered) $(rv "$_von" gpio)" "1 1"
			check "s$c visa still powered live" "$(rv "$_vli" powered)" "1"
			check "s$c visa standby and GPIO20 low after" "$(rv "$_vof" powered) $(rv "$_vof" gpio)" "0 0"
			note "s$c visa read-back mismatches in the script" "$_vmm"
			c=$((c + 1))
		done
		for _k in powers_on powers_off; do
			_k1=$(rv "$APOST" "$_k"); _k0=$(rv "$APRE" "$_k")
			check "visa $_k this run" "$(( ${_k1:-0} - ${_k0:-0} ))" "$_ns"
		done
		_e1=$(rv "$APOST" i2c_errors); _e0=$(rv "$APRE" i2c_errors)
		check "visa I2C errors this run" "$(( ${_e1:-0} - ${_e0:-0} ))" "0"
		check "visa off at the end (powered, GPIO20)" "$(rv "$APOST" powered) $(rv "$APOST" gpio)" "0 0"
		say "visa at the end: $APOST"
	fi

	# r189: the amplifier's own accounting, and its idle state at the end
	if [ -n "${IPRE:-}" ]; then
		say ""
		say "-- the I2S amplifier's accounting --"
		_ns=0; { [ "$OUTPUT" = "i2s" ] || [ -n "$HOLD_5V" ]; } && _ns=$((n - 1))
		for _k in enables disables bclk_sets bclk_clears; do
			_k1=$(rv "$IPOST" "$_k"); _k0=$(rv "$IPRE" "$_k")
			check "i2s $_k this run" "$(( ${_k1:-0} - ${_k0:-0} ))" "$_ns"
		done
		_e1=$(rv "$IPOST" errors); _e0=$(rv "$IPRE" errors)
		check "i2s errors this run" "$(( ${_e1:-0} - ${_e0:-0} ))" "0"
		check "i2s idle at the end: 5 V, pins, bit clock" \
		      "$(rv "$IPOST" supply_on) $(rv "$IPOST" pins_active) $(rv "$IPOST" bclk_on)" "0 0 0"
		check "the 5 V rail off at the end (regulator class)" "$(printf '%s' "$VPOST" | cut -d' ' -f1)" "disabled"
		check "pins 79-82 GPIO at the end" "$MPOST" "gpio gpio gpio gpio"
	fi

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
		# r190: VDD_SPKDRV once per speaker stream, never for anything else
		_ns=0; [ "$OUTPUT" = "spk" ] && _ns=$((n - 1))
		for _k in spkdrv_enables spkdrv_disables; do
			_k1=$(rv "$OPOST" "$_k"); _k0=$(rv "$OPRE" "$_k")
			check "$_k this run" "$(( ${_k1:-0} - ${_k0:-0} ))" "$_ns"
		done
		check "VDD_SPKDRV off at the end" "$(rv "$OPOST" spkdrv)" "0"
		check "speaker and earpiece at their minimum, PAs off" \
		      "$(rv "$OPOST" spk_field) $(rv "$OPOST" ear_field) $(rv "$OPOST" spk_pa) $(rv "$OPOST" ear_pa)" "8 7 0 0"
		check "speaker gain restored" "$(rv "$OPOST" spkgain_0x1e0)" "$(rv "$OPRE" spkgain_0x1e0)"
		check "earpiece gain restored" "$(rv "$OPOST" eargain_0x1bd)" "$(rv "$OPRE" eargain_0x1bd)"
		check "earpiece fully off" "$(rv "$OPOST" ear_0x1bc)" "00"
		# r194: one CMBUFF clear per clear stream, each restored; the
		# register and the mode as the run found them
		if [ -n "$(rv "$OPRE" ear_cmbuff_mode)" ]; then
			_nc=0; c=1
			while [ "$c" -lt "$n" ]; do
				eval "_cm=\${S${c}_CMB:-}"
				[ "$_cm" = "clear" ] && _nc=$((_nc + 1))
				c=$((c + 1))
			done
			for _k in ear_cmbuff_clears ear_cmbuff_restores; do
				_k1=$(rv "$OPOST" "$_k"); _k0=$(rv "$OPRE" "$_k")
				check "$_k this run" "$(( ${_k1:-0} - ${_k0:-0} ))" "$_nc"
			done
			check "RX_EAR_CMBUFF as found, nothing owed" \
			      "$(rv "$OPOST" cmbuff_0x1be) $(rv "$OPOST" ear_cmbuff_cleared) $(rv "$OPOST" ear_cmbuff_mode)" \
			      "$(rv "$OPRE" cmbuff_0x1be) 0 $(rv "$OPRE" ear_cmbuff_mode)"
		fi
		check "RX7 off" "$(rv "$OPOST" rx7_on)" "0"
		# r188: the line outs, and class-H LO's no-trace restore
		check "line outs at the minimum, all selected, PAs off" \
		      "$(rv "$OPOST" lo_field) $(rv "$OPOST" lo_select) $(rv "$OPOST" lo_pa) $(rv "$OPOST" locnp_0x1ca)" "20 f 0 00"
		for _g in logain_0x1cd logain_0x1d1 logain_0x1d5 logain_0x1d9 misc_0x3b1; do
			check "$_g restored" "$(rv "$OPOST" "$_g")" "$(rv "$OPRE" "$_g")"
		done
		# Only a line-out run owes this: class-H in HPH mode (state_hph) moves
		# 0x185 and 0x194 itself and leaves them (r188's HPH run after the line
		# outs: 02 -> 00, 28 -> 08, r187's post-HPH baseline), by design.
		if [ "$OUTPUT" = "lo" ]; then
			for _g in buck1_0x181 buck4_0x184 buck5_0x185 ncpen_0x192 ncpst_0x194; do
				check "$_g as before the run (class-H LO no trace)" "$(rv "$OPOST" "$_g")" "$(rv "$OPRE" "$_g")"
			done
		else
			_le1=$(rv "$OPOST" lo_enables); _le0=$(rv "$OPRE" lo_enables)
			check "the line outs never powered this run (lo_enables delta)" \
			      "$(( ${_le1:-0} - ${_le0:-0} ))" "0"
		fi
		check "class-H LO restore mismatches" "$(rv "$OPOST" lo_restore_mismatch)" "0"
		check "RX3 and RX5 off" "$(rv "$OPOST" rx3_on) $(rv "$OPOST" rx5_on)" "0 0"
	fi

	# r195: every stream's snapshot in full, for the diff
	if [ "$SNAP" = "1" ]; then
		c=1
		while [ "$c" -lt "$n" ]; do
			eval "_sf=\${S${c}_SNF:-}"
			hdr "register snapshot, stream $c ($SNAP_LABEL PA on)"
			[ -z "$_sf" ] || cat "$_sf" 2>/dev/null
			c=$((c + 1))
		done
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

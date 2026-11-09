#!/bin/sh
#
# r184 DIGITAL GATE: with the Headphones pin OFF, a played stream reaches the
# codec's DAPM graph and powers NOTHING.
#
# r185: the stereo graph (nine stages, the event-less HPH PGA), a stereo tone,
# and the pin FORCED off first -- jack detection turns it on for a plugged
# headset, so the gate takes the manual override before it plays anything.
# docs/audio/wcd9320-r185-stereo-volume-jack-mapping.md, section 7.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md, section 4. The PA cannot come on in
# this run: the pin stays off throughout and is read back before, during and
# after. So this needs no abort watcher and no approval, and it writes no
# forced register.
#
# THE POSITIVE CONTROL. "Nothing powered" is only meaningful if the stream got
# as far as the codec's graph. So during the tone the HPH widget must show at
# least one connected INPUT endpoint (the RX1 DAI, active) and ZERO output
# endpoints (the pin). in 0 would mean the stream never reached the codec, and
# the run is a FAIL, not a pass -- the acoustic run would then be silent for a
# reason this gate did not test.
#
# r187: every output pin OFF -- headphones, speaker, earpiece -- and all three
# graphs must see the stream and power nothing. r188: the line outs too, four
# graphs.
#
# Usage:  EXPECT_VERSION=outputs-rc1 sudo -E sh wcd9320-dapm-evidence.sh
# Exit:   0 pass, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-dapm"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-dapm-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
DBFS="${DBFS:--40}"
WIDGETS="MCLK|CLASS_H PREP|CDC PREREQ|RX1 CHAIN|RX2 CHAIN|HPHL DAC|HPHR DAC|HPHL PA|HPHR PA|HPH|HEADPHONE|AIF1 PB|SPK MCLK|SPK PREP|SPK PREREQ|RX7 CHAIN|SPK DAC|SPK PA|SPK|SPK_OUT|EAR MCLK|EAR PREP|EAR PREREQ|EAR RX1|EAR DAC|EAR PA|EAR|EAR_OUT|LO MCLK|LO PREP|LO PREREQ|RX3+RX5 CHAIN|LO DAC|LO PA|LO|LO_OUT"

TONE=""
for c in "${PCM_TONE:-}" "$DIR/pcm-tone" /tmp/pcm-tone; do
	[ -n "$c" ] && [ -x "$c" ] && { TONE="$c"; break; }
done
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

[ -n "$TONE" ] && [ -n "$SETCTL" ] || {
	say "INVALID SETUP: needs pcm-tone and alsa-setctl beside this script"; exit 2; }

require_module_version
find_devices
[ -e "$PGD/dapm_state" ] || { say "INVALID SETUP: no dapm_state -- not an r184 module"; exit 2; }

# The codec's widget directory, found by its HPH widget; the card's by its pin.
WDIR=$(dirname "$(find /sys/kernel/debug/asoc -maxdepth 4 -path '*/dapm/HPH' 2>/dev/null | head -n1)")
PDIR=$(dirname "$(find /sys/kernel/debug/asoc -maxdepth 3 -path '*/dapm/Headphones' 2>/dev/null | head -n1)")
[ -d "$WDIR" ] && [ -d "$PDIR" ] || {
	say "INVALID SETUP: no DAPM debugfs (codec '$WDIR', card '$PDIR') -- is debugfs mounted?"; exit 2; }

widgets() {	# one "name=power/in/out" per codec widget, then the pin
	_w_ifs=$IFS; IFS='|'
	for _w in $WIDGETS; do
		IFS=$_w_ifs
		set -- $(dapm_widget "$(head -n1 "$WDIR/$_w" 2>/dev/null)")
		printf '%s=%s/%s/%s;' "$(printf '%s' "$_w" | tr ' ' '_')" "$1" "$2" "$3"
		IFS='|'
	done
	IFS=$_w_ifs
	set -- $(dapm_widget "$(head -n1 "$PDIR/Headphones" 2>/dev/null)")
	printf 'Headphones=%s/%s/%s\n' "$1" "$2" "$3"
}
wfield() { printf '%s' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | head -n1; }

pin() { dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "$DAPM_PIN" 2>/dev/null)"; }

# ------------------------------------------------- refuse before playing --
# r185: the jack may have the pin on; the manual override takes it off. Any
# later jack event during the run shows up as a pin check failing.
JACK0=$(cat "$PGD/jack_detect" 2>/dev/null)
"$SETCTL" -D "$CTLDEV" --set "$DAPM_PIN" 0 >/dev/null 2>&1
# r187: the speaker and earpiece pins too -- every output OFF
for _po in "Speaker Switch" "Earpiece Switch" "Lineout Switch"; do
	"$SETCTL" -D "$CTLDEV" --set "$_po" 0 >/dev/null 2>&1
done
PINS_OTHER() { printf '%s %s %s' "$(dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "Speaker Switch" 2>/dev/null)")" "$(dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "Earpiece Switch" 2>/dev/null)")" "$(dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "Lineout Switch" 2>/dev/null)")"; }
CARDV=$(cat "$DAPM_CARD_VERSION_PATH" 2>/dev/null)
_cok=$(dapm_card_ok "$CARDV" "$(pin)")
[ "$_cok" = "OK" ] || { say "INVALID SETUP: ${_cok#REFUSE:}. Nothing was played."; exit 2; }

# ---------------------------------------------------------------- before --
D0=$(cat "$PGD/dapm_state" 2>/dev/null)
PA0=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
CS0=$(cat "$PGD/clk_source_state" 2>/dev/null)
F0=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
PIN0=$(pin)
W0=$(widgets)
# The gain at its minimum before anything plays: if this gate were wrong, the
# least it could do is quiet. The driver refuses while anything is up.
echo 14 > "$PGD/hphl_pa_gain" 2>/dev/null
G0=$(sed -n 's/^gain_field=\([0-9a-f]*\).*/\1/p' "$PGD/hphl_pa_gain" 2>/dev/null)
# r185: and the right channel, through its ALSA control (0 = the minimum)
"$SETCTL" -D "$CTLDEV" --set "HPHR Volume" 0 >/dev/null 2>&1
GR0=$(rv "$(cat "$PGD/hphr_state" 2>/dev/null)" gain_field_r)

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
DM0=$(dmesg_mark)	# r187: a timestamp; the ring may have wrapped

# ---------------------------------------------------------------- during --
"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" --side B >/tmp/.dapm-tone.$$ 2>&1 &
TPID=$!
sleep 0.3
D1=$(cat "$PGD/dapm_state" 2>/dev/null)
W1=$(widgets)
PA1=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
PIN1=$(pin)
PO1=$(PINS_OTHER)
wait "$TPID"
TRC=$?

# ----------------------------------------------------------------- after --
sleep 1
D2=$(cat "$PGD/dapm_state" 2>/dev/null)
W2=$(widgets)
PA2=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
CS2=$(cat "$PGD/clk_source_state" 2>/dev/null)
F2=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
PIN2=$(pin)
CC=$(cat "$PGD/cache_check" 2>/dev/null | tr '\n' ' ')
DMSG=$(dmesg_since "$DM0")
DMESG_FILE="/tmp/.wcd9320-dmesg-dapm-$$"
snap_dmesg

open_output "$OUTDIR/wcd9320-dapm-$STAMP.txt"
{
	hdr "what this run establishes"
	say "With the Headphones pin OFF, a stream that reaches the codec's DAPM"
	say "graph powers nothing on the codec: no MCLK, no prep, no forced write,"
	say "no RX1, no DAC, no PA. The PA was never enabled in this run."
	hdr "raw"
	say "dapm before : $D0"
	say "dapm during : $D1"
	say "dapm after  : $D2"
	say "widgets before : $W0"
	say "widgets during : $W1"
	say "widgets after  : $W2"
	say "pin before/during/after : $PIN0 $PIN1 $PIN2"
	say "jack before the override: $JACK0"
	say "tone rc : $TRC"
	say "codec debugfs : $WDIR"
	say "card debugfs  : $PDIR"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "card module version" "$CARDV" "$DAPM_CARD_VERSION"
	check "pin OFF before" "$PIN0" "0"
	check "pin OFF during" "$PIN1" "0"
	check "pin OFF after" "$PIN2" "0"
	check "speaker, earpiece and line-out pins OFF during" "$PO1" "0 0 0"
	check "gain field at the minimum" "$G0" "14"
	check "HPHR gain field at the minimum" "$GR0" "14"
	check "DAPM holds nothing before" "$(dapm_held_is "$D0" "$DAPM_HELD_NONE")" "OK"
	check "nobody holds MCLK before" "$(rv "$CS0" mclk_users)" "0"
	check "PA off before (0x1ab)" "$(rv "$PA0" pa_0x1ab)" "80"
	check "the tone played" "$TRC" "0"
	check_cond "the BE reached the codec DAI" \
		"$(printf '%s\n' "$DMSG" | grep -q 'RX path invocation: ASoC hw_params' && echo 1 || echo 0)" \
		"no ASoC hw_params on the codec during the tone" "ASoC hw_params seen"

	say ""
	say "-- during the stream: reached the graph, powered nothing --"
	_hp=$(wfield "$W1" HPH)
	check "HPH off during" "${_hp%%/*}" "Off"
	_in=$(printf '%s' "$_hp" | cut -d/ -f2)
	check_cond "HPH sees the active DAI (in >= 1)" \
		"$([ "${_in:-0}" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"in=$_in -- the stream never reached the codec graph" "in=$_in"
	check "HPH sees no sink (out 0)" "$(printf '%s' "$_hp" | cut -d/ -f3)" "0"
	# r187: the speaker and earpiece graphs reach the stream too, and stay off
	for _g in SPK EAR LO; do
		_gw=$(wfield "$W1" "$_g")
		_gi=$(printf '%s' "$_gw" | cut -d/ -f2)
		check_cond "$_g sees the active DAI (in >= 1)" \
			"$([ "${_gi:-0}" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
			"in=$_gi -- the $_g graph is not connected to the stream" "in=$_gi"
		check "$_g sees no sink (out 0)" "$(printf '%s' "$_gw" | cut -d/ -f3)" "0"
	done
	for _w in MCLK CLASS_H_PREP CDC_PREREQ RX1_CHAIN RX2_CHAIN HPHL_DAC HPHR_DAC HPHL_PA HPHR_PA \
		  SPK_MCLK SPK_PREP SPK_PREREQ RX7_CHAIN SPK_DAC SPK_PA SPK \
		  EAR_MCLK EAR_PREP EAR_PREREQ EAR_RX1 EAR_DAC EAR_PA EAR \
		  LO_MCLK LO_PREP LO_PREREQ RX3+RX5_CHAIN LO_DAC LO_PA LO; do
		check "$_w off during" "$(wfield "$W1" "$_w" | cut -d/ -f1)" "Off"
	done
	check "DAPM holds nothing during" "$(dapm_held_is "$D1" "$DAPM_HELD_NONE")" "OK"
	check "speaker, earpiece and line-out paths hold nothing during" \
	      "$(dapm_kv "$D1" spk_held) $(dapm_kv "$D1" ear_held) $(dapm_kv "$D1" lo_held)" "00 00 00"
	check "PA off during (0x1ab)" "$(rv "$PA1" pa_0x1ab)" "80"

	say ""
	say "-- after: nothing ran at all --"
	check "DAPM holds nothing after" "$(dapm_held_is "$D2" "$DAPM_HELD_NONE")" "OK"
	for _k in ups downs refusals failures; do
		check "DAPM $_k this run" "$(dapm_delta "$D0" "$D2" "$_k")" "0"
	done
	check "nobody holds MCLK after" "$(rv "$CS2" mclk_users)" "0"
	check "codec still on RCO" "$(rv "$CS2" on_mclk)" "0"
	check "no forced write this run" "$(( ${F2:-0} - ${F0:-0} ))" "0"
	check "PA off after (0x1ab)" "$(rv "$PA2" pa_0x1ab)" "80"
	check_cond "no DAPM event ran" \
		"$(printf '%s\n' "$DMSG" | grep -q 'dapm: ' && echo 0 || echo 1)" \
		"$(printf '%s\n' "$DMSG" | grep 'dapm: ' | head -n3 | tr '\n' ' ')" "no dapm: lines in dmesg"
	note "cache_check" "$CC"

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1
rm -f /tmp/.dapm-tone.$$ "$DMESG_FILE"
sync
say "evidence: $OUT"
grep -E "FAIL|VERDICT|checks :" "$OUT"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0

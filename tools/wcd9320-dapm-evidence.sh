#!/bin/sh
#
# r184 DIGITAL GATE: with the Headphones pin OFF, a played stream reaches the
# codec's DAPM graph and powers NOTHING.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md, section 4. The PA cannot come on in
# this run: the pin stays off throughout and is read back before, during and
# after. So this needs no abort watcher and no approval, and it writes no
# forced register.
#
# THE POSITIVE CONTROL. "Nothing powered" is only meaningful if the stream got
# as far as the codec's graph. So during the tone the HPHL widget must show at
# least one connected INPUT endpoint (the RX1 DAI, active) and ZERO output
# endpoints (the pin). in 0 would mean the stream never reached the codec, and
# the run is a FAIL, not a pass -- the acoustic run would then be silent for a
# reason this gate did not test.
#
# Usage:  EXPECT_VERSION=dapm-hphl-rc1 sudo -E sh wcd9320-dapm-evidence.sh
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
WIDGETS="MCLK|CLASS_H PREP|CDC PREREQ|RX1 CHAIN|HPHL DAC|HPHL|HEADPHONE|AIF1 PB"

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

# The codec's widget directory, found by its HPHL widget; the card's by its pin.
WDIR=$(dirname "$(find /sys/kernel/debug/asoc -maxdepth 4 -path '*/dapm/HPHL' 2>/dev/null | head -n1)")
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

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
DM0=$(dmesg | wc -l)

# ---------------------------------------------------------------- during --
"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" >/tmp/.dapm-tone.$$ 2>&1 &
TPID=$!
sleep 0.3
D1=$(cat "$PGD/dapm_state" 2>/dev/null)
W1=$(widgets)
PA1=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
PIN1=$(pin)
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
DMSG=$(dmesg | tail -n +"$((DM0 + 1))")
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
	say "tone rc : $TRC"
	say "codec debugfs : $WDIR"
	say "card debugfs  : $PDIR"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "card module version" "$CARDV" "$DAPM_CARD_VERSION"
	check "pin OFF before" "$PIN0" "0"
	check "pin OFF during" "$PIN1" "0"
	check "pin OFF after" "$PIN2" "0"
	check "gain field at the minimum" "$G0" "14"
	check "DAPM holds nothing before" "$(dapm_held_is "$D0" "$DAPM_HELD_NONE")" "OK"
	check "nobody holds MCLK before" "$(rv "$CS0" mclk_users)" "0"
	check "PA off before (0x1ab)" "$(rv "$PA0" pa_0x1ab)" "80"
	check "the tone played" "$TRC" "0"
	check_cond "the BE reached the codec DAI" \
		"$(printf '%s\n' "$DMSG" | grep -q 'RX path invocation: ASoC hw_params' && echo 1 || echo 0)" \
		"no ASoC hw_params on the codec during the tone" "ASoC hw_params seen"

	say ""
	say "-- during the stream: reached the graph, powered nothing --"
	_hp=$(wfield "$W1" HPHL)
	check "HPHL off during" "${_hp%%/*}" "Off"
	_in=$(printf '%s' "$_hp" | cut -d/ -f2)
	check_cond "HPHL sees the active DAI (in >= 1)" \
		"$([ "${_in:-0}" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"in=$_in -- the stream never reached the codec graph" "in=$_in"
	check "HPHL sees no sink (out 0)" "$(printf '%s' "$_hp" | cut -d/ -f3)" "0"
	for _w in MCLK CLASS_H_PREP CDC_PREREQ RX1_CHAIN HPHL_DAC; do
		check "$_w off during" "$(wfield "$W1" "$_w" | cut -d/ -f1)" "Off"
	done
	check "DAPM holds nothing during" "$(dapm_held_is "$D1" "$DAPM_HELD_NONE")" "OK"
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

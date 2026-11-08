#!/bin/sh
#
# r185 JACK GATE: the MBHC jack switch drives the Headphones pin, both ways,
# and with no stream nothing powers.
#
# docs/audio/wcd9320-r185-stereo-volume-jack-mapping.md, sections 5 and 7.
#
# No stream, no PA write, no forced write -- so no abort watcher and no
# approval. The operator unplugs and replugs the headset when prompted; each
# transition is polled for up to HOLD_S seconds and must hold for 0.5 s.
#
# Per settled state:
#   - the reported state matches the chip's level (0x14b bit 2: 1 = removed)
#   - 0x14a is armed for the OTHER state: 6d while inserted, 6f while removed
#   - the "Headphones Jack" control and the "Headphones Switch" pin follow it
#   - JACK_SWITCH is the only unmasked source (ff ff 3f 6f)
#   - DAPM holds nothing, nobody holds MCLK, the PA is off: a pin with no
#     stream powers nothing
# Per transition: at least one JACK_SWITCH interrupt and one more report.
# Then: jack_detect off restores 0x14a 00, the certified masks and the pin
# off; on brings the real state back.
#
# Removal has never been run on this hardware before r185 -- insertion is
# wcd9320-irq-proven -- so this is the first measurement of the re-armed
# polarity.
#
# Usage:  sudo env EXPECT_VERSION=stereo-vol-jack-rc1 sh wcd9320-jack-evidence.sh
# Exit:   0 pass, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-jack"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-dapm-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
HOLD_S="${HOLD_S:-120}"
JACK_CTL="${JACK_CTL:-Headphones Jack}"	# ASoC names one control per jack pin
MASK_ARMED="ff ff 3f 6f"	# JACK_SWITCH (INTR_REG3 bit 4) unmasked, nothing else
MASK_CERT="ff ff 3f 7f"		# wcd9320-irq-parent-idle-validated

SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
js() { cat "$PGD/jack_detect" 2>/dev/null; }
ctl() { dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "$1" 2>/dev/null)"; }
masks() {
	sed -n 's/.*mask=\([0-9a-f][0-9a-f] [0-9a-f][0-9a-f] [0-9a-f][0-9a-f] [0-9a-f][0-9a-f]\).*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}

# snap <tag> -- everything a settled state is judged on, no chip writes
snap() {
	eval "J_$1=\$(js)"
	eval "CTL_$1=\$(ctl \"\$JACK_CTL\")"
	eval "PIN_$1=\$(ctl \"\$DAPM_PIN\")"
	eval "D_$1=\$(cat \"\$PGD/dapm_state\" 2>/dev/null)"
	eval "CS_$1=\$(cat \"\$PGD/clk_source_state\" 2>/dev/null)"
	eval "PA_$1=\$(rv \"\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)\" pa_0x1ab)"
	eval "M_$1=\$(masks)"
}

# wait_state <0|1> -> 0 once the driver reports it, steady for 0.5 s
wait_state() {
	_w=0
	while [ "$_w" -lt $((HOLD_S * 10)) ]; do
		if [ "$(rv "$(js)" inserted)" = "$1" ]; then
			sleep 0.5
			[ "$(rv "$(js)" inserted)" = "$1" ] && return 0
		fi
		sleep 0.1
		_w=$((_w + 1))
	done
	return 1
}

# ------------------------------------------------------------- the setup --
[ -n "$SETCTL" ] || { say "INVALID SETUP: needs alsa-setctl beside this script"; exit 2; }
require_module_version
find_devices
[ -e "$PGD/jack_detect" ] || { say "INVALID SETUP: no jack_detect -- not an r185 module"; exit 2; }
CARDV=$(cat "$DAPM_CARD_VERSION_PATH" 2>/dev/null)
[ "$CARDV" = "$DAPM_CARD_VERSION" ] ||
	{ say "INVALID SETUP: card module is '${CARDV:-absent}', not $DAPM_CARD_VERSION"; exit 2; }
[ "$(ctl "$JACK_CTL")" != "?" ] ||
	{ say "INVALID SETUP: no \"$JACK_CTL\" control -- the card made no jack"; exit 2; }
[ "$(rv "$(js)" has_jack)" = "1" ] ||
	{ say "INVALID SETUP: the codec holds no jack -- did the card's set_jack fail? (dmesg)"; exit 2; }
if [ "$(rv "$(js)" on)" != "1" ]; then
	echo on > "$PGD/jack_detect" 2>/dev/null ||
		{ say "INVALID SETUP: jack detection would not turn on"; exit 2; }
	say "jack detection was off -- turned on"
	sleep 0.3
fi

F0=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
DM0=$(dmesg_mark)	# r187: a timestamp; the ring may have wrapped
snap S0
I0=$(rv "$J_S0" inserted)
case "$I0" in 0|1) ;; *) say "INVALID SETUP: jack_detect reports no state: $J_S0"; exit 2 ;; esac
T1=$((1 - I0))

# --------------------------------------------------------- the transitions --
say ""
if [ "$I0" = "1" ]; then
	say "  ==> The headset is IN. UNPLUG it now. (${HOLD_S} s)"
else
	say "  ==> The headset is OUT. PLUG IT IN now. (${HOLD_S} s)"
fi
wait_state "$T1"; RC1=$?
snap S1
say "      seen: $(rv "$J_S1" inserted) (rc $RC1)"
say ""
if [ "$T1" = "1" ]; then
	say "  ==> Now UNPLUG it again. (${HOLD_S} s)"
else
	say "  ==> Now PLUG IT BACK IN. (${HOLD_S} s)"
fi
wait_state "$I0"; RC2=$?
snap S2
say "      seen: $(rv "$J_S2" inserted) (rc $RC2)"

# ------------------------------------------------- off, then on, by hand --
echo off > "$PGD/jack_detect" 2>/dev/null
sleep 0.3
snap S3
echo on > "$PGD/jack_detect" 2>/dev/null
sleep 0.3
snap S4
F4=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
DMSG=$(dmesg_since "$DM0")
DMESG_FILE="/tmp/.wcd9320-dmesg-jack-$$"
snap_dmesg

# settled <tag> <want 0|1>
settled() {
	eval "_j=\$J_$1; _c=\$CTL_$1; _p=\$PIN_$1; _d=\$D_$1; _cs=\$CS_$1; _pa=\$PA_$1; _m=\$M_$1"
	_st=$(rv "$_j" status_0x14b)
	check "$1 reported inserted" "$(rv "$_j" inserted)" "$2"
	check "$1 the chip's level agrees (0x14b bit 2 = removed)" \
	      "$(( (0x${_st:-04} & 0x04) ? 0 : 1 ))" "$2"
	if [ "$2" = "1" ]; then _want=6d; else _want=6f; fi
	check "$1 0x14a armed for the other state" "$(rv "$_j" detect_0x14a)" "$_want"
	check "$1 Headphone Jack control" "$_c" "$2"
	check "$1 Headphones pin follows" "$_p" "$2"
	check "$1 JACK_SWITCH the only unmasked source" "$_m" "$MASK_ARMED"
	check "$1 DAPM holds nothing (no stream)" "$(dapm_kv "$_d" held)" "$DAPM_HELD_NONE"
	check "$1 nobody holds MCLK" "$(rv "$_cs" mclk_users)" "0"
	check "$1 PA off" "$(printf '%02x' $(( 0x${_pa:-ff} & 0x30 )))" "00"
}
# moved <from> <to> <key> -> the increase, or ?
moved() {
	eval "_a=\$(rv \"\$J_$1\" $3); _b=\$(rv \"\$J_$2\" $3)"
	case "$_a$_b" in ''|*[!0-9]*) echo "?"; return ;; esac
	echo $((_b - _a))
}
ge1() { [ "$1" != "?" ] && [ "$1" -ge 1 ] 2>/dev/null && echo 1 || echo 0; }

open_output "$OUTDIR/wcd9320-jack-$STAMP.txt"
{
	hdr "what this run establishes"
	say "That the WCD9320's mechanical jack switch, through MBHC_JACK_SWITCH, drives"
	say "the card's Headphones pin in both directions -- removal for the first time"
	say "on this hardware -- with 0x14a re-armed for the opposite state each time,"
	say "and that a pin turned on by the jack powers nothing without a stream."
	hdr "raw"
	for _t in S0 S1 S2 S3 S4; do
		eval "say \"$_t jack : \$J_$_t\""
		eval "say \"$_t ctl \$CTL_$_t pin \$PIN_$_t masks \$M_$_t pa \$PA_$_t dapm \$D_$_t\""
	done
	say "transitions rc : $RC1 $RC2"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "card module version" "$CARDV" "$DAPM_CARD_VERSION"
	say ""
	say "-- the starting state ($I0) --"
	settled S0 "$I0"
	say ""
	say "-- transition 1: $I0 -> $T1 --"
	check "transition 1 seen within ${HOLD_S} s" "$RC1" "0"
	check_cond "transition 1: at least one JACK_SWITCH interrupt" \
		"$(ge1 "$(moved S0 S1 irqs)")" "irqs +$(moved S0 S1 irqs)" "irqs +$(moved S0 S1 irqs)"
	check_cond "transition 1: at least one report" \
		"$(ge1 "$(moved S0 S1 reports)")" "reports +$(moved S0 S1 reports)" "reports +$(moved S0 S1 reports)"
	settled S1 "$T1"
	say ""
	say "-- transition 2: $T1 -> $I0 --"
	check "transition 2 seen within ${HOLD_S} s" "$RC2" "0"
	check_cond "transition 2: at least one JACK_SWITCH interrupt" \
		"$(ge1 "$(moved S1 S2 irqs)")" "irqs +$(moved S1 S2 irqs)" "irqs +$(moved S1 S2 irqs)"
	check_cond "transition 2: at least one report" \
		"$(ge1 "$(moved S1 S2 reports)")" "reports +$(moved S1 S2 reports)" "reports +$(moved S1 S2 reports)"
	settled S2 "$I0"
	say ""
	say "-- jack_detect off: everything it owned is given back --"
	check "S3 detection off" "$(rv "$J_S3" on)" "0"
	check "S3 0x14a back to 00" "$(rv "$J_S3" detect_0x14a)" "00"
	check "S3 the certified masks again" "$M_S3" "$MASK_CERT"
	check "S3 Headphone Jack control off" "$CTL_S3" "0"
	check "S3 Headphones pin off" "$PIN_S3" "0"
	say ""
	say "-- jack_detect on: the real state comes back --"
	check "S4 detection on" "$(rv "$J_S4" on)" "1"
	settled S4 "$I0"
	say ""
	check "no forced write this run" "$(( ${F4:-0} - ${F0:-0} ))" "0"
	check_cond "no DAPM stage ran" \
		"$(printf '%s\n' "$DMSG" | grep -q 'dapm: .* up,' && echo 0 || echo 1)" \
		"$(printf '%s\n' "$DMSG" | grep 'dapm: ' | head -n3 | tr '\n' ' ')" "no stage powered"
	note "cache_check" "$(cat "$PGD/cache_check" 2>/dev/null | tr '\n' ' ')"

	hdr "jack events (dmesg)"
	printf '%s\n' "$DMSG" | grep -E 'jack: |insert-detect' | tail -n 30

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1
rm -f "$DMESG_FILE"
sync
say "evidence: $OUT"
grep -E "FAIL|VERDICT|checks :" "$OUT"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0

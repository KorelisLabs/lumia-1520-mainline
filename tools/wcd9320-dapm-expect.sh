#!/bin/sh
#
# r184: the DAPM expectations, as pure functions, so the selftest can run them
# offline against the same rules the gates use on the phone.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md. The driver exports one line,
#
#   dapm_state: held=1ff ups=9 downs=0 refusals=0 failures=0 mclk_users=1 pa_on=1 pa_r_on=1
#
# where held is a bitmask of the nine stages DAPM powered itself (r185):
#
#   bit 0 MCLK, 1 class-H prep, 2 cdc prereq (forced 0x314), 3 RX1, 4 RX2,
#   bit 5 HPHL DAC, 6 HPHR DAC, 7 HPHL PA, 8 HPHR PA
#
# so the whole path is 1ff and nothing is 000. No other value is legal at a
# boundary -- a partial mask means a stage refused or failed. (r184 had six
# stages, 3f; docs/audio/wcd9320-r185-stereo-volume-jack-mapping.md.)

DAPM_HELD_ALL=1ff
DAPM_HELD_NONE=000
DAPM_STAGES=9			# ups and downs per stream (r185: nine)
DAPM_PIN="${DAPM_PIN:-Headphones Switch}"

# dapm_kv <dapm_state text> <key>
dapm_kv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

# dapm_held_is <dapm_state text> <want> -> OK, or REFUSE:<why>
dapm_held_is() {
	_dh=$(dapm_kv "$1" held)
	if [ -z "$_dh" ]; then
		echo "REFUSE:no held= in dapm_state"
	elif [ "$_dh" = "$2" ]; then
		echo "OK"
	else
		echo "REFUSE:held=$_dh want $2"
	fi
}

# dapm_delta <before text> <after text> <key> -> after - before, or "?"
dapm_delta() {
	_db=$(dapm_kv "$1" "$3")
	_da=$(dapm_kv "$2" "$3")
	case "$_db" in ''|*[!0-9]*) echo "?"; return ;; esac
	case "$_da" in ''|*[!0-9]*) echo "?"; return ;; esac
	echo $((_da - _db))
}

# dapm_widget <first line of a debugfs dapm widget file> -> "power in out"
#
#   "HPHL: Off  in 1 out 0"           -> "Off 1 0"
#   "MCLK: On  in 1 out 1 - R..."     -> "On 1 1"
#
# A line that does not parse gives "? ? ?", which matches no expectation.
dapm_widget() {
	# -E, not \| in a basic expression: musl's BRE has no alternation.
	printf '%s\n' "$1" | sed -n -E \
		's/^[^:]*: (On|Off)( \(forced\))? +in ([0-9]+) out ([0-9]+).*/\1 \3 \4/p' |
		head -n1 | grep . || echo "? ? ?"
}

# THE CARD MUST BE r184's. With an older card the codec's HEADPHONE output has
# no pin behind it and is a DAPM endpoint by itself, so any stream would power
# the whole path, PA included. Every gate checks this BEFORE anything plays.
DAPM_CARD_VERSION="${DAPM_CARD_VERSION:-q6-card-rc11}"
DAPM_CARD_VERSION_PATH="${DAPM_CARD_VERSION_PATH:-/sys/module/snd_soc_lumia1520_q6/version}"

# dapm_card_ok <card version> <pin value> -> OK, or REFUSE:<why>
dapm_card_ok() {
	if [ "$1" != "$DAPM_CARD_VERSION" ]; then
		echo "REFUSE:card module is '${1:-absent}', not $DAPM_CARD_VERSION -- no pin behind HEADPHONE"
	elif [ "$2" != "0" ]; then
		echo "REFUSE:Headphones pin reads '$2', not 0"
	else
		echo "OK"
	fi
}

# dapm_pin_value <alsa-setctl --get output> -> 0, 1, or ?
dapm_pin_value() {
	_pv=$(printf '%s\n' "$1" | sed -n 's/^readback=//p' | head -n1)
	case "$_pv" in
	0|1) echo "$_pv" ;;
	*) echo "?" ;;
	esac
}

# ------------------------------------------------------------------ r185 --
#
# Both PAs are live while a stereo stream plays: 0x1ab masked 30.
DAPM_PA_LIVE=30

# One stereo stream issues SIX forced writes, in DAPM's order:
#   PREREQ up (314 set), HPHL DAC up (30d bit 1), HPHR DAC up (30d bit 2),
#   then down in reverse: HPHR DAC, HPHL DAC, PREREQ.
DAPM_FORCED_PER_STREAM=6

# dapm_forced_want <index within the run> -> "reg mask dir"
dapm_forced_want() {
	case $(( $1 % DAPM_FORCED_PER_STREAM )) in
	0) echo "314 ff set" ;;
	1) echo "30d 02 set" ;;
	2) echo "30d 04 set" ;;
	3) echo "30d 04 clear" ;;
	4) echo "30d 02 clear" ;;
	5) echo "314 ff clear" ;;
	esac
}

# A listen stream is "side:hph:dig":
#   side  L, R or B -- which channel carries the tone (the other is zero)
#   hph   HPHL/HPHR Volume, 0..20, 20 loudest (the field is 20 - hph)
#   dig   RX1/RX2 Digital Volume, 0..84 = -84..0 dB, 84 is 0 dB
#
# dapm_spec_ok <spec> -> OK, or REFUSE:<why>
dapm_spec_ok() {
	_ss=$(printf '%s' "$1" | cut -d: -f1)
	_sh=$(printf '%s' "$1" | cut -d: -f2)
	_sd=$(printf '%s' "$1" | cut -d: -f3)
	case "$_ss" in L|R|B) ;; *) echo "REFUSE:side '$_ss' is not L, R or B"; return ;; esac
	case "$_sh" in ''|*[!0-9]*) echo "REFUSE:hph '$_sh' is not a number"; return ;; esac
	case "$_sd" in ''|*[!0-9]*) echo "REFUSE:dig '$_sd' is not a number"; return ;; esac
	[ "$(printf '%s' "$1" | tr -cd ':' | wc -c)" -eq 2 ] ||
		{ echo "REFUSE:'$1' is not side:hph:dig"; return; }
	[ "$_sh" -le 20 ] || { echo "REFUSE:hph $_sh above 20"; return; }
	[ "$_sd" -le 84 ] || { echo "REFUSE:dig $_sd above 84 (0 dB)"; return; }
	echo OK
}
# dapm_spec_field <hph> -> the 0x1ae / 0x1b4 field the driver must hold, hex
dapm_spec_field() { printf '%02x' $(( 20 - $1 )); }
# dapm_spec_dig <dig> -> the 0x2b7 / 0x2bf byte, hex (s8 dB, two's complement)
dapm_spec_dig() { printf '%02x' $(( ($1 - 84) & 0xff )); }

# ------------------------------------------------------------------ r187 --
#
# Three outputs, each its own DAPM chain and ownership mask in dapm_state:
#   hph  held=      nine stages, 1ff, 6 forced writes per stream (r185)
#   spk  spk_held=  six stages, 3f, 2 forced writes (the 0x314 pair only)
#   ear  ear_held=  six stages, 3f, 2 forced writes
#   lo   lo_held=   six stages, 3f, 2 forced writes (r188, all four line outs)
#
# dapm_out <hph|spk|ear|lo> -> sets OUT_PIN OUT_KEY OUT_ALL OUT_NONE OUT_STAGES
#                           OUT_FORCED OUT_VMAX; returns 1 for anything else
dapm_out() {
	case "$1" in
	hph) OUT_PIN="Headphones Switch"; OUT_KEY=held; OUT_ALL=1ff; OUT_NONE=000
	     OUT_STAGES=9; OUT_FORCED=6; OUT_VMAX=20 ;;
	spk) OUT_PIN="Speaker Switch"; OUT_KEY=spk_held; OUT_ALL=3f; OUT_NONE=00
	     OUT_STAGES=6; OUT_FORCED=2; OUT_VMAX=8 ;;
	ear) OUT_PIN="Earpiece Switch"; OUT_KEY=ear_held; OUT_ALL=3f; OUT_NONE=00
	     OUT_STAGES=6; OUT_FORCED=2; OUT_VMAX=6 ;;
	lo)  OUT_PIN="Lineout Switch"; OUT_KEY=lo_held; OUT_ALL=3f; OUT_NONE=00
	     OUT_STAGES=6; OUT_FORCED=2; OUT_VMAX=20 ;;
	# r189: the I2S loudspeaker. The codec must hold NOTHING for it (held 000
	# live and after); the path's own state is i2s_spk_state, below.
	i2s) OUT_PIN="Loudspeaker Switch"; OUT_KEY=held; OUT_ALL=000; OUT_NONE=000
	     OUT_STAGES=0; OUT_FORCED=0; OUT_VMAX=0 ;;
	*) return 1 ;;
	esac
}

# dapm_held_key_is <dapm_state text> <key> <want> -> OK, or REFUSE:<why>
dapm_held_key_is() {
	_dk=$(dapm_kv "$1" "$2")
	if [ -z "$_dk" ]; then
		echo "REFUSE:no $2= in dapm_state"
	elif [ "$_dk" = "$3" ]; then
		echo "OK"
	else
		echo "REFUSE:$2=$_dk want $3"
	fi
}

# dapm_forced_want_out <out> <index> -> "reg mask dir"
dapm_forced_want_out() {
	case "$1" in
	hph) dapm_forced_want "$2" ;;
	*) if [ $(( $2 % 2 )) -eq 0 ]; then echo "314 ff set"; else echo "314 ff clear"; fi ;;
	esac
}

# dapm_spec_ok_out <out> <spec> -> OK, or REFUSE:<why>. hph is dapm_spec_ok's
# side:hph:dig; spk and ear take side:vol:dig with vol up to the output's max
# (Speaker Volume 0..8, Earpiece Volume 0..6, r188 Lineout Volume 0..20).
dapm_spec_ok_out() {
	dapm_out "$1" || { echo "REFUSE:unknown output '$1'"; return; }
	[ "$1" = "hph" ] && { dapm_spec_ok "$2"; return; }
	_so=$(dapm_spec_ok "$(printf '%s' "$2" | awk -F: '{print $1 ":0:" $3}')")
	[ "$_so" = "OK" ] || { echo "$_so"; return; }
	_sv=$(printf '%s' "$2" | cut -d: -f2)
	case "$_sv" in ''|*[!0-9]*) echo "REFUSE:vol '$_sv' is not a number"; return ;; esac
	[ "$_sv" -le "$OUT_VMAX" ] || { echo "REFUSE:vol $_sv above $OUT_VMAX for $1"; return; }
	# r189: the I2S path has no digital volume either -- the tone is the level
	if [ "$1" = "i2s" ] && [ "$(printf '%s' "$2" | cut -d: -f3)" != "84" ]; then
		echo "REFUSE:dig must be 84 for i2s (no digital volume on this path)"; return
	fi
	echo OK
}

# r189: THE I2S LOUDSPEAKER. Its route from MultiMedia1, its own state (the
# card module's component), and two oracles that component does not write:
# the regulator class for the 5 V rail (PM8941 s4) and the TLMM pinmux.
I2S_MIXER="${I2S_MIXER:-SEC_MI2S_RX Audio Mixer MultiMedia1}"
SLIM_MIXER="${SLIM_MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
# r191: THE VISA SPEAKER AMPLIFIER (I2C5 @ 0x40, PM8941 GPIO20) -- its sysfs
# in the card module's I2C driver: visa_state, visa_dump, visa_identify
# (read-only on the chip), visa_power (Windows' script / standby + GPIO low).
visa_dir() { ls -d /sys/bus/i2c/drivers/lumia1520-visa/*-0040 2>/dev/null | head -n1; }
visa_state() { _vsd=$(visa_dir); [ -n "$_vsd" ] && cat "$_vsd/visa_state" 2>/dev/null; }
visa_power() { _vsd=$(visa_dir); [ -n "$_vsd" ] && echo "$1" > "$_vsd/visa_power" 2>/dev/null; }
i2s_state_file() { ls /sys/bus/platform/drivers/lumia1520-i2s-spk/*/i2s_spk_state 2>/dev/null | head -n1; }
i2s_state() { _isf=$(i2s_state_file); [ -n "$_isf" ] && cat "$_isf" 2>/dev/null; }
# vreg_5v -> "<state> <num_users>" of the regulator named s4 at 5000000 uV
# The directory is found ONCE, when this file is sourced: a scan of every
# regulator is ~120 forks, and r189's first I2S stream ended (1 s) while the
# live sample was still scanning -- it then read the pins already asleep.
vreg_5v_find() {
	for _vr in /sys/class/regulator/regulator.*; do
		[ "$(cat "$_vr/name" 2>/dev/null)" = "s4" ] || continue
		[ "$(cat "$_vr/microvolts" 2>/dev/null)" = "5000000" ] || continue
		printf '%s' "$_vr"
		return 0
	done
}
VREG5V_DIR="${VREG5V_DIR:-$(vreg_5v_find)}"
vreg_5v() {
	[ -n "$VREG5V_DIR" ] || { printf '? ?'; return; }
	printf '%s %s' "$(cat "$VREG5V_DIR/state" 2>/dev/null)" "$(cat "$VREG5V_DIR/num_users" 2>/dev/null)"
}
# mi2s_mux -> the pinmux function of TLMM 79 80 81 82 ("?" when unclaimed)
mi2s_mux_parse() {	# mi2s_mux_parse <pinmux-pins text>
	for _mp in 79 80 81 82; do
		_mf=$(printf '%s\n' "$1" | grep -E "^pin $_mp \(" | sed -n 's/.* function \([a-z0-9_]*\) .*/\1/p' | head -n1)
		printf '%s\n' "${_mf:-?}"
	done | tr '\n' ' ' | sed 's/ $//'
}
mi2s_mux() {
	mi2s_mux_parse "$(cat "$(ls /sys/kernel/debug/pinctrl/*fd510000*/pinmux-pins 2>/dev/null | head -n1)" 2>/dev/null)"
}
# r194: EAR_CMBUFF -- a comma list of clear|keep, one per earpiece stream,
# the last repeating (docs/audio/wcd9320-r194-earpiece-mapping.md)
ear_cmbuff_list_ok() {	# ear_cmbuff_list_ok <list> -> 0 when every element is clear|keep
	[ -n "$1" ] || return 1
	for _ec in $(printf '%s' "$1" | tr ',' ' '); do
		case "$_ec" in clear|keep) ;; *) return 1 ;; esac
	done
	case "$1" in ,*|*,|*,,*) return 1 ;; esac
	return 0
}
# r195: EAR_ORDER -- a comma list of downstream|windows, one per earpiece
# stream, the last repeating; picked per stream with ear_cmbuff_for
ear_order_list_ok() {	# ear_order_list_ok <list> -> 0 when every element is downstream|windows
	[ -n "$1" ] || return 1
	for _eo in $(printf '%s' "$1" | tr ',' ' '); do
		case "$_eo" in downstream|windows) ;; *) return 1 ;; esac
	done
	case "$1" in ,*|*,|*,,*) return 1 ;; esac
	return 0
}
ear_cmbuff_for() {	# ear_cmbuff_for <list> <stream n, from 1> -> its mode
	_ecl=""; _eci=0
	for _ec in $(printf '%s' "$1" | tr ',' ' '); do
		_eci=$((_eci + 1)); _ecl=$_ec
		[ "$_eci" -lt "$2" ] || break
	done
	printf '%s' "$_ecl"
}

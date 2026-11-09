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
DAPM_CARD_VERSION="${DAPM_CARD_VERSION:-q6-card-rc7}"
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
	echo OK
}

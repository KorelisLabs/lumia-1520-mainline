#!/bin/sh
#
# r184: the DAPM expectations, as pure functions, so the selftest can run them
# offline against the same rules the gates use on the phone.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md. The driver exports one line,
#
#   dapm_state: held=3f ups=6 downs=0 refusals=0 failures=0 mclk_users=1 pa_on=1
#
# where held is a bitmask of the six stages DAPM powered itself:
#
#   bit 0 MCLK, 1 class-H prep, 2 cdc prereq (forced 0x314), 3 RX1,
#   bit 4 HPHL DAC, 5 HPHL PA
#
# so the whole path is 3f and nothing is 00. No other value is legal at a
# boundary -- a partial mask means a stage refused or failed.

DAPM_HELD_ALL=3f
DAPM_HELD_NONE=00
DAPM_STAGES=6			# ups and downs per stream
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
DAPM_CARD_VERSION="${DAPM_CARD_VERSION:-q6-card-rc4}"
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

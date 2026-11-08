#!/bin/sh
#
# r184: the end-of-run checks of wcd9320-dapm-listen.sh, run on their own
# against the codec's current state. For a run whose report did not complete
# (the first full run's report looped on stream 1 until it was killed), and
# valid only while nothing has touched the codec since that run.
#
# Usage:  sudo env STREAMS=2 FORCED_START=0 sh wcd9320-dapm-postcheck.sh
#
# The register baseline is the one every C3a teardown on this boot restores
# to, read from the fuse-loaded range at boot: wg ctl da, wg time 15, wg ocp
# 2a, chopper a4, gain 00.

set -u
MODE="wcd9320-dapm-postcheck"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-hphl-pa-expect.sh"
. "$DIR/wcd9320-dapm-expect.sh"
rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

STREAMS="${STREAMS:-2}"
FORCED_START="${FORCED_START:-0}"
find_devices
D=$(cat "$PGD/dapm_state")
POST=$(cat "$PGD/hphl_pa_state")
DPOST=$(cat "$PGD/hphl_dac_state")
CPOST=$(cat "$PGD/clk_source_state")
FLOG=$(cat "$PGD/forced_log")
PIN=$(dapm_pin_value "$("$DIR/alsa-setctl" -D /dev/snd/controlC0 --get "$DAPM_PIN" 2>/dev/null)")

hdr "end-of-run checks, $STREAMS stream(s) from a boot-fresh DAPM state"
say "dapm_state: $D"
check "card module version" "$(cat "$DAPM_CARD_VERSION_PATH" 2>/dev/null)" "$DAPM_CARD_VERSION"
check "DAPM ups" "$(dapm_kv "$D" ups)" "$((DAPM_STAGES * STREAMS))"
check "DAPM downs" "$(dapm_kv "$D" downs)" "$((DAPM_STAGES * STREAMS))"
check "DAPM refusals" "$(dapm_kv "$D" refusals)" "0"
check "DAPM failures" "$(dapm_kv "$D" failures)" "0"
check "DAPM holds nothing" "$(dapm_kv "$D" held)" "$DAPM_HELD_NONE"
check "pin OFF" "$PIN" "0"
check "nobody holds MCLK" "$(rv "$CPOST" mclk_users)" "0"
check "codec back on RCO" "$(rv "$CPOST" on_mclk)" "0"
check "PA off (0x1ab)" "$(rv "$POST" pa_0x1ab)" "80"
check "guard never tripped" "$(rv "$POST" guard_tripped)" "0"
check "no OCP fault" "$(rv "$POST" ocp_seen)" "0"
check "PA enables == disables" "$(rv "$POST" enables)" "$(rv "$POST" disables)"
check "PA enables" "$(rv "$POST" enables)" "$STREAMS"
check "C3 aborts" "$(rv "$POST" aborts)" "0"
check "forced operations" "$(( $(rv "$FLOG" forced_n) - FORCED_START ))" "$((WCD9320_PA_FORCED_PER_CYCLE * STREAMS))"
_i=0
while [ "$_i" -lt "$((WCD9320_PA_FORCED_PER_CYCLE * STREAMS))" ]; do
	case $((_i % 4)) in
	0) _wr=314; _wd=set ;;
	1) _wr=30d; _wd=set ;;
	2) _wr=30d; _wd=clear ;;
	3) _wr=314; _wd=clear ;;
	esac
	_j=$((FORCED_START + _i))
	check "f$_j register" "$(rv "$FLOG" "f${_j}_reg")" "$_wr"
	check "f$_j direction" "$(rv "$FLOG" "f${_j}_dir")" "$_wd"
	_i=$((_i + 1))
done
check "gain restored" "$(rv "$POST" lgain_0x1ae)" "00"
check "wg ctl restored" "$(rv "$POST" wgctl_0x1ac)" "da"
check "wg time restored" "$(rv "$POST" wgtime_0x1ad)" "15"
check "wg ocp restored" "$(rv "$POST" wgocp_0x1a9)" "2a"
check "chopper restored" "$(rv "$POST" chop_0x1a5)" "a4"
check "DAC off" "$(rv "$DPOST" dac_0x1b1)" "00"
check "DSM mux cleared" "$(rv "$DPOST" dsm_0x3b0)" "00"
check "RX bias released" "$(rv "$DPOST" bias_refs)" "0"
say "cache_check: $(cat "$PGD/cache_check" | tr '\n' ' ')"
check "cache mismatches" "$(rv "$(cat "$PGD/cache_check")" mismatches)" "0"
emit_verdict

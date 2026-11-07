#!/bin/sh
#
# When does bit 3 of CDC_RX1_B6_CTL (0x2b5) / CDC_RX2_B6_CTL (0x2bd) set?
#
# r179's first zdet left both reading 88 where they read 80, and writing 80
# back does not clear bit 3. The r165-era C2b runs saw 0x2b5 = 88 too, with
# the compander up. Downstream never writes bit 3 and never reads these
# registers back. So: a hardware-set status bit, and if the chip sets it on
# its own the register is NOT cacheable as it stands.
#
# One fresh boot, steps in order, each followed by:
#   - cache_check (cacheable registers: cache against chip)
#   - the chip value of 0x2b5 (rx1_digital_state, chip read)
#
#   0  idle, as booted
#   1  the r178 voltmeter (never writes 0x2b5)
#   2  RX1 digital chain on, then off (writes 0x2b5 bit 5)
#   3  RX1 on + a 2 s stream through it, then off
#   4  one zdet (writes 0x2b5 / 0x2bd = 0x81, then restores)
#
# Reported, not graded: this is a classification run. PA never enabled except
# inside the zdet, exactly as r179.
#
# Usage:  sudo sh wcd9320-rxb6-trace.sh     (fresh boot, headset plugged in)

set -u
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
find_devices

PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
RUNNER="$DIR/pcm-run-measured"
SETCTL="$DIR/alsa-setctl"
CSRC="$PGD/clk_source_test"; MCLKT="$PGD/mclk_test"
DIVT=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -d "$d" ] && { DIVT="$d/mclk_div_test"; break; }
done
rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

[ "$(id -u)" = "0" ] || { say "need root"; exit 2; }
[ -e "$PGD/hphl_zdet" ] || { say "need zdet-rc1"; exit 2; }
[ "$(rv "$(cat "$PGD/hphl_zdet")" runs)" = "0" ] || { say "not a fresh boot (zdet already ran)"; exit 2; }

snap() {	# snap <label>
	_cc=$(cat "$PGD/cache_check" 2>/dev/null | tr '\n' ' ')
	_ch=$(grep -o 'chain_0x2b5=[0-9a-f]*' "$PGD/rx1_digital_state")
	_dbg=$(grep -E '^(2b5|2bd):' "/sys/kernel/debug/regmap/$PGD_NAME/registers" | tr '\n' ' ')
	printf '%-26s chip %s | cache(debugfs) %s| %s\n' "$1" "${_ch#chain_0x2b5=}" "$_dbg" \
		"$(printf '%s' "$_cc" | sed 's/  */ /g')"
}

say "RX_B6 bit-3 trace, $(date -u '+%Y%m%dT%H%M%SZ'), module $(cat /sys/module/wcd9320/version)"
snap "0 idle"

echo on > "$DIVT"; echo on > "$MCLKT"; echo mclk > "$CSRC"
snap "  on MCLK"

echo measure > "$PGD/hphl_vm"; say "  vm rc=$?"
snap "1 after voltmeter"

echo rx1-on > "$PGD/rx1_digital_test"; snap "2 rx1 on"
echo rx1-off > "$PGD/rx1_digital_test"; snap "2 rx1 off"

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
echo rx1-on > "$PGD/rx1_digital_test"
"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p 960 -n 4 -t 2 > /tmp/.b6-$$ 2>&1
say "  stream: $(grep -E '^(final_rc|hw_ptr_advance)=' /tmp/.b6-$$ | tr '\n' ' ')"
rm -f /tmp/.b6-$$
snap "3 rx1 on, after stream"
echo rx1-off > "$PGD/rx1_digital_test"; snap "3 rx1 off"

echo measure > "$PGD/hphl_zdet"; say "  zdet rc=$?"
snap "4 after one zdet"
say "  zdet: $(cat "$PGD/hphl_zdet" | tr '\n' ' ')"

echo rco > "$CSRC"; echo off > "$MCLKT"; echo off > "$DIVT"
snap "  back on RCO"
say ""
say "-- dmesg: writes to 0x2b5 / 0x2bd and restore mismatches --"
dmesg | grep -E '0x2b5|0x2bd|RESTORE MISMATCH' | tail -n 20

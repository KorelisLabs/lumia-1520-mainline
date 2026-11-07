#!/bin/sh
#
# r177 repeat: row C (RX1 on, data, nothing else) N times on one boot, with
# the RC oscillator tuner (0x1fd, hardware-populated and volatile, measured to
# move on its own) sampled at each window.
#
# Why: the gate and the confirmation together gave 3 clean and 4 overflowing
# steady windows out of 7 with RX1 on, independent of the forced 0x314 write.
# This measures the rate on the plainest configuration and records whether the
# codec's free-running clock trim moves with it. Digital only: no 0x314, no
# prep, no DAC, no PA. Supplementary evidence.
#
# Usage:  sudo sh wcd9320-port-flow-repeat.sh [N]

set -u
N="${1:-8}"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
find_devices
PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
RUNNER="$DIR/pcm-run-measured"
PS="$PGD/slim_port_status"
RX1T="$PGD/rx1_digital_test"
PAS="$PGD/hphl_pa_state"
REGS="/sys/kernel/debug/regmap/$PGD_NAME/registers"

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
pa() { _p=$(rv "$(cat "$PAS")" pa_0x1ab); printf '%02x' $(( 0x${_p:-ff} & 0x30 )); }
tuner() { grep -m1 '^1fd:' "$REGS" 2>/dev/null | cut -d' ' -f2; }

[ "$(id -u)" = "0" ] || { say "need root"; exit 2; }
[ "$(pa)" = "00" ] || { say "PA not off"; exit 2; }

say "r177 repeat, $(date -u '+%Y%m%dT%H%M%SZ'), module $(cat /sys/module/wcd9320/version), N=$N"
say "step  tuner-before  s0:pend/src  s1:pend/src  verdict   tuner-s1  pa"
clean=0
i=0
while [ "$i" -lt "$N" ]; do
	i=$((i + 1))
	sleep 1
	echo clear > "$PS"
	t0=$(tuner)
	echo rx1-on > "$RX1T"
	"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p 960 -n 4 -t 6 > /tmp/.pfr-$$ 2>&1 &
	pid=$!
	sleep 2
	echo clear > "$PS"
	s0=$(cat "$PS")
	sleep 2
	s1=$(cat "$PS")
	t1=$(tuner)
	wait "$pid"
	echo rx1-off > "$RX1T"
	v=clean
	[ "$(rv "$s1" pending)" = "1" ] && [ "$(rv "$s1" overflow)" = "1" ] && v=OVERFLOW
	[ "$v" = "clean" ] && clean=$((clean + 1))
	printf '%-5s %-13s %s/%-10s %s/%-10s %-9s %-9s %s\n' "$i" "$t0" \
		"$(rv "$s0" pending)" "$(rv "$s0" src)" \
		"$(rv "$s1" pending)" "$(rv "$s1" src)" "$v" "$t1" "$(pa)"
done
rm -f /tmp/.pfr-$$
say ""
say "clean windows: $clean of $N"

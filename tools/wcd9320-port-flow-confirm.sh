#!/bin/sh
#
# r177 confirmation: the C/D comparison, alternated, on the same boot.
#
# The main gate ran C (RX1 only) then D (forced 0x314 = 03, then RX1) once
# each, and C was clean while D overflowed. Two things that one pass cannot
# rule out:
#
#   order      D always ran after C
#   recovery   whether the 0x314 inverse (restore to the measured 00) brings
#              consumption back
#
# So this alternates D C D C. Same settle/clear/watch shape as the gate. Digital
# only: no prep, no DAC, no PA. Supplementary evidence, not a milestone gate.
#
# Usage:  sudo sh wcd9320-port-flow-confirm.sh
# Exit:   0 ran, 2 invalid setup.

set -u
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
find_devices

PCMDEV="${PCMDEV:-/dev/snd/pcmC0D0p}"
RUNNER="$DIR/pcm-run-measured"
PS="$PGD/slim_port_status"
PREREQ="$PGD/cdc_clk_prereq"
RX1T="$PGD/rx1_digital_test"
PAS="$PGD/hphl_pa_state"
FLOG="$PGD/forced_log"

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
pa() { _p=$(rv "$(cat "$PAS")" pa_0x1ab); printf '%02x' $(( 0x${_p:-ff} & 0x30 )); }

[ "$(id -u)" = "0" ] || { say "need root"; exit 2; }
[ -x "$RUNNER" ] || { say "no pcm-run-measured"; exit 2; }
F0=$(rv "$(cat "$FLOG")" forced_n)
[ $(( ${F0:-99} + 4 )) -le 16 ] || { say "forced journal too full: $F0"; exit 2; }
[ "$(pa)" = "00" ] || { say "PA not off"; exit 2; }

say "r177 confirmation, $(date -u '+%Y%m%dT%H%M%SZ'), module $(cat /sys/module/wcd9320/version)"
say "forced journal starts at $F0"
say "step  setup     s0:pend/src  s1:pend/src  verdict   pa"
n=0
for step in D C D C; do
	n=$((n + 1))
	sleep 1
	echo clear > "$PS"
	[ "$step" = "D" ] && echo on > "$PREREQ"
	echo rx1-on > "$RX1T"
	"$RUNNER" -D "$PCMDEV" -r 48000 -c 1 -p 960 -n 4 -t 6 > /tmp/.pfc-$$ 2>&1 &
	pid=$!
	sleep 2
	echo clear > "$PS"
	s0=$(cat "$PS")
	sleep 2
	s1=$(cat "$PS")
	wait "$pid"
	adv=$(sed -n 's/^hw_ptr_advance=//p' /tmp/.pfc-$$)
	echo rx1-off > "$RX1T"
	[ "$step" = "D" ] && echo off > "$PREREQ"
	v=clean
	[ "$(rv "$s1" pending)" = "1" ] && [ "$(rv "$s1" overflow)" = "1" ] && v=OVERFLOW
	printf '%-5s %-9s %s/%-10s %s/%-10s %-9s %s  (hw_ptr_advance=%s)\n' \
		"$n$step" "$([ "$step" = D ] && echo 'clk rx1' || echo 'rx1')" \
		"$(rv "$s0" pending)" "$(rv "$s0" src)" \
		"$(rv "$s1" pending)" "$(rv "$s1" src)" "$v" "$(pa)" "$adv"
done
rm -f /tmp/.pfc-$$
say ""
say "forced journal now:"
cat "$FLOG"

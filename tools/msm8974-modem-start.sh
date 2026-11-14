#!/bin/sh
#
# M3: the first modem start, by hand -- docs/msm8974-modem-mapping.md.
#
# Starts the MSS remoteproc once and watches what happens: the MBA (modem
# boot authenticator) loading and checking the modem image, the modem
# coming up, its SMD channels appearing. rmtfs is NOT running for this
# step, so a modem that gets far enough will wait on, or crash over, its
# file systems -- that is expected. Automatic recovery is switched off for
# the run, so a crash cannot turn into a restart loop. At the end the modem
# is stopped again and every setting goes back.
#
# Before running: the modem file systems are backed up (M0), and the
# firmware is installed as /lib/firmware/mba.b00 + modem.mdt/.bNN (M1).
#
# Usage (as root on the phone): sh msm8974-modem-start.sh [watch-seconds]
# Output: /var/log/msm8974-modem-start-<stamp>.txt
# Exit: 0 the modem reached "running" and was stopped cleanly, 1 it did not
#       (the evidence says how far it got), 2 refused before anything changed.

set -u
WATCH="${1:-30}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-modem-start-$STAMP.txt"
FW=/lib/firmware

# the MSS remoteproc: the one bound to remoteproc@fc880000
RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in
	*fc880000*) RP=$r ;;
	esac
done
bad=""
[ -n "$RP" ] || bad="$bad no-mss-remoteproc"
[ -z "$RP" ] || [ "$(cat "$RP/state" 2>/dev/null)" = offline ] || bad="$bad state=$(cat "$RP/state" 2>/dev/null)"
[ -f "$FW/mba.b00" ] || bad="$bad no-mba.b00"
[ -f "$FW/modem.mdt" ] || bad="$bad no-modem.mdt"
[ -f "$FW/modem.b28" ] || bad="$bad no-modem.b28"
pgrep -x rmtfs >/dev/null 2>&1 && bad="$bad rmtfs-running(this-step-is-without-it)"
case "$WATCH" in ''|*[!0-9]*) bad="$bad watch=$WATCH" ;; esac
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
since() { dmesg | awk -v t="${T0:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }'; }
REC_PRE=$(cat "$RP/recovery" 2>/dev/null)
RES=1

{
echo "================ msm8974 modem start $STAMP ================"
echo "remoteproc: $RP ($(cat "$RP/name" 2>/dev/null)), firmware $(cat "$RP/firmware" 2>/dev/null), state $(cat "$RP/state")"
echo "kernel: $(uname -r); dmesg from $T0 s"
echo "firmware: $(ls -la $FW/mba.b00 | awk '{print $5}') bytes mba.b00, $(ls $FW/modem.* | wc -l) modem files"
echo "recovery was: $REC_PRE -> disabled for this run"
echo disabled > "$RP/recovery" 2>/dev/null
echo "rpmsg devices before: $(ls /sys/bus/rpmsg/devices 2>/dev/null | tr '\n' ' ')"
echo "---- start at uptime $(cut -d' ' -f1 /proc/uptime)"
# the write blocks while the driver boots the MBA and the modem
timeout 90 sh -c "echo start > '$RP/state'" 2>&1; echo "start write exit $?"
echo "state right after: $(cat "$RP/state")"
_w=0; _last=""
while [ "$_w" -lt "$WATCH" ]; do
	_s=$(cat "$RP/state" 2>/dev/null)
	[ "$_s" != "$_last" ] && echo "  t+${_w}s state $_s" && _last=$_s
	sleep 1; _w=$((_w + 1))
done
echo "rpmsg devices after: $(ls /sys/bus/rpmsg/devices 2>/dev/null | tr '\n' ' ')"
[ "$_last" = running ] && RES=0
echo "---- stop"
if [ "$(cat "$RP/state")" = running ]; then
	timeout 30 sh -c "echo stop > '$RP/state'" 2>&1; echo "stop write exit $?"
fi
sleep 1
echo "state after stop: $(cat "$RP/state")"
[ -n "$REC_PRE" ] && echo "$REC_PRE" > "$RP/recovery" 2>/dev/null
echo "recovery back to: $(cat "$RP/recovery" 2>/dev/null)"
echo "---- dmesg since the start (remoteproc, mss, rpmsg, smd, qrtr, sysmon, errors)"
since | grep -i -E "remoteproc|q6v5|mss|mba|modem|rpmsg|smd|qrtr|sysmon|rmtfs|wwan|fatal|error|fail|crash|wdog" | tail -n 80
echo "---- verdict"
[ "$RES" = 0 ] && echo "RESULT: the modem reached running" || echo "RESULT: the modem did not stay running (last state: $_last)"
} > "$OUT" 2>&1
cat "$OUT"
exit "$RES"

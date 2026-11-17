#!/bin/sh
#
# bam-dmux modem-restart test -- docs/msm8974-modem-mapping.md section 31.
#
# Patch 0010 makes qcom_bam_dmux forget the modem's open channels when the
# modem goes down (QCOM_SSR_BEFORE_SHUTDOWN), so a restarted modem can open
# them again. Before it, every OPEN after the first modem start of a boot
# was rejected with "Channel already open".
#
# Run after a boot with the patched module (version ssr-rc1) and the modem
# services running, as they come up at boot. Each cycle stops ModemManager
# and rmtfs (rmtfs -s stops the modem), then starts them again, the same way
# the services test does. READ-ONLY for the modem partitions (rmtfs -r);
# nothing enables the radio, and the same radio-on guard stops everything.
# bam-dmux dynamic debug is switched on for the run, so the log shows the
# channel opens, the shutdown reset and the power-control edges.
#
# Usage (as root on the phone): sh msm8974-bam-dmux-restart-test.sh [cycles]
# Output: /var/log/msm8974-bam-dmux-restart-<stamp>.txt
# Exit: 0 pass: every restart reopened the channels, no "Channel already open"
#       1 not (the per-cycle evidence says where), partitions unchanged
#       2 refused before anything changed
#       3 A PARTITION CHANGED -- restore it from the M0 backup
#       4 the radio-on guard tripped (services stopped), partitions unchanged

set -u
CYCLES="${1:-3}"
WANT_VERSION="${WANT_VERSION:-ssr-rc1}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-bam-dmux-restart-$STAMP.txt"
PARTS="MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG DPP SSD"
QDEV=/dev/wwan0qmi0
DDC=/sys/kernel/debug/dynamic_debug/control

RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in *fc880000*) RP=$r ;; esac
done
bad=""
[ -n "$RP" ] || bad="$bad no-mss-remoteproc"
case "$CYCLES" in ''|*[!0-9]*|0) bad="$bad cycles=$CYCLES" ;; esac
V=$(cat /sys/module/qcom_bam_dmux/version 2>/dev/null)
[ "$V" = "$WANT_VERSION" ] || bad="$bad qcom_bam_dmux-version=${V:-none}(want-$WANT_VERSION)"
[ "$(nmcli radio wwan 2>/dev/null)" = disabled ] || bad="$bad NM-wwan-not-disabled"
systemctl cat rmtfs 2>/dev/null | grep -q -x 'ExecStart=/usr/bin/rmtfs -r -P -s -o /run/rmtfs-parts' || bad="$bad rmtfs-drop-in-missing"
systemctl is-active -q rmtfs || bad="$bad rmtfs-not-active"
systemctl is-active -q ModemManager || bad="$bad ModemManager-not-active"
[ -z "$RP" ] || [ "$(cat "$RP/state")" = running ] || bad="$bad modem-not-running"
[ -w "$DDC" ] || bad="$bad no-dynamic-debug"
command -v mmcli >/dev/null || bad="$bad no-mmcli"
for p in $PARTS; do [ -b "/dev/disk/by-partlabel/$p" ] || bad="$bad no-partition-$p"; done
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

hashes() { for p in $PARTS; do printf '%s=%s ' "$p" "$(sha256sum "/dev/disk/by-partlabel/$p" | cut -c1-64)"; done; }
short() { echo "$1" | sed -E 's/=([0-9a-f]{16})[0-9a-f]*/=\1/g'; }
dlast() { dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p'; }
since() { dmesg | awk -v t="${1:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }'; }
redact() {
	sed -E -e '/([Ee]quipment id|[Dd]evice id|device-identifier|IMEI|imei|IMSI|imsi|ICCID|iccid|[Oo]wn number|own-numbers|[Ee]id|ESN|MEID|[Ss]erial)/ { s/(: |= ?)[^ ].*/\1<redacted>/; }' \
	       -e 's/[0-9]{14,}/<redacted-digits>/g'
}
mm_get() { mmcli -m any -K 2>/dev/null | awk -F': ' -v k="$1" '$1 ~ "^"k" *$" { print $2; exit }'; }
ports() { for n in /sys/class/net/wwan*; do [ -e "$n" ] && printf '%s(%s,%s) ' "$(basename "$n")" "$(cat "$n/operstate")" "$(udevadm info -q property "$n" | grep -q '^ID_MM_QCOM_SOC=1' && echo tagged || echo UNTAGGED)"; done; }
GUARD=0
FAILS=""

stop_all() {
	timeout 30 systemctl stop ModemManager 2>&1
	timeout 40 systemctl stop rmtfs 2>&1
	_w=0
	while [ "$(cat "$RP/state")" != offline ] && [ "$_w" -lt 15 ]; do sleep 1; _w=$((_w + 1)); done
	if [ "$(cat "$RP/state")" != offline ]; then
		echo "    modem still $(cat "$RP/state") 15 s after rmtfs stopped -- stopping it directly"
		timeout 30 sh -c "echo stop > '$RP/state'" 2>&1
	fi
	echo "    stopped: ModemManager $(systemctl is-active ModemManager), rmtfs $(systemctl is-active rmtfs), modem $(cat "$RP/state") (${_w} s)"
}

# Start both services and wait for ModemManager to settle; sets ST/PW/NP.
start_all() {
	timeout 60 systemctl start rmtfs 2>&1
	_w=0
	while [ "$(cat "$RP/state")" != running ] && [ "$_w" -lt 90 ] && systemctl is-active -q rmtfs; do sleep 1; _w=$((_w + 1)); done
	echo "    modem $(cat "$RP/state") after ${_w} s"
	_w=0
	while [ ! -c "$QDEV" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
	echo "    $QDEV $([ -c "$QDEV" ] && echo "present after ${_w} s" || echo "ABSENT after 30 s")"
	timeout 60 systemctl start ModemManager 2>&1
	_w=0; ST=""
	while [ "$_w" -lt 120 ]; do
		ST=$(mm_get modem.generic.state)
		case "$ST" in failed|disabled|enabling|enabled|searching|registered|connecting|connected) break ;; esac
		sleep 2; _w=$((_w + 2))
	done
	PW=$(mm_get modem.generic.power-state)
	RG=$(mm_get modem.3gpp.registration-state)
	NP=$(mmcli -m any -K 2>/dev/null | grep -c '^modem.generic.ports.value')
	echo "    ModemManager after ${_w} s: state ${ST:-none} ($(mm_get modem.generic.state-failed-reason)), power ${PW:-none}, registration ${RG:-none}, ports $NP, NM wwan $(nmcli radio wwan)"
	case "$PW:$ST:$RG" in
	on:*|*:enabling:*|*:enabled:*|*:searching:*|*:registered:*|*:connecting:*|*:connected:*|*:*:home|*:*:roaming|*:*:searching)
		echo "    GUARD: the modem looks powered or registering -- stopping everything now"
		GUARD=1 ;;
	esac
}

{
echo "================ msm8974 bam-dmux restart test $STAMP ($CYCLES cycles) ================"
echo "kernel $(uname -r); qcom_bam_dmux $V; uptime $(cut -d' ' -f1 /proc/uptime) s"
echo "boot so far: $(dmesg | grep -c 'Channel already open') 'Channel already open', $(dmesg | grep -c -E 'WARNING|BUG:|Oops') warnings/oopses"
echo "net ports: $(ports)"
H0=$(hashes)
echo "partitions before: $(short "$H0")"
echo 'module qcom_bam_dmux +p' > "$DDC" && echo "bam-dmux dynamic debug on"

c=1
while [ "$c" -le "$CYCLES" ] && [ "$GUARD" = 0 ]; do
	echo "---- cycle $c at uptime $(cut -d' ' -f1 /proc/uptime) s"
	T0=$(dlast)
	echo "  stop:"
	stop_all
	T1=$(dlast)
	echo "  bam-dmux while stopping:"
	since "$T0" | grep -E "bam-dmux|bam_dmux" | sed 's/^/    /' | tail -n 20
	echo "  start:"
	start_all
	echo "  net ports: $(ports)"
	echo "  bam-dmux while starting:"
	since "$T1" | grep -E "bam-dmux|bam_dmux" | grep -v "pending skbs" | sed 's/^/    /' | tail -n 30
	NA=$(since "$T1" | grep -c "Channel already open")
	NO=$(since "$T1" | grep -c "open channel:")
	ND=$(since "$T0" | grep -c "modem going down")
	NW=$(since "$T0" | grep -c -E "WARNING|BUG:|Oops|Unable to handle")
	echo "  cycle $c: shutdown resets $ND, channel opens $NO, 'Channel already open' $NA, warnings $NW, MM ${ST:-none}/${PW:-none} ports $NP"
	[ "$ND" -ge 1 ] || FAILS="$FAILS c$c:no-shutdown-reset"
	[ "$NA" = 0 ] || FAILS="$FAILS c$c:already-open=$NA"
	[ "$NO" -ge 1 ] || FAILS="$FAILS c$c:no-channel-opens"
	[ "$NW" = 0 ] || FAILS="$FAILS c$c:warnings=$NW"
	case "$ST:$PW" in failed:off|failed:low|disabled:off|disabled:low) ;; *) FAILS="$FAILS c$c:mm=$ST/$PW" ;; esac
	[ "$NP" = 11 ] || FAILS="$FAILS c$c:ports=$NP"
	c=$((c + 1))
done

echo 'module qcom_bam_dmux -p' > "$DDC" && echo "bam-dmux dynamic debug off"
if [ "$GUARD" = 1 ]; then
	echo "---- guard: stopping ModemManager and rmtfs"
	stop_all
fi
echo "---- ModemManager journal, last cycle (redacted)"
journalctl -u ModemManager --no-pager -o short-monotonic -n 25 2>&1 | grep -E "<wrn>|<err>|state changed|created" | grep -v plugin-manager | redact | sed 's/^/    /'
echo "end: rmtfs $(systemctl is-active rmtfs), ModemManager $(systemctl is-active ModemManager), modem $(cat "$RP/state"), recovery $(cat "$RP/recovery"), NM wwan $(nmcli radio wwan)"
H1=$(hashes)
echo "partitions after:  $(short "$H1")"
echo "---- verdict"
if [ "$H0" != "$H1" ]; then
	echo "RESULT: A PARTITION CHANGED -- compare with the M0 backup and restore"; RES=3
elif [ "$GUARD" = 1 ]; then
	echo "RESULT: GUARD TRIPPED -- the modem looked powered/registering; services stopped; partitions unchanged"; RES=4
elif [ -z "$FAILS" ]; then
	echo "RESULT: $CYCLES restarts, each reset and reopened the bam-dmux channels with no 'Channel already open'; ModemManager back each time, radio off; partitions unchanged"; RES=0
else
	echo "RESULT: not clean:$FAILS; partitions unchanged"; RES=1
fi
} > "$OUT" 2>&1
cat "$OUT"
exit "$RES"

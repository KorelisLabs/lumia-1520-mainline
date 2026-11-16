#!/bin/sh
#
# Daily-use steps 1-2 -- docs/msm8974-modem-mapping.md sections 26-27.
#
# Starts the modem the way a normal boot will: rmtfs.service (stock unit plus
# /etc/systemd/system/rmtfs.service.d/lumia1520.conf: rmtfs -r -P -s -o
# /run/rmtfs-parts, READ-ONLY, rmtfs starts the MSS remoteproc itself), then
# ModemManager.service. Nothing here enables the modem: NetworkManager's WWAN
# switch must already be off, and nothing calls mmcli --enable. If the modem
# ever reports power "on" or a registration state, the guard stops
# ModemManager and rmtfs (which stops the modem) at once.
#
# The six irreplaceable partitions are hashed before and after. Identifiers
# (IMEI, IMSI, ICCID, equipment id, own numbers) are redacted on the phone.
#
# Usage (as root on the phone): sh msm8974-modem-services-test.sh [watch-seconds]
# Output: /var/log/msm8974-modem-services-<stamp>.txt
# Exit: 0 pass: modem up from rmtfs.service, ModemManager has it, radio off
#       1 not (the evidence says how far it got), partitions unchanged
#       2 refused before anything changed
#       3 A PARTITION CHANGED -- restore it from the M0 backup
#       4 the radio-on guard tripped (services stopped), partitions unchanged

set -u
WATCH="${1:-60}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-modem-services-$STAMP.txt"
PARTS="MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG DPP SSD"
QDEV=/dev/wwan0qmi0

RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in
	*fc880000*) RP=$r ;;
	esac
done
bad=""
[ -n "$RP" ] || bad="$bad no-mss-remoteproc"
[ -z "$RP" ] || [ "$(cat "$RP/state" 2>/dev/null)" = offline ] || bad="$bad state=$(cat "$RP/state" 2>/dev/null)"
systemctl is-active -q rmtfs && bad="$bad rmtfs-active"
systemctl is-active -q ModemManager && bad="$bad ModemManager-active"
pgrep -x rmtfs >/dev/null 2>&1 && bad="$bad rmtfs-running"
[ "$(nmcli radio wwan 2>/dev/null)" = disabled ] || bad="$bad NM-wwan-not-disabled"
systemctl cat rmtfs 2>/dev/null | grep -q -x 'ExecStart=/usr/bin/rmtfs -r -P -s -o /run/rmtfs-parts' || bad="$bad rmtfs-drop-in-missing"
command -v mmcli >/dev/null || bad="$bad no-mmcli"
for p in $PARTS; do [ -b "/dev/disk/by-partlabel/$p" ] || bad="$bad no-partition-$p"; done
case "$WATCH" in ''|*[!0-9]*) bad="$bad watch=$WATCH" ;; esac
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

hashes() { for p in $PARTS; do printf '%s=%s ' "$p" "$(sha256sum "/dev/disk/by-partlabel/$p" | cut -c1-64)"; done; }
T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
since() { dmesg | awk -v t="${T0:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }'; }
JSINCE="@$(date +%s)"
redact() {
	sed -E -e '/([Ee]quipment id|IMEI|imei|IMSI|imsi|ICCID|iccid|[Oo]wn number|own-numbers|[Ee]id|ESN|MEID|[Ss]erial)/ { s/(: |= ?)[^ ].*/\1<redacted>/; }' \
	       -e 's/[0-9]{14,}/<redacted-digits>/g'
}
mm_kv() { mmcli -m any -K 2>/dev/null | grep -E "^modem\.(generic\.(state|state-failed-reason|power-state|plugin|primary-port|ports\.value\[[0-9]+\]|drivers\.value\[[0-9]+\]|sim) |3gpp\.registration-state )" | redact; }
mm_get() { mmcli -m any -K 2>/dev/null | awk -F': ' -v k="$1" '$1 ~ "^"k" *$" { print $2; exit }'; }
RES=1
GUARD=0

stop_all() {
	echo "---- stop: ModemManager, then rmtfs (rmtfs -s stops the modem)"
	timeout 30 systemctl stop ModemManager 2>&1; echo "  ModemManager: $(systemctl is-active ModemManager)"
	timeout 40 systemctl stop rmtfs 2>&1; echo "  rmtfs: $(systemctl is-active rmtfs)"
	_w=0
	while [ "$(cat "$RP/state")" != offline ] && [ "$_w" -lt 15 ]; do sleep 1; _w=$((_w + 1)); done
	if [ "$(cat "$RP/state")" != offline ]; then
		echo "  modem still $(cat "$RP/state") 15 s after rmtfs stopped -- stopping it directly"
		timeout 30 sh -c "echo stop > '$RP/state'" 2>&1
	fi
	echo "  modem: $(cat "$RP/state") ($_w s after rmtfs stopped)"
}

{
echo "================ msm8974 modem services (rmtfs.service + ModemManager) $STAMP ================"
echo "remoteproc: $RP ($(cat "$RP/name")), state $(cat "$RP/state"), recovery $(cat "$RP/recovery")"
echo "kernel: $(uname -r); $(apk info -e -v rmtfs modemmanager libmm-glib 2>/dev/null | tr '\n' ' ')"
echo "NetworkManager wwan radio: $(nmcli radio wwan); units: rmtfs $(systemctl is-enabled rmtfs), ModemManager $(systemctl is-enabled ModemManager)"
H0=$(hashes)
echo "partitions before: $(echo "$H0" | sed -E 's/=([0-9a-f]{16})[0-9a-f]*/=\1/g')"

echo "---- systemctl start rmtfs at uptime $(cut -d' ' -f1 /proc/uptime)"
timeout 60 systemctl start rmtfs 2>&1; echo "  start exit $?; rmtfs $(systemctl is-active rmtfs): $(pgrep -a -x rmtfs 2>/dev/null || ps -o args | grep '^/usr/bin/rmtfs' | head -n1)"
echo "  links: $(for l in modemst1 modemst2 fsc fsg; do printf '%s->%s ' "$l" "$(readlink -f "/run/rmtfs-parts/$l")"; done)"
_w=0
while [ "$(cat "$RP/state")" != running ] && [ "$_w" -lt 90 ] && systemctl is-active -q rmtfs; do sleep 1; _w=$((_w + 1)); done
echo "  modem $(cat "$RP/state") after ${_w} s"
_w=0
while [ ! -c "$QDEV" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
echo "  $QDEV: $([ -c "$QDEV" ] && echo "present after ${_w} s" || echo "absent after 30 s")"

if [ "$(cat "$RP/state")" = running ]; then
	echo "---- systemctl start ModemManager at uptime $(cut -d' ' -f1 /proc/uptime) (NM wwan: $(nmcli radio wwan))"
	timeout 60 systemctl start ModemManager 2>&1; echo "  start exit $?; ModemManager $(systemctl is-active ModemManager)"
	_w=0
	while ! mmcli -L 2>/dev/null | grep -q /Modem/ && [ "$_w" -lt 90 ]; do sleep 1; _w=$((_w + 1)); done
	echo "  mmcli -L after ${_w} s:"; mmcli -L 2>&1 | redact | sed 's/^/    /'
	if mmcli -L 2>/dev/null | grep -q /Modem/; then
		echo "---- mmcli -m any (redacted)"
		mmcli -m any 2>&1 | redact | sed 's/^/    /'
		echo "---- watch ${WATCH} s (every 15 s: state, power, registration, NM wwan)"
		_w=0; SEEN=""
		while [ "$_w" -le "$WATCH" ]; do
			st=$(mm_get modem.generic.state); pw=$(mm_get modem.generic.power-state)
			rg=$(mm_get modem.3gpp.registration-state)
			echo "  t+${_w}s state=$st power=$pw registration=$rg nm-wwan=$(nmcli radio wwan)"
			SEEN="$SEEN $st/$pw"
			case "$pw:$st:$rg" in
			on:*|*:enabling:*|*:enabled:*|*:searching:*|*:registered:*|*:connecting:*|*:connected:*|*:*:home|*:*:roaming|*:*:searching)
				echo "  GUARD: the modem looks powered or registering -- stopping everything now"
				GUARD=1; break ;;
			esac
			[ "$_w" -ge "$WATCH" ] && break
			sleep 15; _w=$((_w + 15))
		done
		echo "---- final key values"; mm_kv | sed 's/^/    /'
		FST=$(mm_get modem.generic.state); FPW=$(mm_get modem.generic.power-state)
		FRS=$(mm_get modem.generic.state-failed-reason)
		case "$FST:$FPW" in
		disabled:low|disabled:off|failed:low|failed:off) [ "$GUARD" = 0 ] && RES=0 ;;
		esac
	fi
	echo "---- ModemManager journal (redacted, last 60 lines)"
	journalctl -u ModemManager --since "$JSINCE" --no-pager -o short-monotonic 2>&1 | redact | tail -n 60 | sed 's/^/    /'
fi

stop_all
echo "---- rmtfs journal"
journalctl -u rmtfs --since "$JSINCE" --no-pager -o short-monotonic 2>&1 | redact | tail -n 30 | sed 's/^/    /'
echo "---- dmesg since the start"
since | grep -i -E "remoteproc|q6v5|mss|mba|modem|rmtfs|rpmsg|qrtr|sysmon|wwan|bam|fatal|error|fail|crash|wdog|WARNING" | tail -n 50
echo "after: rmtfs $(systemctl is-active rmtfs), ModemManager $(systemctl is-active ModemManager), modem $(cat "$RP/state"), recovery $(cat "$RP/recovery"), NM wwan $(nmcli radio wwan)"
H1=$(hashes)
echo "partitions after:  $(echo "$H1" | sed -E 's/=([0-9a-f]{16})[0-9a-f]*/=\1/g')"
echo "---- verdict"
if [ "$H0" != "$H1" ]; then
	echo "RESULT: A PARTITION CHANGED -- compare with the M0 backup and restore"; RES=3
elif [ "$GUARD" = 1 ]; then
	echo "RESULT: GUARD TRIPPED -- the modem looked powered/registering; services stopped; partitions unchanged"; RES=4
elif [ "$RES" = 0 ]; then
	echo "RESULT: the modem came up from rmtfs.service, ModemManager holds it ($FST${FRS:+, $FRS}, power $FPW), radio off; partitions unchanged"
else
	echo "RESULT: not complete (modem/ModemManager evidence above; states seen:${SEEN:-none}); partitions unchanged"
fi
} > "$OUT" 2>&1
cat "$OUT"
exit "$RES"

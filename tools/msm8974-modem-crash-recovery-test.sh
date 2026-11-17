#!/bin/sh
#
# Modem crash-recovery test -- docs/msm8974-modem-mapping.md section 32.
#
# Reports a modem crash to remoteproc through debugfs (crash type 1,
# watchdog). That is the host side of a real crash: remoteproc marks the
# modem crashed and recovers it -- rproc_stop(crashed=true) with no sysmon
# shutdown request, SSR notifications (bam-dmux resets its channels on
# BEFORE_SHUTDOWN, patch 0010), coredump, firmware reload (MBA and modem
# segments decrypted by TrustZone again, patches 0008/0009) and restart --
# while rmtfs and ModemManager stay running. The modem firmware itself does
# not fault; it gets the stop request over smp2p.
#
# The coredump must be "disabled" (the default here): a dump reloads the MBA
# and copies the decrypted modem region into memory.
#
# READ-ONLY for the modem partitions (rmtfs -r); nothing enables the radio,
# and the radio-on guard stops ModemManager and rmtfs if the modem ever
# looks powered or registering.
#
# Usage (as root on the phone): sh msm8974-modem-crash-recovery-test.sh [crashes]
# Output: /var/log/msm8974-modem-crash-recovery-<stamp>.txt
# Exit: 0 pass: every crash was recovered, bam-dmux reopened, MM back
#       1 not (the evidence says where), partitions unchanged
#       2 refused before anything changed
#       3 A PARTITION CHANGED -- restore it from the M0 backup
#       4 the radio-on guard tripped (services stopped), partitions unchanged

set -u
CRASHES="${1:-2}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-modem-crash-recovery-$STAMP.txt"
PARTS="MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG DPP SSD"
QDEV=/dev/wwan0qmi0
DDC=/sys/kernel/debug/dynamic_debug/control

RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in *fc880000*) RP=$r ;; esac
done
DBG=/sys/kernel/debug/remoteproc/$(basename "${RP:-none}")
bad=""
[ -n "$RP" ] || bad="$bad no-mss-remoteproc"
case "$CRASHES" in ''|*[!0-9]*|0) bad="$bad crashes=$CRASHES" ;; esac
[ "$(cat /sys/module/qcom_bam_dmux/version 2>/dev/null)" = ssr-rc1 ] || bad="$bad qcom_bam_dmux-not-ssr-rc1"
[ "$(nmcli radio wwan 2>/dev/null)" = disabled ] || bad="$bad NM-wwan-not-disabled"
systemctl is-active -q rmtfs || bad="$bad rmtfs-not-active"
systemctl is-active -q ModemManager || bad="$bad ModemManager-not-active"
ps -o args | grep -q -x '/usr/bin/rmtfs -r -P -s -o /run/rmtfs-parts' || bad="$bad rmtfs-not-read-only"
[ -z "$RP" ] || [ "$(cat "$RP/state")" = running ] || bad="$bad modem-not-running"
[ -z "$RP" ] || [ "$(cat "$RP/recovery")" = enabled ] || bad="$bad recovery-not-enabled"
[ -w "$DBG/crash" ] || bad="$bad no-debugfs-crash"
[ "$(cat "$DBG/coredump" 2>/dev/null)" = disabled ] || bad="$bad coredump-not-disabled"
[ -w "$DDC" ] || bad="$bad no-dynamic-debug"
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
	echo "    stopped: ModemManager $(systemctl is-active ModemManager), rmtfs $(systemctl is-active rmtfs), modem $(cat "$RP/state")"
}

{
echo "================ msm8974 modem crash recovery $STAMP ($CRASHES crashes) ================"
echo "kernel $(uname -r); qcom_bam_dmux $(cat /sys/module/qcom_bam_dmux/version); uptime $(cut -d' ' -f1 /proc/uptime) s"
echo "remoteproc $(basename "$RP") ($(cat "$RP/name")): $(cat "$RP/state"), recovery $(cat "$RP/recovery"), coredump $(cat "$DBG/coredump")"
echo "rmtfs pid $(systemctl show -p MainPID --value rmtfs), ModemManager pid $(systemctl show -p MainPID --value ModemManager)"
echo "boot so far: $(dmesg | grep -c 'Channel already open') 'Channel already open', $(dmesg | grep -c -E 'WARNING|BUG:|Oops') warnings/oopses, $(dmesg | grep -c 'handling crash') crashes"
H0=$(hashes)
echo "partitions before: $(short "$H0")"
echo 'module qcom_bam_dmux +p' > "$DDC" && echo "bam-dmux dynamic debug on"

c=1
while [ "$c" -le "$CRASHES" ] && [ "$GUARD" = 0 ]; do
	echo "---- crash $c at uptime $(cut -d' ' -f1 /proc/uptime) s"
	T0=$(dlast)
	echo 1 > "$DBG/crash"
	# crashed -> (recovery) -> running; the crashed state can be brief
	_w=0; SEEN=""
	while [ "$_w" -lt 120 ]; do
		s=$(cat "$RP/state"); case " $SEEN " in *" $s "*) ;; *) SEEN="$SEEN $s" ;; esac
		[ "$_w" -ge 2 ] && [ "$s" = running ] && since "$T0" | grep -q "is now up" && break
		sleep 1; _w=$((_w + 1))
	done
	echo "  remoteproc states seen:$SEEN; now $(cat "$RP/state") after ${_w} s"
	_q=0
	while [ ! -c "$QDEV" ] && [ "$_q" -lt 30 ]; do sleep 1; _q=$((_q + 1)); done
	echo "  $QDEV $([ -c "$QDEV" ] && echo present || echo ABSENT)"
	_m=0; ST=""
	sleep 3
	while [ "$_m" -lt 120 ]; do
		ST=$(mm_get modem.generic.state)
		case "$ST" in failed|disabled|enabling|enabled|searching|registered|connecting|connected) break ;; esac
		sleep 2; _m=$((_m + 2))
	done
	PW=$(mm_get modem.generic.power-state); RG=$(mm_get modem.3gpp.registration-state)
	NP=$(mmcli -m any -K 2>/dev/null | grep -c '^modem.generic.ports.value')
	echo "  ModemManager after ${_m} s more: state ${ST:-none} ($(mm_get modem.generic.state-failed-reason)), power ${PW:-none}, registration ${RG:-none}, ports $NP, NM wwan $(nmcli radio wwan)"
	case "$PW:$ST:$RG" in
	on:*|*:enabling:*|*:enabled:*|*:searching:*|*:registered:*|*:connecting:*|*:connected:*|*:*:home|*:*:roaming|*:*:searching)
		echo "  GUARD: the modem looks powered or registering -- stopping everything now"
		GUARD=1 ;;
	esac
	echo "  services: rmtfs $(systemctl is-active rmtfs) pid $(systemctl show -p MainPID --value rmtfs), ModemManager $(systemctl is-active ModemManager) pid $(systemctl show -p MainPID --value ModemManager)"
	echo "  net ports: $(ports)"
	echo "  kernel log since the crash report:"
	since "$T0" | grep -E "remoteproc|q6v5|qcom-q6v5-mss|SSD|bam-dmux|sysmon|qrtr|rpmsg|wwan|smd|rmtfs|WARNING|BUG:|Oops|Unable to handle|error|fail" \
		| grep -v -E "Unsupported channel|open channel: [1-6]$|pending skbs" | sed 's/^/    /' | tail -n 40
	NC=$(since "$T0" | grep -c "handling crash")
	NR=$(since "$T0" | grep -c "recovering")
	NU=$(since "$T0" | grep -c "is now up")
	ND=$(since "$T0" | grep -c "modem going down")
	NO=$(since "$T0" | grep -c "open channel:")
	NA=$(since "$T0" | grep -c "Channel already open")
	NW=$(since "$T0" | grep -c -E "WARNING|BUG:|Oops|Unable to handle")
	echo "  crash $c: handled $NC, recovering $NR, up $NU, bam-dmux resets $ND, channel opens $NO, 'Channel already open' $NA, warnings $NW"
	[ "$NC" -ge 1 ] && [ "$NR" -ge 1 ] && [ "$NU" -ge 1 ] || FAILS="$FAILS k$c:not-recovered"
	[ "$(cat "$RP/state")" = running ] || FAILS="$FAILS k$c:modem-$(cat "$RP/state")"
	[ "$ND" -ge 1 ] || FAILS="$FAILS k$c:no-bam-dmux-reset"
	[ "$NO" -ge 8 ] || FAILS="$FAILS k$c:opens=$NO"
	[ "$NA" = 0 ] || FAILS="$FAILS k$c:already-open=$NA"
	[ "$NW" = 0 ] || FAILS="$FAILS k$c:warnings=$NW"
	case "$ST:$PW" in failed:off|failed:low|disabled:off|disabled:low) ;; *) FAILS="$FAILS k$c:mm=$ST/$PW" ;; esac
	[ "$NP" = 11 ] || FAILS="$FAILS k$c:ports=$NP"
	systemctl is-active -q rmtfs || FAILS="$FAILS k$c:rmtfs-down"
	c=$((c + 1))
done

echo 'module qcom_bam_dmux -p' > "$DDC" && echo "bam-dmux dynamic debug off"
if [ "$GUARD" = 1 ]; then
	echo "---- guard: stopping ModemManager and rmtfs"
	stop_all
fi
echo "---- rmtfs journal during the run"
journalctl -u rmtfs --no-pager -o short-monotonic -n 20 2>&1 | redact | sed 's/^/    /'
echo "---- ModemManager journal, last 25 (redacted)"
journalctl -u ModemManager --no-pager -o short-monotonic -n 25 2>&1 | grep -E "<wrn>|<err>|state changed|created|removed|disappeared" | grep -v plugin-manager | redact | sed 's/^/    /'
echo "end: rmtfs $(systemctl is-active rmtfs), ModemManager $(systemctl is-active ModemManager), modem $(cat "$RP/state"), recovery $(cat "$RP/recovery"), coredump $(cat "$DBG/coredump"), NM wwan $(nmcli radio wwan)"
H1=$(hashes)
echo "partitions after:  $(short "$H1")"
echo "---- verdict"
if [ "$H0" != "$H1" ]; then
	echo "RESULT: A PARTITION CHANGED -- compare with the M0 backup and restore"; RES=3
elif [ "$GUARD" = 1 ]; then
	echo "RESULT: GUARD TRIPPED -- the modem looked powered/registering; services stopped; partitions unchanged"; RES=4
elif [ -z "$FAILS" ]; then
	echo "RESULT: $CRASHES crashes recovered: modem back up (decrypted again), bam-dmux reset and reopened with no 'Channel already open', ModemManager back, radio off; partitions unchanged"; RES=0
else
	echo "RESULT: not clean:$FAILS; partitions unchanged"; RES=1
fi
} > "$OUT" 2>&1
cat "$OUT"
exit "$RES"

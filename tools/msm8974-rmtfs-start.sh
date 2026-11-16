#!/bin/sh
#
# M4: the modem with its file systems, served READ-ONLY -- docs/msm8974-modem-mapping.md
# section 19.
#
# rmtfs serves the modem's EFS (/boot/modem_fs1, fs2, fsc, fsg) from the
# Windows Phone partitions MODEM_FS1/FS2/FSC/FSG, through a directory of
# symlinks under the partlabels rmtfs looks for (modemst1, modemst2, fsc,
# fsg). It runs with -r: no partition is ever opened for writing; the
# modem's writes land in an in-memory shadow that is thrown away. The six
# irreplaceable partitions (the four above, DPP, SSD) are hashed before and
# after, and the run says so loudly if any of them changed.
#
# The modem is started once by this script (not by rmtfs), automatic
# recovery off, and stopped at the end; rmtfs is stopped after it, and
# every setting goes back.
#
# M5 (section 21): with QMI_PROBE=1, once the modem is running and
# /dev/wwan0qmi0 exists, a fixed list of READ-ONLY qmicli queries runs
# (service versions, revision, capabilities, operating mode, card status,
# serving system...). Nothing is set. Device identifiers (IMEI, IMEI SV,
# ESN, MEID, serials) are redacted on the phone before anything is written:
# only "present, N characters" is logged, and any 14+ digit run anywhere in
# the QMI output is masked as well.
#
# Usage (as root on the phone): [QMI_PROBE=1] sh msm8974-rmtfs-start.sh [watch-seconds]
# Output: /var/log/msm8974-rmtfs-start-<stamp>.txt (+ the rmtfs log beside it)
# Exit: 0 the modem ran and read its file systems, partitions unchanged
#       1 it did not (the evidence says how far it got), partitions unchanged
#       2 refused before anything changed
#       3 A PARTITION CHANGED -- restore it from the M0 backup

set -u
WATCH="${1:-60}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-rmtfs-start-$STAMP.txt"
RLOG="/var/log/msm8974-rmtfs-$STAMP.log"
FW=/lib/firmware
LINKS=/run/rmtfs-parts
PARTS="MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG DPP SSD"

RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in
	*fc880000*) RP=$r ;;
	esac
done
bad=""
[ -n "$RP" ] || bad="$bad no-mss-remoteproc"
[ -z "$RP" ] || [ "$(cat "$RP/state" 2>/dev/null)" = offline ] || bad="$bad state=$(cat "$RP/state" 2>/dev/null)"
[ -f "$FW/mba.b00" ] && [ -f "$FW/modem.mdt" ] || bad="$bad no-modem-firmware"
command -v rmtfs >/dev/null || bad="$bad no-rmtfs"
command -v qrtr-lookup >/dev/null || bad="$bad no-qrtr-lookup"
[ -c /dev/qcom_rmtfs_mem1 ] || bad="$bad no-/dev/qcom_rmtfs_mem1"
pgrep -x rmtfs >/dev/null 2>&1 && bad="$bad rmtfs-already-running"
for p in $PARTS; do [ -b "/dev/disk/by-partlabel/$p" ] || bad="$bad no-partition-$p"; done
case "$WATCH" in ''|*[!0-9]*) bad="$bad watch=$WATCH" ;; esac
QMI_PROBE="${QMI_PROBE:-0}"
[ "$QMI_PROBE" = 1 ] && ! command -v qmicli >/dev/null && bad="$bad no-qmicli"
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing changed"
	exit 2
fi

hashes() { for p in $PARTS; do printf '%s=%s ' "$p" "$(sha256sum "/dev/disk/by-partlabel/$p" | cut -c1-64)"; done; }
T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
since() { dmesg | awk -v t="${T0:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }'; }
svc14() { qrtr-lookup 2>/dev/null | awk '$1 == 14' | head -n1; }
QDEV=/dev/wwan0qmi0
QMI_OK=0
# identifiers never reach the log: quoted values on identifier lines become
# "<present, N chars>", and any run of 14+ digits anywhere is masked
redact() {
	sed -E -e "/(IMEI|ESN|MEID|[Ss]erial|ICCID|IMSI|MSISDN|[Ee]id)/ { s/'([^']*)'/'<redacted>'/g; }" \
	       -e 's/[0-9]{14,}/<redacted-digits>/g'
}
idlens() {
	awk -F"'" '/IMEI|ESN|MEID/ { n = $1; sub(/^[ \t]*/, "", n); sub(/:[ \t]*$/, "", n);
		v = $2; printf "  %s: %s\n", n, (v == "" || v ~ /^0+$/) ? "absent/empty" : "present, " length(v) " chars" }'
}
qmi() {
	echo "  \$ qmicli $*"
	timeout 25 qmicli -d "$QDEV" "$@" 2>&1 | redact | sed 's/^/    /'
}
qmi_probe() {
	_w=0
	while [ ! -c "$QDEV" ] && [ "$_w" -lt 30 ]; do sleep 1; _w=$((_w + 1)); done
	if [ ! -c "$QDEV" ]; then echo "  no $QDEV after 30 s -- QMI probe skipped"; return; fi
	echo "  $QDEV after ${_w} s ($(ls -l "$QDEV" | awk '{print $1, $5, $6}'))"
	_v=$(timeout 25 qmicli -d "$QDEV" --get-service-version-info 2>&1)
	echo "  \$ qmicli --get-service-version-info"; echo "$_v" | redact | sed 's/^/    /'
	echo "$_v" | grep -q -i "supported versions" && QMI_OK=1
	qmi --dms-get-manufacturer
	qmi --dms-get-model
	qmi --dms-get-revision
	qmi --dms-get-capabilities
	qmi --dms-get-band-capabilities
	qmi --dms-get-operating-mode
	qmi --dms-get-power-state
	echo "  \$ qmicli --dms-get-ids   (identifiers: presence and length only)"
	timeout 25 qmicli -d "$QDEV" --dms-get-ids 2>&1 | idlens
	qmi --uim-get-card-status
	qmi --nas-get-system-selection-preference
	qmi --nas-get-serving-system
	qmi --nas-get-signal-strength
	qmi --voice-get-config
	qmi --wds-get-packet-service-status
}
# section 23: is "shutting-down" (with "battery 0 %") only how the modem looks
# right after boot? The operating mode is sampled through the watch and the
# state queries are repeated at its end -- still read-only, nothing is set.
qmi_mode() {
	echo "  [uptime $(cut -d' ' -f1 /proc/uptime)] $(timeout 15 qmicli -d "$QDEV" --dms-get-operating-mode 2>&1 | redact | grep -i -E "mode|error" | tr -s ' \t' ' ' | tr '\n' ';')"
}
qmi_late() {
	echo "---- QMI late re-query (read-only) at uptime $(cut -d' ' -f1 /proc/uptime)"
	qmi --dms-get-operating-mode
	qmi --dms-get-power-state
	qmi --uim-get-card-status
	qmi --nas-get-serving-system
	qmi --nas-get-signal-strength
}
REC_PRE=$(cat "$RP/recovery" 2>/dev/null)
RES=1
RPID=""

{
echo "================ msm8974 rmtfs (read-only) + modem start $STAMP ================"
echo "remoteproc: $RP ($(cat "$RP/name" 2>/dev/null)), state $(cat "$RP/state")"
echo "kernel: $(uname -r); rmtfs $(apk info -e rmtfs >/dev/null 2>&1 && apk info rmtfs 2>/dev/null | head -n1); dmesg from $T0 s"
echo "rmtfs memory: $(cat /sys/class/rmtfs/qcom_rmtfs_mem1/phys_addr 2>/dev/null) + $(cat /sys/class/rmtfs/qcom_rmtfs_mem1/size 2>/dev/null)"
H0=$(hashes)
echo "partitions before: $(echo "$H0" | sed -E 's/=([0-9a-f]{16})[0-9a-f]*/=\1/g')"

mkdir -p "$LINKS"
ln -sfn /dev/disk/by-partlabel/MODEM_FS1 "$LINKS/modemst1"
ln -sfn /dev/disk/by-partlabel/MODEM_FS2 "$LINKS/modemst2"
ln -sfn /dev/disk/by-partlabel/MODEM_FSC "$LINKS/fsc"
ln -sfn /dev/disk/by-partlabel/MODEM_FSG "$LINKS/fsg"
echo "links: $(for l in modemst1 modemst2 fsc fsg; do printf '%s->%s ' "$l" "$(readlink -f "$LINKS/$l")"; done)"

echo "---- rmtfs -r -P -o $LINKS -v"
rmtfs -r -P -o "$LINKS" -v > "$RLOG" 2>&1 &
RPID=$!
_w=0
while [ "$_w" -lt 20 ] && [ -z "$(svc14)" ] && kill -0 "$RPID" 2>/dev/null; do sleep 0.5; _w=$((_w + 1)); done
if ! kill -0 "$RPID" 2>/dev/null; then
	echo "rmtfs EXITED before publishing:"; cat "$RLOG"
elif [ -z "$(svc14)" ]; then
	echo "rmtfs running (pid $RPID) but QMI service 14 not published after 10 s"
else
	echo "rmtfs pid $RPID, published: $(svc14)"
fi
echo "qrtr services before the modem:"; qrtr-lookup 2>&1 | sed 's/^/  /'

if kill -0 "$RPID" 2>/dev/null && [ -n "$(svc14)" ]; then
	echo "recovery was: $REC_PRE -> disabled for this run"
	echo disabled > "$RP/recovery" 2>/dev/null
	echo "---- modem start at uptime $(cut -d' ' -f1 /proc/uptime)"
	timeout 90 sh -c "echo start > '$RP/state'" 2>&1; echo "start write exit $?"
	if [ "$QMI_PROBE" = 1 ] && [ "$(cat "$RP/state" 2>/dev/null)" = running ]; then
		echo "---- QMI probe (read-only queries) at uptime $(cut -d' ' -f1 /proc/uptime)"
		qmi_probe
		echo "---- QMI probe done at uptime $(cut -d' ' -f1 /proc/uptime); watching the modem for ${WATCH} s more"
	fi
	_w=0; _last=""; _ran=0
	while [ "$_w" -lt "$WATCH" ]; do
		_s=$(cat "$RP/state" 2>/dev/null)
		[ "$_s" != "$_last" ] && echo "  t+${_w}s state $_s" && _last=$_s
		[ "$_s" = running ] && _ran=1
		kill -0 "$RPID" 2>/dev/null || { echo "  t+${_w}s rmtfs EXITED"; break; }
		[ "$QMI_OK" = 1 ] && [ "$_s" = running ] && [ $((_w % 15)) = 0 ] && echo "  t+${_w}s operating mode:" && qmi_mode
		sleep 1; _w=$((_w + 1))
	done
	[ "$QMI_OK" = 1 ] && [ "$(cat "$RP/state" 2>/dev/null)" = running ] && qmi_late
	echo "qrtr services with the modem up:"; qrtr-lookup 2>&1 | sed 's/^/  /'
	echo "rpmsg devices: $(ls /sys/bus/rpmsg/devices 2>/dev/null | grep remoteproc1 | tr '\n' ' ')"
	echo "---- modem stop"
	if [ "$(cat "$RP/state")" = running ]; then
		timeout 30 sh -c "echo stop > '$RP/state'" 2>&1; echo "stop write exit $?"
	fi
	sleep 1
	echo "state after stop: $(cat "$RP/state")"
	[ -n "$REC_PRE" ] && echo "$REC_PRE" > "$RP/recovery" 2>/dev/null
	echo "recovery back to: $(cat "$RP/recovery" 2>/dev/null)"
	[ "$_last" = running ] && [ "$_ran" = 1 ] && RES=0
fi

echo "---- rmtfs stop"
if [ -n "$RPID" ] && kill -0 "$RPID" 2>/dev/null; then
	kill "$RPID"; _w=0
	while kill -0 "$RPID" 2>/dev/null && [ "$_w" -lt 10 ]; do sleep 0.5; _w=$((_w + 1)); done
	kill -0 "$RPID" 2>/dev/null && { kill -9 "$RPID"; echo "rmtfs killed"; } || echo "rmtfs stopped"
fi
rm -rf "$LINKS"

echo "---- what the modem asked rmtfs for ($RLOG, $(wc -l < "$RLOG") lines)"
for f in /boot/modem_fs1 /boot/modem_fs2 /boot/modem_fsc /boot/modem_fsg; do
	echo "  $f: $(grep -c -F "$f" "$RLOG") mentions"
done
echo "  other requested paths: $(grep -o -E "'/[^']*'|/[a-z_]+/[a-z0-9_/]+" "$RLOG" | grep -v -E "^'?/boot/modem_fs[12cg]'?$|^'?/run/rmtfs-parts" | sort -u | tr '\n' ' ')"
echo "  errors/unknown: $(grep -c -i -E "unknown|fail|error|reject|exceed" "$RLOG")"
if [ "$(wc -l < "$RLOG")" -le 80 ]; then
	echo "  rmtfs log:"; sed 's/^/    /' "$RLOG"
else
	echo "  rmtfs log, head and tail:"; head -n 40 "$RLOG" | sed 's/^/    /'; echo "    ..."; tail -n 40 "$RLOG" | sed 's/^/    /'
fi

echo "---- dmesg since the start (remoteproc, mss, rmtfs, qrtr, smd, errors)"
since | grep -i -E "remoteproc|q6v5|mss|mba|modem|rmtfs|rpmsg|smd|qrtr|sysmon|wwan|bam|fatal|error|fail|crash|wdog" | tail -n 60

H1=$(hashes)
echo "partitions after:  $(echo "$H1" | sed -E 's/=([0-9a-f]{16})[0-9a-f]*/=\1/g')"
echo "---- verdict"
if [ "$H0" != "$H1" ]; then
	echo "RESULT: A PARTITION CHANGED -- compare with the M0 backup and restore"
	RES=3
elif [ "$RES" = 0 ] && grep -q -F /boot/modem_fs "$RLOG"; then
	echo "RESULT: the modem ran and read its file systems through rmtfs (read-only); partitions unchanged"
	if [ "$QMI_PROBE" = 1 ]; then
		if [ "$QMI_OK" = 1 ]; then echo "RESULT: the modem answered QMI on $QDEV"
		else echo "RESULT: the modem did NOT answer QMI on $QDEV"; RES=1; fi
	fi
else
	[ "$RES" = 0 ] && echo "RESULT: the modem ran but never asked rmtfs for a file system; partitions unchanged" ||
		echo "RESULT: the modem did not stay running (last state: ${_last:-not started}); partitions unchanged"
	RES=1
fi
} > "$OUT" 2>&1
cat "$OUT"
exit "$RES"

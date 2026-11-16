#!/bin/sh
#
# Cold-boot check for the modem services -- docs/msm8974-modem-mapping.md
# section 29. READ-ONLY: it starts, stops and sets nothing.
#
# After a boot with rmtfs.service and ModemManager.service enabled (and the
# udev hold removed), check that everything came up by itself: rmtfs read-only
# through the links, the modem running, the bam-dmux net ports tagged for
# ModemManager, ModemManager holding the modem with the radio off, NetworkManager
# WWAN still disabled, and the six partitions unchanged against the hashes
# recorded in M4-M5 (docs section 20) unless REF is given.
#
# Usage (as root): sh msm8974-modem-boot-check.sh
# Output: /var/log/msm8974-modem-boot-check-<stamp>.txt
# Exit: 0 all good, 1 something did not come up, 3 A PARTITION CHANGED

set -u
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-modem-boot-check-$STAMP.txt"
PARTS="MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG DPP SSD"
# first 16 hex digits of each sha256, as logged since M4
REF="${REF:-MODEM_FS1=e786a33704fe8e05 MODEM_FS2=18440a783f7e7822 MODEM_FSC=fac43e5c5e86b963 MODEM_FSG=f5a8780814ef1483 DPP=b9fed6c58ed3f876 SSD=9f88bd8e8583c4bb }"
redact() {
	sed -E -e '/([Ee]quipment id|[Dd]evice id|device-identifier|IMEI|imei|IMSI|imsi|ICCID|iccid|[Oo]wn number|own-numbers|[Ee]id|ESN|MEID|[Ss]erial)/ { s/(: |= ?)[^ ].*/\1<redacted>/; }' \
	       -e 's/[0-9]{14,}/<redacted-digits>/g'
}
mm_get() { mmcli -m any -K 2>/dev/null | awk -F': ' -v k="$1" '$1 ~ "^"k" *$" { print $2; exit }'; }
RP=""
for r in /sys/class/remoteproc/remoteproc*; do
	case "$(readlink -f "$r/device" 2>/dev/null)" in *fc880000*) RP=$r ;; esac
done
ok=1
fail() { echo "  FAIL: $*"; ok=0; }

{
echo "================ msm8974 modem boot check $STAMP (uptime $(cut -d' ' -f1 /proc/uptime) s) ================"
echo "kernel $(uname -r); cmdline has $(wc -w < /proc/cmdline) words"
echo "---- units"
for u in rmtfs ModemManager NetworkManager; do echo "  $u: $(systemctl is-enabled $u 2>&1) / $(systemctl is-active $u 2>&1)"; done
systemctl is-active -q rmtfs || fail "rmtfs not active"
systemctl is-active -q ModemManager || fail "ModemManager not active"
echo "  rmtfs: $(ps -o args | grep '^/usr/bin/rmtfs' | head -n1)"
ps -o args | grep -q -x '/usr/bin/rmtfs -r -P -s -o /run/rmtfs-parts' || fail "rmtfs not running read-only with the links"
echo "  links: $(for l in modemst1 modemst2 fsc fsg; do printf '%s->%s ' "$l" "$(readlink -f "/run/rmtfs-parts/$l")"; done)"
echo "  udev hold: $([ -e /etc/udev/rules.d/rmtfs.rules ] && echo PRESENT || echo removed)"
echo "  NetworkManager wwan radio: $(nmcli radio wwan)"
[ "$(nmcli radio wwan)" = disabled ] || fail "NetworkManager WWAN not disabled"
echo "---- modem"
echo "  remoteproc: $(cat "$RP/state"), recovery $(cat "$RP/recovery")"
[ "$(cat "$RP/state")" = running ] || fail "modem not running"
echo "  boot sequence:"
dmesg | grep -E "rmtfs|Booting fw image|SSD M(BA|PSS): decrypted|is now up|wwan0qmi0 attached|Channel already open|ssctl|q6v5.*(fatal|crash|wdog)|remoteproc1: crash" | head -n 20 | sed 's/^/    /'
dmesg | grep -q "Channel already open" && echo "  note: bam-dmux 'Channel already open' this boot (a restart happened)"
echo "  net ports: $(for n in /sys/class/net/wwan*; do [ -e "$n" ] && printf '%s(%s,%s) ' "$(basename "$n")" "$(cat "$n/operstate")" "$(udevadm info -q property "$n" | grep -q '^ID_MM_QCOM_SOC=1' && echo mm-tagged || echo UNTAGGED)"; done)"
echo "---- ModemManager"
mmcli -L 2>&1 | redact | sed 's/^/  /'
if mmcli -L 2>/dev/null | grep -q /Modem/; then
	ST=$(mm_get modem.generic.state); PW=$(mm_get modem.generic.power-state)
	FR=$(mm_get modem.generic.state-failed-reason); RG=$(mm_get modem.3gpp.registration-state)
	echo "  state $ST${FR:+ ($FR)}, power $PW, registration $RG, plugin $(mm_get modem.generic.plugin), ports $(mmcli -m any -K | grep -c '^modem.generic.ports.value')"
	case "$ST:$PW" in
	disabled:low|disabled:off|failed:low|failed:off) ;;
	*) fail "ModemManager state $ST / power $PW is not radio-off" ;;
	esac
else
	fail "ModemManager lists no modem"
fi
echo "  ModemManager journal this boot (warnings and state changes):"
journalctl -b -u ModemManager --no-pager -o short-monotonic 2>/dev/null | grep -E "<wrn>|<err>|state changed|created|initializ" | grep -v "plugin-manager" | redact | tail -n 15 | sed 's/^/    /'
echo "---- partitions (read only)"
H=$(for p in $PARTS; do printf '%s=%s ' "$p" "$(sha256sum "/dev/disk/by-partlabel/$p" | cut -c1-16)"; done)
echo "  now: $H"
echo "  ref: $REF"
echo "---- verdict"
if [ "$H" != "$REF" ]; then
	echo "RESULT: A PARTITION DIFFERS FROM THE REFERENCE -- compare with the M0 backup"; RES=3
elif [ "$ok" = 1 ]; then
	echo "RESULT: the modem came up at boot by itself; ModemManager holds it with the radio off; partitions unchanged"; RES=0
else
	echo "RESULT: not everything came up (see FAIL lines); partitions unchanged"; RES=1
fi
} > "$OUT" 2>&1
cat "$OUT"
exit "${RES:-1}"

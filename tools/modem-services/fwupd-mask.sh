#!/bin/sh
#
# Keep fwupd away from the modem -- docs/msm8974-modem-mapping.md section 33.
#
# fwupd has a ModemManager plugin that can flash modem firmware. postmarketos-
# base-ui >= 65 hard-depends on fwupd, so an apk pin (!fwupd) would make every
# future upgrade fail; instead its systemd units are masked, which works before
# fwupd is installed. With fwupd.service masked the daemon cannot start, also
# not through D-Bus activation (its D-Bus service file names
# SystemdService=fwupd.service, and the bus hands activation to systemd).
# fwupd-refresh would also fetch metadata from the LVFS.
#
# Usage (as root): sh fwupd-mask.sh [--check]
# Undo: systemctl unmask fwupd.service fwupd-refresh.service fwupd-refresh.timer fwupd-offline-update.service

set -u
UNITS="fwupd.service fwupd-refresh.service fwupd-refresh.timer fwupd-offline-update.service"
if [ "${1:-}" != --check ]; then
	systemctl mask $UNITS 2>&1
	systemctl daemon-reload
fi
ok=1
for u in $UNITS; do
	l=$(readlink "/etc/systemd/system/$u" 2>/dev/null)
	s=$(systemctl is-enabled "$u" 2>&1)
	echo "$u: $s (-> ${l:-none})"
	[ "$l" = /dev/null ] && [ "$s" = masked ] || ok=0
done
echo "fwupd installed: $(apk info -e fwupd 2>/dev/null || echo no)"
if [ "$ok" = 1 ]; then echo "RESULT: all fwupd units masked"; exit 0; fi
echo "RESULT: NOT all fwupd units masked"; exit 1

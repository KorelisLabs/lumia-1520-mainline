#!/bin/sh
#
# E1: does TrustZone decrypt the SSD-encrypted MBA for Linux? -- the
# qcom_ssd_probe module (patch 0007), docs/msm8974-modem-mapping.md section 12.
#
# Loads the module once from the tools directory (never installed in
# /lib/modules, so nothing autoloads it). It decrypts /lib/firmware/mba.b00
# in a DMA buffer of its own and reports only the structure of the result;
# the plaintext never leaves kernel memory. Nothing is loaded into the modem,
# started or reset.
#
# Usage (as root on the phone): sh msm8974-ssd-probe.sh [path/to/qcom_ssd_probe.ko] [fw_name]
# Output: /var/log/msm8974-ssd-probe-<stamp>.txt
# Exit: 0 decrypted (an MBN header came out), 1 TrustZone answered but did not
#       decrypt, 2 refused or the module would not load.

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
KO="${1:-$DIR/qcom_ssd_probe.ko}"
FWN="${2:-mba.b00}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-ssd-probe-$STAMP.txt"

[ -f "$KO" ] || { echo "INVALID SETUP: no $KO"; exit 2; }
[ -f "/lib/firmware/$FWN" ] || { echo "INVALID SETUP: no /lib/firmware/$FWN"; exit 2; }
lsmod | grep -q '^qcom_ssd_probe ' && { echo "INVALID SETUP: qcom_ssd_probe already loaded"; exit 2; }

T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
{
echo "================ SSD decryption probe $STAMP ================"
echo "kernel $(uname -r); module $KO ($(sha256sum "$KO" | cut -c1-16)); image $FWN ($(stat -c %s /lib/firmware/$FWN) bytes)"
echo "remoteprocs: $(for r in /sys/class/remoteproc/remoteproc*; do printf '%s=%s ' "$(cat $r/name)" "$(cat $r/state)"; done)"
if insmod "$KO" fw_name="$FWN"; then
	echo "result: $(cat /sys/module/qcom_ssd_probe/parameters/result 2>/dev/null)"
	rmmod qcom_ssd_probe && echo "unloaded"
	LOADED=1
else
	echo "insmod FAILED"
	LOADED=0
fi
echo "---- kernel log"
dmesg | awk -v t="${T0:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }' | grep -E "qcom_ssd_probe|scm|WARNING|BUG|Oops"
echo "remoteprocs after: $(for r in /sys/class/remoteproc/remoteproc*; do printf '%s=%s ' "$(cat $r/name)" "$(cat $r/state)"; done)"
} > "$OUT" 2>&1
cat "$OUT"
[ "$LOADED" = 1 ] || exit 2
grep -q '^result: DECRYPTED' "$OUT" && exit 0 || exit 1

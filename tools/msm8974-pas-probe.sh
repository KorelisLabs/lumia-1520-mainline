#!/bin/sh
#
# Ask TrustZone which PAS peripheral ids it supports -- the qcom_pas_probe
# module (patch 0006), docs/msm8974-modem-mapping.md section 9-10.
#
# Loads the module once from the tools directory (it is not installed in
# /lib/modules, so nothing autoloads it), records its answer, unloads it.
# The module is a pure query (QCOM_SCM_PIL_PAS_IS_SUPPORTED): nothing is
# loaded, authenticated, reset or assigned.
#
# Usage (as root on the phone): sh msm8974-pas-probe.sh [path/to/qcom_pas_probe.ko]
# Output: /var/log/msm8974-pas-probe-<stamp>.txt
# Exit: 0 answered (the ADSP's id 1, the positive control, reported supported),
#       1 answered but the control failed, 2 refused or the module would not load.

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
KO="${1:-$DIR/qcom_pas_probe.ko}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-pas-probe-$STAMP.txt"

[ -f "$KO" ] || { echo "INVALID SETUP: no $KO"; exit 2; }
lsmod | grep -q '^qcom_pas_probe ' && { echo "INVALID SETUP: qcom_pas_probe already loaded"; exit 2; }

T0=$(dmesg | tail -n1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
{
echo "================ PAS support probe $STAMP ================"
echo "kernel $(uname -r); module $KO ($(sha256sum "$KO" | cut -c1-16))"
echo "remoteprocs: $(for r in /sys/class/remoteproc/remoteproc*; do printf '%s=%s ' "$(cat $r/name)" "$(cat $r/state)"; done)"
if insmod "$KO"; then
	echo "result: $(cat /sys/module/qcom_pas_probe/parameters/result 2>/dev/null)"
	rmmod qcom_pas_probe && echo "unloaded"
	LOADED=1
else
	echo "insmod FAILED"
	LOADED=0
fi
echo "---- kernel log"
dmesg | awk -v t="${T0:-0}" 'match($0, /^\[ *[0-9.]+\]/) { if (substr($0, 2, RLENGTH - 2) + 0 > t + 0) print }' | grep -E "qcom_pas_probe|scm|WARNING|BUG"
echo "remoteprocs after: $(for r in /sys/class/remoteproc/remoteproc*; do printf '%s=%s ' "$(cat $r/name)" "$(cat $r/state)"; done)"
} > "$OUT" 2>&1
cat "$OUT"
[ "$LOADED" = 1 ] || exit 2
grep -q 'PAS id  1: SUPPORTED' "$OUT" && exit 0 || exit 1

#!/bin/sh
#
# SMP check -- docs/msm8974-smp-mapping.md.
#
# Patch 0011 boots CPUs 1-3 through the Microsoft Parking Protocol mailboxes
# the Windows Phone UEFI leaves them parked in. Run after a boot whose
# cmdline has no "nosmp" / "maxcpus=1", on a kernel carrying park-rc1.
#
# What it records and checks:
#   - the cpu masks (possible / present / online) and /proc/cpuinfo;
#   - the parking messages per CPU (parked, left the loop, failures) and any
#     oops / BUG / WARNING / soft-lockup line in the kernel log;
#   - real parallelism: one hashing job on CPU0, then one pinned to every
#     online CPU at once; four CPUs should finish four jobs in about the time
#     one CPU takes one. /proc/stat confirms every CPU did the work;
#   - with --suspend: one s2idle cycle with an RTC wake 15 s out, then the
#     same masks and log checks again.
#
# Nothing here writes to storage other than the log file. The modem and
# audio regressions are separate scripts.
#
# Usage (as root on the phone): sh msm8974-smp-check.sh [--suspend]
# Output: /var/log/msm8974-smp-check-<stamp>.txt
# Exit: 0 pass: 4 CPUs online, every one did work, parallel speedup >= 3x,
#         no oops/BUG/WARNING (and the suspend cycle came back with 4 CPUs)
#       1 not (the evidence says which part)
#       2 refused: the boot is not an SMP test boot of a park-rc1 kernel

set -u
SUSPEND=0
[ "${1:-}" = "--suspend" ] && SUSPEND=1
WANT_TAG="${WANT_TAG:-park-rc1}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/msm8974-smp-check-$STAMP.txt"
MB="${MB:-48}"
CPUS=/sys/devices/system/cpu

bad=""
grep -qw nosmp /proc/cmdline && bad="$bad cmdline-has-nosmp"
grep -q 'maxcpus=1' /proc/cmdline && bad="$bad cmdline-has-maxcpus=1"
dmesg | grep -q "\[$WANT_TAG\]" || bad="$bad no-$WANT_TAG-in-kernel-log"
command -v taskset >/dev/null || bad="$bad no-taskset"
if [ "$SUSPEND" = 1 ] && [ ! -w /sys/class/rtc/rtc0/wakealarm ]; then bad="$bad no-rtc-wakealarm"; fi
if [ -n "$bad" ]; then
	echo "INVALID SETUP:$bad -- nothing done"
	exit 2
fi

FAILS=""
fail() { FAILS="$FAILS $1"; echo "  FAIL: $1"; }
up() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
busy() { awk -v c="cpu$1" '$1 == c { print $2 + $3 + $4 }' /proc/stat; }
loglines() {
	dmesg | grep -E 'parking|parked|CPU[0-9]+: (failed|did not|left|thread)|SMP: |Brought up|smp: '
}
errlines() {
	dmesg | grep -E -i 'oops|BUG[: ]|WARNING:|soft lockup|hard lockup|rcu.*stall|Internal error|Unable to handle'
}
masks() {
	echo "  possible $(cat $CPUS/possible)  present $(cat $CPUS/present)  online $(cat $CPUS/online)"
	echo "  cpuinfo processors: $(grep -c '^processor' /proc/cpuinfo)"
	for c in 1 2 3; do
		[ -e "$CPUS/cpu$c/online" ] && echo "  cpu$c/online exists ($(cat $CPUS/cpu$c/online)) -- hotplug unexpectedly enabled"
	done
}
nonline() { grep -c '^processor' /proc/cpuinfo; }

job() { taskset -c "$1" sh -c "head -c ${MB}M /dev/zero | sha256sum >/dev/null"; }

{
echo "== SMP check $STAMP ($(uname -r))"
echo "cmdline: $(cat /proc/cmdline | sed -E 's/pmos_(boot|root)_uuid=[^ ]*/pmos_\1_uuid=<uuid>/g')"
echo
echo "== masks"
masks
echo
echo "== parking / SMP log"
loglines | sed 's/^/  /'
echo
echo "== errors in the kernel log (none expected)"
E=$(errlines); [ -z "$E" ] && echo "  none" || echo "$E" | sed 's/^/  /'
[ -z "$E" ] || fail "kernel-log-errors"
N=$(nonline)
[ "$N" = 4 ] || fail "online-cpus=$N"

echo
echo "== parallel load (${MB} MiB sha256 per job)"
T0=$(up); job 0; T1=$(up)
SOLO=$((T1 - T0))
echo "  one job on cpu0: ${SOLO}0 ms"
B0=""; for c in 0 1 2 3; do B0="$B0 $(busy $c)"; done
T0=$(up)
c=0
while [ "$c" -lt "$N" ]; do job "$c" & c=$((c + 1)); done
wait
T1=$(up)
PAR=$((T1 - T0))
B1=""; for c in 0 1 2 3; do B1="$B1 $(busy $c)"; done
echo "  $N jobs, one per cpu: ${PAR}0 ms"
set -- $B1
i=0
for b0 in $B0; do
	d=$(( $1 - b0 )); shift
	echo "  cpu$i busy ticks during the parallel run: $d"
	[ "$i" -lt "$N" ] && [ "$d" -lt $((SOLO / 2)) ] && fail "cpu$i-did-little-work($d)"
	i=$((i + 1))
done
if [ "$PAR" -gt 0 ]; then
	SPEED=$(( (N * SOLO * 10) / PAR ))
	echo "  speedup: $((SPEED / 10)).$((SPEED % 10))x (ideal ${N}.0x)"
	[ "$SPEED" -ge 30 ] || fail "speedup-${SPEED}e-1"
fi
E2=$(errlines); [ "$E2" = "$E" ] || { echo "  new kernel-log errors after the load:"; echo "$E2" | sed 's/^/    /'; fail "errors-after-load"; }

if [ "$SUSPEND" = 1 ]; then
	echo
	echo "== s2idle cycle (RTC wake in 15 s)"
	echo 0 > /sys/class/rtc/rtc0/wakealarm
	echo +15 > /sys/class/rtc/rtc0/wakealarm
	S0=$(awk '/^success/ { print $2 }' /sys/kernel/debug/suspend_stats 2>/dev/null)
	systemctl suspend
	w=0; while [ "$w" -lt 60 ]; do
		S1=$(awk '/^success/ { print $2 }' /sys/kernel/debug/suspend_stats 2>/dev/null)
		[ -n "$S1" ] && [ "$S1" != "$S0" ] && break
		sleep 1; w=$((w + 1))
	done
	sleep 3
	echo "  suspend_stats success $S0 -> ${S1:-?} (waited ${w} s)"
	[ -n "$S1" ] && [ "$S1" != "$S0" ] || fail "no-completed-suspend"
	masks
	[ "$(nonline)" = 4 ] || fail "online-cpus-after-resume=$(nonline)"
	E3=$(errlines); [ "$E3" = "$E2" ] || { echo "  new kernel-log errors after resume:"; echo "$E3" | sed 's/^/    /'; fail "errors-after-resume"; }
fi

echo
if [ -z "$FAILS" ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL:$FAILS"; fi
} 2>&1 | tee "$OUT"

grep -q '^RESULT: PASS' "$OUT" && exit 0
exit 1

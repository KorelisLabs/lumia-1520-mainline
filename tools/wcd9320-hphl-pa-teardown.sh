#!/bin/sh
#
# The C3a emergency teardown. One implementation, three triggers.
#
# WHO CALLS THIS
#
#   1. the runner's own abort path, when Volume Down is pressed or a gate
#      times out or errors;
#   2. the runner's TERM/INT/HUP trap, if the run is killed;
#   3. an independent transient systemd timer armed at the PA-enable boundary,
#      if the runner dies without running its own trap.
#
# (3) is the one that matters most and the reason this is a separate file. The
# failure it covers is the runner being killed between the PA enable and the
# teardown -- an OOM kill, a segfault in a helper, a bug in this very script --
# on a phone with USB disconnected, no ssh, and a scope probe in the jack.
# A teardown that only exists inside the process that died is not a teardown.
#
# WHAT IT ACTUALLY DOES: ONE SYSFS WRITE.
#
#   echo abort > hphl_pa_test
#
# The whole mapped order -- PA bit clear, mapped settle, real class-H POST_PA
# teardown, DAC down, the forced 0x30d inverse, the forced 0x314 inverse, the
# gain and pop/click restore -- lives in the driver, in one function, taken
# under the C3 state lock. Assembling that order here would put the safety path
# in ash, which is the least reliable component in the system, and would give
# the project a second copy of a sequence that must never drift from the first.
#
# IDEMPOTENT AND BEST-EFFORT. Every step inside the driver is attempted whatever
# the ones before it did, each is a no-op if that stage was never reached, and
# this script ALWAYS EXITS 0. A non-zero exit would make a caller think the
# teardown had not happened and possibly retry into a codec already being torn
# down; there is nothing useful a caller could do with a failure here anyway,
# because this IS the fallback.
#
# Usage:  wcd9320-hphl-pa-teardown.sh [reason]
# Exit:   0, always.

set -u

REASON="${1:-unspecified}"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || echo unknown)
JOURNAL="${C3A_JOURNAL:-/var/log/wcd9320-c3a-journal.txt}"
SLIM="${SLIM_DEVICES:-/sys/bus/slimbus/devices}"

note() {
	printf '%s teardown: %s\n' "$STAMP" "$*"
	#
	# Appended and SYNCED. With USB disconnected there is no ssh and no
	# second chance to collect this: if the phone stops here, what reached
	# the disk is the entire record of what happened.
	#
	printf '%s teardown: %s\n' "$STAMP" "$*" >> "$JOURNAL" 2>/dev/null
	sync 2>/dev/null
}

note "invoked, reason=$REASON"

#
# Find the control function the same way the evidence library does: by the
# presence of the attribute, never by a device name that could move.
#
PGD=""
for d in "$SLIM"/*; do
	[ -e "$d/hphl_pa_test" ] || continue
	PGD="$d"
	break
done

if [ -z "$PGD" ]; then
	#
	# Nothing to tear down, or the module is gone. Say which, and do not
	# pretend this was a successful teardown -- but still exit 0, because a
	# caller has no better option than the one it already took.
	#
	note "NO CODEC FOUND with an hphl_pa_test attribute -- nothing to do"
	note "if a run was live, the module has unloaded and the codec is at"
	note "whatever state it was left in; power cycle before running again"
	exit 0
fi

note "codec at $PGD"

if echo abort > "$PGD/hphl_pa_test" 2>/dev/null; then
	note "abort accepted by the driver"
else
	note "THE ABORT WRITE FAILED -- the codec may still be powered"
fi

#
# Read the state back and record it. This is the only thing that can tell a
# reader afterwards whether the teardown actually landed, and it costs one
# read of a file that reads the CHIP rather than the cache.
#
if [ -r "$PGD/hphl_pa_state" ]; then
	sed -n '1,6p' "$PGD/hphl_pa_state" 2>/dev/null |
		while read -r line; do note "state: $line"; done
else
	note "hphl_pa_state is not readable"
fi

#
# The one value that decides whether this was enough: the PA mask. Reported on
# its own line so it can be grepped out of a journal without parsing anything.
#
PA=$(sed -n 's/.*pa_0x1ab=\([0-9a-f]*\).*/\1/p' "$PGD/hphl_pa_state" 2>/dev/null |
     head -n1)
if [ -n "$PA" ]; then
	MASKED=$(printf '%02x' $(( 0x$PA & 0x30 )) 2>/dev/null || echo "??")
	note "PA_AFTER_TEARDOWN 0x1ab=$PA masked=$MASKED expected=00"
else
	note "PA_AFTER_TEARDOWN unknown -- could not read 0x1ab"
fi

note "complete"
exit 0

# shellcheck shell=sh
#
# Shared collection and assertion helpers for the WCD9320 core-init acceptance
# runs. Sourced by wcd9320-coldboot-evidence.sh and wcd9320-adoption-evidence.sh;
# it is not executable on its own.
#
# Runs on the device (postmarketOS / busybox ash), as root.
#
# The version gate is the first thing every run does. `fastboot boot` only
# RAM-loads the kernel -- the rootfs on eMMC is untouched -- so a stale .ko in
# /lib/modules will happily produce a complete, plausible, and entirely
# meaningless evidence file. Two runs were voided that way. A missing or
# mismatched MODULE_VERSION aborts before a single register is read, and no
# evidence file is written at all, so there is nothing to mistake for a result.

EXPECT_VERSION="${EXPECT_VERSION:-core-init-rc2}"

# Paths are overridable for the offline self-test (wcd9320-evidence-selftest.sh)
# only. On the device, leave them alone -- pointing them somewhere else is how
# you get a confident PASS from a tree that is not the codec.
MODULE_VERSION_PATH="${MODULE_VERSION_PATH:-/sys/module/wcd9320/version}"
SLIM_DEVICES="${SLIM_DEVICES:-/sys/bus/slimbus/devices}"

PASS_N=0
FAIL_N=0

# ------------------------------------------------------------------ output --

say() { printf '%s\n' "$*"; }
hdr() { printf '\n=== %s ===\n' "$*"; }

check() {	# check <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '  PASS  %-32s %s\n' "$1" "$2"
		PASS_N=$((PASS_N + 1))
	else
		printf '  FAIL  %-32s got=%s want=%s\n' "$1" "$2" "$3"
		FAIL_N=$((FAIL_N + 1))
	fi
}

check_cond() {	# check_cond <label> <0|1 truth> <detail>
	if [ "$2" = "1" ]; then
		printf '  PASS  %-32s %s\n' "$1" "$3"
		PASS_N=$((PASS_N + 1))
	else
		printf '  FAIL  %-32s %s\n' "$1" "$3"
		FAIL_N=$((FAIL_N + 1))
	fi
}

note() { printf '  ....  %-32s %s\n' "$1" "$2"; }

# ------------------------------------------------------------ version gate --

require_module_version() {
	if [ ! -r "$MODULE_VERSION_PATH" ]; then
		say "INVALID RUN: $MODULE_VERSION_PATH is missing."
		say "  The wcd9320 module is not loaded, or the running kernel has it"
		say "  built in rather than as a module. Nothing was collected."
		if [ -d /sys/module/wcd9320 ]; then
			say "  /sys/module/wcd9320 exists; contents:"
			ls -1 /sys/module/wcd9320 2>/dev/null | sed 's/^/    /'
		fi
		say "  Expected MODULE_VERSION: $EXPECT_VERSION"
		say "  Push the .ko to /lib/modules/\$(uname -r)/kernel/..., run"
		say "  depmod -a, reboot, and start this run again."
		exit 2
	fi

	RUNNING_VERSION=$(cat "$MODULE_VERSION_PATH" 2>/dev/null)
	if [ "$RUNNING_VERSION" != "$EXPECT_VERSION" ]; then
		say "INVALID RUN: wrong module version."
		say "  running:  $RUNNING_VERSION"
		say "  expected: $EXPECT_VERSION"
		say "  The kernel was RAM-loaded but /lib/modules still holds an older"
		say "  build. Nothing was collected. Push the matching .ko, depmod -a,"
		say "  reboot, and start this run again."
		exit 2
	fi
}

# --------------------------------------------------------------- discovery --

find_devices() {
	PGD=""
	IFD=""
	for d in "$SLIM_DEVICES"/*; do
		[ -e "$d/rco_wake" ] || continue
		if grep -qi 'not applicable' "$d/rco_wake" 2>/dev/null; then
			IFD="$d"
		else
			PGD="$d"
		fi
	done
	if [ -z "$PGD" ]; then
		say "INVALID RUN: no WCD9320 control function (PGD) found under"
		say "  $SLIM_DEVICES/. Nothing was collected."
		exit 2
	fi
	PGD_NAME=$(basename "$PGD")
	if [ -n "$IFD" ]; then IFD_NAME=$(basename "$IFD"); else IFD_NAME="(none)"; fi
}

# ----------------------------------------------------------------- parsing --

# kv <file> <key> -- pull key=value out of a whitespace-separated sysfs blob
kv() {
	tr ' \t' '\n\n' < "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n1
}

# dmesg lines from this driver only, numbered, captured once per run
snap_dmesg() {
	dmesg 2>/dev/null | grep -n 'wcd9320' > "$DMESG_FILE" 2>/dev/null || true
	DMESG_LINES=$(wc -l < "$DMESG_FILE" 2>/dev/null | tr -d ' ')
	[ -n "$DMESG_LINES" ] || DMESG_LINES=0
}

# first_line <pattern> -- 1-based index within the wcd9320 excerpt, or 0
first_line() {
	_l=$(grep -n -- "$1" "$DMESG_FILE" 2>/dev/null | head -n1 | cut -d: -f1)
	[ -n "$_l" ] || _l=0
	echo "$_l"
}

# count_lines <pattern>
# grep -c prints 0 *and* exits 1 when there is no match, so `|| echo 0` would
# emit two values. Take grep's stdout and only default when it is empty.
count_lines() {
	_n=$(grep -c -- "$1" "$DMESG_FILE" 2>/dev/null)
	[ -n "$_n" ] || _n=0
	echo "$_n"
}

# ------------------------------------------------------------- collection --

# Everything the run can observe, written verbatim before any judgement is
# applied, so a failed gate is still diagnosable from the same file.
collect_evidence() {
	hdr "run identity"
	say "mode              : $MODE"
	say "date              : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
	say "module version    : $RUNNING_VERSION   (expected $EXPECT_VERSION)"
	say "uname -r          : $(uname -r)"
	say "uname -v          : $(uname -v)"
	say "uptime            : $(cut -d' ' -f1 /proc/uptime 2>/dev/null) s"
	say "control function  : $PGD_NAME"
	say "interface function: $IFD_NAME"
	say "dmesg wcd9320     : $DMESG_LINES lines"

	hdr "PGD identity";     cat "$PGD/identity"     2>/dev/null
	hdr "PGD bringup";      cat "$PGD/bringup"      2>/dev/null
	hdr "PGD rco_wake";     cat "$PGD/rco_wake"     2>/dev/null
	hdr "PGD irq_observe";  cat "$PGD/irq_observe"  2>/dev/null

	if [ -n "$IFD" ]; then
		hdr "IFD identity"; cat "$IFD/identity" 2>/dev/null
		hdr "IFD bringup";  cat "$IFD/bringup"  2>/dev/null
	fi

	# All three snapshots are kept on every run: attributing the 16 non-POR
	# registers is the next task after this milestone and needs them.
	hdr "sentinel snapshot: before (as found)"
	cat "$PGD/sentinel_before" 2>/dev/null
	hdr "sentinel snapshot: after (post-RCO)"
	cat "$PGD/sentinel_after" 2>/dev/null
	hdr "sentinel snapshot: teardown"
	cat "$PGD/sentinel_teardown" 2>/dev/null

	hdr "dmesg (wcd9320)"
	sed 's/^[0-9]*://' "$DMESG_FILE" 2>/dev/null
}

# --------------------------------------------------- checks shared by both --

check_version() {
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
}

# core_ready is true on both paths: it describes register accessibility, which
# is why it deliberately survives teardown.
check_core_ready() {
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
}

# No manual trigger on either run. The automatic path never touches wake_state,
# so a manual write shows up as attempts>0, state!=idle, or the experiment
# banner in dmesg.
check_no_manual_wake() {
	check "manual wake attempts" "$(kv "$PGD/rco_wake" attempts)" "0"
	check "wake state" "$(kv "$PGD/rco_wake" state)" "idle"
	check "manual experiment banner" "$(count_lines 'RCO wake experiment')" "0"
}

# The canary is the second, independent half of the accessibility test: 0x320
# CDC_CLSH_B1_CTL must read its documented POR of 0xe4. A non-zero count alone
# can be satisfied by garbage.
check_canary() {
	_c=$(grep -o 'canary 0x320 = [0-9a-f]* (want [0-9a-f]*)' "$DMESG_FILE" 2>/dev/null | tail -n1)
	if [ -z "$_c" ]; then
		check_cond "canary 0x320 = e4" 0 "no core-verify canary line in dmesg"
		return
	fi
	check "canary 0x320" "$(echo "$_c" | sed -n 's/.*= \([0-9a-f]*\) (want.*/\1/p')" "e4"
}

# A sequence is complete when the driver's own summary line prints -- it only
# prints after every step applied without aborting -- and when the number of
# step lines actually seen equals the N that line reports. The count is read
# from the log rather than hardcoded, so the check cannot drift out of step
# with the sequence tables.
check_sequence_complete() {	# check_sequence_complete <label>
	_lbl="$1"
	_sum=$(grep -o "$_lbl: all [0-9]* steps applied cleanly" "$DMESG_FILE" 2>/dev/null | head -n1)
	if [ -z "$_sum" ]; then
		check_cond "$_lbl completed" 0 "no 'all N steps applied cleanly' line"
		return
	fi
	_want=$(echo "$_sum" | sed -n 's/.*all \([0-9]*\) steps.*/\1/p')
	_got=$(count_lines "$_lbl step")
	if [ "$_got" = "$_want" ]; then
		check_cond "$_lbl completed" 1 "$_got/$_want steps, applied cleanly"
	else
		check_cond "$_lbl completed" 0 "saw $_got step lines, summary claims $_want"
	fi
}

# ------------------------------------------------------------------ verdict --

emit_verdict() {
	hdr "verdict"
	say "mode   : $MODE"
	say "checks : $PASS_N passed, $FAIL_N failed"
	if [ "$FAIL_N" -eq 0 ]; then
		say "VERDICT: PASS ($MODE)"
		return 0
	fi
	say "VERDICT: FAIL ($MODE)"
	return 1
}

# Refuse to clobber the other mode's evidence. The filenames already differ,
# but a mis-copied file must not be able to masquerade as the wrong run.
open_output() {	# open_output <path>
	OUT="$1"
	if [ -e "$OUT" ] && ! grep -q "^mode              : $MODE$" "$OUT" 2>/dev/null; then
		say "REFUSING: $OUT exists and is not a $MODE evidence file."
		exit 2
	fi
}

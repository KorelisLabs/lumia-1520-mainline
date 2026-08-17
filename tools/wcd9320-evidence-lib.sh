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

# NO HARD-CODED DEFAULT FOR EXPECT_VERSION. There used to be one here, frozen
# at "core-init-rc2" -- eight milestones stale -- and one in every evidence
# script besides, each frozen at whatever build was current when it was
# written. They failed loudly the day the version moved on, which was lucky:
# the dangerous shape of that bug is a default that still MATCHES something
# and quietly validates the wrong artefact. A gate whose expectation can drift
# out from under it is not a gate.
#
# Expectations now come from, in order:
#   1. the environment          -- EXPECT_VERSION / EXPECT_SHA, explicit
#   2. an artefact manifest     -- written by build-wcd9320-kernel.sh at stage
#                                  time, so it describes the build that was
#                                  actually produced
#   3. nothing                  -- and then the run FAILS CLOSED
#
# There is deliberately no fourth option.

# Paths are overridable for the offline self-test (wcd9320-evidence-selftest.sh)
# only. On the device, leave them alone -- pointing them somewhere else is how
# you get a confident PASS from a tree that is not the codec.
MODULE_VERSION_PATH="${MODULE_VERSION_PATH:-/sys/module/wcd9320/version}"
SLIM_DEVICES="${SLIM_DEVICES:-/sys/bus/slimbus/devices}"

# Where the manifest may live. $DIR is the tools directory of the calling
# script; the module tree is the fallback for a manifest installed with the
# modules themselves.
ARTIFACT_MANIFEST="${ARTIFACT_MANIFEST:-}"
EXPECT_SOURCE="unresolved"

resolve_expectations() {
	_mf=""
	if [ -n "$ARTIFACT_MANIFEST" ]; then
		_mf="$ARTIFACT_MANIFEST"
	else
		for _c in "${DIR:-.}/wcd9320-artifact.manifest" \
			  "/lib/modules/$(uname -r)/wcd9320-artifact.manifest"; do
			[ -r "$_c" ] && { _mf="$_c"; break; }
		done
	fi

	# The environment always wins, and says so, so a deliberate override is
	# never silently replaced by a manifest that happens to be lying around.
	if [ -n "${EXPECT_VERSION:-}" ]; then
		EXPECT_SOURCE="environment"
	elif [ -n "$_mf" ]; then
		EXPECT_VERSION=$(sed -n 's/^version=//p' "$_mf" | head -n1)
		EXPECT_SOURCE="manifest $_mf"
	fi
	if [ -z "${EXPECT_SHA:-}" ] && [ -n "$_mf" ]; then
		EXPECT_SHA=$(sed -n 's/^sha256=//p' "$_mf" | head -n1)
	fi
	EXPECT_SHA="${EXPECT_SHA:-}"

	if [ -z "${EXPECT_VERSION:-}" ]; then
		say "INVALID RUN: no artefact expectation, and no default to fall back on."
		say ""
		say "  This run cannot say which build it is supposed to be checking,"
		say "  so it will not check anything. Nothing was collected."
		say ""
		say "  Supply one of:"
		say "    EXPECT_VERSION=<ver> [EXPECT_SHA=<sha256>] sudo -E sh <script>"
		say "    a manifest at \$DIR/wcd9320-artifact.manifest"
		say "    ARTIFACT_MANIFEST=<path>"
		say ""
		say "  build-wcd9320-kernel.sh writes the manifest into its staging"
		say "  directory; copy it to the phone beside these scripts and every"
		say "  run picks up the right expectation with no arguments at all."
		exit 2
	fi
}

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

# check_cond <label> <0|1 truth> <fail detail> [pass detail]
#
# The third argument explains a FAILURE and must not be printed on success --
# a PASS line reading "no such line in dmesg" is computationally harmless and
# actively misleading to anyone reading the evidence later. The optional
# fourth argument is what to show on success; it defaults to "ok", so existing
# three-argument callers keep working.
check_cond() {
	if [ "$2" = "1" ]; then
		printf '  PASS  %-32s %s\n' "$1" "${4:-ok}"
		PASS_N=$((PASS_N + 1))
	else
		printf '  FAIL  %-32s %s\n' "$1" "$3"
		FAIL_N=$((FAIL_N + 1))
	fi
}

note() { printf '  ....  %-32s %s\n' "$1" "$2"; }

# ------------------------------------------------------------ version gate --

require_module_version() {
	# Resolve before anything else: a run that cannot name the build it is
	# checking must abort before it reads a single register, not after.
	resolve_expectations

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

# dmesg lines from this driver only, numbered, captured once per run.
#
# If DMESG_MARKER is set and present, everything up to and including its LAST
# occurrence is dropped, so the sequence assertions see only what happened
# after that point.
#
# This matters because dmesg is cumulative across a boot. An adoption run
# staged by re-entering the driver in place still carries the boot's own
# fresh initialisation in the log, and counting "bring-up step" lines over the
# whole history then reports writes that this attempt did not make. That was
# measured: 8 bring-up and 30 rco-wake lines, exactly two prior fresh runs,
# failing an adoption attempt that had in fact written nothing.
#
# With no marker set, or none found, behaviour is unchanged -- which is
# correct for the cold-boot run and for a reboot-staged adoption, where the
# whole log IS the delta.
snap_dmesg() {
	dmesg 2>/dev/null | grep -n 'wcd9320' > "$DMESG_FILE" 2>/dev/null || true

	if [ -n "${DMESG_MARKER:-}" ]; then
		_mk=$(grep -n -- "$DMESG_MARKER" "$DMESG_FILE" 2>/dev/null |
			tail -n1 | cut -d: -f1)
		if [ -n "$_mk" ]; then
			tail -n +"$((_mk + 1))" "$DMESG_FILE" > "$DMESG_FILE.d" 2>/dev/null
			mv "$DMESG_FILE.d" "$DMESG_FILE" 2>/dev/null
			DMESG_DELTA="from marker, dropped $_mk earlier line(s)"
		else
			DMESG_DELTA="marker not found, using full history"
		fi
	else
		DMESG_DELTA="full history"
	fi

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

# ------------------------------------------------- raw sentinel arithmetic --
#
# The driver reports nonzero_before/nonzero_after as counters. These recount
# the same thing straight off the raw dump, so the precondition rests on the
# register bytes themselves rather than on a counter that could be stale or
# carried over. The dump is 448 registers as hex pairs, 32 per line, starting
# at WCD9320_CDC_FIRST (0x200).

CDC_FIRST_DEC=512	# 0x200

# sentinel_index <reg-hex-no-prefix> -- byte index within the dump
sentinel_index() {
	awk -v r="$1" -v f="$CDC_FIRST_DEC" 'BEGIN {
		n = 0
		r = tolower(r)
		for (i = 1; i <= length(r); i++) {
			c = index("0123456789abcdef", substr(r, i, 1)) - 1
			if (c < 0) { print -1; exit }
			n = n * 16 + c
		}
		print n - f
	}'
}

# sentinel_byte <dump-file> <index> -- the hex pair at that index, or empty
sentinel_byte() {
	[ -r "$1" ] || return 0
	awk -v i="$2" '
		/^[0-9a-f][0-9a-f]*$/ { s = s $0 }
		END {
			if (i >= 0 && length(s) >= (i + 1) * 2)
				print substr(s, i * 2 + 1, 2)
		}
	' "$1" 2>/dev/null
}

# sentinel_nonzero <dump-file> -- independent recount of non-zero registers
sentinel_nonzero() {
	[ -r "$1" ] || { echo ""; return 0; }
	awk '
		/^[0-9a-f][0-9a-f]*$/ { s = s $0 }
		END {
			if (length(s) == 0) { print ""; exit }
			n = 0
			for (i = 1; i <= length(s); i += 2)
				if (substr(s, i, 2) != "00") n++
			print n
		}
	' "$1" 2>/dev/null
}

# num <value> <default> -- guard arithmetic against an unreadable attribute
num() {
	case "$1" in
	'' | *[!0-9]*) echo "$2" ;;
	*) echo "$1" ;;
	esac
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
	say "dmesg wcd9320     : $DMESG_LINES lines (${DMESG_DELTA:-full history})"

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

# An invalid *setup* is not a driver failure, and conflating the two would put
# a black mark against rc2 for something rc2 never did. Distinct verdict,
# distinct exit code, distinct filename.
emit_invalid_setup() {	# emit_invalid_setup <one-line reason>
	hdr "verdict"
	say "mode   : $MODE"
	say "reason : $1"
	say "VERDICT: INVALID SETUP ($MODE) -- not an rc2 failure"
	return 2
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

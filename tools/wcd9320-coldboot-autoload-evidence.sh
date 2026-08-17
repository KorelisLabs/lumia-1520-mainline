#!/bin/sh
#
# WCD9320 cold boot + autoload: does the driver come up through the real boot
# path, with no manual intervention?
#
# This is the milestone `wcd9320-irq-proven` explicitly deferred. That tag was
# earned with the module hand-inserted from /tmp, because
# /lib/modules/.../wcd9320.ko had become a zero-byte file. Nothing may claim
# cold-boot behaviour until this passes.
#
# WHAT "COLD BOOT" MEANS ON THIS DEVICE
#
# There is no state where the SoC is unpowered and reachable: powering off
# lands at the Windows boot screen, and the port is operated RAM-boot style by
# design -- `fastboot boot` each time, nothing Android-bootable flashed, so the
# Windows chain stays intact (docs/boot-chain.md). So a cold start here is:
# power off, restart into the bootloader, fastboot boot the matching image.
# That is every part of the boot path except fetching the kernel from flash,
# which this port never does.
#
# Rather than argue about how cold that is, the run measures it: the codec
# reports path=fresh with nonzero_before=0 only when it genuinely came up dark.
# An adopted codec would say so.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="coldboot-autoload"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-cold-$$"
MASK_ALL="ff ff 3f 7f"
KREL=$(uname -r)
KO="/lib/modules/$KREL/kernel/drivers/slimbus/wcd9320.ko"
# sha256 of the built artefact this run must match; override per build.
EXPECT_SHA="${EXPECT_SHA:-}"	# resolved by the lib from the manifest
# A probe later than this many seconds into the boot did not come from udev.
MAX_PROBE_S="${MAX_PROBE_S:-120}"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-coldboot-autoload-$STAMP.txt"

UPTIME_S=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
KO_SIZE=$(stat -c%s "$KO" 2>/dev/null)
KO_SHA=$(sha256sum "$KO" 2>/dev/null | cut -d' ' -f1)
# Any module outside the canonical path is a manual-insertion route.
STRAY=$(find / -name wcd9320.ko -o -name wcd9320.ko.zst 2>/dev/null |
	grep -v "^/usr/lib/modules/\|^/lib/modules/" | tr '\n' ' ')
# When did the driver first speak? udev autoload lands early in the boot.
PROBE_S=$(sed -n 's/^[0-9]*:\[ *\([0-9]*\)\.[0-9]* *\].*/\1/p' "$DMESG_FILE" 2>/dev/null | head -n1)
PARENT_LINE=$(grep 'wcd9320' /proc/interrupts 2>/dev/null | grep -v 'wcd9320-mbhc' | head -n1)
PARENT_COUNT=$(printf '%s' "$PARENT_LINE" | awk '{print $2+0}')
LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)
LIVE_STATUS=$(sed -n 's/^status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

{
	hdr "how this boot happened"
	say "uptime            : ${UPTIME_S}s"
	say "kernel            : $(uname -r)  $(uname -v)"
	say "module file       : $KO"
	say "  size            : ${KO_SIZE:-missing} bytes"
	say "  sha256          : ${KO_SHA:-none}"
	say "first driver line : ${PROBE_S:-unknown}s into the boot"
	say "modules elsewhere : ${STRAY:-none}"

	hdr "the codec's own account of coldness"
	cat "$PGD/bringup" 2>/dev/null
	cat "$PGD/rco_wake" 2>/dev/null

	hdr "interrupt controller"
	say "parent line       : ${PARENT_LINE:-absent}"
	say "live mask         : $LIVE_MASK"
	say "live status       : $LIVE_STATUS"

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- it autoloaded, and could not have been rescued by hand --
	check_cond "module file is not empty" \
		"$([ "$(num "${KO_SIZE:-0}" 0)" -gt 0 ] && echo 1 || echo 0)" \
		"$KO is ${KO_SIZE:-missing} bytes -- the zero-byte fault has recurred" \
		"$KO_SIZE bytes"
	check "module matches the built artefact" "$KO_SHA" "$EXPECT_SHA"
	check_cond "no module outside /lib/modules" \
		"$([ -z "$STRAY" ] && echo 1 || echo 0)" \
		"a manual-insertion route exists: $STRAY" \
		"none -- no /tmp fallback was available"
	check_cond "driver probed during boot" \
		"$([ -n "${PROBE_S:-}" ] && [ "$(num "${PROBE_S:-99999}" 99999)" -le "$MAX_PROBE_S" ] && echo 1 || echo 0)" \
		"first driver line at ${PROBE_S:-unknown}s -- too late for udev autoload" \
		"${PROBE_S}s into the boot"
	check_cond "module loading errors" \
		"$([ "$(dmesg 2>/dev/null | grep -ci 'could not insert\|Invalid argument\|Unknown symbol\|disagrees about version')" -eq 0 ] && echo 1 || echo 0)" \
		"the log carries a module-loading failure" "none"

	# -- the codec genuinely came up cold --
	check "bring-up path" "$(kv "$PGD/bringup" path)" "fresh"
	check "not adopted" "$(kv "$PGD/bringup" adopted)" "0"
	check "driver owns power" "$(kv "$PGD/bringup" power_owned)" "1"
	check "codec was dark at probe" "$(kv "$PGD/rco_wake" nonzero_before)" "0"

	# -- automatic core init succeeded --
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	check "registers after init" "$(kv "$PGD/rco_wake" nonzero_after)" "95"
	check "core init FAILED lines" "$(count_lines 'core init: FAILED')" "0"
	check_canary

	# -- identity and regmap intact --
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "identity minor" \
		"$(sed -n 's/.*minor \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0001"
	check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
	check "stale bus state" "$(kv "$PGD/bringup" stale_bus_state)" "0"

	# -- nested controller up, parent idle, masks initialised --
	_reg=$(count_lines 'nested irq chip registered')
	check_cond "nested chip registered" "$([ "$_reg" -ge 1 ] && echo 1 || echo 0)" \
		"no registration line in dmesg" "$_reg line(s)"
	check_cond "parent line present" "$([ -n "$PARENT_LINE" ] && echo 1 || echo 0)" \
		"no wcd9320 line in /proc/interrupts" "msmgpio 72"
	check "parent hwirq" "$(printf '%s' "$PARENT_LINE" | awk '{print $4}')" "72"
	check "parent idle" "${PARENT_COUNT:-x}" "0"
	check "masks initialised" "$LIVE_MASK" "$MASK_ALL"
	check "nothing asserted" "$LIVE_STATUS" "00 00 00 00"

	# -- and nothing else went wrong --
	# Specific patterns: a bare 'warning' matches the routine ext2 /boot line,
	# and a bare 'regulator' matches platform notes from t=2s that have
	# nothing to do with this driver.
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "regulator faults" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"
	check "spurious irq complaints" \
		"$(dmesg 2>/dev/null | grep -ci 'nobody cared\|disabling IRQ')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE DRIVER COMES UP ON ITS OWN."
		say ""
		say "Cold restart, RAM-loaded kernel, udev autoload from /lib/modules"
		say "with no module anywhere else to fall back on. The codec reports"
		say "path=fresh with nonzero_before=0, so it genuinely came up dark;"
		say "automatic core init ran once and reached core_ready; identity,"
		say "regmap and the nested controller are all as proven before."
		say ""
		say "What this does NOT cover: booting the kernel from flash. This"
		say "port never does that, by design, to keep the Windows boot chain"
		say "intact."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If the module file is empty again, capture it before touching"
		say "anything: size, blocks, mtime and the filesystem state together"
		say "distinguish a zero-length write from corruption, and last time"
		say "the filesystem was clean."
	fi

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== how this boot happened/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

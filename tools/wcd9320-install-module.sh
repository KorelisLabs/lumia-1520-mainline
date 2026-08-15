#!/bin/sh
#
# Install a built wcd9320.ko into /lib/modules and prove it landed intact.
#
# WHY THIS IS A SCRIPT AND NOT THREE COMMANDS
#
# Getting this wrong has voided runs twice, in two different ways, and neither
# announced itself:
#
#   - `fastboot boot` only RAM-loads the kernel. The rootfs on eMMC is
#     untouched, so a new kernel happily loads the OLD module and produces a
#     complete, plausible, entirely meaningless evidence file.
#   - The module in /lib/modules was once zero bytes. An empty file is not an
#     ELF, and the loader rejects it early enough to log nothing, so the
#     failure was a silent EINVAL that hand-loading from /tmp always masked.
#
# So this verifies the source before installing, verifies the installed copy
# after, and refuses to leave a stale .ko.zst or a stray module anywhere that
# could be loaded instead. On any mismatch it exits non-zero having changed
# nothing it can still undo.
#
# Run as root on the device:
#   EXPECT_SHA=<sha256> EXPECT_VERSION=<ver> sh wcd9320-install-module.sh [src]
#
# Exit: 0 installed and verified, 1 refused or failed.

set -u

SRC="${1:-/tmp/wcd9320.ko}"
EXPECT_SHA="${EXPECT_SHA:-}"
EXPECT_VERSION="${EXPECT_VERSION:-}"

KREL=$(uname -r)
DESTDIR="/lib/modules/$KREL/kernel/drivers/slimbus"
DEST="$DESTDIR/wcd9320.ko"

die() { printf '\nREFUSED: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ "$(id -u)" = "0" ] || die "must run as root (sudo sh $0)"
[ -n "$EXPECT_SHA" ] || die "EXPECT_SHA is not set -- refusing to install an unverified module"
[ -f "$SRC" ] || die "no source module at $SRC"

say "=== source ==="
SRC_SIZE=$(stat -c%s "$SRC" 2>/dev/null)
SRC_SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
say "path   : $SRC"
say "size   : $SRC_SIZE bytes"
say "sha256 : $SRC_SHA"

[ "$SRC_SIZE" -gt 0 ] 2>/dev/null || die "source module is empty -- the zero-byte fault again"
[ "$SRC_SHA" = "$EXPECT_SHA" ] ||
	die "source sha does not match the built artefact
       got  $SRC_SHA
       want $EXPECT_SHA
       The copy to the device is corrupt or the wrong file was sent."

# The version string lives in .modinfo; grep the raw file rather than relying
# on modinfo(8), which is not always present on the device image.
if [ -n "$EXPECT_VERSION" ]; then
	if strings "$SRC" 2>/dev/null | grep -q "^version=$EXPECT_VERSION$"; then
		say "version: $EXPECT_VERSION (found in .modinfo)"
	else
		die "module does not carry version=$EXPECT_VERSION"
	fi
fi

say ""
say "=== what is already there ==="
[ -d "$DESTDIR" ] || die "$DESTDIR does not exist -- wrong kernel release? (uname -r = $KREL)"
for f in "$DESTDIR"/wcd9320.ko "$DESTDIR"/wcd9320.ko.zst "$DESTDIR"/wcd9320.ko.gz \
         "$DESTDIR"/wcd9320.ko.xz; do
	if [ -e "$f" ]; then
		say "  present: $f  ($(stat -c%s "$f") bytes)"
	fi
done

# A compressed copy beside the plain one is not harmless: modprobe may pick
# either, and the zstd copy is the one that produced a silent EINVAL.
say ""
say "=== removing anything that could be loaded instead ==="
REMOVED=0
for f in "$DESTDIR"/wcd9320.ko.zst "$DESTDIR"/wcd9320.ko.gz "$DESTDIR"/wcd9320.ko.xz; do
	if [ -e "$f" ]; then
		rm -f "$f" && say "  removed $f" && REMOVED=$((REMOVED + 1))
	fi
done
[ "$REMOVED" = "0" ] && say "  nothing to remove"

say ""
say "=== install ==="
install -m 0644 "$SRC" "$DEST" || die "install failed"
sync
say "  wrote $DEST"

# Verify the INSTALLED copy, not the source. This is the check that would have
# caught the zero-byte module at the moment it was created.
DEST_SIZE=$(stat -c%s "$DEST" 2>/dev/null)
DEST_SHA=$(sha256sum "$DEST" | cut -d' ' -f1)
say "  size   : $DEST_SIZE bytes"
say "  sha256 : $DEST_SHA"
[ "$DEST_SIZE" = "$SRC_SIZE" ] || die "installed size $DEST_SIZE != source $SRC_SIZE"
[ "$DEST_SHA" = "$EXPECT_SHA" ] ||
	die "installed sha does not match -- the write did not land intact
       got  $DEST_SHA
       want $EXPECT_SHA"

say ""
say "=== depmod ==="
depmod -a || die "depmod failed"
say "  depmod -a ok"
if modinfo wcd9320 >/dev/null 2>&1; then
	say "  modinfo resolves: $(modinfo -n wcd9320 2>/dev/null)"
fi

# The cold-boot gate requires that no module exists outside /lib/modules, so
# that a hand-insertion route cannot mask a broken autoload. Report it now
# rather than discovering it in the evidence run.
say ""
say "=== stray modules outside the module tree ==="
STRAY=$(find / -name 'wcd9320.ko' -o -name 'wcd9320.ko.*' 2>/dev/null |
	grep -v '^/usr/lib/modules/' | grep -v '^/lib/modules/')
if [ -n "$STRAY" ]; then
	say "  FOUND -- these will fail the cold-boot gate and can mask a bad autoload:"
	printf '%s\n' "$STRAY" | sed 's/^/    /'
	say ""
	say "  Remove them before the evidence boot, including the copy in /tmp:"
	printf '%s\n' "$STRAY" | sed 's/^/    rm -f /'
else
	say "  none"
fi

say ""
say "INSTALLED AND VERIFIED."
say "  module : $DEST"
say "  version: ${EXPECT_VERSION:-(not checked)}"
say "  sha256 : $DEST_SHA"
say ""
say "Now power off, restart into the bootloader, and fastboot boot the"
say "matching image. Do not modprobe by hand -- the point of the next run is"
say "that the driver comes up on its own."
exit 0

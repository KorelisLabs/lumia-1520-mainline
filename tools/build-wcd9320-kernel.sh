#!/bin/bash
#
# Build, verify and stage a WCD9320 kernel package, reproducibly, from a
# checkout of this repository.
#
# WHY THIS EXISTS
#
# Every milestone through wcd9320-asoc-component-proven was built by a script
# that lived in one developer's home directory and hardcoded that machine's
# paths. The tags were therefore reproducible only by the person holding that
# file. This is the same recipe with the machine taken out of it: paths are
# derived from the checkout or passed in, and nothing about one workstation is
# assumed.
#
# WHAT IT DOES NOT DO
#
# It does not stage the patch, the pkgrel or the checksums -- those live in
# pmaports and in patches/ and are expected to be correct before this runs. It
# checks them and refuses rather than fixing them, because silently
# regenerating a checksum is how a build stops corresponding to its source.
#
# VERIFICATION IS BY ARTEFACT, NEVER BY EXIT CODE
#
# pmbootstrap has reported success while producing no package, and returns
# non-zero when a post-run umount fails despite a good build. So every claim
# here is checked against the file that was produced.
#
# USAGE
#
#   build-wcd9320-kernel.sh --pkgrel 145 --version asoc-component-rc1 \
#                           --stage /path/to/staging
#
#   --pkgrel N        the pkgrel staged in pmaports; must already match
#   --version STR     the MODULE_VERSION the built module must report
#   --stage DIR       where the image and module are written
#   --module-dir DIR  module destination if different from --stage
#   --guard STR       an extra string that must appear in the built module;
#                     repeatable, on top of the always-required set
#   --verify-only     run the checks against an existing package and exit;
#                     needs no sudo, so it is safe in CI or on a workstation
#                     that cannot build
#   --force-build     rebuild even if a matching package already exists
#
# Environment overrides, all with sane defaults:
#
#   PMB          pmbootstrap work dir      (default ~/.local/var/pmbootstrap)
#   PKG          package name              (default linux-postmarketos-qcom-msm8974)
#   KVER         kernel version            (default 6.16.12)
#   ARCH         package arch              (default armv7)
#   DEVICE       pmbootstrap device        (default nokia-rm940)
#   BOOT_UUID    boot partition UUID       (see below)
#   ROOT_UUID    root partition UUID       (see below)
#
# THE PARTITION UUIDs
#
# pmbootstrap's installer mints fresh partition UUIDs on every run, but the
# eMMC keeps its originals, so an image carrying the minted pair fails in the
# initramfs with "failed to mount subpartitions" on mmcblk0p28. The defaults
# below are this device's actual UUIDs, already documented in
# docs/audio/HANDOFF.md. Override them for a different handset.
#
# Exit: 0 everything verified, non-zero with a reason otherwise.

set -u

PKG="${PKG:-linux-postmarketos-qcom-msm8974}"
KVER="${KVER:-6.16.12}"
ARCH="${ARCH:-armv7}"
DEVICE="${DEVICE:-nokia-rm940}"
PMB="${PMB:-$HOME/.local/var/pmbootstrap}"
BOOT_UUID="${BOOT_UUID:-a9d9c6cd-eda8-4246-8a5d-2ff04682aa95}"
ROOT_UUID="${ROOT_UUID:-de214b3a-0811-4b22-a5f7-095ac1f8d676}"

PKGREL=""
VERSION=""
STAGE=""
MODULE_DIR=""
VERIFY_ONLY=0
FORCE_BUILD=0
EXTRA_GUARDS=""

die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

usage() { sed -n '2,/^# Exit:/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--pkgrel)     PKGREL="${2:-}"; shift 2 ;;
	--version)    VERSION="${2:-}"; shift 2 ;;
	--stage)      STAGE="${2:-}"; shift 2 ;;
	--module-dir) MODULE_DIR="${2:-}"; shift 2 ;;
	--guard)      EXTRA_GUARDS="$EXTRA_GUARDS
${2:-}"; shift 2 ;;
	--verify-only) VERIFY_ONLY=1; shift ;;
	--force-build) FORCE_BUILD=1; shift ;;
	-h|--help)    usage 0 ;;
	*) printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
	esac
done

[ -n "$PKGREL" ]  || die "--pkgrel is required"
[ -n "$VERSION" ] || die "--version is required"

# The repo is wherever this script lives, so a checkout anywhere works.
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATCH="$REPO/patches/0002-slimbus-wcd9320-codec-core.patch"
APKBUILD="$PMB/cache_git/pmaports/device/testing/$PKG/APKBUILD"
STAGED_PATCH="$PMB/cache_git/pmaports/device/testing/$PKG/0002-slimbus-wcd9320-codec-core.patch"
APK="$PMB/packages/edge/$ARCH/$PKG-$KVER-r$PKGREL.apk"

if [ "$VERIFY_ONLY" = "0" ]; then
	[ -n "$STAGE" ] || die "--stage is required (or pass --verify-only)"
fi
[ -n "$MODULE_DIR" ] || MODULE_DIR="$STAGE"
OUTIMG="${STAGE:+$STAGE/boot-1520-$VERSION.img}"

# --- PATH ---------------------------------------------------------------
#
# pmbootstrap installs to ~/.local/bin, which only a login shell adds. Invoked
# as `bash script.sh` from a non-login shell it is simply absent, and the
# failure lands after the password prompt and all the precondition work.
step "environment"
for d in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
	case ":$PATH:" in
	*":$d:"*) ;;
	*) [ -d "$d" ] && PATH="$d:$PATH" ;;
	esac
done
export PATH
echo "repo      : $REPO"
echo "pmaports  : $(dirname "$APKBUILD")"
echo "package   : $APK"
[ -n "$STAGE" ] && echo "stage     : $STAGE"
if [ "$VERIFY_ONLY" = "0" ]; then
	command -v pmbootstrap >/dev/null 2>&1 ||
		die "pmbootstrap not found on PATH (looked in ~/.local/bin).
       Install it, or re-run with --verify-only to check an existing package."
	echo "pmbootstrap: $(command -v pmbootstrap) ($(pmbootstrap --version 2>/dev/null || echo '?'))"
fi

# --- preconditions -------------------------------------------------------
step "preconditions"
[ -f "$APKBUILD" ] || die "no APKBUILD at $APKBUILD -- is pmaports checked out?"
[ -f "$PATCH" ]    || die "no patch at $PATCH"
grep -q "^pkgrel=$PKGREL\$" "$APKBUILD" ||
	die "APKBUILD is not at pkgrel=$PKGREL (found: $(sed -n 's/^pkgrel=//p' "$APKBUILD"))"
grep -q "MODULE_VERSION(\"$VERSION\")" "$PATCH" ||
	die "the repo's patch does not carry MODULE_VERSION(\"$VERSION\")"
if [ -f "$STAGED_PATCH" ]; then
	cmp -s "$STAGED_PATCH" "$PATCH" ||
		die "the patch staged in pmaports differs from $PATCH.
       Re-sync before building, or the artefact will not correspond to the
       source this repository publishes."
	echo "staged patch is byte-identical to the repo's copy"
fi
echo "pkgrel $PKGREL, patch carries $VERSION"

# abuild pairs source= and sha512sums= BY POSITION. A filename-keyed check
# gives a false pass, which is why this walks both lists in order.
python3 - "$APKBUILD" <<'PY' || die "source= and sha512sums= are misaligned"
import re, sys
t = open(sys.argv[1]).read()
src = re.search(r'^source="\n(.*?)^"$', t, re.M | re.S).group(1).split()
sums = re.search(r'^sha512sums="\n(.*?)^"$', t, re.M | re.S).group(1).split()
names = sums[1::2]
if len(src) != len(names):
    sys.exit(f"{len(src)} sources vs {len(names)} sums")
for i, (a, b) in enumerate(zip(src, names)):
    a = a.rsplit("/", 1)[-1]
    if "$" not in a and a != b:
        sys.exit(f"position {i}: {a} != {b}")
print(f"{len(src)} sources aligned with {len(names)} sums")
PY

# --- module extraction helper -------------------------------------------
extract_module() {	# extract_module <apk> <destdir> -> echoes path
	_w="$1_x"
	rm -rf "$_w"; mkdir -p "$_w"
	( cd "$_w" && tar -xzf "$2" 2>/dev/null )
	_k="$_w/usr/lib/modules/$KVER/kernel/drivers/slimbus/wcd9320.ko"
	if [ -f "$_k.zst" ]; then
		zstd -dqf "$_k.zst" -o "$_k" 2>/dev/null || return 1
	fi
	[ -f "$_k" ] || return 1
	printf '%s\n' "$_k"
}

# --- build ---------------------------------------------------------------
#
# Resumable: a run interrupted after the build should not cost a second one.
# A package is reused only when it exists AND the module inside reports the
# version being asked for -- anything less is not good enough to trust.
if [ "$VERIFY_ONLY" = "0" ]; then
	step "build"
	REUSE=0
	if [ "$FORCE_BUILD" = "0" ] && [ -f "$APK" ]; then
		_t=$(mktemp -d)
		if _k=$(extract_module "$_t/m" "$APK" 2>/dev/null) &&
		   strings "$_k" | grep -q "^version=$VERSION$"; then
			REUSE=1
		fi
		rm -rf "$_t"
	fi
	if [ "$REUSE" = "1" ]; then
		echo "r$PKGREL already built and reports $VERSION -- reusing (--force-build overrides)"
	else
		echo "pmbootstrap needs an interactive sudo; enter it once and the rest runs clean."
		sudo -v || die "sudo authentication failed -- nothing was built"
		( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
		KEEPALIVE=$!
		trap 'if [ -n "${KEEPALIVE:-}" ]; then kill "$KEEPALIVE" 2>/dev/null; fi' EXIT
		rm -f "$APK"
		pmbootstrap build --force "$PKG"
	fi
fi

# --- verify the package by artefact --------------------------------------
step "verify the package"
[ -f "$APK" ] || {
	sh "$REPO/tools/check-modpost.sh" 2>/dev/null
	die "no package at r$PKGREL"
}
ls -l "$APK"
sh "$REPO/tools/check-modpost.sh" || die "unresolved symbols at modpost"

WORK=$(mktemp -d)
# Guard the kill: "${KEEPALIVE:-0}" would expand to 0 in --verify-only, where
# no keepalive was ever started, and `kill 0` signals the whole process group
# -- which SIGTERMs this script and turns a clean verification into exit 15.
cleanup() {
	_rc=$?
	rm -rf "$WORK"
	[ -n "${KEEPALIVE:-}" ] && kill "$KEEPALIVE" 2>/dev/null
	return "$_rc"
}
trap cleanup EXIT
KO=$(extract_module "$WORK/m" "$APK") || die "no wcd9320.ko in the package"

GOT=$(strings "$KO" | sed -n 's/^version=//p' | head -n1)
[ "$GOT" = "$VERSION" ] || die "module reports '$GOT', wanted '$VERSION'"
echo "MODULE_VERSION: $GOT"

# Guard strings: features whose absence would mean a build that dropped
# something without failing. The always-required set is what every milestone
# from the interrupt work onward depends on.
GUARDS="nested irq chip registered
irq_live
low_before
low_after
cache_check
cacheable_checked=
first_mismatch$EXTRA_GUARDS"
printf '%s\n' "$GUARDS" | while IFS= read -r s; do
	[ -n "$s" ] || continue
	strings "$KO" | grep -q "$s" || { echo "GUARD MISSING: $s" >&2; exit 1; }
	echo "guard present: $s"
done || die "a guard string is missing from the built module"

# --- stage ---------------------------------------------------------------
#
# The module ships UNCOMPRESSED. The kernel's in-tree zstd decompressor once
# rejected a .ko.zst with a silent -EINVAL -- module_decompress() returns it
# without logging -- while the identical bytes decompressed fine in userspace.
# Until that is understood, do not hand the device a file it may refuse.
if [ "$VERIFY_ONLY" = "0" ]; then
	step "stage"
	mkdir -p "$MODULE_DIR" "$STAGE" || die "cannot create staging directories"
	cp "$KO" "$MODULE_DIR/wcd9320.ko" || die "could not stage the module"
	[ -s "$MODULE_DIR/wcd9320.ko" ] || die "staged module is empty"
	echo "module : $MODULE_DIR/wcd9320.ko"
	echo "size   : $(stat -c%s "$MODULE_DIR/wcd9320.ko") bytes"
	echo "sha256 : $(sha256sum "$MODULE_DIR/wcd9320.ko" | cut -d' ' -f1)"

	# --- install, export, image ---------------------------------------
	step "install and export (interactive sudo)"
	sudo -v || die "sudo authentication failed"
	pmbootstrap install --no-sparse || die "install failed"
	pmbootstrap export || die "export failed"

	BUILT="$PMB/chroot_rootfs_$DEVICE/boot/boot.img"
	[ -f "$BUILT" ] || die "no boot.img at $BUILT"

	step "cmdline"
	CUR=$(python3 -c "
import sys
d = open(sys.argv[1], 'rb').read(576)
print(d[64:576].rstrip(b'\0').decode())
" "$BUILT")
	NEW=$(printf '%s' "$CUR" |
		sed "s/pmos_boot_uuid=[0-9a-f-]*/pmos_boot_uuid=$BOOT_UUID/;
		     s/pmos_root_uuid=[0-9a-f-]*/pmos_root_uuid=$ROOT_UUID/")
	case "$NEW" in
	*"$BOOT_UUID"*) ;;
	*) die "boot UUID substitution did not take" ;;
	esac
	case "$NEW" in
	*"$ROOT_UUID"*) ;;
	*) die "root UUID substitution did not take" ;;
	esac
	python3 "$REPO/tools/patch-cmdline.py" "$BUILT" "$OUTIMG" = "$NEW" ||
		die "cmdline patch failed"

	step "verify the image"
	python3 - "$BUILT" "$OUTIMG" <<'PY' || die "image differs outside the cmdline field"
import sys
a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
if len(a) != len(b):
    sys.exit(f"size mismatch {len(a)} vs {len(b)}")
bad = [i for i in range(len(a)) if a[i] != b[i] and not (64 <= i < 576)]
if bad:
    sys.exit(f"{len(bad)} differing bytes outside the cmdline, first at {bad[0]}")
print("identical to the built boot.img apart from the cmdline field")
PY
	python3 "$REPO/tools/check-bootimg.py" "$OUTIMG" | tail -3
fi

# --- the artefact gate ---------------------------------------------------
#
# Everything above is the build's own sanity checking. This is the acceptance
# gate: it re-reads the module's ELF and asserts the register tables, the
# classification invariants and the bypass call sites, so a build that quietly
# produced different tables cannot reach the device.
step "artefact gate"
GATE_ARGS="--pkgrel $PKGREL --expect-version $VERSION"
case "$VERSION" in
asoc-*)   GATE_ARGS="$GATE_ARGS --expect-asoc --expect-dais 0" ;;
rx-dai-*) GATE_ARGS="$GATE_ARGS --expect-asoc --expect-dais 1" ;;
esac
#
# The image path is passed as its own quoted argument, never folded into
# GATE_ARGS. A staging directory containing a space would otherwise word-split
# when GATE_ARGS is expanded unquoted, and the gate would reject the tail of
# the path as an unrecognised option -- failing a build that was fine.
# shellcheck disable=SC2086
if [ "$VERIFY_ONLY" = "1" ] || [ -z "${OUTIMG:-}" ]; then
	python3 "$REPO/tools/wcd9320-verify-artifact.py" $GATE_ARGS \
		--skip-bootimg ||
		die "artefact verification failed -- do NOT flash this"
else
	python3 "$REPO/tools/wcd9320-verify-artifact.py" $GATE_ARGS \
		--bootimg "$OUTIMG" ||
		die "artefact verification failed -- do NOT flash this"
fi

step "done"
if [ "$VERIFY_ONLY" = "1" ]; then
	echo "verified an existing r$PKGREL package; nothing was built or staged."
else
	echo "image  : $OUTIMG"
	echo "module : $MODULE_DIR/wcd9320.ko  ($VERSION, uncompressed)"
	echo
	echo "Next: install the module with tools/wcd9320-install-module.sh, remove"
	echo "      any stray copy, cold restart, fastboot boot the image, then run"
	echo "      the evidence scripts."
fi

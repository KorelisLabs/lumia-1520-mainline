#!/bin/sh
#
# Build pcm-prepare-only for the device (armv7, musl).
#
# The kernel build already has a cross toolchain, but it is clang driven by the
# kernel's own makefiles. For one small userspace program it is simpler and
# less surprising to compile INSIDE pmbootstrap's armv7 buildroot, which has a
# native gcc, musl headers and the kernel uapi headers -- so the binary is
# built against exactly the libc and <sound/asound.h> the device runs.
#
# Usage:
#   build-pcm-helper.sh --stage <dir> [--force]
#
# Needs an interactive sudo once, like the kernel build.
# Exit: 0 built and verified, non-zero otherwise.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/tools/pcm-prepare-only.c"
AUDIT="$REPO/tools/pcm-helper-audit.py"
PMB="${PMB:-$HOME/.local/var/pmbootstrap}"
ARCH=armv7
CHROOT="$PMB/chroot_buildroot_$ARCH"
STAGE=""
FORCE=0

die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--stage) STAGE="${2:-}"; shift 2 ;;
	--force) FORCE=1; shift ;;
	-h|--help)
		sed -n '2,/^# Exit:/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
		exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$STAGE" ] || die "--stage is required"
[ -f "$SRC" ] || die "no source at $SRC"
[ -f "$AUDIT" ] || die "no audit script at $AUDIT"

# pmbootstrap is often not on a non-login shell's PATH; the kernel build hit
# this too.
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

step "environment"
echo "repo    : $REPO"
echo "source  : $SRC"
echo "chroot  : $CHROOT"
echo "stage   : $STAGE"

#
# THE AUDIT RUNS FIRST, BEFORE ANY COMPILATION.
#
# This tool's whole value is what it does NOT do. A binary that starts a stream
# would silently invalidate every conclusion drawn with it, so the source is
# checked before it is allowed to become a binary -- not afterwards, and not
# only at review time.
#
step "forbidden-call audit (before compiling)"
python3 "$AUDIT" --selftest >/dev/null 2>&1 ||
	die "the audit's own selftest fails -- it cannot be trusted to check anything"
echo "  audit selftest: passed (it can still reject bad sources)"
python3 "$AUDIT" "$SRC" || die "the source contains a forbidden call, or is missing a required one"

OUT="$STAGE/pcm-prepare-only"
if [ "$FORCE" = "0" ] && [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then
	step "compile"
	echo "already built and newer than the source -- reusing (--force overrides)"
else
	step "toolchain (interactive sudo)"
	echo "pmbootstrap needs sudo once; the rest runs clean."
	command -v pmbootstrap >/dev/null 2>&1 ||
		die "pmbootstrap is not on PATH (tried \$HOME/.local/bin)"
	sudo -v || die "sudo authentication failed -- nothing was built"

	pmbootstrap -y chroot --arch "$ARCH" -- apk add gcc musl-dev linux-headers ||
		die "could not install the build tools in the $ARCH chroot"
	echo "gcc, musl-dev and linux-headers present in the $ARCH chroot"

	step "compile"
	sudo mkdir -p "$CHROOT/tmp/pcmhelper" || die "cannot create the build dir"
	sudo cp "$SRC" "$CHROOT/tmp/pcmhelper/" || die "cannot stage the source"

	#
	# -static: the device's musl is the same musl, but a static binary
	# removes the one remaining way this tool can fail for a reason that has
	# nothing to do with the measurement.
	#
	pmbootstrap -y chroot --arch "$ARCH" -- \
		gcc -O2 -Wall -Wextra -Werror -static \
		    -o /tmp/pcmhelper/pcm-prepare-only \
		    /tmp/pcmhelper/pcm-prepare-only.c ||
		die "compilation failed"

	mkdir -p "$STAGE" || die "cannot create $STAGE"
	sudo cp "$CHROOT/tmp/pcmhelper/pcm-prepare-only" "$OUT" ||
		die "cannot copy the binary out of the chroot"
	sudo chmod 0755 "$OUT" || die "cannot chmod the staged binary"
fi

step "verify the artefact"
[ -s "$OUT" ] || die "the built binary is empty"
printf '  path   : %s\n' "$OUT"
printf '  size   : %s bytes\n' "$(stat -c%s "$OUT")"
printf '  sha256 : %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"

#
# The host binutils is x86; do not assume `file` is present. Read the ELF
# header directly -- e_machine 40 is EM_ARM, class 1 is 32-bit.
#
python3 "$REPO/tools/pcm-helper-elfcheck.py" "$OUT" ||
	die "the binary is not a 32-bit ARM ELF"

step "done"
echo "binary : $OUT"
echo
echo "Copy it to the phone (ONE file per scp) and run, e.g.:"
echo "  ./pcm-prepare-only -D /dev/snd/pcmC0D0p -r 48000 -c 1 -f S16_LE"
echo
echo "It drives the PCM to PREPARED and stops. It never writes and never"
echo "starts a stream, which is what makes it usable as the control-plane"
echo "instrument."

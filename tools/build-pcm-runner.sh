#!/bin/sh
#
# Build pcm-run-measured for the device (armv7, musl).
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
SRC="$REPO/tools/pcm-run-measured.c"
AUDIT="$REPO/tools/runner-audit.py"
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
# This tool is allowed -- required -- to start a stream, so its audit is the
# INVERSE of the oracle's: write() and an explicit START are mandatory, and
# what is forbidden is an unbounded loop or straying onto the control device.
# A measurement tool that can spin forever against a wedged DSP turns a failed
# run into a hung phone and an evidence file that never gets written.
#
step "forbidden-call audit (before compiling)"
python3 "$AUDIT" --selftest >/dev/null 2>&1 ||
	die "the audit's own selftest fails -- it cannot be trusted to check anything"
echo "  audit selftest: passed (it can still reject bad sources)"
python3 "$AUDIT" "$SRC" || die "the source contains a forbidden call, or is missing a required one"

OUT="$STAGE/pcm-run-measured"
if [ "$FORCE" = "0" ] && [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then
	step "compile"
	echo "already built and newer than the source -- reusing (--force overrides)"
else
	step "toolchain (interactive sudo)"
	#
	# The armv7 buildroot usually does NOT exist yet: the kernel is built
	# cross-native with clang, which never needs one. "pmbootstrap chroot -b
	# armv7" creates it on demand, running under qemu binfmt -- slower than
	# the native chroot, but it gives a real armv7 gcc with musl headers and
	# the kernel uapi headers, which is exactly what a userspace binary for
	# this device should be built against.
	#
	echo "pmbootstrap needs sudo once; the rest runs clean."
	echo "the armv7 buildroot is created on demand and runs under qemu,"
	echo "so the first apk add here is slow."
	command -v pmbootstrap >/dev/null 2>&1 ||
		die "pmbootstrap is not on PATH (tried \$HOME/.local/bin)"
	sudo -v || die "sudo authentication failed -- nothing was built"

	pmbootstrap -y chroot -b "$ARCH" -- apk add gcc musl-dev linux-headers ||
		die "could not install the build tools in the $ARCH chroot"
	echo "gcc, musl-dev and linux-headers present in the $ARCH chroot"

	step "compile"
	sudo mkdir -p "$CHROOT/tmp/pcmrunner" || die "cannot create the build dir"
	sudo cp "$SRC" "$CHROOT/tmp/pcmrunner/" || die "cannot stage the source"

	#
	# -static: the device's musl is the same musl, but a static binary
	# removes the one remaining way this tool can fail for a reason that has
	# nothing to do with the measurement.
	#
	pmbootstrap -y chroot -b "$ARCH" -- \
		gcc -O2 -Wall -Wextra -Werror -static \
		    -o /tmp/pcmrunner/pcm-run-measured \
		    /tmp/pcmrunner/pcm-run-measured.c ||
		die "compilation failed"

	mkdir -p "$STAGE" || die "cannot create $STAGE"
	sudo cp "$CHROOT/tmp/pcmrunner/pcm-run-measured" "$OUT" ||
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
echo "  ./pcm-run-measured -D /dev/snd/pcmC0D0p -r 48000 -c 1 -p 960 -n 4 -t 3"
echo
echo "It writes a ramp, starts the stream explicitly, measures period"
echo "progression for a bounded interval, and stops. It is NOT the control-plane"
echo "oracle -- pcm-prepare-only stays frozen and is a separate binary."

#!/bin/sh
#
# Build pcm-capture for the device (armv7, musl, static) -- r197.
#
# Same method as build-pcm-helper.sh: compile INSIDE pmbootstrap's armv7
# buildroot, which has a native gcc, musl headers and the kernel uapi
# headers, so the binary is built against exactly the libc and
# <sound/asound.h> the device runs.
#
# Usage:
#   build-pcm-capture.sh --stage <dir> [--force]
#
# Needs an interactive sudo once, like the kernel build.
# Exit: 0 built and verified, non-zero otherwise.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/tools/pcm-capture.c"
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
	-h|--help) sed -n '2,/^# Exit:/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$STAGE" ] || die "--stage is required"
[ -f "$SRC" ] || die "no source at $SRC"
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

OUT="$STAGE/pcm-capture"
if [ "$FORCE" = "0" ] && [ -f "$OUT" ] && [ "$OUT" -nt "$SRC" ]; then
	step "compile"
	echo "already built and newer than the source -- reusing (--force overrides)"
else
	step "toolchain (interactive sudo)"
	command -v pmbootstrap >/dev/null 2>&1 ||
		die "pmbootstrap is not on PATH (tried \$HOME/.local/bin)"
	sudo -v || die "sudo authentication failed -- nothing was built"
	pmbootstrap -y chroot -b "$ARCH" -- apk add gcc musl-dev linux-headers ||
		die "could not install the build tools in the $ARCH chroot"
	step "compile"
	sudo mkdir -p "$CHROOT/tmp/pcmcapture" || die "cannot create the build dir"
	sudo cp "$SRC" "$CHROOT/tmp/pcmcapture/" || die "cannot stage the source"
	pmbootstrap -y chroot -b "$ARCH" -- \
		gcc -O2 -Wall -Wextra -Werror -static \
		    -o /tmp/pcmcapture/pcm-capture \
		    /tmp/pcmcapture/pcm-capture.c ||
		die "compilation failed"
	mkdir -p "$STAGE" || die "cannot create $STAGE"
	sudo cp "$CHROOT/tmp/pcmcapture/pcm-capture" "$OUT" ||
		die "cannot copy the binary out of the chroot"
	sudo chmod 0755 "$OUT" || die "cannot chmod the staged binary"
fi

step "verify the artefact"
[ -s "$OUT" ] || die "the built binary is empty"
printf '  path   : %s\n  size   : %s bytes\n  sha256 : %s\n' \
	"$OUT" "$(stat -c%s "$OUT")" "$(sha256sum "$OUT" | cut -d' ' -f1)"
python3 "$REPO/tools/pcm-helper-elfcheck.py" "$OUT" ||
	die "the binary is not a 32-bit ARM ELF"
step "done"
echo "binary : $OUT"

#!/bin/sh
#
# Build alsa-setctl for the device (armv7, musl).
#
# Same approach as build-pcm-helper.sh: compile INSIDE pmbootstrap's armv7
# buildroot so the binary is built against exactly the musl and
# <sound/asound.h> the device runs. The device has no amixer, no tinymix, no
# alsactl and no DNS, so the control plane is otherwise unreachable.
#
# Usage:
#   build-alsa-setctl.sh --stage <dir> [--force]
#
# Needs an interactive sudo once. Exit: 0 built and verified.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/tools/alsa-setctl.c"
AUDIT="$REPO/tools/setctl-audit.py"
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
	-h|--help) sed -n '2,/^# Needs/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$STAGE" ] || die "--stage is required"
[ -f "$SRC" ] || die "no source at $SRC"
[ -f "$AUDIT" ] || die "no audit script at $AUDIT"

case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

step "environment"
echo "source  : $SRC"
echo "chroot  : $CHROOT"
echo "stage   : $STAGE"

#
# The audit runs before any compilation, for the same reason it does for the
# prepare-only helper: this tool's value is bounded by what it cannot do, and
# a binary that could start a stream would invalidate the milestone it serves.
#
step "forbidden-call audit (before compiling)"
python3 "$AUDIT" --selftest >/dev/null 2>&1 ||
	die "the audit's own selftest fails -- it cannot be trusted to check anything"
echo "  audit selftest: passed (it can still reject bad sources)"
python3 "$AUDIT" "$SRC" || die "the source failed the audit"

OUT="$STAGE/alsa-setctl"
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
	sudo mkdir -p "$CHROOT/tmp/setctl" || die "cannot create the build dir"
	sudo cp "$SRC" "$CHROOT/tmp/setctl/" || die "cannot stage the source"
	pmbootstrap -y chroot -b "$ARCH" -- \
		gcc -O2 -Wall -Wextra -Werror -static \
		    -o /tmp/setctl/alsa-setctl /tmp/setctl/alsa-setctl.c ||
		die "compilation failed"

	mkdir -p "$STAGE" || die "cannot create $STAGE"
	sudo cp "$CHROOT/tmp/setctl/alsa-setctl" "$OUT" ||
		die "cannot copy the binary out of the chroot"
	sudo chmod 0755 "$OUT" || die "cannot chmod the staged binary"
fi

step "verify the artefact"
[ -s "$OUT" ] || die "the built binary is empty"
printf '  path   : %s\n' "$OUT"
printf '  size   : %s bytes\n' "$(stat -c%s "$OUT")"
printf '  sha256 : %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
python3 "$REPO/tools/pcm-helper-elfcheck.py" "$OUT" ||
	die "the binary is not a 32-bit ARM ELF"

step "done"
echo "Copy it to the phone as a SINGLE scp (multi-file scp truncates), then:"
echo "  ./alsa-setctl --list | grep -i slimbus"
echo "  ./alsa-setctl --set 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 1"

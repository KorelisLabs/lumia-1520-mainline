#!/bin/sh
#
# Build the two C3a helpers for the device (armv7, musl): input-gate and
# pcm-tone.
#
# ONE SCRIPT FOR BOTH, ON PURPOSE. They are built the same way, into the same
# staging directory, and they are useless apart -- the tone must never play
# without the interlock armed. Two near-identical scripts would drift, and the
# first thing to drift would be whichever one ran the audit.
#
# THE AUDITS RUN FIRST, AND THE AUDIT'S OWN SELFTEST RUNS BEFORE THEM.
#
# A fence that cannot reject anything is worse than no fence: it prints a pass.
# So the order is selftest, then audit, then compile, and a failure at any of
# the three stops before a binary exists to be copied to the phone.
#
# Usage:
#   build-c3a-helpers.sh --stage <dir> [--force]
#
# Needs an interactive sudo once, like the kernel build.
# Exit: 0 built and verified, non-zero otherwise.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
AUDIT="$REPO/tools/c3a-helper-audit.py"
ELFCHECK="$REPO/tools/pcm-helper-elfcheck.py"
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
[ -f "$AUDIT" ] || die "no audit script at $AUDIT"
[ -f "$ELFCHECK" ] || die "no ELF checker at $ELFCHECK"

for f in input-gate pcm-tone; do
	[ -f "$REPO/tools/$f.c" ] || die "no source at $REPO/tools/$f.c"
done

case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
esac

step "environment"
echo "repo    : $REPO"
echo "chroot  : $CHROOT"
echo "stage   : $STAGE"

step "the audit's own selftest, before it is trusted to check anything"
python3 "$AUDIT" --selftest || die "the helper audit's selftest fails"

step "audit input-gate (polarity: every ambiguity resolves to abort)"
python3 "$AUDIT" --input-gate "$REPO/tools/input-gate.c" ||
	die "input-gate failed its audit"

step "audit pcm-tone (amplitude: the ceiling is compiled in)"
python3 "$AUDIT" --pcm-tone "$REPO/tools/pcm-tone.c" ||
	die "pcm-tone failed its audit"

NEED_BUILD=0
for f in input-gate pcm-tone; do
	if [ "$FORCE" = "1" ] || [ ! -f "$STAGE/$f" ] ||
	   [ ! "$STAGE/$f" -nt "$REPO/tools/$f.c" ]; then
		NEED_BUILD=1
	fi
done

if [ "$NEED_BUILD" = "0" ]; then
	step "compile"
	echo "both binaries are built and newer than their sources -- reusing"
	echo "(--force overrides)"
else
	step "toolchain (interactive sudo)"
	echo "pmbootstrap needs sudo once; the rest runs clean."
	command -v pmbootstrap >/dev/null 2>&1 ||
		die "pmbootstrap is not on PATH (tried \$HOME/.local/bin)"
	sudo -v || die "sudo authentication failed -- nothing was built"

	pmbootstrap -y chroot -b "$ARCH" -- apk add gcc musl-dev linux-headers ||
		die "could not install the build tools in the $ARCH chroot"

	step "compile"
	sudo mkdir -p "$CHROOT/tmp/c3a" || die "cannot create the build dir"
	mkdir -p "$STAGE" || die "cannot create $STAGE"

	for f in input-gate pcm-tone; do
		sudo cp "$REPO/tools/$f.c" "$CHROOT/tmp/c3a/" ||
			die "cannot stage $f.c"
		#
		# -Werror, and -static for the same reason the PCM runner is
		# static: the device's musl is the same musl, but a static
		# binary removes the last way an interlock can fail for a
		# reason that has nothing to do with the experiment.
		#
		# -lm is harmless under musl, where libm is part of libc, and
		# is kept so the command does not depend on that being true.
		#
		pmbootstrap -y chroot -b "$ARCH" -- \
			gcc -O2 -Wall -Wextra -Werror -static \
			    -o "/tmp/c3a/$f" "/tmp/c3a/$f.c" -lm ||
			die "compilation of $f failed"
		sudo cp "$CHROOT/tmp/c3a/$f" "$STAGE/$f" ||
			die "cannot copy $f out of the chroot"
		sudo chmod 0755 "$STAGE/$f" || die "cannot chmod $f"
	done
fi

step "verify the artefacts"
for f in input-gate pcm-tone; do
	OUT="$STAGE/$f"
	[ -s "$OUT" ] || die "$f is empty"
	printf '  %-12s %8s bytes  %s\n' "$f" "$(stat -c%s "$OUT")" \
	       "$(sha256sum "$OUT" | cut -d' ' -f1)"
	python3 "$ELFCHECK" "$OUT" >/dev/null ||
		die "$f is not a 32-bit ARM ELF"
done
echo "  both are 32-bit ARM ELF"

step "done"
echo "binaries : $STAGE/input-gate  $STAGE/pcm-tone"
echo
echo "Copy them to the phone ONE FILE PER SCP, and verify sha256 on the"
echo "phone before use -- single-file scp to this device has silently"
echo "delivered 0 bytes more than once."
echo
echo "Neither is run by hand during a C3a run. The runner arms the interlock"
echo "and drives the tone; pcm-tone refuses anything above -20 dBFS whatever"
echo "it is asked for, and input-gate refuses to arm unless BOTH the approve"
echo "and the abort device are present."

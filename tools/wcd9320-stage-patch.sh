#!/bin/bash
#
# Regenerate the WCD9320 patch from the working tree, bump pkgrel, and fix the
# checksums in BOTH APKBUILDs -- the live pmaports one and this repo's mirror.
#
# WHY THIS EXISTS
#
# build-wcd9320-kernel.sh deliberately refuses to stage anything: it verifies
# the patch, the pkgrel and the checksums and stops if they are stale, because
# silently regenerating a checksum is how a build stops corresponding to its
# source. That is the right split, but it left the staging half living in
# whatever ad-hoc commands the session happened to run, which is exactly the
# machine-specific state this project already removed from the build half.
#
# TWO THINGS THAT HAVE BITTEN BEFORE
#
#   abuild pairs source= and sha512sums= BY POSITION, and this package's
#   source= is ordered 0001, 0003, 0002. A filename-keyed checksum update gives
#   a false pass. The rewrite here is positional.
#
#   The repo's pmaports/ mirror is NOT a byte copy of the live tree. The live
#   APKBUILD and qcom-msm8974-microsoft-common.dtsi each carry a private
#   substrate string that must never reach a public repo, so the mirror's dtsi
#   checksum legitimately differs. Each tree's sums are therefore computed
#   against ITS OWN files. Syncing live -> mirror verbatim would both leak the
#   branding and look like a routine checksum fix.
#
# Usage:
#   tools/wcd9320-stage-patch.sh --pkgrel 164 --version hphl-dac-rc1
#   tools/wcd9320-stage-patch.sh --pkgrel 164 --version hphl-dac-rc1 --check
#
#   --check   verify only; touches nothing, exits non-zero if staging is stale
#
# Exit: 0 staged (or verified clean), non-zero with a reason otherwise.

set -u

PKG="${PKG:-linux-postmarketos-qcom-msm8974}"
PMB="${PMB:-$HOME/.local/var/pmbootstrap}"
COREPATCH="${COREPATCH:-$HOME/corepatch}"
Q6CARD="${Q6CARD:-$HOME/q6card}"

PKGREL=""
VERSION=""
CHECK=0

while [ $# -gt 0 ]; do
	case "$1" in
	--pkgrel)  PKGREL="${2:-}"; shift 2 ;;
	--version) VERSION="${2:-}"; shift 2 ;;
	--check)   CHECK=1; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }

# patch_header <file> -- everything before the first diff hunk.
#
# THIS IS NOT "UP TO THE FIRST BLANK LINE". The first version of this script
# used sed -n '1,/^$/p', which stops after From:/Subject: and would have
# silently deleted the entire rationale from both patches -- 31 lines of
# measured findings from 0005 alone, including why the front-end DAI cannot be
# named MultiMedia1 and why the channel map is provisional. The patch would
# still have applied, and the loss would only have shown up the next time
# somebody needed to know why.
patch_header() {
	sed -n '/^diff /q;p' "$1"
}

STALE=0
mark_stale() { STALE=1; echo "STALE: $*"; }

[ -n "$PKGREL" ]  || die "--pkgrel is required"
[ -n "$VERSION" ] || die "--version is required"

REPO=$(cd "$(dirname "$0")/.." && pwd)
APORTS="$PMB/cache_git/pmaports/device/testing/$PKG"
# The mirror is flattened -- pmaports/<pkg>/ -- and keeps only the files that
# are genuinely its own. Its patches live in the repo's patches/ directory and
# are shared with everything else that references them.
MIRROR="$REPO/pmaports/$PKG"

[ -d "$APORTS" ] || die "no pmaports package dir at $APORTS"
[ -d "$MIRROR" ] || die "no mirror at $MIRROR"

P2=0002-slimbus-wcd9320-codec-core.patch
P5=0005-asoc-qcom-lumia1520-q6-sndcard.patch

# ---------------------------------------------------------------- 1. source --
step "the working tree carries the version being staged"
grep -q "MODULE_VERSION(\"$VERSION\")" \
	"$COREPATCH/new/drivers/slimbus/wcd9320-core.c" ||
	die "$COREPATCH/new/.../wcd9320-core.c does not carry MODULE_VERSION(\"$VERSION\")"
echo "wcd9320-core.c reports $VERSION"

# ------------------------------------------------------------- 2. the patch --
#
# Regenerated into a temp file first and only moved into place if it differs,
# so a --check run is genuinely read-only and a no-op stage does not churn the
# mtime (which would make the build think it must rebuild).
step "regenerate $P2"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

{
	patch_header "$REPO/patches/$P2"
	( cd "$COREPATCH" && diff -uprN orig new )
} > "$TMP/$P2"

# diff exits 1 when files differ, which is the normal case here; what matters
# is that the result is non-empty and contains the driver.
[ -s "$TMP/$P2" ] || die "regenerated patch is empty"
grep -q "MODULE_VERSION(\"$VERSION\")" "$TMP/$P2" ||
	die "regenerated patch does not carry MODULE_VERSION(\"$VERSION\")"
echo "regenerated: $(wc -l < "$TMP/$P2") lines"

if cmp -s "$TMP/$P2" "$APORTS/$P2" && cmp -s "$TMP/$P2" "$REPO/patches/$P2"; then
	echo "patch already staged and identical in both trees"
	P2_CHANGED=0
else
	P2_CHANGED=1
	if [ "$CHECK" = "1" ]; then
		mark_stale "$P2 differs from the working tree"
	else
		cp "$TMP/$P2" "$APORTS/$P2"
		cp "$TMP/$P2" "$REPO/patches/$P2"
		echo "staged to pmaports and to $REPO/patches/"
	fi
fi

# 0005 comes from a different tree and usually does not change; regenerate it
# anyway so the two can never drift silently.
step "regenerate $P5"
if [ -d "$Q6CARD/orig" ] && [ -d "$Q6CARD/new" ]; then
	{
		patch_header "$REPO/patches/$P5"
		( cd "$Q6CARD" && diff -uprN orig new )
	} > "$TMP/$P5"
	[ -s "$TMP/$P5" ] || die "regenerated $P5 is empty"
	if cmp -s "$TMP/$P5" "$APORTS/$P5" && cmp -s "$TMP/$P5" "$REPO/patches/$P5"; then
		echo "unchanged"
	elif [ "$CHECK" = "1" ]; then
		mark_stale "$P5 differs from the working tree"
	else
		cp "$TMP/$P5" "$APORTS/$P5"
		cp "$TMP/$P5" "$REPO/patches/$P5"
		echo "staged"
	fi
else
	echo "no $Q6CARD orig/new pair, leaving $P5 alone"
fi

# ------------------------------------------------------------- 3. the pkgrel --
step "pkgrel"
for a in "$APORTS/APKBUILD" "$MIRROR/APKBUILD"; do
	cur=$(sed -n 's/^pkgrel=//p' "$a" | head -n1)
	if [ "$cur" = "$PKGREL" ]; then
		echo "$(basename "$(dirname "$a")")/$(basename "$a"): already $PKGREL"
	elif [ "$CHECK" = "1" ]; then
		mark_stale "$a is at pkgrel=$cur, wanted $PKGREL"
	else
		sed -i "s/^pkgrel=.*/pkgrel=$PKGREL/" "$a"
		echo "$a: $cur -> $PKGREL"
	fi
done

# ---------------------------------------------------------- 4. the checksums --
#
# Positional, and against each tree's OWN files.
step "sha512sums, positionally, per tree"
for a in "$APORTS/APKBUILD" "$MIRROR/APKBUILD"; do
	d=$(dirname "$a")
	echo "--- $a"
	CHECK=$CHECK python3 - "$a" "$d" "$REPO/patches" <<'PY' || die "checksum staging failed for $a"
import hashlib, os, re, sys

apk, d, fallback = sys.argv[1], sys.argv[2], sys.argv[3]
check = os.environ.get("CHECK") == "1"
t = open(apk).read()

msrc = re.search(r'^source="\n(.*?)^"$', t, re.M | re.S)
msum = re.search(r'^sha512sums="\n(.*?)^"$', t, re.M | re.S)
if not msrc or not msum:
    sys.exit("could not parse source= / sha512sums=")

src = msrc.group(1).split()
sums = msum.group(1).split()
names = sums[1::2]
if len(src) != len(names):
    sys.exit("%d sources vs %d sums -- fix by hand" % (len(src), len(names)))

lines, changed = [], 0
for i, s in enumerate(src):
    base = s.rsplit("/", 1)[-1]

    # Remote sources keep their recorded sum -- we are not going to download a
    # 200 MB kernel tarball to confirm a checksum nobody touched.
    if s.startswith(("http://", "https://")):
        lines.append("%s  %s" % (sums[i * 2], names[i]))
        continue

    # The filename is taken POSITIONALLY from the sums list, because source=
    # entries may carry unexpanded shell variables ($_config) that we cannot
    # resolve here. Where the source entry IS a plain filename, the two must
    # agree -- that mismatch is precisely the misalignment abuild would not
    # catch, since it pairs the two lists by position and never by name.
    if "$" not in base and base != names[i]:
        sys.exit("position %d: source %s but sum names %s" % (i, base, names[i]))
    fname = names[i]

    # The mirror keeps only its own files; its patches live in the repo's
    # shared patches/ directory. Look beside the APKBUILD first so a tree that
    # does have its own copy always wins.
    for cand in (os.path.join(d, fname), os.path.join(fallback, fname)):
        if os.path.exists(cand):
            p = cand
            break
    else:
        sys.exit("source %s not found in %s or %s" % (fname, d, fallback))

    h = hashlib.sha512(open(p, "rb").read()).hexdigest()
    if h != sums[i * 2]:
        changed += 1
        print("    %s: sum updated (from %s)" % (fname, os.path.dirname(p)))
    lines.append("%s  %s" % (h, fname))

if not changed:
    print("    all %d sums already correct" % len(src))
    sys.exit(0)
if check:
    print("    STALE: %d sum(s) would change" % changed)
    sys.exit(0)

new = t[:msum.start(1)] + "\n".join(lines) + "\n" + t[msum.end(1):]
open(apk, "w").write(new)
print("    wrote %d sums" % len(lines))
PY
done

# -------------------------------------------------------------- 5. verify ----
#
# In --check mode nothing was written, so the hard verify below would fail on
# exactly the staleness --check was asked to report. Report and exit instead.
if [ "$CHECK" = "1" ]; then
	step "check result"
	if [ "$STALE" = "1" ]; then
		echo "STAGING IS STALE -- rerun without --check to fix it."
		exit 1
	fi
	echo "staging is current: patches, pkgrel and both checksum sets agree"
	exit 0
fi

step "verify"
cmp -s "$APORTS/$P2" "$REPO/patches/$P2" ||
	die "staged $P2 differs from the repo copy"
echo "$P2 identical in both trees"
grep -q "^pkgrel=$PKGREL\$" "$APORTS/APKBUILD" ||
	die "live APKBUILD is not at pkgrel=$PKGREL"
grep -q "^pkgrel=$PKGREL\$" "$MIRROR/APKBUILD" ||
	die "mirror APKBUILD is not at pkgrel=$PKGREL"
echo "both APKBUILDs at pkgrel=$PKGREL"
grep -q "MODULE_VERSION(\"$VERSION\")" "$APORTS/$P2" ||
	die "staged patch does not carry $VERSION"
echo "staged patch carries $VERSION"

step "done"
echo "Next:"
echo "  tools/build-wcd9320-kernel.sh --pkgrel $PKGREL --version $VERSION \\"
echo "      --expect-asoc --expect-dais 1 --stage <dir> \\"
echo "      --extra-module sound/soc/qcom/qdsp6/q6core.ko \\"
echo "      --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko"

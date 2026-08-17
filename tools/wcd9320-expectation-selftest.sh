#!/bin/sh
#
# Offline proof that the evidence harness cannot validate an artefact it
# cannot name.
#
# Every evidence script used to carry a hard-coded EXPECT_VERSION frozen at
# whatever build was current when it was written -- and the shared lib carried
# "core-init-rc2", eight milestones stale. Those defaults failed loudly the day
# the version moved on, which was luck. The dangerous shape is a stale default
# that still MATCHES something: the gate passes, the evidence looks complete,
# and it describes the wrong build. Every milestone after it inherits the
# doubt.
#
# So the rule is now: environment, then manifest, then FAIL CLOSED. This proves
# all three, and proves the precedence between them -- an explicit override
# must never be silently replaced by a manifest that happens to be lying
# around next to the scripts.
#
# No hardware, no root, no kernel:
#   sh tools/wcd9320-expectation-selftest.sh
#
# Exit: 0 all cases pass, 1 otherwise.

set -u

DIR_SELF=$(dirname "$0")
LIB="$DIR_SELF/wcd9320-evidence-lib.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0

check() {	# check <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '    PASS  %-44s %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	else
		printf '    FAIL  %-44s got=[%s] want=[%s]\n' "$1" "$2" "$3"
		FAIL=$((FAIL + 1))
	fi
}

mkmanifest() {	# mkmanifest <dir> <version> <sha>
	mkdir -p "$1"
	{
		echo "# test manifest"
		echo "version=$2"
		echo "sha256=$3"
		echo "size=70896"
	} > "$1/wcd9320-artifact.manifest"
}

# Run resolve_expectations in a clean subshell and echo what it resolved.
# MODULE_VERSION_PATH is pointed at nothing: this exercises resolution only.
resolve() {	# resolve <dir> [env assignments...]
	_d=$1; shift
	env -u EXPECT_VERSION -u EXPECT_SHA -u ARTIFACT_MANIFEST "$@" \
		sh -c '
			set -u
			DIR="$1"
			. "$2"
			resolve_expectations
			printf "V=%s S=%s SRC=%s SHASRC=%s MF=%s\n" \
				"${EXPECT_VERSION:-}" "${EXPECT_SHA:-}" \
				"$EXPECT_SOURCE" "$EXPECT_SHA_SOURCE" "$MANIFEST_PATH"
		' _ "$_d" "$LIB" 2>&1
	echo "rc=$?"
}

# ---------------------------------------------------------------- case 1 --
echo "case 1: no environment, no manifest -> MUST FAIL CLOSED"
mkdir -p "$W/empty"
OUT=$(resolve "$W/empty")
check "exit code is 2 (invalid run)" \
	"$(printf '%s\n' "$OUT" | sed -n 's/^rc=//p')" "2"
check "says INVALID RUN" \
	"$(printf '%s\n' "$OUT" | grep -c 'INVALID RUN')" "1"
check "refuses to resolve a version" \
	"$(printf '%s\n' "$OUT" | grep -c '^V=[a-z]')" "0"
check "names the ways to supply one" \
	"$(printf '%s\n' "$OUT" | grep -c 'EXPECT_VERSION=<ver>')" "1"

# ---------------------------------------------------------------- case 2 --
echo "case 2: manifest only -> resolves from it, and says so"
mkmanifest "$W/m2" "asoc-card-rc1" "91461ca6704d169b1f1dc3b9c6be261a86651f7912166e9e44ca3ff350090beb"
OUT=$(resolve "$W/m2")
check "version from manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*V=\([^ ]*\).*/\1/p')" "asoc-card-rc1"
check "sha from manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*S=\([^ ]*\).*/\1/p')" \
	"91461ca6704d169b1f1dc3b9c6be261a86651f7912166e9e44ca3ff350090beb"
check "version source recorded as manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.* SRC=\([^ ]*\).*/\1/p')" "manifest"
check "sha source recorded as manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*SHASRC=\([^ ]*\).*/\1/p')" "manifest"
check "manifest path recorded" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*MF=\(.*\)/\1/p')" \
	"$W/m2/wcd9320-artifact.manifest"
check "exit 0" "$(printf '%s\n' "$OUT" | sed -n 's/^rc=//p')" "0"

# ---------------------------------------------------------------- case 3 --
echo "case 3: environment AND manifest disagree -> environment wins"
mkmanifest "$W/m3" "stale-from-manifest" "aaaa"
OUT=$(resolve "$W/m3" EXPECT_VERSION=explicit-from-env)
check "environment overrides the manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*V=\([^ ]*\).*/\1/p')" "explicit-from-env"
check "version source recorded as environment" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.* SRC=\([^ ]*\).*/\1/p')" "environment"

# ---------------------------------------------------------------- case 4 --
echo "case 4: environment sets only the version -> sha still comes from manifest"
mkmanifest "$W/m4" "ignored" "bbbbcccc"
OUT=$(resolve "$W/m4" EXPECT_VERSION=env-version)
check "version from environment" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*V=\([^ ]*\).*/\1/p')" "env-version"
check "sha still filled from manifest" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*S=\([^ ]*\).*/\1/p')" "bbbbcccc"

# ---------------------------------------------------------------- case 5 --
echo "case 5: explicit sha is never overwritten by the manifest"
mkmanifest "$W/m5" "v" "manifest-sha"
OUT=$(resolve "$W/m5" EXPECT_VERSION=v EXPECT_SHA=env-sha)
check "explicit sha survives" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*S=\([^ ]*\).*/\1/p')" "env-sha"
check "sha source recorded as environment" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*SHASRC=\([^ ]*\).*/\1/p')" "environment"

# ---------------------------------------------------------------- case 6 --
echo "case 6: ARTIFACT_MANIFEST points somewhere else -> that file is used"
mkmanifest "$W/m6a" "beside-the-scripts" "aa"
mkmanifest "$W/m6b" "explicitly-pointed-at" "bb"
OUT=$(resolve "$W/m6a" ARTIFACT_MANIFEST="$W/m6b/wcd9320-artifact.manifest")
check "the pointed-at manifest wins over the adjacent one" \
	"$(printf '%s\n' "$OUT" | sed -n 's/.*V=\([^ ]*\).*/\1/p')" "explicitly-pointed-at"

# ---------------------------------------------------------------- case 7 --
echo "case 7: a manifest with no version line is not a usable expectation"
mkdir -p "$W/m7"
printf '# nothing useful here\nsize=1\n' > "$W/m7/wcd9320-artifact.manifest"
OUT=$(resolve "$W/m7")
check "still fails closed" \
	"$(printf '%s\n' "$OUT" | sed -n 's/^rc=//p')" "2"

# ---------------------------------------------------------------- case 8 --
echo "case 8: no stale expectation survives anywhere in tools/"
STALE=$(grep -l 'EXPECT_VERSION="${EXPECT_VERSION:-[a-z0-9]' "$DIR_SELF"/*.sh 2>/dev/null | wc -l)
check "no script carries a hard-coded version default" "$STALE" "0"
STALE_SHA=$(grep -l 'EXPECT_SHA="${EXPECT_SHA:-[0-9a-f][0-9a-f]' "$DIR_SELF"/*.sh 2>/dev/null | wc -l)
check "no script carries a hard-coded sha default" "$STALE_SHA" "0"

echo
echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "expectation resolution proven: environment > manifest > fail closed."

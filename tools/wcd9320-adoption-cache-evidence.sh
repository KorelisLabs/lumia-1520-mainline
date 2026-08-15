#!/bin/sh
#
# Adoption with the cache live: does adopting an already-initialised codec
# leave cacheable reads stale relative to hardware?
#
# wcd9320-regcache-proven certified the FRESH path: the codec came up dark, the
# cache was populated from reg_defaults, and 460 cacheable registers agreed
# with the chip. It explicitly did not claim the adoption path. This is the
# regression that closes the remaining regcache-specific risk, and it is
# additional evidence against that milestone rather than a new one.
#
# STAGING: core_reinit, not unbind
#
# handoff_on_remove leaves the supplies enabled while devres frees the handles,
# which was measured to produce one _regulator_put() "releasing supply whilst
# still enabled" warning per supply -- seven in total. Evidence staged that way
# is not clean enough to certify against. core_reinit instead touches no
# hardware at all: it clears only the driver's software record of having
# initialised the core and re-enters the SAME production decision function that
# probe uses, so wcd9320_core_init() has to re-read the sentinel and decide for
# itself. With the block still accessible the only correct answer is adoption
# with no writes.
#
# WHAT THIS DOES AND DOES NOT EXERCISE -- read before quoting the result
#
# core_reinit does not recreate the regmap, so the cache persists across the
# re-entry holding what the driver wrote through it during the fresh boot.
# What this run therefore proves is that TAKING THE ADOPTION BRANCH does not
# leave cacheable reads stale: no writes are made behind the cache's back, the
# cache is not dropped or dirtied, and cached and bypassed reads still agree
# register for register afterwards.
#
# It does NOT exercise a NEW regmap created against an already-initialised
# codec. That is the case where reg_defaults -- which describes the reset
# state -- would start out disagreeing with hardware for the six core-init
# writes. No available staging route reaches it: core_reinit keeps the regmap,
# and rmmod/modprobe was measured to re-reset and take the fresh path. That
# case stays recorded as latent and unreachable in wcd9320-regcache.md, and
# this run does not change its status.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="adoption-cache"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-regcache-rc9}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-adoptcache-$$"
SETTLE="${SETTLE:-3}"

EXPECT_CACHEABLE="${EXPECT_CACHEABLE:-460}"
EXPECT_VOLATILE="${EXPECT_VOLATILE:-209}"

REGMAP_DEBUGFS="${REGMAP_DEBUGFS:-/sys/kernel/debug/regmap}"

require_module_version
find_devices

[ -w "$PGD/core_reinit" ] || {
	say "INVALID RUN: $PGD/core_reinit is not writable."
	say "  This run must be root, and the module must carry the research hook."
	exit 2
}
[ -r "$PGD/cache_check" ] || {
	say "INVALID RUN: no cache_check attribute -- module predates the regcache work."
	exit 2
}

# ---------------------------------------------------------------- baseline --
#
# Everything the adoption gate needs as a baseline, plus the cache state, read
# BEFORE the re-entry. The counters are cumulative for the life of the driver
# instance, so what has to be zero afterwards is the delta, not the absolute.
BASE_RESET=$(kv "$PGD/bringup" reset_transitions)
BASE_SUPPLY_EN=$(kv "$PGD/bringup" supply_enables)
BASE_SUPPLY_DIS=$(kv "$PGD/bringup" supply_disables)
BASE_INIT_RUNS=$(kv "$PGD/rco_wake" init_runs)
BASE_CORE_READY=$(kv "$PGD/rco_wake" core_ready)
BASE_NZ_AFTER=$(kv "$PGD/rco_wake" nonzero_after)

CACHE_BEFORE=$(cat "$PGD/cache_check" 2>/dev/null)
CB_FILE="/tmp/.wcd9320-cache-before-$$"
printf '%s\n' "$CACHE_BEFORE" > "$CB_FILE"
B_CHECKED=$(kv "$CB_FILE" cacheable_checked)
B_MISMATCH=$(kv "$CB_FILE" mismatches)
B_VOL=$(kv "$CB_FILE" volatile_checked)

WARN_BEFORE=$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')
REGPUT_BEFORE=$(dmesg 2>/dev/null | grep -c '_regulator_put')

# The codec must already be initialised, or there is nothing to adopt and the
# run would be measuring the fresh path again under a different name.
if [ "$BASE_CORE_READY" != "1" ]; then
	say "INVALID RUN: core_ready=$BASE_CORE_READY -- the codec is not initialised,"
	say "  so there is nothing to adopt. Boot the device and let core init run"
	say "  before staging this."
	rm -f "$CB_FILE"
	exit 2
fi

# ------------------------------------------------------------- the re-entry --
printf 'staging adoption via core_reinit (no hardware touched)...\n' >&2
if ! printf 'reinit-test' > "$PGD/core_reinit" 2>/dev/null; then
	say "INVALID RUN: writing the core_reinit token failed."
	rm -f "$CB_FILE"
	exit 2
fi
sleep "$SETTLE"

# The banner core_reinit prints is the marker the log delta is taken from, so
# the sequence assertions below see only what this re-entry did.
DMESG_MARKER="${DMESG_MARKER:-core reinit test: clearing software init state}"
snap_dmesg

# ----------------------------------------------------------------- after ----
AFTER_RESET=$(kv "$PGD/bringup" reset_transitions)
AFTER_SUPPLY_EN=$(kv "$PGD/bringup" supply_enables)
AFTER_SUPPLY_DIS=$(kv "$PGD/bringup" supply_disables)
AFTER_INIT_RUNS=$(kv "$PGD/rco_wake" init_runs)
AFTER_INIT_CALLS=$(kv "$PGD/rco_wake" init_calls)
CORE_ADOPTED=$(kv "$PGD/rco_wake" core_adopted)
NZB_AFTER_REENTRY=$(kv "$PGD/rco_wake" nonzero_before)

# The cache reading that is the point of the run. Taken AFTER adoption.
CACHE_AFTER=$(cat "$PGD/cache_check" 2>/dev/null)
CA_FILE="/tmp/.wcd9320-cache-after-$$"
printf '%s\n' "$CACHE_AFTER" > "$CA_FILE"
A_CHECKED=$(kv "$CA_FILE" cacheable_checked)
A_MISMATCH=$(kv "$CA_FILE" mismatches)
A_VOL=$(kv "$CA_FILE" volatile_checked)
A_ERRORS=$(kv "$CA_FILE" read_errors)
A_FM=$(printf '%s\n' "$CACHE_AFTER" | grep 'first_mismatch')

REGMAP_DBG=""
for d in "$REGMAP_DEBUGFS"/"$PGD_NAME"*; do
	[ -d "$d" ] && REGMAP_DBG="$d" && break
done
CACHE_FILES=""
for f in cache_only cache_dirty cache_bypass; do
	[ -e "$REGMAP_DBG/$f" ] && CACHE_FILES="$CACHE_FILES $f"
done
CACHE_FILES="${CACHE_FILES# }"

LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

open_output "$OUTDIR/wcd9320-adoption-cache-$STAMP.txt"

{
	hdr "the cache, before and after adoption"
	say "before:"
	printf '%s\n' "$CACHE_BEFORE" | sed 's/^/  /'
	say "after:"
	printf '%s\n' "$CACHE_AFTER" | sed 's/^/  /'
	say ""
	say "regmap debugfs   : ${REGMAP_DBG:-none found}"
	say "cache files      : ${CACHE_FILES:-none}"

	hdr "counters across the re-entry"
	say "                     before   after"
	say "reset_transitions : ${BASE_RESET:-?}        ${AFTER_RESET:-?}"
	say "supply_enables    : ${BASE_SUPPLY_EN:-?}        ${AFTER_SUPPLY_EN:-?}"
	say "supply_disables   : ${BASE_SUPPLY_DIS:-?}        ${AFTER_SUPPLY_DIS:-?}"
	say "init_runs         : ${BASE_INIT_RUNS:-?}        ${AFTER_INIT_RUNS:-?}"
	say "init_calls        : -        ${AFTER_INIT_CALLS:-?}  (entries that all no-opped)"
	say "core_adopted      : -        ${CORE_ADOPTED:-?}"
	say "nonzero_before    : -        ${NZB_AFTER_REENTRY:-?}  (as-found at re-entry; the block was alive)"
	say "dmesg delta       : ${DMESG_DELTA:-?}"

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- the adoption branch was actually taken --
	check "core_adopted" "$CORE_ADOPTED" "1"
	check "init_runs (no sequence ran)" "$AFTER_INIT_RUNS" "0"
	check_cond "codec was already initialised at re-entry" \
		"$([ "$(num "$NZB_AFTER_REENTRY" 0)" -ge 48 ] && echo 1 || echo 0)" \
		"nonzero_before=$NZB_AFTER_REENTRY -- the block was dark, so this was not an adoption" \
		"nonzero_before=$NZB_AFTER_REENTRY"
	_adopt=$(count_lines 'core init: already accessible')
	check_cond "adoption logged, no writes" \
		"$([ "$_adopt" -ge 1 ] && echo 1 || echo 0)" \
		"no 'already accessible ... adopting, no writes' line in the delta" \
		"x$_adopt"

	# -- zero new init, reset or supply operations --
	check "reset_transitions delta" "$((AFTER_RESET - BASE_RESET))" "0"
	check "supply_enables delta" "$((AFTER_SUPPLY_EN - BASE_SUPPLY_EN))" "0"
	check "supply_disables delta" "$((AFTER_SUPPLY_DIS - BASE_SUPPLY_DIS))" "0"
	check "bring-up step lines" "$(count_lines 'bring-up step')" "0"
	check "rco-wake step lines" "$(count_lines 'rco-wake step')" "0"
	check "fresh bring-up lines" "$(count_lines 'fresh bring-up')" "0"
	check "core init initialising lines" "$(count_lines 'core init: .* -- initialising')" "0"

	# -- THE POINT: the cache is not stale after adopting --
	check "cache still enabled" "$CACHE_FILES" "cache_only cache_dirty cache_bypass"
	check "cacheable mismatches after adoption" "$(num "$A_MISMATCH" x)" "0"
	check "read errors after adoption" "$(num "$A_ERRORS" x)" "0"
	check "cacheable registers checked" "$(num "$A_CHECKED" 0)" "$EXPECT_CACHEABLE"
	check "volatile registers checked" "$(num "$A_VOL" 0)" "$EXPECT_VOLATILE"
	check_cond "no first_mismatch reported" \
		"$([ -z "$A_FM" ] && echo 1 || echo 0)" "$A_FM" "none"

	# The population must not have changed across the re-entry either: a
	# different count would mean the predicates or the map moved under us.
	check "cacheable count unchanged" "$A_CHECKED" "$B_CHECKED"
	check "volatile count unchanged" "$A_VOL" "$B_VOL"
	check "mismatches were zero before too" "$(num "$B_MISMATCH" x)" "0"

	# -- and nothing complained --
	check "new regulator warnings" \
		"$(($(dmesg 2>/dev/null | grep -c '_regulator_put') - REGPUT_BEFORE))" "0"
	check "new kernel WARNING/BUG" \
		"$(($(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:') - WARN_BEFORE))" "0"
	check "core init FAILED lines" "$(count_lines 'core init: FAILED')" "0"
	check "sequence ABORTED lines" "$(count_lines 'ABORTED')" "0"
	check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
	check "masks undisturbed" "$LIVE_MASK" "ff ff 3f 7f"
	check_no_manual_wake

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "ADOPTION DOES NOT LEAVE THE CACHE STALE."
		say ""
		say "The driver re-entered its production decision path, found the CDC"
		say "block already accessible ($NZB_AFTER_REENTRY non-zero as-found) and"
		say "adopted it without writing a single register: zero reset"
		say "transitions, zero supply operations, no replay of either sequence."
		say ""
		say "With the cache live throughout, all $A_CHECKED cacheable registers"
		say "still read identically through the cache and with the cache"
		say "bypassed. Adoption makes no writes behind the cache's back and"
		say "leaves no cacheable read stale."
		say ""
		say "SCOPE. core_reinit does not recreate the regmap, so this exercises"
		say "the adoption BRANCH with an existing cache. It does not exercise a"
		say "new regmap created against an already-initialised codec, where"
		say "reg_defaults would start out describing a reset state the hardware"
		say "has left. No staging route reaches that case; it remains recorded"
		say "as latent and unreachable in wcd9320-regcache.md, and this run"
		say "does not change its status."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If mismatches is non-zero, first_mismatch names the register, the"
		say "cached value and the hardware value. A mismatch here means the"
		say "adoption path let hardware and cache diverge -- either a write that"
		say "bypassed the cache, or state the codec changed that is not marked"
		say "volatile."
	fi

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE" "$CB_FILE" "$CA_FILE"

sed -n '/=== the cache, before and after adoption/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
printf '\nBaselines for the adoption gate, if running it against this same re-entry:\n'
printf '  BASE_RESET=%s BASE_SUPPLY_EN=%s BASE_SUPPLY_DIS=%s EXPECT_POWER_OWNED=1\n' \
	"$BASE_RESET" "$BASE_SUPPLY_EN" "$BASE_SUPPLY_DIS"
exit "$RC"

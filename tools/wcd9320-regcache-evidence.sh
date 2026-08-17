#!/bin/sh
#
# WCD9320 regcache acceptance: does the cache tell the truth about the chip?
#
# Enabling REGCACHE_MAPLE replaces a hardware read with a remembered value on
# every non-volatile register. That is silent when it is right and silent when
# it is wrong, which is the worst failure mode this port has -- it has been
# bitten by a silently-wrong value twice. So the cache does not get to be
# assumed correct because it was derived carefully; it gets measured against
# the chip, register by register, on real hardware.
#
# WHAT THE GATE ACTUALLY RESTS ON
#
# The driver's cache_check attribute walks every readable register and reads it
# twice: once through the cache, once with regcache_cache_bypass() set so the
# read reaches the codec. For a non-volatile register those two values must be
# identical. Any disagreement is a stale cache entry, and since every cacheable
# register is preloaded from reg_defaults, a disagreement is equally a wrong
# entry in the defaults table. One mismatch fails this run.
#
# The three population counts are asserted too, and they are not decorative.
# They were derived independently of the driver, by parsing the built .ko's
# ELF and counting bits in wcd9320_readable_bitmap and wcd9320_volatile_bitmap
# and entries in wcd9320_reg_defaults. If the running module's predicates
# disagree with the tables that were reviewed, the counts move and this run
# fails rather than quietly measuring a different driver.
#
#   cacheable_checked  readable AND NOT volatile   460
#   volatile_checked   readable AND volatile       209
#   sum                readable                    669
#
# WHY THE COUNTS ARE CHECKED AND NOT JUST THE MISMATCHES
#
# mismatches=0 is trivially satisfiable by a driver that checks nothing. A run
# where cacheable_checked came back 0 would report a clean cache and mean
# nothing at all -- the same shape of hole as the frozen irq_observe fields
# that made two acceptance checks unfailable in aa6feac. The counts are what
# make mismatches=0 a measurement.
#
# WHEN TO RUN IT
#
# After the cold-boot run and before arming any interrupt. It performs 669
# bypassed hardware reads and nothing else: it writes no register, and every
# address it touches has been read on this hardware by the existing snapshot
# paths. Running it with a source armed would interleave these reads with the
# interrupt path for no benefit.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="regcache"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-regcache-$$"
MASK_ALL="ff ff 3f 7f"

# Derived from the built module's own ELF, not from the driver's report of
# itself. Override only when the tables are regenerated.
EXPECT_CACHEABLE="${EXPECT_CACHEABLE:-460}"
EXPECT_VOLATILE="${EXPECT_VOLATILE:-209}"
EXPECT_READABLE="${EXPECT_READABLE:-669}"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-regcache-$STAMP.txt"

if [ ! -r "$PGD/cache_check" ]; then
	say "INVALID RUN: no cache_check attribute on $PGD_NAME."
	say "  The running module predates the regcache work, or the control"
	say "  function was misidentified. Nothing was collected."
	rm -f "$DMESG_FILE"
	exit 2
fi

# Is a cache actually active? cache_check alone cannot tell you.
#
# With REGCACHE_NONE every regmap_read reaches the chip, so the cached read and
# the bypassed read are the same read, mismatches is 0 for free, and
# cacheable_checked is still 460. A driver that had quietly lost its cache_type
# would produce a flawless-looking run. regmap creates cache_only, cache_dirty
# and cache_bypass under debugfs only when cache_type != REGCACHE_NONE, so
# their presence is the discriminator the attribute cannot provide.
#
# REGMAP_DEBUGFS is overridable for the offline self-test only, the same way
# MODULE_VERSION_PATH and SLIM_DEVICES are. On the device, leave it alone.
REGMAP_DEBUGFS="${REGMAP_DEBUGFS:-/sys/kernel/debug/regmap}"
REGMAP_DBG=""
for d in "$REGMAP_DEBUGFS"/"$PGD_NAME"*; do
	[ -d "$d" ] || continue
	REGMAP_DBG="$d"
	break
done
if [ -z "$REGMAP_DBG" ]; then
	for d in "$REGMAP_DEBUGFS"/*; do
		[ -d "$d" ] || continue
		[ -e "$d/cache_only" ] || continue
		REGMAP_DBG="$d"
		break
	done
fi
CACHE_FILES=""
for f in cache_only cache_dirty cache_bypass; do
	[ -e "$REGMAP_DBG/$f" ] && CACHE_FILES="$CACHE_FILES $f"
done
CACHE_FILES="${CACHE_FILES# }"

# One read of the attribute, reused for every assertion. Reading it twice would
# be two different walks of the chip and the numbers could not be compared.
CACHE_RAW=$(cat "$PGD/cache_check" 2>/dev/null)
CACHE_FILE="/tmp/.wcd9320-cache-$$"
printf '%s\n' "$CACHE_RAW" > "$CACHE_FILE"

CHECKED=$(kv "$CACHE_FILE" cacheable_checked)
MISMATCH=$(kv "$CACHE_FILE" mismatches)
VOL_CHECKED=$(kv "$CACHE_FILE" volatile_checked)
VOL_MOVED=$(kv "$CACHE_FILE" volatile_moved)
ERRORS=$(kv "$CACHE_FILE" read_errors)
READABLE_SUM=$(( $(num "$CHECKED" 0) + $(num "$VOL_CHECKED" 0) ))

LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)
LIVE_STATUS=$(sed -n 's/^status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

{
	hdr "what the cache says about the chip"
	printf '%s\n' "$CACHE_RAW"

	hdr "is there actually a cache"
	say "regmap debugfs   : ${REGMAP_DBG:-none found}"
	say "cache files      : ${CACHE_FILES:-none} (regmap creates these only when cache_type != REGCACHE_NONE)"

	hdr "population, derived from the built module's ELF"
	say "cacheable (readable & !volatile) : ${CHECKED:-?}   expected $EXPECT_CACHEABLE"
	say "volatile  (readable &  volatile) : ${VOL_CHECKED:-?}   expected $EXPECT_VOLATILE"
	say "readable  (the sum of those two) : $READABLE_SUM   expected $EXPECT_READABLE"
	say "volatile registers seen to move  : ${VOL_MOVED:-?} (informational -- not a gate)"

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- a cache exists at all, before believing anything it says --
	check_cond "regmap debugfs found" \
		"$([ -n "$REGMAP_DBG" ] && echo 1 || echo 0)" \
		"no regmap directory under /sys/kernel/debug/regmap -- is debugfs mounted?" \
		"$REGMAP_DBG"
	check "cache is enabled (not REGCACHE_NONE)" \
		"$CACHE_FILES" "cache_only cache_dirty cache_bypass"

	# -- the gate --
	check "cacheable mismatches" "$(num "$MISMATCH" x)" "0"
	check "read errors" "$(num "$ERRORS" x)" "0"

	# -- and the counts that make the gate mean something --
	check "cacheable registers checked" "$(num "$CHECKED" 0)" "$EXPECT_CACHEABLE"
	check "volatile registers checked" "$(num "$VOL_CHECKED" 0)" "$EXPECT_VOLATILE"
	check "readable registers walked" "$READABLE_SUM" "$EXPECT_READABLE"

	# A first_mismatch line is printed by the driver only when something
	# diverged; its absence is part of the result. Kept as an independent
	# read of the attribute text rather than a restatement of mismatches=0,
	# so a driver that miscounted would still be caught here.
	FM=$(printf '%s\n' "$CACHE_RAW" | grep 'first_mismatch')
	check_cond "no first_mismatch reported" \
		"$([ -z "$FM" ] && echo 1 || echo 0)" \
		"$FM" "none"

	# -- the codec is in the state the cache was derived for --
	check "bring-up path" "$(kv "$PGD/bringup" path)" "fresh"
	check "not adopted" "$(kv "$PGD/bringup" adopted)" "0"
	check "codec was dark at probe" "$(kv "$PGD/rco_wake" nonzero_before)" "0"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	check "registers after init" "$(kv "$PGD/rco_wake" nonzero_after)" "95"
	check "core init FAILED lines" "$(count_lines 'core init: FAILED')" "0"
	check_canary

	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "identity minor" \
		"$(sed -n 's/.*minor \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0001"

	# -- interrupt state untouched by 669 bypassed reads --
	check "masks still initialised" "$LIVE_MASK" "$MASK_ALL"
	check "nothing asserted" "$LIVE_STATUS" "00 00 00 00"

	# -- regmap itself is not complaining --
	check "regmap/regcache warnings" \
		"$(dmesg 2>/dev/null | grep -ci 'regmap.*error\|regcache\|invalid.*cache')" "0"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE CACHE AGREES WITH THE CHIP."
		say ""
		say "$CHECKED cacheable registers were read through the cache and again"
		say "with the cache bypassed, and every pair was identical. Because all"
		say "$CHECKED are preloaded from reg_defaults, that is simultaneously a"
		say "check of the cache and of the defaults table: a wrong reset value"
		say "would surface here as a mismatch against the live codec."
		say ""
		say "$VOL_CHECKED readable volatile registers were walked and excluded"
		say "from the comparison by the volatile predicate, so nothing in the"
		say "interrupt or status path was served from the cache."
		say ""
		say "What this does NOT cover: volatility of families this run has no"
		say "stimulus for. Digital gain, clip-detect, VBAT and the IIR/ANC"
		say "windows are marked volatile on downstream's authority, not on"
		say "measurement here, and a register wrongly marked volatile costs"
		say "only a hardware read. The dangerous direction -- cacheable when it"
		say "should not be -- is what this run measures, and only for state the"
		say "codec reached on this boot."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If mismatches is non-zero, the first_mismatch line names the"
		say "register, the cached value and the hardware value. Decide which of"
		say "the two is wrong before changing anything: a register that moved"
		say "with no write from us belongs in volatile_reg, and a register whose"
		say "reset value was mis-derived belongs in reg_defaults. 0x1fd was"
		say "already found to be the first kind."
		say ""
		say "If the counts are wrong but mismatches is 0, the running module is"
		say "not the one whose tables were reviewed. Check the .ko in"
		say "/lib/modules against the built artefact by sha256 before rerunning."
	fi

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE" "$CACHE_FILE"

sed -n '/=== what the cache says about the chip/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

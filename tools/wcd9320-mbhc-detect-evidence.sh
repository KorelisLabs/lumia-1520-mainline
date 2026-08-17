#!/bin/sh
#
# WCD9320 minimal MBHC insert detection: does a physical headset event produce
# a reproducible codec-visible status transition?
#
# ACCEPTANCE FOR THIS STEP, AND NOTHING MORE:
#
#   physical insertion/removal -> reproducible MBHC status transition
#
# It must transition on insertion AND return on removal. Interrupts are not in
# scope: every MBHC source stays masked throughout, and the run asserts that.
# IRQ arming is the next step and only if this one passes.
#
# WHAT IS WRITTEN, AND WHY THAT AND NOT MORE
#
# Three writes, all to one register, all sourced from downstream's
# wcd9xxx_insert_detect_setup():
#
#   update_bits(0x14A, 0x01, 0)     disable first -- "avoid glitch"
#   write(0x14A, 0x6C | BIT(1))     = 0x6E, set up for insertion
#   update_bits(0x14A, 0x01, 1)     re-enable -> 0x6F
#
# That function touches no micbias, no MBHC_EN_CTL and no MBHC clock, which is
# why this is tried before anything larger. Jack presence is bit 2 of 0x14B,
# per wcd9xxx_swch_level_remove(); wcd9320.c marks that register volatile.
#
# Every write the driver makes is logged and printed here. Any register that
# moved and is NOT in that log changed by itself, and the run reports those
# separately as side effects rather than folding them in.
#
# Exit: 0 PASS  -- transitioned on insertion and returned on removal
#       1 FAIL  -- configured, but no reproducible transition
#       2 INVALID -- the run itself did not hold up

set -u

MODE="mbhc-detect"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-detect-$$"
SETTLE="${SETTLE:-20}"
VARIANT="${VARIANT:-on}"		# 'on' = 0x6c base, 'on-alt' = 0x68
MASK_ALL="ff ff 3f 7f"
MBHC_BASE=960				# 0x3c0

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-mbhc-detect-$STAMP.txt"

# --- reading -----------------------------------------------------------------

det_hdr()     { head -n1 "$PGD/mbhc_detect" 2>/dev/null; }
det_field()   { det_hdr | tr ' ' '\n' | sed -n "s/^$1=//p"; }
det_writes()  { sed -n '2,$p' "$PGD/mbhc_detect" 2>/dev/null; }
present()     { det_field present_bit; }
probe_block() { sed -n '3,$p' "$PGD/mbhc_probe" 2>/dev/null | tr -d '\n '; }
probe_field() { head -n1 "$PGD/mbhc_probe" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
live_mask() {
	sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
diff_block() {
	awk -v a="$1" -v b="$2" -v base="$MBHC_BASE" 'BEGIN {
		if (length(a) == 0 || length(a) != length(b)) {
			print "  (cannot compare)"; exit
		}
		n = 0
		for (i = 0; i < length(a) / 2; i++) {
			x = substr(a, i * 2 + 1, 2); y = substr(b, i * 2 + 1, 2)
			if (x != y) { printf "  0x%03x: %s -> %s\n", base + i, x, y; n++ }
		}
		if (n == 0) print "  (no byte changed)"
	}'
}
tty_note() { printf '%s\n' "$*" >&2; }

# Poll the presence bit across a window; echo every distinct value seen, so a
# transition that settles back is recorded rather than missed.
watch_present() {
	_seen=""
	_i=0
	while [ "$_i" -lt "$1" ]; do
		_v=$(present)
		case " $_seen " in
			*" $_v "*) ;;
			*) _seen="$_seen $_v" ;;
		esac
		sleep 1
		_i=$((_i + 1))
	done
	printf '%s' "${_seen# }"
}

# --- COLLECT -----------------------------------------------------------------

if [ ! -r "$PGD/mbhc_detect" ]; then
	say "INVALID RUN: $PGD/mbhc_detect is missing."
	say "  This build predates the insert-detect hook."
	exit 2
fi

MASK_BEFORE=$(live_mask)
DET_BEFORE=$(det_hdr)
STATUS_OFF=$(det_field status)
PRESENT_OFF=$(present)
BLK_BEFORE=$(probe_block)
NZ_BEFORE=$(head -n1 "$PGD/mbhc_probe" 2>/dev/null | tr ' ' '\n' | sed -n 's/^insert_det=//p')

tty_note "before: $DET_BEFORE"

# --- the writes --------------------------------------------------------------
tty_note "enabling insert detection (variant: $VARIANT)"
if ! echo "$VARIANT" > "$PGD/mbhc_detect" 2>/dev/null; then
	say "could not enable insert detection"
	emit_invalid_setup "writing '$VARIANT' to mbhc_detect failed"
	exit 2
fi
sleep 1

DET_ON=$(det_hdr)
WRITE_LOG=$(det_writes)
DET_REG=$(det_field detect)
STATUS_ON=$(det_field status)
PRESENT_ON=$(present)
BLK_ON=$(probe_block)
MASK_ON=$(live_mask)
tty_note "enabled: $DET_ON"

# --- physical events ---------------------------------------------------------
printf '\n>>> INSERT A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
SEQ_IN=$(watch_present "$SETTLE")
STATUS_IN=$(det_field status)
PRESENT_IN=$(present)
BLK_IN=$(probe_block)
tty_note "inserted: status=$STATUS_IN present_bit=$PRESENT_IN (seen: $SEQ_IN)"

printf '\n>>> NOW REMOVE THE HEADSET (%ss) <<<\n\n' "$SETTLE" >&2
SEQ_OUT=$(watch_present "$SETTLE")
STATUS_OUT=$(det_field status)
PRESENT_OUT=$(present)
BLK_OUT=$(probe_block)
tty_note "removed: status=$STATUS_OUT present_bit=$PRESENT_OUT (seen: $SEQ_OUT)"

# --- restore -----------------------------------------------------------------
tty_note "restoring 0x14a"
echo off > "$PGD/mbhc_detect" 2>/dev/null
sleep 1
DET_AFTER=$(det_hdr)
RESTORE_LOG=$(det_writes)
DET_REG_AFTER=$(det_field detect)
MASK_AFTER=$(live_mask)
BLK_AFTER=$(probe_block)

snap_dmesg
tty_note "collected; writing $OUT"

# The acceptance question, reduced to two facts.
TRANSITIONED=0
RETURNED=0
[ "$PRESENT_OFF" != "$PRESENT_IN" ] && TRANSITIONED=1
[ "$PRESENT_IN" != "$PRESENT_OUT" ] && RETURNED=1
# A transition that settled back inside the window still counts as movement.
case "$SEQ_IN" in *" "*) TRANSITIONED=1 ;; esac
case "$SEQ_OUT" in *" "*) RETURNED=1 ;; esac

# --- REPORT ------------------------------------------------------------------

{
	hdr "what this run wrote"
	say "Three writes, one register, sourced from downstream's"
	say "wcd9xxx_insert_detect_setup(). No micbias, no MBHC_EN_CTL, no MBHC"
	say "clock, no interrupt source unmasked."
	say ""
	say "enable log:"
	printf '%s\n' "$WRITE_LOG" | sed 's/^/  /'
	say ""
	say "restore log:"
	printf '%s\n' "$RESTORE_LOG" | sed 's/^/  /'

	hdr "0x14b MBHC_INSERT_DET_STATUS, bit 2 = jack present"
	say "                     status  present_bit"
	say "detection off      : ${STATUS_OFF:-??}      ${PRESENT_OFF:-?}"
	say "detection on, out  : ${STATUS_ON:-??}      ${PRESENT_ON:-?}"
	say "headset inserted   : ${STATUS_IN:-??}      ${PRESENT_IN:-?}"
	say "headset removed    : ${STATUS_OUT:-??}      ${PRESENT_OUT:-?}"
	say ""
	say "present_bit values seen during insertion : ${SEQ_IN:-none}"
	say "present_bit values seen during removal   : ${SEQ_OUT:-none}"
	# The variant has to come from the header captured while enabled. Reading
	# it here would read it after the restore, which reports "off" next to a
	# value of 6f -- a self-contradictory line in the evidence file.
	note "0x14a while enabled" \
		"$DET_REG (variant $(printf '%s' "$DET_ON" | tr ' ' '\n' | sed -n 's/^variant=//p'))"
	note "0x14a after restore" "$DET_REG_AFTER"

	hdr "MBHC block 0x3c0-0x3ff: what moved that we did NOT write"
	say "Nothing in this range was written. Anything here is a side effect."
	say ""
	say "baseline -> detection enabled:"
	diff_block "$BLK_BEFORE" "$BLK_ON"
	say "detection enabled -> inserted:"
	diff_block "$BLK_ON" "$BLK_IN"
	say "inserted -> removed:"
	diff_block "$BLK_IN" "$BLK_OUT"
	say "baseline -> after restore (net):"
	diff_block "$BLK_BEFORE" "$BLK_AFTER"

	hdr "run validity"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "enable log has 3 writes" \
		"$([ "$(printf '%s\n' "$WRITE_LOG" | grep -c '^write=')" -eq 3 ] && echo 1 || echo 0)" \
		"expected exactly 3 writes, got $(printf '%s\n' "$WRITE_LOG" | grep -c '^write=')" \
		"3 writes"
	check_cond "only 0x14a was written" \
		"$([ "$(printf '%s\n' "$WRITE_LOG" "$RESTORE_LOG" | sed -n 's/.*reg=\(0x[0-9a-f]*\).*/\1/p' | sort -u | grep -vc '^0x14a$')" -eq 0 ] && echo 1 || echo 0)" \
		"a register other than 0x14a appears in the write log" \
		"0x14a only"
	check "no failed writes" \
		"$(printf '%s\n' "$WRITE_LOG" "$RESTORE_LOG" | grep -c 'ret=-')" "0"
	check "detect register took the value" "$DET_REG" "6f"
	check "0x14a restored to reset" "$DET_REG_AFTER" "00"

	# The whole point of this step is that interrupts are NOT involved.
	check "MBHC sources masked before" "$MASK_BEFORE" "$MASK_ALL"
	check "MBHC sources masked while detecting" "$MASK_ON" "$MASK_ALL"
	check "MBHC sources masked after" "$MASK_AFTER" "$MASK_ALL"
	check "nothing armed" "$(kv "$PGD/mbhc_test" armed)" "0"

	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	hdr "acceptance: physical event -> status transition"
	check_cond "transitioned on insertion" "$TRANSITIONED" \
		"present_bit stayed ${PRESENT_OFF:-?} through the insertion window" \
		"${PRESENT_OFF:-?} -> ${PRESENT_IN:-?}"
	check_cond "returned on removal" "$RETURNED" \
		"present_bit stayed ${PRESENT_IN:-?} through the removal window" \
		"${PRESENT_IN:-?} -> ${PRESENT_OUT:-?}"

	hdr "finding"
	if [ "$TRANSITIONED" = "1" ] && [ "$RETURNED" = "1" ]; then
		say "MINIMAL CONFIGURATION IS SUFFICIENT."
		say ""
		say "Three writes to one register make a physical headset event"
		say "visible in 0x14b bit 2, and it returns on removal. No micbias,"
		say "no MBHC_EN_CTL, no MBHC clock were needed."
		say ""
		say "Next: arm MBHC_INSERTION and run the single-source acceptance"
		say "proof. The stimulus question is now answered."
	else
		say "NOT SUFFICIENT. Report exactly this, and add nothing blindly."
		say ""
		say "Programmed : 0x14a = $DET_REG (three writes, logged above)"
		say "Static     : 0x14b stayed ${STATUS_OFF:-??} throughout"
		say "             transitioned=$TRANSITIONED returned=$RETURNED"
		say ""
		say "The MBHC block diffs above say whether anything moved at all."
		say "Before adding registers, the cheap next test is the other"
		say "sourced candidate: VARIANT=on-alt, which writes 0x68 instead"
		say "of 0x6c -- one bit, and the branch downstream takes when"
		say "gpio_level_insert is set. If that also does nothing, the next"
		say "question is whether detection needs micbias powered, and that"
		say "should be established before writing it."
	fi

	collect_evidence

	hdr "verdict"
	say "mode   : $MODE"
	say "checks : $PASS_N passed, $FAIL_N failed"
	if [ "$FAIL_N" -ne 0 ]; then
		say "VERDICT: FAIL ($MODE)"
	else
		say "VERDICT: PASS ($MODE) -- minimal insert detection works"
	fi
} > "$OUT" 2>&1

if [ "$FAIL_N" -ne 0 ]; then
	RC=1
else
	RC=0
fi
# A run whose own preconditions broke is invalid, not a hardware failure.
case "$RUNNING_VERSION" in
	"$EXPECT_VERSION") ;;
	*) RC=2 ;;
esac

rm -f "$DMESG_FILE"

sed -n '/=== what this run wrote/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

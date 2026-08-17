#!/bin/sh
#
# WCD9320 MBHC read-only probe: does ANY MBHC state track the jack before the
# block is configured?
#
# This writes nothing. Not one register. It exists to scope the MBHC
# configuration work before a single write is made to an analog block this
# port has never touched.
#
# r138 established that no MBHC interrupt source asserts unconfigured -- all
# seven armed and verified unmasked at 81 ff 3f 6f, a physical insertion and a
# removal, every counter still zero. So configuration is needed. How much
# depends on something not yet measured:
#
#   - if MBHC_INSERT_DET_STATUS or the MBHC block tracks the jack, the
#     comparator already works and only the detection-to-interrupt path is
#     missing -- a small, targeted enable
#   - if nothing moves, detection itself is off and micbias plus the
#     comparator have to be brought up first
#
# Neither 0x14b nor 0x3c0-0x3ff has ever been read on this hardware: the CDC
# sentinel stops at 0x3bf, immediately below the MBHC block.
#
# Interactive: it asks for an insertion, then a removal.
#
# Exit: 0 something tracks the jack -- a signal exists
#       1 valid run, nothing moved -- detection is off, not just ungated
#       2 invalid run, nothing collected

set -u

MODE="mbhc-probe"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-probe-$$"
SETTLE="${SETTLE:-20}"
MBHC_BASE=960			# 0x3c0, as a decimal for awk

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-mbhc-probe-$STAMP.txt"

# --- reading -----------------------------------------------------------------

probe_hdr() {
	head -n1 "$PGD/mbhc_probe" 2>/dev/null
}
probe_field() {		# probe_field <key>
	probe_hdr | tr ' ' '\n' | sed -n "s/^$1=//p"
}
probe_meta() {		# probe_meta <key>  -- from the second line
	sed -n '2p' "$PGD/mbhc_probe" 2>/dev/null |
		tr ' ' '\n' | sed -n "s/^$1=//p"
}
# The 64-register block as one hex string, so it can be diffed positionally.
probe_block() {
	sed -n '3,$p' "$PGD/mbhc_probe" 2>/dev/null | tr -d '\n '
}

# diff_block <hexA> <hexB> -- print every byte that differs, by address
diff_block() {
	awk -v a="$1" -v b="$2" -v base="$MBHC_BASE" 'BEGIN {
		if (length(a) == 0 || length(a) != length(b)) {
			print "  (cannot compare: lengths " length(a) " vs " length(b) ")"
			exit
		}
		n = 0
		for (i = 0; i < length(a) / 2; i++) {
			x = substr(a, i * 2 + 1, 2)
			y = substr(b, i * 2 + 1, 2)
			if (x != y) {
				printf "  0x%03x: %s -> %s\n", base + i, x, y
				n++
			}
		}
		if (n == 0) print "  (no byte changed)"
	}'
}
count_diff() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		if (length(a) == 0 || length(a) != length(b)) { print -1; exit }
		n = 0
		for (i = 0; i < length(a) / 2; i++)
			if (substr(a, i * 2 + 1, 2) != substr(b, i * 2 + 1, 2)) n++
		print n
	}'
}

tty_note() { printf '%s\n' "$*" >&2; }

# Poll insert_det across a window and collect the distinct values seen, so a
# transient that settles back is still recorded rather than missed between two
# endpoint reads.
watch_insert() {	# watch_insert <seconds> -- echoes the distinct sequence
	_seen=""
	_i=0
	while [ "$_i" -lt "$1" ]; do
		_v=$(probe_field insert_det)
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

if [ ! -r "$PGD/mbhc_probe" ]; then
	say "INVALID RUN: $PGD/mbhc_probe is missing."
	say "  This build predates the read-only MBHC probe."
	exit 2
fi

HDR_BASE=$(probe_hdr)
case "$HDR_BASE" in
	*failed*)
		say "INVALID RUN: mbhc_probe reports a read failure: $HDR_BASE"
		exit 2
		;;
esac

INS_BASE=$(probe_field insert_det)
HPHL_BASE=$(probe_field hph_l)
HPHR_BASE=$(probe_field hph_r)
RCOSC=$(probe_field rc_osc)
NZ_BASE=$(probe_meta nonzero)
BLK_BASE=$(probe_block)
RANGE=$(probe_meta range)

tty_note "baseline: $HDR_BASE"
tty_note "MBHC block: $(probe_meta count) registers, $NZ_BASE non-zero"

printf '\n>>> INSERT A HEADSET NOW (%ss) <<<\n\n' "$SETTLE" >&2
INS_SEQ_IN=$(watch_insert "$SETTLE")
HDR_IN=$(probe_hdr)
INS_IN=$(probe_field insert_det)
HPHL_IN=$(probe_field hph_l)
HPHR_IN=$(probe_field hph_r)
NZ_IN=$(probe_meta nonzero)
BLK_IN=$(probe_block)
tty_note "inserted: $HDR_IN"
tty_note "insert_det values seen: $INS_SEQ_IN"

printf '\n>>> NOW REMOVE THE HEADSET (%ss) <<<\n\n' "$SETTLE" >&2
INS_SEQ_OUT=$(watch_insert "$SETTLE")
HDR_OUT=$(probe_hdr)
INS_OUT=$(probe_field insert_det)
HPHL_OUT=$(probe_field hph_l)
HPHR_OUT=$(probe_field hph_r)
NZ_OUT=$(probe_meta nonzero)
BLK_OUT=$(probe_block)
tty_note "removed: $HDR_OUT"
tty_note "insert_det values seen: $INS_SEQ_OUT"

snap_dmesg

D_IN=$(count_diff "$BLK_BASE" "$BLK_IN")
D_OUT=$(count_diff "$BLK_IN" "$BLK_OUT")
D_NET=$(count_diff "$BLK_BASE" "$BLK_OUT")

# Did anything at all respond to the jack?
MOVED=0
[ "$INS_BASE" != "$INS_IN" ] && MOVED=1
[ "$INS_IN" != "$INS_OUT" ] && MOVED=1
[ "$HPHL_BASE" != "$HPHL_IN" ] && MOVED=1
[ "$HPHR_BASE" != "$HPHR_IN" ] && MOVED=1
[ "${D_IN:-0}" -gt 0 ] && MOVED=1
[ "${D_OUT:-0}" -gt 0 ] && MOVED=1
# More than one distinct value across a window is a transient worth catching.
case "$INS_SEQ_IN" in *" "*) MOVED=1 ;; esac
case "$INS_SEQ_OUT" in *" "*) MOVED=1 ;; esac

tty_note "collected; writing $OUT"

# --- REPORT ------------------------------------------------------------------

{
	hdr "what this run did"
	say "It read registers. It wrote none. The MBHC block was not"
	say "configured, enabled, biased or otherwise touched."

	hdr "single registers, across the three states"
	say "                    baseline  inserted  removed"
	say "MBHC_INSERT_DET_STATUS 0x14b   ${INS_BASE:-??}        ${INS_IN:-??}        ${INS_OUT:-??}"
	say "RX_HPH_L_STATUS        0x1b3   ${HPHL_BASE:-??}        ${HPHL_IN:-??}        ${HPHL_OUT:-??}"
	say "RX_HPH_R_STATUS        0x1b9   ${HPHR_BASE:-??}        ${HPHR_IN:-??}        ${HPHR_OUT:-??}"
	say ""
	say "insert_det values seen during insertion : ${INS_SEQ_IN:-none}"
	say "insert_det values seen during removal   : ${INS_SEQ_OUT:-none}"
	note "RC_OSC_STATUS 0x1fc" "$RCOSC -- anchor; detection runs off this oscillator"

	hdr "MBHC block $RANGE"
	say "non-zero registers : baseline $NZ_BASE, inserted $NZ_IN, removed $NZ_OUT"
	say "bytes changed      : baseline->inserted $D_IN, inserted->removed $D_OUT,"
	say "                     baseline->removed (net) $D_NET"

	hdr "block diff: baseline -> inserted"
	diff_block "$BLK_BASE" "$BLK_IN"

	hdr "block diff: inserted -> removed"
	diff_block "$BLK_IN" "$BLK_OUT"

	hdr "MBHC block, baseline (0x3c0 first, 32 per line)"
	printf '%s\n' "$BLK_BASE" | fold -w 64

	hdr "MBHC block, inserted"
	printf '%s\n' "$BLK_IN" | fold -w 64

	hdr "MBHC block, removed"
	printf '%s\n' "$BLK_OUT" | fold -w 64

	# --- validity -----------------------------------------------------------
	# These say whether the run could have detected a change at all. A
	# negative from a run that could not read the block would be worthless.
	hdr "run validity"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "MBHC block readable" \
		"$([ -n "$BLK_BASE" ] && [ "${#BLK_BASE}" -eq 128 ] && echo 1 || echo 0)" \
		"block read short or empty (${#BLK_BASE} hex chars, want 128)" \
		"64 registers"
	check_cond "all three snapshots same length" \
		"$([ "${#BLK_BASE}" -eq "${#BLK_IN}" ] && [ "${#BLK_IN}" -eq "${#BLK_OUT}" ] && echo 1 || echo 0)" \
		"snapshots differ in length -- a read was truncated" "comparable"
	check_cond "RC oscillator alive" \
		"$([ -n "$RCOSC" ] && [ "$RCOSC" != "00" ] && echo 1 || echo 0)" \
		"RC_OSC_STATUS reads $RCOSC -- detection cannot work without it" \
		"0x$RCOSC"
	check_cond "insert_det readable" \
		"$([ -n "$INS_BASE" ] && echo 1 || echo 0)" \
		"could not read 0x14b" "0x$INS_BASE"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "mbhc probe read failures" "$(count_lines 'mbhc probe read failed')" "0"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	# Nothing may have been written. The interrupt masks are the cheapest
	# witness to that: this run never armed anything, so they must be
	# untouched at the all-masked value.
	check "nothing armed during this run" "$(kv "$PGD/mbhc_test" armed)" "0"

	hdr "finding"
	if [ "$MOVED" = "1" ]; then
		say "SOMETHING TRACKS THE JACK."
		say ""
		say "MBHC state changed with the headset, with no configuration"
		say "written. The comparator is doing work already, so what is"
		say "missing is the path from detection to an interrupt rather than"
		say "detection itself."
		say ""
		say "Next: identify which enable gates that path -- the changed"
		say "addresses above are the place to start -- and write the"
		say "smallest configuration that makes one MBHC source assert."
	else
		say "NOTHING MOVED."
		say ""
		say "Neither 0x14b, nor the headphone status registers, nor any of"
		say "the 64 MBHC registers changed across an insertion and a"
		say "removal. Detection is off, not merely ungated."
		say ""
		say "Next: micbias and the comparator have to be brought up before"
		say "any physical event can be detected at all. That is a larger"
		say "write than the alternative, and this run is the evidence for"
		say "why it is necessary rather than assumed."
	fi

	collect_evidence

	hdr "verdict"
	say "mode   : $MODE"
	say "checks : $PASS_N passed, $FAIL_N failed"
	if [ "$FAIL_N" -ne 0 ]; then
		say "VERDICT: INVALID ($MODE) -- the run itself did not hold up"
	elif [ "$MOVED" = "1" ]; then
		say "VERDICT: SIGNAL FOUND ($MODE)"
	else
		say "VERDICT: NO SIGNAL ($MODE) -- valid run, detection is off"
	fi
} > "$OUT" 2>&1

if [ "$FAIL_N" -ne 0 ]; then
	RC=2
elif [ "$MOVED" = "1" ]; then
	RC=0
else
	RC=1
fi

rm -f "$DMESG_FILE"

sed -n '/=== what this run did/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

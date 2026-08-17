#!/bin/sh
#
# WCD9320 register volatility, PROVOKED: which registers move when the hardware
# is made to do something?
#
# An earlier idle run found 0 of 1024 registers changed over 50 s. That is a
# null result, not a safety argument: with the codec idle, even the registers
# downstream marks volatile held still, because nothing happened to move them.
# A positive test that provokes nothing proves nothing.
#
# So this run provokes. Six full snapshots:
#
#   d0  idle
#   d1  idle again, 10 s later      -- spontaneous movement, if any
#   d2  after insert detection on   -- 3 known writes to 0x14a
#   d3  after a physical INSERTION
#   d4  after a physical REMOVAL
#   d5  after insert detection off  -- 1 known write to 0x14a
#
# WHAT IS WRITTEN
#
# Exactly four registers writes, all to 0x14a, all logged by the driver and
# all asserted here. 0x14a is therefore EXCLUDED from volatility
# classification -- we moved it, so its movement says nothing about the
# hardware. Every other register that moves, moved by itself.
#
# NO INTERRUPT SOURCE IS ARMED. All 29 stay masked for the whole run, which is
# deliberate: it asks whether INTR_STATUS (0x098-0x09b) latches a physical
# event independently of arming and dispatch. Our regmap-irq reads exactly
# those registers, so whether they can move with no write is the single most
# important fact for cache safety.
#
# WHAT THIS CAN AND CANNOT SHOW
#
# Movement proves volatility. Stillness proves nothing -- a register that did
# not move here is NOT thereby shown to be constant, and must not be treated
# as cacheable on this evidence. Classification against taiko_volatile() is
# done offline; this script measures and does not interpret.
#
# Interactive: it asks for an insertion, then a removal.
#
# Exit: 0 measurement completed, 1 the run did not hold up, 2 invalid.

set -u

MODE="volatility"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-vol-$$"
SETTLE="${SETTLE:-90}"
IDLE_GAP="${IDLE_GAP:-10}"
WORK="/tmp/.wcd9320-vol-$$"
MASK_ALL="ff ff 3f 7f"
WRITTEN_REG="14a"

require_module_version
find_devices
snap_dmesg
open_output "$OUTDIR/wcd9320-volatility-$STAMP.txt"

REGS="/sys/kernel/debug/regmap/$PGD_NAME/registers"
tty_note() { printf '%s\n' "$*" >&2; }
live_mask() {
	sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
		"$PGD/irq_live" 2>/dev/null | head -n1
}
# Count of driver-logged register writes so far this boot.
write_lines() { dmesg 2>/dev/null | grep -c 'insert-detect write'; }

if [ ! -r "$REGS" ]; then
	say "INVALID RUN: $REGS is not readable."
	exit 2
fi

ARMED0=$(kv "$PGD/mbhc_test" armed)
DET0=$(head -n1 "$PGD/mbhc_detect" 2>/dev/null | tr ' ' '\n' | sed -n 's/^on=//p')
if [ "${ARMED0:-0}" != "0" ] || [ "${DET0:-0}" != "0" ]; then
	say "INVALID RUN: codec not idle (armed=$ARMED0 detect_on=$DET0)."
	exit 2
fi

mkdir -p "$WORK" || { say "INVALID RUN: cannot create $WORK"; exit 2; }
WRITES_BEFORE=$(write_lines)

snap() { cp "$REGS" "$WORK/$1" 2>/dev/null || { say "dump $1 failed"; exit 2; }; }

# --- d0, d1: idle ------------------------------------------------------------
tty_note "d0 idle"
snap d0
MASK_D0=$(live_mask)
sleep "$IDLE_GAP"
tty_note "d1 idle again (+${IDLE_GAP}s)"
snap d1

# --- d2: detection on --------------------------------------------------------
tty_note "d2 enabling insert detection (3 writes to 0x14a)"
if ! echo on > "$PGD/mbhc_detect" 2>/dev/null; then
	say "could not enable insert detection"
	emit_invalid_setup "writing 'on' to mbhc_detect failed"
	rm -rf "$WORK"
	exit 2
fi
sleep 2
snap d2
MASK_D2=$(live_mask)

# --- d3, d4: physical events -------------------------------------------------
#
# Wait for the event rather than sleeping through a window. Three earlier runs
# were spoiled by the operator having to hit a stopwatch on a detached run --
# the snapshot landed before the headset went in, and the resulting "(no
# change)" looked like a hardware result when it was an absent stimulus.
#
# 0x14b bit 2 is the witness: 1 = no jack, 0 = jack present (rc5, and
# downstream's wcd9xxx_swch_level_remove). Poll it, proceed on change, and
# record whether the wait ended in a real transition or a timeout so a
# mistimed run cannot be mistaken for a measurement.
present_bit() {
	_v=$(sed -n 's/^14b: //p' "$REGS" 2>/dev/null)
	case "$_v" in
		'') echo "?" ;;
		*)  echo $(( 0x$_v / 4 % 2 )) ;;
	esac
}

wait_for_present() {	# wait_for_present <target 0|1> <label>
	_want="$1"
	_i=0
	while [ "$_i" -lt "$SETTLE" ]; do
		[ "$(present_bit)" = "$_want" ] && { echo seen; return 0; }
		sleep 1
		_i=$((_i + 1))
	done
	echo timeout
	return 1
}

printf '\n>>> INSERT A HEADSET NOW (waiting up to %ss) <<<\n\n' "$SETTLE" >&2
INS_RESULT=$(wait_for_present 0 insert)
tty_note "d3 after insertion: $INS_RESULT (present_bit=$(present_bit))"
sleep 1
snap d3
MASK_D3=$(live_mask)

printf '\n>>> NOW REMOVE THE HEADSET (waiting up to %ss) <<<\n\n' "$SETTLE" >&2
REM_RESULT=$(wait_for_present 1 remove)
tty_note "d4 after removal: $REM_RESULT (present_bit=$(present_bit))"
sleep 1
snap d4
MASK_D4=$(live_mask)

# --- d5: detection off -------------------------------------------------------
tty_note "d5 restoring 0x14a"
echo off > "$PGD/mbhc_detect" 2>/dev/null
sleep 2
snap d5
MASK_D5=$(live_mask)

WRITES_AFTER=$(write_lines)
WRITES_MADE=$((WRITES_AFTER - WRITES_BEFORE))
WRITE_REGS=$(dmesg 2>/dev/null | grep 'insert-detect write' | tail -n "$WRITES_MADE" |
	sed -n 's/.*reg 0x\([0-9a-f]*\).*/\1/p' | sort -u | tr '\n' ' ')

snap_dmesg

# changed <a> <b> -- registers differing between two dumps, as "addr old new"
changed() {
	awk '
		FNR == 1 { n++ }
		{ addr = $1; sub(/:$/, "", addr); v[addr, n] = $2; if (n == 1) o[++c] = addr }
		END {
			for (i = 1; i <= c; i++) {
				a = o[i]
				if (v[a, 1] != v[a, 2]) print a, v[a, 1], v[a, 2]
			}
		}
	' "$WORK/$1" "$WORK/$2"
}
count_of() { printf '%s\n' "$1" | grep -c '[0-9a-f]' 2>/dev/null || echo 0; }
# everything except the register we wrote ourselves
minus_written() { printf '%s\n' "$1" | grep -v "^$WRITTEN_REG " ; }

C01=$(changed d0 d1)
C12=$(changed d1 d2)
C23=$(changed d2 d3)
C34=$(changed d3 d4)
C45=$(changed d4 d5)

ALL_MOVED=$(printf '%s\n%s\n%s\n%s\n%s\n' "$C01" "$C12" "$C23" "$C34" "$C45" |
	awk 'NF {print $1}' | sort -u | grep '[0-9a-f]')
SPONTANEOUS=$(printf '%s\n' "$ALL_MOVED" | grep -v "^$WRITTEN_REG$")
N_SPONT=$(count_of "$SPONTANEOUS")

tty_note "collected; $N_SPONT register(s) moved without being written"

{
	hdr "method"
	say "snapshots         : d0 idle, d1 idle+${IDLE_GAP}s, d2 detection on,"
	say "                    d3 inserted, d4 removed, d5 detection off"
	say "event waits       : up to ${SETTLE}s each, polled -- not fixed sleeps"
	say "insertion         : $INS_RESULT"
	say "removal           : $REM_RESULT"
	say "source            : $REGS"
	say "registers/dump    : $(wc -l < "$WORK/d0")"
	say ""
	say "Writes made by this run : $WRITES_MADE, to register(s): ${WRITE_REGS:-none}"
	say "0x$WRITTEN_REG is EXCLUDED from volatility classification -- we moved it."
	say "Everything else that moved, moved by itself."
	say ""
	say "No interrupt source was armed at any point. All 29 stayed masked, so"
	say "any movement in INTR_STATUS is latching independent of arming."
	say ""
	say "Movement proves volatility. Stillness proves NOTHING: a register that"
	say "did not move here is not thereby constant, and must not be treated as"
	say "cacheable on this evidence."

	hdr "d0 -> d1   idle, nothing touched"
	if [ -n "$C01" ]; then printf '%s\n' "$C01" | sed 's/^/  /'
	else say "  (no change)"; fi

	hdr "d1 -> d2   insert detection enabled"
	if [ -n "$C12" ]; then printf '%s\n' "$C12" | sed 's/^/  /'
	else say "  (no change)"; fi

	hdr "d2 -> d3   PHYSICAL INSERTION"
	if [ -n "$C23" ]; then printf '%s\n' "$C23" | sed 's/^/  /'
	else say "  (no change)"; fi

	hdr "d3 -> d4   PHYSICAL REMOVAL"
	if [ -n "$C34" ]; then printf '%s\n' "$C34" | sed 's/^/  /'
	else say "  (no change)"; fi

	hdr "d4 -> d5   insert detection disabled"
	if [ -n "$C45" ]; then printf '%s\n' "$C45" | sed 's/^/  /'
	else say "  (no change)"; fi

	hdr "registers of special interest, across all six snapshots"
	for r in 098 099 09a 09b 14a 14b 1b3 1b9; do
		_l="  0x$r :"
		for d in d0 d1 d2 d3 d4 d5; do
			_v=$(sed -n "s/^$r: //p" "$WORK/$d")
			_l="$_l ${_v:-??}"
		done
		case "$r" in
			098|099|09a|09b) _l="$_l   INTR_STATUS" ;;
			14a) _l="$_l   MBHC_INSERT_DETECT (written by us)" ;;
			14b) _l="$_l   MBHC_INSERT_DET_STATUS" ;;
			1b3) _l="$_l   RX_HPH_L_STATUS" ;;
			1b9) _l="$_l   RX_HPH_R_STATUS" ;;
		esac
		say "$_l"
	done

	hdr "positively volatile: moved without being written"
	say "count             : $N_SPONT"
	if [ "$N_SPONT" -gt 0 ]; then
		printf '%s\n' "$SPONTANEOUS" | sed 's/^/  0x/'
	else
		say "  none"
	fi

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	# Without a stimulus the event transitions are meaningless, and a
	# run that timed out must not be read as "nothing changed".
	check "insertion observed" "$INS_RESULT" "seen"
	check "removal observed" "$REM_RESULT" "seen"
	check "writes made by this run" "$WRITES_MADE" "4"
	check "only 0x14a was written" "$(printf '%s' "$WRITE_REGS" | tr -d ' ')" "14a"
	check "nothing armed at start" "${ARMED0:-x}" "0"
	check "nothing armed at end" "$(kv "$PGD/mbhc_test" armed)" "0"
	check "sources masked, d0" "$MASK_D0" "$MASK_ALL"
	check "sources masked, d2" "$MASK_D2" "$MASK_ALL"
	check "sources masked, d3" "$MASK_D3" "$MASK_ALL"
	check "sources masked, d4" "$MASK_D4" "$MASK_ALL"
	check "sources masked, d5" "$MASK_D5" "$MASK_ALL"
	check "0x14a restored" "$(sed -n 's/^14a: //p' "$WORK/d5")" "00"
	check "all dumps same length" \
		"$(for f in "$WORK"/d?; do wc -l < "$f"; done | sort -u | wc -l)" "1"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"
	check "adsp state" "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" "running"

	# Raw data last, so the analysis can be recomputed from the artefact.
	for d in d0 d1 d2 d3 d4 d5; do
		hdr "raw dump: $d"
		cat "$WORK/$d"
	done

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -rf "$WORK"
rm -f "$DMESG_FILE"

sed -n '/=== method/,/=== raw dump: d0/p' "$OUT" | sed '$d'
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

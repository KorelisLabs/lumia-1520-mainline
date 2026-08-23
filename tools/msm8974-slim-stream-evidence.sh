#!/bin/sh
#
# Branch B1: does the codec's side of a SLIMbus RX stream come up?
#
# THE CLAIM UNDER TEST
#
#   Slave port 16 / channel 144 can be connected and activated on the ADSP's
#   bus: slim_stream_prepare() and slim_stream_enable() reach the manager and
#   succeed, the codec's port registers reproduce their frozen delta, and the
#   whole thing tears down cleanly.
#
# NOT claimed: no PCM is opened, no ASM RUN is issued, no sample moves, and
# nothing is audible. This driver has no RX interpolator, no output path and
# no DAPM graph -- samples that arrive at the slave port would stop there.
# This is transport, and only the codec's half of it.
#
# WHY A TIMESTAMP WINDOW AND NOT JUST CALL COUNTS
#
# The design map claims something specific and load-bearing: on this NGD,
# slim_stream_disable() is a NO-OP, because the controller drops every message
# code from 0x40 to 0x5F. That was read out of the source, and reading is not
# evidence. Counting calls cannot show it either -- disable() *is* called and
# *does* enter the controller.
#
# So the run is sliced by ftrace timestamp into prepare / enable / disable /
# unprepare windows, and slim_alloc_txn_tid() is counted in each. A TID is
# allocated only for a message that actually goes to the manager; messages
# dropped by the early return never reach it. That distinguishes the two
# explanations that matter:
#
#   "we never called disable"        -> qcom_slim_ngd_xfer_msg count is 0 too
#   "we called it and it was dropped" -> xfer_msg >= 1 while TIDs == 0
#
# Only the second is consistent with the map. The gate asserts it, so a future
# kernel that starts really deactivating channels here will fail this gate
# rather than silently invalidating the documentation.
#
# Exit: 0 proven, 1 checks failed, 2 invalid setup.

set -u

MODE="slim-stream"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-b1-$$"
TRACE="${TRACE:-/sys/kernel/tracing}"
EV="/tmp/.b1-events-$$"
WANT_PORT="${WANT_PORT:-16}"
WANT_CH="${WANT_CH:-144}"

require_module_version
find_devices

# ------------------------------------------------------------ preconditions --
HOOK="$PGD/slim_stream_test"
STATE="$PGD/slim_stream_state"
[ -e "$HOOK" ] || {
	say "INVALID RUN: $HOOK does not exist."
	say "  The running module has no B1 hook, so this gate has nothing to"
	say "  drive. Install the slim-stream-rc1 module and cold boot."
	exit 2
}
[ -e "$STATE" ] || { say "INVALID RUN: $STATE does not exist."; exit 2; }
[ -w "$TRACE/kprobe_events" ] || {
	say "INVALID RUN: $TRACE/kprobe_events is not writable (need root)."
	exit 2
}

# A stream left up by an earlier run would make prepare() return -EINVAL and
# the whole ladder would read as a driver failure.
if [ "$(kv "$STATE" up)" = "1" ]; then
	say "INVALID RUN: a stream is already up on this boot."
	say "  echo stream-off > $HOOK, or cold boot, then run this again."
	exit 2
fi

# A boot that has already run a cycle cannot produce clean evidence: dmesg is
# cumulative, so the frozen-delta counts would include the earlier cycle and
# the file would not describe one bring-up. This is a contaminated SETUP, not
# a driver fault, so it exits 2 rather than failing the driver.
#
# It is worth knowing separately that a second cycle DOES work -- teardown
# leaves the codec able to come back up. That is a repeatability result and
# belongs in its own run, not smuggled into the milestone evidence.
PRIOR_UPS=$(printf "%s" "$(cat "$STATE" 2>/dev/null)" | tr " " "
" |
	sed -n "s/^ups=//p" | head -n1)
[ -n "${PRIOR_UPS:-}" ] || PRIOR_UPS=0
if [ "$PRIOR_UPS" != "0" ]; then
	say "INVALID RUN: this boot has already run $PRIOR_UPS stream cycle(s)."
	say "  dmesg is cumulative, so the frozen-delta counts would include"
	say "  them and the evidence would not describe a single bring-up."
	say "  Cold boot, then run this once."
	exit 2
fi

snap_dmesg
open_output "$OUTDIR/msm8974-slim-stream-$STAMP.txt"

# ------------------------------------------------------------- observation --
#
# slim_alloc_txn_tid is the discriminator: it is reached only by messages that
# actually leave for the manager. qcom_slim_ngd_xfer_msg is reached by every
# message, including the ones dropped by the early return.
#
PROBES="b1_prepare:slim_stream_prepare
b1_enable:slim_stream_enable
b1_disable:slim_stream_disable
b1_unprepare:slim_stream_unprepare
b1_free:slim_stream_free
b1_ngd_en:qcom_slim_ngd_enable_stream
b1_tid:slim_alloc_txn_tid
b1_xfer:qcom_slim_ngd_xfer_msg"

# A RETURN probe, for two reasons: its entry/exit pair brackets the enable
# phase tightly -- the plain windows below are otherwise bounded by the next
# userspace step and sweep up a second of unrelated bus traffic -- and
# $retval is the ADSP's own answer to DEF_ACT_CHAN.
RETPROBES="b1_ngd_ret:qcom_slim_ngd_enable_stream"

# kprobe_events returns EBUSY while any of its events is still enabled, and
# ":" is a POSIX special builtin whose failed redirect would exit the shell.
clear_probes() {
	echo 0 2>/dev/null > "$TRACE/tracing_on"
	for _p in $PROBES $RETPROBES; do
		_e="$TRACE/events/kprobes/${_p%%:*}/enable"
		[ -e "$_e" ] && echo 0 2>/dev/null > "$_e"
	done
	printf "" 2>/dev/null > "$TRACE/kprobe_events"
	true
}

clear_probes
printf "" 2>/dev/null > "$TRACE/trace"

PROBE_OK=""
PROBE_BAD=""
for _p in $PROBES; do
	_n=${_p%%:*}
	_s=${_p#*:}
	if printf 'p:%s %s\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null; then
		PROBE_OK="$PROBE_OK $_n"
		echo 1 2>/dev/null > "$TRACE/events/kprobes/$_n/enable"
	else
		PROBE_BAD="$PROBE_BAD $_n"
	fi
done
for _p in $RETPROBES; do
	_n=${_p%%:*}
	_s=${_p#*:}
	if printf 'r:%s %s ret=$retval:s32\n' "$_n" "$_s" >> "$TRACE/kprobe_events" 2>/dev/null; then
		PROBE_OK="$PROBE_OK $_n"
		echo 1 2>/dev/null > "$TRACE/events/kprobes/$_n/enable"
	else
		PROBE_BAD="$PROBE_BAD $_n"
	fi
done
echo 1 2>/dev/null > "$TRACE/tracing_on"

# -------------------------------------------------------------- the sequence --
ON_RC=""
OFF_RC=""
STATE_UP=""
STATE_DOWN=""

echo stream-on > "$HOOK" 2>/dev/null
ON_RC=$?
sleep 1
STATE_UP=$(cat "$STATE" 2>/dev/null)

echo stream-off > "$HOOK" 2>/dev/null
OFF_RC=$?
sleep 1
STATE_DOWN=$(cat "$STATE" 2>/dev/null)

echo 0 2>/dev/null > "$TRACE/tracing_on"

# dmesg is re-read HERE, not before the run. The earlier snapshot was taken
# during setup and cannot contain anything this run logged -- reading it made
# seven checks fail against hardware that had in fact worked.
snap_dmesg

# --------------------------------------------------------------- the windows --
#
# Reduce the trace to "<timestamp> <probe>" pairs, then slice.
#
awk '{
	for (i = 1; i <= NF; i++)
		if ($i ~ /^[0-9]+\.[0-9]+:$/) {
			ts = substr($i, 1, length($i) - 1)
			nm = $(i + 1)
			sub(/:$/, "", nm)
			print ts, nm
			break
		}
}' "$TRACE/trace" > "$EV" 2>/dev/null

first_ts() { awk -v n="$1" '$2 == n { print $1; exit }' "$EV"; }
cnt_all()  { awk -v n="$1" '$2 == n { c++ } END { print c + 0 }' "$EV"; }
cnt_win()  {	# cnt_win <name> <from> <to>
	awk -v n="$1" -v a="$2" -v b="$3" \
	    '$2 == n && $1 >= a && $1 < b { c++ } END { print c + 0 }' "$EV"
}

T_PREP=$(first_ts b1_prepare)
T_EN=$(first_ts b1_enable)
T_DIS=$(first_ts b1_disable)
T_UNP=$(first_ts b1_unprepare)
T_FREE=$(first_ts b1_free)
T_NGD=$(first_ts b1_ngd_en)
T_NGDR=$(first_ts b1_ngd_ret)
# The ADSP's own answer to DEF_ACT_CHAN, straight off the return probe.
NGD_RET=$(grep -m1 "b1_ngd_ret" "$TRACE/trace" 2>/dev/null |
	sed -n "s/.*ret=\(\-\{0,1\}[0-9]\{1,\}\).*/\1/p")
[ -n "${NGD_RET:-}" ] || NGD_RET=absent
T_END=999999999

N_PREP=$(cnt_all b1_prepare);   N_EN=$(cnt_all b1_enable)
N_DIS=$(cnt_all b1_disable);    N_UNP=$(cnt_all b1_unprepare)
N_FREE=$(cnt_all b1_free);      N_NGD=$(cnt_all b1_ngd_en)
N_TID=$(cnt_all b1_tid);        N_XFER=$(cnt_all b1_xfer)

# Windows only make sense if the four boundaries were observed in order.
WINDOWS_OK=0
if [ -n "$T_PREP" ] && [ -n "$T_EN" ] && [ -n "$T_DIS" ] && [ -n "$T_UNP" ]; then
	WINDOWS_OK=1
	TID_PREP=$(cnt_win b1_tid "$T_PREP" "$T_EN")
	# Bounded by the NGD hook's own entry and exit, not by the next
	# userspace step, so this counts DEF_ACT_CHAN and nothing else.
	if [ -n "$T_NGD" ] && [ -n "$T_NGDR" ]; then
		TID_EN=$(cnt_win b1_tid "$T_NGD" "$T_NGDR")
	else
		TID_EN=$(cnt_win b1_tid "$T_EN" "$T_DIS")
	fi
	TID_DIS=$(cnt_win b1_tid "$T_DIS" "$T_UNP")
	# Bounded by free(), which follows immediately. Left open-ended this
	# window also swallowed the port-teardown register writes and a
	# second of background traffic, and reported 121.
	TID_UNP=$(cnt_win b1_tid "$T_UNP" "${T_FREE:-$T_END}")
	XFER_DIS=$(cnt_win b1_xfer "$T_DIS" "$T_UNP")
else
	TID_PREP=-1; TID_EN=-1; TID_DIS=-1; TID_UNP=-1; XFER_DIS=-1
fi

# ------------------------------------------------------------ what was logged --
d() { grep -c -- "$1" "$DMESG_FILE" 2>/dev/null || true; }
L_PREP0=$(d 'slim-stream: prepare -> 0')
L_EN0=$(d 'slim-stream: enable -> 0')
L_UP=$(d "slim-stream: UP port $WANT_PORT channel $WANT_CH")
L_UNP0=$(d 'slim-stream: unprepare -> 0')
L_DOWN=$(d "slim-stream: DOWN port $WANT_PORT")
RX_PROG=$(d "rx-port $WANT_PORT: PROGRAMMED")
RX_TORN=$(d "rx-port $WANT_PORT: TORN DOWN")
RX_CFG=$(d 'config 0x040 want 05 -> read 05')
RX_MCH=$(d 'multi-channel 0x180 want 01 -> read 01')
ERRS=$(dmesg 2>/dev/null | grep -c 'slim-stream:.*failed' || true)
WARNS=$(dmesg 2>/dev/null | grep -cE 'WARNING:|BUG:|Call trace' || true)

for v in L_PREP0 L_EN0 L_UP L_UNP0 L_DOWN RX_PROG RX_TORN RX_CFG RX_MCH ERRS WARNS; do
	eval "[ -n \"\$$v\" ] || $v=0"
done

U_UP=$(printf '%s' "$STATE_UP" | sed -n 's/^up=\([0-9]*\).*/\1/p' | head -n1)
U_PORT=$(printf '%s' "$STATE_UP" | tr ' ' '\n' | sed -n 's/^port=//p' | head -n1)
U_CH=$(printf '%s' "$STATE_UP" | tr ' ' '\n' | sed -n 's/^channel=//p' | head -n1)
U_ALLOC=$(printf '%s' "$STATE_UP" | sed -n 's/^allocated=//p' | head -n1)
D_UP=$(printf '%s' "$STATE_DOWN" | sed -n 's/^up=\([0-9]*\).*/\1/p' | head -n1)
D_ALLOC=$(printf '%s' "$STATE_DOWN" | sed -n 's/^allocated=//p' | head -n1)

{
	hdr "the hook"
	say "control function     : $PGD_NAME"
	say "interface function   : $IFD_NAME"
	say "stream-on  exit      : $ON_RC"
	say "stream-off exit      : $OFF_RC"

	hdr "slim_stream_state while up"
	printf '%s\n' "${STATE_UP:-  (unreadable)}" | sed 's/^/  /'

	hdr "slim_stream_state after teardown"
	printf '%s\n' "${STATE_DOWN:-  (unreadable)}" | sed 's/^/  /'

	hdr "observed calls"
	say "probes registered    :${PROBE_OK:- none}"
	[ -n "$PROBE_BAD" ] && say "probes FAILED        :$PROBE_BAD"
	say ""
	say "  slim_stream_prepare        : $N_PREP"
	say "  slim_stream_enable         : $N_EN"
	say "  qcom_slim_ngd_enable_stream: $N_NGD"
	say "  slim_stream_disable        : $N_DIS"
	say "  slim_stream_unprepare      : $N_UNP"
	say "  slim_stream_free           : $N_FREE"
	say "  slim_alloc_txn_tid (total) : $N_TID"
	say "  ngd xfer_msg (total)       : $N_XFER"

	hdr "messages that actually reached the manager, by phase"
	say "A TID is allocated only for a message that really goes out."
	say "Dropped message codes return before ever reaching it."
	say ""
	say "  during prepare       : $TID_PREP   (expect >= 1, CONNECT_SINK)"
	say "  during enable        : $TID_EN   (expect >= 1, DEF_ACT_CHAN)"
	say "  during disable       : $TID_DIS   (expect EXACTLY 0 -- the no-op)"
	say "  during unprepare     : $TID_UNP   (expect >= 1, DISCONNECT_PORT)"
	say ""
	say "  xfer_msg during disable: $XFER_DIS  (expect >= 1: it WAS called,"
	say "                           and the controller dropped it -- which is"
	say "                           not the same as never calling it)"
	say ""
	say "  NGD enable_stream returned : $NGD_RET"
	say "                           (the ADSP own answer to DEF_ACT_CHAN,"
	say "                            taken from the return probe)"

	hdr "the codec's frozen delta"
	say "port $WANT_PORT PROGRAMMED       : $RX_PROG"
	say "port $WANT_PORT TORN DOWN        : $RX_TORN"
	say "0x040 -> 05              : $RX_CFG"
	say "0x180 -> 01              : $RX_MCH"

	hdr "the ladder"
	L() { printf '  %-4s %-5s %s\n' "$1" "$2" "$3"; }
	yn() { [ "$1" = 1 ] && echo PASS || echo FAIL; }
	ge() { [ "${1:-0}" -ge "${2:-1}" ] 2>/dev/null && echo PASS || echo FAIL; }

	L B0 "$([ "$ON_RC" = 0 ] && echo PASS || echo FAIL)" "stream-on accepted"
	L B1 "$(ge "$N_PREP" 1)" "slim_stream_prepare called"
	L B2 "$(ge "$TID_PREP" 1)" "CONNECT_SINK reached the manager"
	L B3 "$(yn "$([ "$L_PREP0" -ge 1 ] && echo 1 || echo 0)")" "prepare returned 0"
	L B4 "$(ge "$N_NGD" 1)" "the NGD enable_stream hook ran"
	L B5 "$(ge "$TID_EN" 1)" "DEF_ACT_CHAN reached the manager"
	L B6 "$(yn "$([ "$L_EN0" -ge 1 ] && echo 1 || echo 0)")" "enable returned 0"
	L B7 "$(yn "$([ "$L_UP" -ge 1 ] && echo 1 || echo 0)")" "stream UP on port $WANT_PORT ch $WANT_CH"
	L B8 "$(ge "$RX_PROG" 1)" "codec port programmed"
	L B9 "$([ "$OFF_RC" = 0 ] && echo PASS || echo FAIL)" "stream-off accepted"
	L B10 "$([ "$TID_DIS" = 0 ] && echo PASS || echo FAIL)" "disable sent nothing (the no-op)"
	L B11 "$(ge "$XFER_DIS" 1)" "...but disable WAS called"
	L B12 "$(ge "$TID_UNP" 1)" "DISCONNECT_PORT reached the manager"
	L B13 "$(ge "$RX_TORN" 1)" "codec port torn down"

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check_cond "every kprobe registered" \
		"$([ -z "$PROBE_BAD" ] && echo 1 || echo 0)" \
		"these did not register:$PROBE_BAD" "all"
	check "stream-on accepted" "$ON_RC" "0"
	check "prepare was called" "$N_PREP" "1"
	check "enable was called" "$N_EN" "1"
	check "the NGD hook ran" "$N_NGD" "1"
	#
	# The hook running proves a request was made. Its return value is the
	# ADSP answer, and only that separates "we asked" from "it agreed".
	#
	check "the ADSP accepted DEF_ACT_CHAN" "$NGD_RET" "0"
	check_cond "CONNECT_SINK went out" \
		"$([ "$TID_PREP" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"no TID allocated during prepare -- nothing reached the manager" \
		"$TID_PREP"
	check_cond "DEF_ACT_CHAN went out" \
		"$([ "$TID_EN" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"no TID allocated during enable -- the channel was never activated" \
		"$TID_EN"
	check_cond "prepare returned 0" \
		"$([ "$L_PREP0" -ge 1 ] && echo 1 || echo 0)" \
		"no 'prepare -> 0' in the log"
	check_cond "enable returned 0" \
		"$([ "$L_EN0" -ge 1 ] && echo 1 || echo 0)" \
		"no 'enable -> 0' in the log"
	check_cond "the stream came up" \
		"$([ "$L_UP" -ge 1 ] && echo 1 || echo 0)" \
		"no UP line for port $WANT_PORT channel $WANT_CH"
	check "state: up" "$(num "$U_UP" 0)" "1"
	check "state: port" "$(num "$U_PORT" 0)" "$WANT_PORT"
	check "state: channel" "$(num "$U_CH" 0)" "$WANT_CH"
	check "state: runtime allocated" "$(num "$U_ALLOC" 0)" "1"
	check_cond "codec port programmed" \
		"$([ "$RX_PROG" -ge 1 ] && echo 1 || echo 0)" \
		"the frozen RX path did not run"
	check_cond "0x040 00 -> 05 reproduced" \
		"$([ "$RX_CFG" -ge 1 ] && echo 1 || echo 0)" "not seen"
	check_cond "0x180 00 -> 01 reproduced" \
		"$([ "$RX_MCH" -ge 1 ] && echo 1 || echo 0)" "not seen"

	check "stream-off accepted" "$OFF_RC" "0"
	check "disable was called" "$N_DIS" "1"
	#
	# The two halves of the no-op claim. Asserted separately because they
	# fail for opposite reasons and must not be confusable.
	#
	check "disable sent NOTHING" "$TID_DIS" "0"
	check_cond "disable did enter the controller" \
		"$([ "$XFER_DIS" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"xfer_msg was never called during disable -- the call was skipped, which is NOT the documented no-op" \
		"$XFER_DIS"
	check_cond "DISCONNECT_PORT went out" \
		"$([ "$TID_UNP" -ge 1 ] 2>/dev/null && echo 1 || echo 0)" \
		"no TID during unprepare -- nothing was actually disconnected" \
		"$TID_UNP"
	check "unprepare was called" "$N_UNP" "1"
	check "free was called" "$N_FREE" "1"
	check "state: down" "$(num "$D_UP" 1)" "0"
	check "state: runtime released" "$(num "$D_ALLOC" 1)" "0"
	check_cond "codec port torn down" \
		"$([ "$RX_TORN" -ge 1 ] && echo 1 || echo 0)" \
		"the port was left programmed"
	check "no slim-stream failure logged" "$ERRS" "0"
	check "no kernel WARNING/BUG" "$WARNS" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE CODEC'S SLIMbus RX STREAM COMES UP."
		say ""
		say "Slave port $WANT_PORT was connected to channel $WANT_CH and activated on the"
		say "ADSP's bus. CONNECT_SINK and DEF_ACT_CHAN each reached the"
		say "manager and were accepted, and the codec reproduced its frozen"
		say "register delta through the same production helper the DAI uses."
		say ""
		say "The no-op is now measured rather than read out of the source:"
		say "slim_stream_disable() entered the controller ($XFER_DIS message(s))"
		say "and allocated ZERO transaction IDs, so nothing left for the"
		say "manager. The real teardown was unprepare's DISCONNECT_PORT."
		say ""
		say "WHAT THIS DOES NOT CLAIM. No PCM was opened, no ASM RUN was"
		say "issued, no sample moved, and nothing was audible. This driver"
		say "has no RX interpolator and no output path, so audio could not"
		say "have been produced by this run under any circumstances."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "The ladder shows where the chain stopped. B0-B8 are the bring-up"
		say "and B9-B13 the teardown, so a teardown failure does not"
		say "invalidate a successful bring-up."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

clear_probes
rm -f "$DMESG_FILE" "$EV"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== the hook ===/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

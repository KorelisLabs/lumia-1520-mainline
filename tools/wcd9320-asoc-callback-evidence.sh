#!/bin/sh
#
# Does ASoC itself invoke the WCD9320 RX DAI's hw_params(), and does it produce
# the same hardware result as the manual path?
#
# WHAT THIS RUN CLAIMS
#
# That a real snd_soc_card registered, a real ALSA PCM appeared, a real
# userspace hw_params reached the framework, ASoC entered the codec's
# production hw_params(), and the resulting register delta is BYTE-IDENTICAL
# to the delta the manual research hook produces.
#
# The equality is the point. Two independent callers entering one production
# path and producing the same attributable hardware transition is a much
# stronger claim than either alone -- and it is compared as TRANSITIONS
# (addr: old -> new), not as final values, because identical endpoints can hide
# different paths.
#
# WHY aplay's EXIT CODE IS NOT THE GATE
#
# The card's platform side is ASoC's dummy, which provides only .open and no
# pcm_construct -- so there is NO DMA buffer. A PCM node exists and can be
# opened and configured, but samples cannot be written. aplay may therefore
# report an error AFTER hw_params has already run and done its work.
#
# So this is a SUCCESSFUL experiment:
#
#     hw_params proven -> expected registers changed -> write fails
#     -> aplay exits non-zero
#
# aplay's status is recorded as informational and is deliberately not a check.
# Anyone editing this file later: do not promote it to one.
#
# THE CARD DOES NOT AUTOLOAD, AND THIS RUN DOES NOT PRETEND IT DOES
#
# The machine driver creates its own platform device in module_init, so nothing
# matches an alias and udev never loads it. This script modprobes it explicitly
# and records that it did. Autoload is not claimed by this milestone.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="asoc-callback"
DIR=$(dirname "$0")
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-asoccb-$$"
CARD_MODULE="${CARD_MODULE:-wcd9320-lumia-card}"
ASOC_DEBUGFS="${ASOC_DEBUGFS:-/sys/kernel/debug/asoc}"
DAI_NAME="${DAI_NAME:-wcd9320-slim-rx1}"
SNAP_FIRST=$((0x030))
RATE="${RATE:-48000}"
FMT="${FMT:-S16_LE}"
CHANS="${CHANS:-1}"

require_module_version
find_devices

[ -w "$PGD/rx_port_test" ] || {
	say "INVALID RUN: $PGD/rx_port_test is not writable (run as root)."
	exit 2
}
command -v aplay >/dev/null 2>&1 || {
	say "INVALID RUN: aplay is not installed."
	say "  This milestone drives the callback through an ordinary ALSA client."
	say "  Install alsa-utils, or set the fallback ioctl helper up instead."
	exit 2
}

# ------------------------------------------------------- snapshot helpers --
#
# rx_port_state carries three hex dumps -- before, after, teardown -- of the
# interface port space starting at 0x030. These pull one section out of a saved
# copy and express the before->after change as a list of transitions.
snap_delta() {	# snap_delta <file> <sectA> <sectB>
	awk -v a="$2" -v b="$3" -v first="$SNAP_FIRST" '
		$0 == a ":" { cur = "a"; next }
		$0 == b ":" { cur = "b"; next }
		/^[a-z_]+:$/ { cur = "" }
		cur == "a" && /^[0-9a-f]+$/ { sa = sa $0 }
		cur == "b" && /^[0-9a-f]+$/ { sb = sb $0 }
		END {
			if (length(sa) == 0 || length(sa) != length(sb)) { print "UNREADABLE"; exit }
			out = ""
			for (i = 1; i <= length(sa); i += 2) {
				x = substr(sa, i, 2); y = substr(sb, i, 2)
				if (x != y)
					out = out sprintf("0x%03x:%s->%s ", first + (i-1)/2, x, y)
			}
			if (out == "") out = "NONE"
			print out
		}
	' "$1"
}

kvf() { tr ' \t' '\n\n' < "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n1; }

# ------------------------------------------------- phase A: manual oracle --
printf 'phase A: manual rx_port_test cycle (the reference delta)...\n' >&2
printf 'rx-port-on' > "$PGD/rx_port_test" 2>/dev/null
A_ON_RC=$?
sleep 1
printf 'rx-port-off' > "$PGD/rx_port_test" 2>/dev/null
A_OFF_RC=$?
sleep 1
A_STATE="/tmp/.wcd9320-stateA-$$"
cat "$PGD/rx_port_state" > "$A_STATE" 2>/dev/null
A_ORIGIN=$(kvf "$A_STATE" origin)
A_DELTA=$(snap_delta "$A_STATE" before after)
A_RESIDUE=$(snap_delta "$A_STATE" before teardown)

# ------------------------------------------------------ the card, loaded --
printf 'loading the machine driver...\n' >&2
#
# lsmod reports module names with underscores. Matching on the card's FULL
# name matters: an earlier version stripped at the first hyphen and tested for
# "wcd9320", which matches the already-loaded CODEC -- so it concluded the card
# was present, skipped modprobe entirely, and reported rc 0 for a command it
# never ran.
#
CARD_MOD_LSMOD=$(printf '%s' "$CARD_MODULE" | tr '-' '_')
CARD_LOAD_RC=0
CARD_LOAD_RAN=0
if lsmod 2>/dev/null | grep -q "^$CARD_MOD_LSMOD "; then
	CARD_LOAD_OUT="(already loaded)"
else
	CARD_LOAD_RAN=1
	CARD_LOAD_OUT=$(modprobe "$CARD_MODULE" 2>&1) || CARD_LOAD_RC=$?
fi
sleep 2
CARD_LOADED=$(lsmod 2>/dev/null | grep -c "^$CARD_MOD_LSMOD ")

CARDS_LIST=""
[ -r /proc/asound/cards ] && CARDS_LIST=$(cat /proc/asound/cards 2>/dev/null)
PCM_LIST=""
[ -r /proc/asound/pcm ] && PCM_LIST=$(cat /proc/asound/pcm 2>/dev/null)
CARD_NUM=$(printf '%s\n' "$CARDS_LIST" | sed -n 's/^ *\([0-9]\+\) \[.*/\1/p' | head -n1)
DAIS=""
[ -r "$ASOC_DEBUGFS/dais" ] && DAIS=$(cat "$ASOC_DEBUGFS/dais" 2>/dev/null)

# ------------------------------------------- phase B: ASoC drives hw_params --
APLAY_RC="n/a"
APLAY_OUT=""
if [ -n "$CARD_NUM" ]; then
	printf 'phase B: aplay -> ALSA -> ASoC -> hw_params...\n' >&2
	APLAY_OUT=$(timeout 15 aplay -D "hw:${CARD_NUM},0" -t raw \
		-f "$FMT" -r "$RATE" -c "$CHANS" -d 1 /dev/zero 2>&1)
	APLAY_RC=$?
	sleep 1
fi
B_STATE="/tmp/.wcd9320-stateB-$$"
cat "$PGD/rx_port_state" > "$B_STATE" 2>/dev/null
B_ORIGIN=$(kvf "$B_STATE" origin)
B_DELTA=$(snap_delta "$B_STATE" before after)
B_RESIDUE=$(snap_delta "$B_STATE" before teardown)

snap_dmesg
open_output "$OUTDIR/wcd9320-asoc-callback-$STAMP.txt"

# The IFD probe classification, from this boot's log.
# Count ENTRIES, not log lines: each probe emits an entry line and a return
# line, so matching 'IFD probe #' alone double-counts.
IFD_PROBES=$(count_lines 'IFD probe #.*sdev=')
IFD_BOUND=$(count_lines 'IFD probe #.*returning 0 (bound)')

LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

{
	hdr "the card"
	say "module loaded      : $CARD_LOADED (modprobe rc $CARD_LOAD_RC) -- loaded explicitly, autoload is NOT claimed"
	say "/proc/asound/cards :"
	printf '%s\n' "${CARDS_LIST:-  (none)}" | sed 's/^/  /'
	say "/proc/asound/pcm   :"
	printf '%s\n' "${PCM_LIST:-  (none)}" | sed 's/^/  /'
	say "ASoC DAIs          :"
	printf '%s\n' "${DAIS:-  (none)}" | sed 's/^/  /'

	hdr "the two invocations"
	say "A  manual   origin=$A_ORIGIN"
	say "   delta    $A_DELTA"
	say "   residue  $A_RESIDUE   (after teardown)"
	say ""
	say "B  ASoC     origin=$B_ORIGIN"
	say "   delta    $B_DELTA"
	say "   residue  $B_RESIDUE   (after teardown)"
	say ""
	say "aplay rc   : $APLAY_RC   <-- INFORMATIONAL ONLY, not a check."
	say "             The dummy platform has no DMA buffer, so a write after"
	say "             a successful hw_params is expected to fail."
	if [ -n "$APLAY_OUT" ]; then
		say "aplay says :"
		printf '%s\n' "$APLAY_OUT" | sed 's/^/  /'
	fi

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- 1..3 the card, the link, the PCM --
	check_cond "machine driver loaded" \
		"$([ "$CARD_LOADED" -ge 1 ] && echo 1 || echo 0)" \
		"$CARD_MOD_LSMOD is not in lsmod (modprobe ran=$CARD_LOAD_RAN rc=$CARD_LOAD_RC: ${CARD_LOAD_OUT:-no output})" \
		"explicitly, modprobe ran=$CARD_LOAD_RAN rc=$CARD_LOAD_RC"
	check_cond "a sound card exists" \
		"$([ -n "$CARD_NUM" ] && echo 1 || echo 0)" \
		"no card in /proc/asound/cards -- did the link bind?" \
		"card $CARD_NUM"
	check_cond "a PCM exists" \
		"$(printf '%s' "$PCM_LIST" | grep -c . | sed 's/^0$/0/;s/^[1-9].*/1/')" \
		"no PCM in /proc/asound/pcm" "present"
	check_cond "the RX DAI is still the only WCD9320 DAI" \
		"$(printf '%s\n' "$DAIS" | grep -Fxc "$DAI_NAME")" \
		"$DAI_NAME missing from the ASoC DAI list" "$DAI_NAME"
	check "card registration failures" \
		"$(count_lines 'failed to register card')" "0"

	# -- 4..5 ASoC actually entered the production callback --
	_hp=$(count_lines 'RX path invocation: ASoC hw_params')
	_hf=$(count_lines 'RX path invocation: ASoC hw_free')
	check_cond "ASoC entered hw_params" \
		"$([ "$_hp" -ge 1 ] && echo 1 || echo 0)" \
		"no 'RX path invocation: ASoC hw_params' line -- the framework never called the DAI" \
		"x$_hp"
	check "last invocation origin was ASoC" "$B_ORIGIN" "asoc-hw_free"

	# -- 6 THE EQUALITY: same production path, same hardware transition --
	check_cond "manual delta is readable" \
		"$([ "$A_DELTA" != "UNREADABLE" ] && [ "$A_DELTA" != "NONE" ] && echo 1 || echo 0)" \
		"manual delta: $A_DELTA" "$A_DELTA"
	check_cond "ASoC delta is readable" \
		"$([ "$B_DELTA" != "UNREADABLE" ] && [ "$B_DELTA" != "NONE" ] && echo 1 || echo 0)" \
		"ASoC delta: $B_DELTA" "$B_DELTA"
	check "ASoC delta EQUALS the manual delta" "$B_DELTA" "$A_DELTA"

	# -- 7 framework teardown restores the state --
	check_cond "ASoC entered hw_free" \
		"$([ "$_hf" -ge 1 ] && echo 1 || echo 0)" \
		"no 'RX path invocation: ASoC hw_free' line" "x$_hf"
	check "nothing left changed after ASoC teardown" "$B_RESIDUE" "NONE"
	check "nothing left changed after manual teardown" "$A_RESIDUE" "NONE"
	check "port programming failures" "$(count_lines 'rx-port .*failed')" "0"

	# -- 8 the foundation is unchanged --
	check "bring-up path" "$(kv "$PGD/bringup" path)" "fresh"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	check "registers after init" "$(kv "$PGD/rco_wake" nonzero_after)" "95"
	check_canary
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	if [ -r "$PGD/cache_check" ]; then
		_cc="/tmp/.wcd9320-cc-$$"
		cat "$PGD/cache_check" > "$_cc" 2>/dev/null
		check "codec cache mismatches" "$(kv "$_cc" mismatches)" "0"
		check "codec cacheable checked" "$(kv "$_cc" cacheable_checked)" "460"
		rm -f "$_cc"
	fi
	check "masks undisturbed" "$LIVE_MASK" "ff ff 3f 7f"

	# -- 9 the triple probe, classified --
	note "IFD probe entries" "$IFD_PROBES"
	note "IFD probes that bound" "$IFD_BOUND"
	check_cond "IFD probe classification captured" \
		"$([ "$IFD_PROBES" -ge 1 ] && echo 1 || echo 0)" \
		"no 'IFD probe #' lines -- instrumentation missing" \
		"$IFD_PROBES entries, $IFD_BOUND bound"

	# -- and nothing complained --
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "asoc errors" \
		"$(dmesg 2>/dev/null | grep -ci 'asoc:.*error\|snd_soc.*failed')" "0"
	check "regulator faults" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "ASoC DRIVES THE CODEC."
		say ""
		say "A real card registered, a real PCM appeared, and an ordinary ALSA"
		say "client's hw_params reached the framework, which entered"
		say "$DAI_NAME's production hw_params(). The register transition it"
		say "produced is byte-identical to the one the manual research hook"
		say "produces:"
		say ""
		say "  manual : $A_DELTA"
		say "  ASoC   : $B_DELTA"
		say ""
		say "Two independent callers, one production path, the same"
		say "attributable hardware result -- compared as transitions, not as"
		say "final values. Framework teardown restored the state exactly."
		say ""
		say "WHAT THIS DOES NOT CLAIM. No DMA, no q6/AFE, no ADSP audio"
		say "service, no SLIMbus channel allocation or activation, no sample"
		say "movement, no routing, no audible playback. The platform side is a"
		say "dummy with no buffer, which is why aplay's exit status is"
		say "informational here. Nothing has made a sound."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If the card did not register, read the driver's own line first:"
		say "it prints codec_component= and codec_dai= on failure, and a"
		say "changed SLIMbus enumeration name is the likely cause. There is"
		say "deliberately no fallback -- a changed name is evidence."
		say ""
		say "If ASoC never entered hw_params but the card bound, the PCM was"
		say "probably never opened: check /proc/asound/pcm and the aplay"
		say "output above. Remember aplay's exit code is NOT the gate -- a"
		say "failed write after a successful hw_params is the expected shape."
	fi

	hdr "manual state (phase A)"
	cat "$A_STATE" 2>/dev/null
	hdr "ASoC state (phase B)"
	cat "$B_STATE" 2>/dev/null

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE" "$A_STATE" "$B_STATE"

sed -n '/=== the card/,$p' "$OUT" | sed -n '1,110p'
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

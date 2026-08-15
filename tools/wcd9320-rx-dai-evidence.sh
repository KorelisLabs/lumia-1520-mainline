#!/bin/sh
#
# RX DAI and the IFD port path: is the DAI there, and does the production
# programming path reach hardware and reverse cleanly?
#
# WHAT THIS RUN CLAIMS, AND WHAT IT DOES NOT
#
# It claims: one RX DAI is registered and visible to ASoC, and the production
# IFD port-programming path was executed on hardware and is reversible.
#
# It does NOT claim that ASoC invoked the DAI callback. ASoC calls DAI ops from
# PCM operations on a sound card, and there is deliberately no card and no
# machine driver yet, so nothing drives them. The path is instead reached
# through a token-guarded research hook that calls the SAME production function
# the DAI's hw_params calls -- the register sequence exists once, so what is
# exercised here is what the DAI will execute when a card arrives. That is a
# real difference and the evidence says so rather than blurring it.
#
# It also claims nothing about PCM, routing, playback, capture or audible
# audio. Configuring the codec's side of a slave port is not a data path: no
# SLIMbus channel is allocated, defined or activated, and on this device the
# ADSP owns the bus master anyway.
#
# WHAT MAKES THE REGISTER EVIDENCE ATTRIBUTABLE
#
# Three snapshots of the whole interface port space (0x030-0x1b0) -- before
# programming, after programming, after teardown. The gate asserts the two
# registers that must change AND that nothing else did, so a write landing
# somewhere unintended shows up as drift rather than going unnoticed because
# nobody thought to look there.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="rx-dai"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-rx-dai-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-rxdai-$$"
MASK_ALL="ff ff 3f 7f"

ASOC_DEBUGFS="${ASOC_DEBUGFS:-/sys/kernel/debug/asoc}"
DAI_NAME="${DAI_NAME:-wcd9320-slim-rx1}"

# The addresses this milestone programs, derived in
# docs/audio/wcd9320-rx-dai-mapping.md. Stated here so the run asserts against
# the mapping rather than against whatever the driver happened to do.
RX_PORT="${RX_PORT:-16}"
CH_REG=$((0x140 + 4 * RX_PORT))		# 0x180 for port 16
CFG_REG=$((0x030 + RX_PORT))		# 0x040 for port 16
CFG_ON="${CFG_ON:-05}"
CFG_OFF="${CFG_OFF:-00}"
CH_ON="${CH_ON:-01}"
SNAP_FIRST=$((0x030))

require_module_version
find_devices
open_output "$OUTDIR/wcd9320-rx-dai-$STAMP.txt"

[ -w "$PGD/rx_port_test" ] || {
	say "INVALID RUN: $PGD/rx_port_test is not writable."
	say "  Run as root, and check the module carries the RX DAI work."
	exit 2
}

# ------------------------------------------------------------- the run ----
printf 'programming RX slave port %s ...\n' "$RX_PORT" >&2
printf 'rx-port-on' > "$PGD/rx_port_test" 2>/dev/null
ON_RC=$?
sleep 1
STATE_ON=$(cat "$PGD/rx_port_state" 2>/dev/null)

printf 'tearing it down ...\n' >&2
printf 'rx-port-off' > "$PGD/rx_port_test" 2>/dev/null
OFF_RC=$?
sleep 1
STATE_OFF=$(cat "$PGD/rx_port_state" 2>/dev/null)

snap_dmesg

STATE_FILE="/tmp/.wcd9320-rxstate-$$"
printf '%s\n' "$STATE_OFF" > "$STATE_FILE"

# ------------------------------------------------------ snapshot decoding --
#
# The three dumps are hex pairs, 32 per line, starting at 0x030. Pull one
# register out of a named section, and count how many bytes differ between two
# sections -- the second is what makes "nothing else moved" a measurement.
snap_byte() {	# snap_byte <section> <reg>
	awk -v sect="$1" -v reg="$2" -v first="$SNAP_FIRST" '
		$0 == sect ":" { inb = 1; next }
		/^[a-z]+:$/    { inb = 0 }
		inb && /^[0-9a-f]+$/ { s = s $0 }
		END {
			i = reg - first
			if (i >= 0 && length(s) >= (i + 1) * 2)
				print substr(s, i * 2 + 1, 2)
		}
	' "$STATE_FILE"
}

snap_diff_count() {	# snap_diff_count <sectA> <sectB>
	awk -v a="$1" -v b="$2" '
		$0 == a ":" { cur = "a"; next }
		$0 == b ":" { cur = "b"; next }
		/^[a-z]+:$/ { cur = "" }
		cur == "a" && /^[0-9a-f]+$/ { sa = sa $0 }
		cur == "b" && /^[0-9a-f]+$/ { sb = sb $0 }
		END {
			if (length(sa) == 0 || length(sa) != length(sb)) { print -1; exit }
			n = 0
			for (i = 1; i <= length(sa); i += 2)
				if (substr(sa, i, 2) != substr(sb, i, 2)) n++
			print n
		}
	' "$STATE_FILE"
}

# Which registers differ, so drift can be named rather than merely counted.
snap_diff_list() {	# snap_diff_list <sectA> <sectB>
	awk -v a="$1" -v b="$2" -v first="$SNAP_FIRST" '
		$0 == a ":" { cur = "a"; next }
		$0 == b ":" { cur = "b"; next }
		/^[a-z]+:$/ { cur = "" }
		cur == "a" && /^[0-9a-f]+$/ { sa = sa $0 }
		cur == "b" && /^[0-9a-f]+$/ { sb = sb $0 }
		END {
			if (length(sa) == 0 || length(sa) != length(sb)) exit
			for (i = 1; i <= length(sa); i += 2) {
				x = substr(sa, i, 2); y = substr(sb, i, 2)
				if (x != y)
					printf "0x%03x %s->%s ", first + (i - 1) / 2, x, y
			}
		}
	' "$STATE_FILE"
}

B_CH=$(snap_byte before "$CH_REG");    B_CFG=$(snap_byte before "$CFG_REG")
A_CH=$(snap_byte after "$CH_REG");     A_CFG=$(snap_byte after "$CFG_REG")
T_CH=$(snap_byte teardown "$CH_REG");  T_CFG=$(snap_byte teardown "$CFG_REG")

DIFF_ON=$(snap_diff_count before after)
DIFF_OFF=$(snap_diff_count before teardown)
DIFF_ON_LIST=$(snap_diff_list before after)
DIFF_OFF_LIST=$(snap_diff_list before teardown)

DAIS=""
COMPONENTS=""
[ -r "$ASOC_DEBUGFS/dais" ] && DAIS=$(cat "$ASOC_DEBUGFS/dais" 2>/dev/null)
[ -r "$ASOC_DEBUGFS/components" ] && COMPONENTS=$(cat "$ASOC_DEBUGFS/components" 2>/dev/null)
DAI_MATCH=$(printf '%s\n' "$DAIS" | grep -Fxc "$DAI_NAME")
# Anything of ours that is not the one RX DAI. snd-soc-dummy-dai is ASoC's own.
DAI_OTHER=$(printf '%s\n' "$DAIS" | grep -v '^snd-soc-dummy-dai$' |
	grep -v "^$DAI_NAME$" | grep -c .)
CARDS=0
[ -d /proc/asound ] && CARDS=$(ls -1 /proc/asound 2>/dev/null | grep -c '^card[0-9]')

LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

{
	hdr "what ASoC has"
	say "components:"
	printf '%s\n' "${COMPONENTS:-  (none)}" | sed 's/^/  /'
	say "DAIs:"
	printf '%s\n' "${DAIS:-  (none)}" | sed 's/^/  /'
	say "sound cards       : $CARDS"

	hdr "the port programming"
	say "slave port        : $RX_PORT   (the first RX slave port; SLIM RX1)"
	say "multi-channel reg : $(printf '0x%03x' "$CH_REG")"
	say "port config reg   : $(printf '0x%03x' "$CFG_REG")"
	say "hook exit codes   : on=$ON_RC off=$OFF_RC"
	say ""
	say "                    before   after   teardown"
	say "$(printf '0x%03x multi-channel' "$CH_REG")  : ${B_CH:-??}       ${A_CH:-??}      ${T_CH:-??}"
	say "$(printf '0x%03x port config ' "$CFG_REG")  : ${B_CFG:-??}       ${A_CFG:-??}      ${T_CFG:-??}"
	say ""
	say "bytes changed by programming : ${DIFF_ON}  ${DIFF_ON_LIST:+[$DIFF_ON_LIST]}"
	say "bytes still changed after teardown : ${DIFF_OFF}  ${DIFF_OFF_LIST:+[$DIFF_OFF_LIST]}"

	hdr "driver state"
	printf '%s\n' "$STATE_ON" | sed -n '1,6p' | sed 's/^/  on : /'
	printf '%s\n' "$STATE_OFF" | sed -n '1,6p' | sed 's/^/  off: /'

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- exactly one RX DAI, and nothing else --
	check_cond "asoc dais readable" \
		"$([ -r "$ASOC_DEBUGFS/dais" ] && echo 1 || echo 0)" \
		"$ASOC_DEBUGFS/dais is not readable" "$ASOC_DEBUGFS/dais"
	check "the RX DAI is registered" "$DAI_MATCH" "1"
	check "no other WCD9320 DAI (no TX)" "$DAI_OTHER" "0"
	check "sound cards" "$CARDS" "0"
	check_cond "component still present" \
		"$(printf '%s\n' "$COMPONENTS" | grep -Fxc "$PGD_NAME")" \
		"$PGD_NAME is not in the component list" "$PGD_NAME"

	# -- the IFD has its own uncached regmap --
	_own=$(count_lines 'interface regmap: own config')
	check_cond "interface regmap is its own config" \
		"$([ "$_own" -ge 1 ] && echo 1 || echo 0)" \
		"no 'interface regmap: own config' line in dmesg" \
		"max_register 0x1b0, uncached"

	# -- the hook reached the production helper --
	check "hook accepted rx-port-on" "$ON_RC" "0"
	check "hook accepted rx-port-off" "$OFF_RC" "0"
	_prog=$(count_lines 'rx-port .*: PROGRAMMED')
	_tear=$(count_lines 'rx-port .*: TORN DOWN')
	check_cond "programming logged" "$([ "$_prog" -ge 1 ] && echo 1 || echo 0)" \
		"no PROGRAMMED line in dmesg" "x$_prog"
	check_cond "teardown logged" "$([ "$_tear" -ge 1 ] && echo 1 || echo 0)" \
		"no TORN DOWN line in dmesg" "x$_tear"
	check "port programming failures" "$(count_lines 'rx-port .*failed')" "0"

	# -- THE POINT: the expected registers changed, and only those --
	check "multi-channel before" "${B_CH:-??}" "00"
	check "multi-channel after" "${A_CH:-??}" "$CH_ON"
	check "port config before" "${B_CFG:-??}" "$CFG_OFF"
	check "port config after" "${A_CFG:-??}" "$CFG_ON"
	check "port config after teardown" "${T_CFG:-??}" "$CFG_OFF"
	check "multi-channel after teardown" "${T_CH:-??}" "00"

	# Exactly the two registers we programmed moved -- nothing else in
	# 0x030-0x1b0. This is what makes every write attributable.
	check "registers changed by programming" "$DIFF_ON" "2"
	check "registers still changed after teardown" "$DIFF_OFF" "0"

	# -- everything already proven is unchanged --
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
	check "masks undisturbed" "$LIVE_MASK" "$MASK_ALL"

	# -- and nothing complained --
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "asoc errors" \
		"$(dmesg 2>/dev/null | grep -ci 'asoc:.*error\|snd_soc.*failed')" "0"
	check "regulator faults" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE RX PORT PATH WORKS, AND REVERSES."
		say ""
		say "One RX DAI, '$DAI_NAME', is registered and visible to ASoC. No"
		say "other DAI exists, and no sound card does."
		say ""
		say "The production port-programming path was executed against slave"
		say "port $RX_PORT through the research hook, and reached hardware:"
		say "$(printf '0x%03x' "$CFG_REG") went $CFG_OFF -> $CFG_ON -> $CFG_OFF and"
		say "$(printf '0x%03x' "$CH_REG") went 00 -> $CH_ON -> 00. Exactly two"
		say "registers moved in 0x030-0x1b0, and after teardown none did."
		say ""
		say "The interface function used its own uncached regmap throughout,"
		say "so none of this went near the codec's register cache -- which"
		say "still reports 460 cacheable registers agreeing with the chip."
		say ""
		say "WHAT THIS DOES NOT CLAIM. ASoC did not invoke the DAI callback:"
		say "that needs a card, which does not exist yet. The hook called the"
		say "same production function hw_params calls, so the path is proven,"
		say "not the framework binding. And no SLIMbus channel was allocated,"
		say "defined or activated -- configuring the codec's side of a port is"
		say "not a data path. Nothing has streamed and nothing has made a"
		say "sound."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If the expected registers did not change, read the hook exit"
		say "codes and the driver's own per-write lines first: the helper"
		say "logs old/want/readback for each write and refuses early if"
		say "core_ready or the interface function is not ready."
		say ""
		say "If MORE than two registers changed, the extra ones are named in"
		say "the drift list above. That is the check's whole purpose -- a"
		say "write landing somewhere unintended is exactly what a bad base"
		say "or a wrong port number would produce."
	fi

	hdr "interface port space, all three snapshots"
	printf '%s\n' "$STATE_OFF"

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE" "$STATE_FILE"

sed -n '/=== what ASoC has/,$p' "$OUT" | sed -n '1,120p'
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

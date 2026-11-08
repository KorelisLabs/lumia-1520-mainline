#!/bin/sh
#
# r184 ACOUSTIC GATE: ordinary playback, powered by DAPM, is heard on HPHL.
#
# docs/audio/wcd9320-dapm-hphl-mapping.md, sections 3c and 4. Per stream:
#
#   approval in chat -> fail-safe armed -> Headphones pin ON
#   -> the plain tone helper plays (DAPM powers MCLK, prep, prereq, RX1, DAC,
#      PA at prepare; tears them down at stream stop)
#   -> pin OFF -> PA chip-verified off -> fail-safe disarmed
#
# No research attribute powers anything in this run. The runner only switches
# the pin, plays, and reads state. That is the claim: the C3a path, driven by
# ASoC alone.
#
# SAFETY, the C3a model kept whole:
#   - the abort path is proven by a live Volume Down press before anything
#     arms, and an independent watcher stays up for the whole run;
#   - a transient systemd fail-safe timer is armed before the pin goes on and
#     cancelled only on a chip-verified PA-off;
#   - every abort runs wcd9320-dapm-teardown.sh: pin off, player killed, then
#     the driver's C3 abort regardless;
#   - one approval per stream, delivered by tools/c3a-approve.sh. This runs as
#     the same unit, journal and drop-box as C3a so that tool works unchanged.
#
# Usage (one line):
#   sudo env EXPECT_VERSION=dapm-hphl-rc1 C3A_GAIN_FIELD=00 sh wcd9320-dapm-listen.sh launch
# Exit:   0 pass, 1 checks failed, 2 invalid setup, 3 aborted.

set -u

MODE="wcd9320-dapm-listen"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-hphl-pa-expect.sh"
. "$DIR/wcd9320-dapm-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/var/log}"
JOURNAL="${C3A_JOURNAL:-$OUTDIR/wcd9320-c3a-journal.txt}"
export C3A_JOURNAL="$JOURNAL"
FLAG="${C3A_FLAG:-/run/wcd9320-c3a.abort}"
RUNLOCK="${C3A_LOCK:-/run/wcd9320-c3a.lock}"
GATELOCK="${C3A_GATELOCK:-/run/wcd9320-c3a-gate.lock}"
FAILSAFE="${C3A_FAILSAFE:-wcd9320-c3a-failsafe}"
UNIT="${C3A_UNIT:-wcd9320-c3a}"
APPROVE_DIR="${C3A_APPROVE_DIR:-/run/wcd9320-c3a-approve}"
TEARDOWN="$DIR/wcd9320-dapm-teardown.sh"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"
DBFS="${DBFS:--40}"
CYCLES="${CYCLES:-2}"
HOLD_ARM="${HOLD_ARM:-300}"
HOLD_GO="${HOLD_GO:-600}"		# waiting for "go", everything OFF
FAILSAFE_S="${FAILSAFE_S:-30}"		# covers pin on, ~1.1 s stream, pin off

GATE=""
for c in "${INPUT_GATE:-}" "$DIR/input-gate" /tmp/input-gate; do
	[ -n "$c" ] && [ -x "$c" ] && { GATE="$c"; break; }
done
TONE=""
for c in "${PCM_TONE:-}" "$DIR/pcm-tone" /tmp/pcm-tone; do
	[ -n "$c" ] && [ -x "$c" ] && { TONE="$c"; break; }
done
SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

jrn() {
	printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"
	printf '%s %s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$*" >> "$JOURNAL" 2>/dev/null
	sync 2>/dev/null
}
rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
pa_masked() { printf '%02x' $(( 0x${1:-ff} & 0x$WCD9320_PA_MASK )); }
hph_status() {
	grep -m2 -E '^(1b3|1b9):' "/sys/kernel/debug/regmap/${PGD_NAME:-none}/registers" \
		2>/dev/null | tr -d ' ' | tr '\n' ' ' | sed 's/:/=/g; s/ *$//'
}
pin_set() {	# pin_set 0|1 -> 0 when it reads back as asked
	[ "$(dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --set "$DAPM_PIN" "$1" 2>/dev/null)")" = "$1" ]
}
pin_get() { dapm_pin_value "$("$SETCTL" -D "$CTLDEV" --get "$DAPM_PIN" 2>/dev/null)"; }

# ------------------------------------------------------------------- abort --
ABORTED=0
ABORT_WHY=""
WATCH_PID=""
TPID=""
failsafe_disarm() {
	systemctl stop "$FAILSAFE.timer" >/dev/null 2>&1
	systemctl stop "$FAILSAFE.service" >/dev/null 2>&1
	systemctl reset-failed "$FAILSAFE.service" >/dev/null 2>&1
	return 0
}
failsafe_arm() {	# failsafe_arm <phase>
	failsafe_disarm
	systemd-run --unit="$FAILSAFE" --collect --on-active="$FAILSAFE_S" \
		sh "$TEARDOWN" "failsafe-$1" >/dev/null 2>&1 ||
		{ jrn "FAIL-SAFE COULD NOT BE ARMED for $1"; return 1; }
	jrn "fail-safe armed: $FAILSAFE_S s, phase $1"
}
watch_stop() { [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }

dl_abort() {	# dl_abort <reason>
	[ "$ABORTED" = "1" ] && return 0
	ABORTED=1
	ABORT_WHY="$1"
	jrn "ABORT reason=$1"
	[ -n "$TPID" ] && kill "$TPID" 2>/dev/null
	sh "$TEARDOWN" "$1" 2>&1 | while read -r _l; do jrn "  $_l"; done
	_ab_pa=$(rv "$(cat "${PGD:-/nonexistent}/hphl_pa_state" 2>/dev/null)" pa_0x1ab)
	if [ -n "$_ab_pa" ] && [ "$(pa_masked "$_ab_pa")" = "00" ]; then
		failsafe_disarm
		jrn "PA chip-verified off after the abort (0x1ab=$_ab_pa); fail-safe disarmed"
	else
		jrn "PA NOT VERIFIED OFF AFTER THE ABORT (0x1ab=${_ab_pa:-unreadable}) -- fail-safe LEFT ARMED"
	fi
	watch_stop
	jrn "ABORT complete"
}
flag_ok() {	# flag_ok <where> -> 1 after aborting on Volume Down
	[ -e "$FLAG" ] || return 0
	jrn "abort flag present at $1 -- the watcher saw Volume Down"
	dl_abort "volume-down at $1"
	return 1
}

# --------------------------------------------------------------- preflight --
preflight() {
	_bad=""
	[ -n "$GATE" ] || _bad="$_bad no-input-gate"
	[ -n "$TONE" ] || _bad="$_bad no-pcm-tone"
	[ -n "$SETCTL" ] || _bad="$_bad no-alsa-setctl"
	[ -f "$TEARDOWN" ] && [ -f "$DIR/wcd9320-hphl-pa-teardown.sh" ] || _bad="$_bad no-teardown"
	[ -n "$_bad" ] && { say "INVALID SETUP:$_bad"; return 1; }

	require_module_version
	find_devices
	[ -e "$PGD/dapm_state" ] || { say "INVALID SETUP: no dapm_state -- not r184"; return 1; }
	jrn "module $RUNNING_VERSION, codec $PGD"

	"$GATE" --resolve >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: the approve and abort devices did not resolve"; return 1; }
	"$TONE" --dbfs "$DBFS" --dry-run >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: the tone helper refused $DBFS dBFS"; return 1; }
	[ "$(pa_gain_ok "$WCD9320_PA_GAIN_FIELD")" = "OK" ] ||
		{ say "INVALID SETUP: gain field $WCD9320_PA_GAIN_FIELD"; return 1; }

	D_PRE=$(cat "$PGD/dapm_state" 2>/dev/null)
	PRE=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	DPRE=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
	_cs=$(cat "$PGD/clk_source_state" 2>/dev/null)
	[ "$(dapm_held_is "$D_PRE" "$DAPM_HELD_NONE")" = "OK" ] || _bad="$_bad dapm-held=$(dapm_kv "$D_PRE" held)"
	CARDV=$(cat "$DAPM_CARD_VERSION_PATH" 2>/dev/null)
	_cok=$(dapm_card_ok "$CARDV" "$(pin_get)")
	[ "$_cok" = "OK" ] || _bad="$_bad ${_cok#REFUSE:}"
	[ "$(rv "$_cs" mclk_users)" = "0" ] || _bad="$_bad mclk-held"
	[ "$(rv "$_cs" on_mclk)" = "0" ] || _bad="$_bad not-on-rco"
	[ "$(pa_masked "$(rv "$PRE" pa_0x1ab)")" = "00" ] || _bad="$_bad pa-on"
	[ "$(rv "$PRE" guard_tripped)" = "0" ] || _bad="$_bad guard-tripped"
	[ "$(rv "$PRE" prep_on)" = "0" ] || _bad="$_bad prep-on"
	[ "$(rv "$DPRE" on)" = "0" ] || _bad="$_bad dac-on"
	[ "$(rv "$DPRE" dac_0x1b1)" = "00" ] || _bad="$_bad dac-dirty"
	[ -n "$_bad" ] && { say "INVALID SETUP: not idle:$_bad"; return 1; }
	jrn "baseline idle: dapm held 00, pin off, RCO, PA off"

	[ "${1:-}" = "arm" ] || return 0
	say ""
	say "  ==> PRESS VOLUME DOWN NOW to prove the abort path. ${HOLD_ARM} s."
	jrn "awaiting the arm-time Volume Down press, up to $HOLD_ARM s"
	"$GATE" --selftest-abort --timeout "$HOLD_ARM" --label armtime >>"$JOURNAL" 2>&1 ||
		{ say "INVALID SETUP: no Volume Down press seen. Nothing armed."; return 1; }
	jrn "ABORT PATH PROVEN ON HARDWARE at arm time"
}

# ------------------------------------------------------------------ stream --
stream() {	# stream <n>
	_n=$1
	jrn "=== stream $_n: begin ==="
	flag_ok "stream-$_n-start" || return 1

	jrn "GATE dapm-c$_n: waiting up to $HOLD_GO s for the approval in chat -- Volume Down aborts"
	pa_chat_wait "$APPROVE_DIR" "dapm-c$_n" "$HOLD_GO" "$FLAG" >/dev/null
	_rc=$?
	if [ "$_rc" != "0" ]; then
		jrn "GATE dapm-c$_n: not approved (rc $_rc) -- abort"
		dl_abort "gate-dapm-c$_n-rc$_rc"
		return 1
	fi
	jrn "GATE dapm-c$_n: APPROVED (chat)"
	flag_ok "gate-dapm-c$_n" || return 1

	failsafe_arm "stream-c$_n" || { dl_abort "failsafe-unavailable"; return 1; }

	pin_set 1 || { jrn "pin ON did not read back"; dl_abort "pin-on"; return 1; }
	_s=$(cat "$PGD/dapm_state" 2>/dev/null)
	eval "S${_n}_PINON=\$_s"
	jrn "pin ON; with no stream: $_s"
	if [ "$(dapm_held_is "$_s" "$DAPM_HELD_NONE")" != "OK" ]; then
		jrn "the pin alone powered something -- abort"
		dl_abort "pin-alone-powered"
		return 1
	fi
	flag_ok "pin-on-c$_n" || return 1

	jrn "tone: 1 kHz, $DBFS dBFS, 250 ms tone/silence/tone/silence, one stream, DAPM-powered"
	"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" >>"$JOURNAL" 2>&1 &
	TPID=$!
	sleep 0.3
	_l=$(cat "$PGD/dapm_state" 2>/dev/null)
	_p=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	_hs=$(hph_status)
	_cs=$(cat "$PGD/clk_source_state" 2>/dev/null)
	eval "S${_n}_LIVE=\$_l; S${_n}_PA=\$_p; S${_n}_HS=\$_hs; S${_n}_CS=\$_cs"
	jrn "live: $_l | 0x1ab=$(rv "$_p" pa_0x1ab) ocp=$(rv "$_p" ocp_seen) | mclk_users=$(rv "$_cs" mclk_users) on_mclk=$(rv "$_cs" on_mclk) | $_hs"
	_bad=""
	[ "$(dapm_held_is "$_l" "$DAPM_HELD_ALL")" = "OK" ] || _bad="$_bad held=$(dapm_kv "$_l" held)"
	[ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "$WCD9320_PA_STATE_ON" ] || _bad="$_bad pa=$(rv "$_p" pa_0x1ab)"
	[ "$(rv "$_p" ocp_seen)" = "0" ] || _bad="$_bad ocp"
	if [ -n "$_bad" ]; then
		jrn "THE PATH IS NOT IN ITS ONE LEGAL LIVE STATE:$_bad"
		dl_abort "live-state"
		return 1
	fi
	wait "$TPID"
	_t=$?
	TPID=""
	eval "S${_n}_TRC=\$_t"
	jrn "tone finished rc=$_t"
	flag_ok "after-tone-c$_n" || return 1

	# The stream has stopped; DAPM powers down at once (no pmdown delay on
	# this card). Polled, not assumed, for up to 3 s.
	_w=0
	while [ "$_w" -lt 30 ]; do
		[ "$(dapm_held_is "$(cat "$PGD/dapm_state" 2>/dev/null)" "$DAPM_HELD_NONE")" = "OK" ] && break
		sleep 0.1
		_w=$((_w + 1))
	done
	_a=$(cat "$PGD/dapm_state" 2>/dev/null)
	_p=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	eval "S${_n}_DOWN_MS=$((_w * 100)); S${_n}_AFTER=\$_a; S${_n}_PAOFF=\$_p"
	jrn "after the stream (~$((_w * 100)) ms): $_a | 0x1ab=$(rv "$_p" pa_0x1ab)"

	pin_set 0 || jrn "pin OFF did not read back"
	_pin=$(pin_get)
	eval "S${_n}_PIN=\$_pin"

	if [ "$(pa_masked "$(rv "$_p" pa_0x1ab)")" = "00" ] &&
	   [ "$(dapm_held_is "$_a" "$DAPM_HELD_NONE")" = "OK" ]; then
		failsafe_disarm
		jrn "fail-safe disarmed: the PA is chip-verified off and DAPM holds nothing"
	else
		jrn "THE PATH DID NOT COME DOWN WITH THE STREAM -- abort"
		dl_abort "not-down-c$_n"
		return 1
	fi
	jrn "=== stream $_n: complete ==="
	return 0
}

# -------------------------------------------------------------------- main --
case "${1:-}" in
check)
	resolve_expectations
	preflight noarm && { say "READY. Next: $0 launch"; exit 0; }
	exit 2 ;;
launch)
	CMD="systemd-run --unit=$UNIT --collect --setenv=OUTDIR=$OUTDIR"
	CMD="$CMD --setenv=DBFS=$DBFS --setenv=CYCLES=$CYCLES --setenv=HOLD_ARM=$HOLD_ARM"
	CMD="$CMD --setenv=C3A_GAIN_FIELD=$WCD9320_PA_GAIN_FIELD"
	CMD="$CMD --setenv=EXPECT_VERSION=${EXPECT_VERSION:-} sh $DIR/$(basename "$0") detached"
	say "  $CMD"
	exec $CMD ;;
detached) ;;
*)
	say "usage: $0 check|launch"
	exit 2 ;;
esac

resolve_expectations
if command -v flock >/dev/null 2>&1; then
	exec 9>"$RUNLOCK"
	flock -n 9 || { say "INVALID SETUP: another run holds $RUNLOCK"; exit 2; }
fi
jrn "================ DAPM listen run $STAMP ================"
jrn "stimulus $DBFS dBFS, $CYCLES stream(s), gain field $WCD9320_PA_GAIN_FIELD"

trap 'jrn "SIGNAL -- running the teardown"; dl_abort signal; exit 3' INT TERM HUP

preflight arm || { jrn "preflight refused -- nothing armed, nothing written"; exit 2; }

# The gain, through the existing attribute, while nothing is up.
if ! echo "$WCD9320_PA_GAIN_FIELD" > "$PGD/hphl_pa_gain" 2>/dev/null ||
   [ "$(sed -n 's/^gain_field=\([0-9a-f]*\).*/\1/p' "$PGD/hphl_pa_gain" 2>/dev/null)" \
     != "$WCD9320_PA_GAIN_FIELD" ]; then
	jrn "gain field $WCD9320_PA_GAIN_FIELD not accepted -- nothing armed"
	exit 2
fi
jrn "gain field $WCD9320_PA_GAIN_FIELD set and read back"

FORCED_START=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
FORCED_START=${FORCED_START:-0}
FORCED_RING=$(sed -n 's/.*ring=\([0-9]*\).*/\1/p' "$PGD/forced_log" 2>/dev/null | head -n1)
FORCED_RING=${FORCED_RING:-16}
if [ $(( FORCED_START + WCD9320_PA_FORCED_PER_CYCLE * CYCLES )) -gt "$FORCED_RING" ]; then
	jrn "the forced-write journal holds $FORCED_START of $FORCED_RING -- this run would not fit; power cycle. Nothing armed."
	exit 2
fi
jrn "forced-write journal starts this run at $FORCED_START of $FORCED_RING"

mkdir -p "$APPROVE_DIR" && rm -f "$APPROVE_DIR"/* 2>/dev/null
rm -f "$FLAG" 2>/dev/null
"$GATE" --watch --flag "$FLAG" --lock "$GATELOCK" >>"$JOURNAL" 2>&1 &
WATCH_PID=$!
sleep 1
kill -0 "$WATCH_PID" 2>/dev/null || { jrn "THE ABORT WATCHER DID NOT STAY UP"; exit 2; }
jrn "abort watcher armed, pid $WATCH_PID"

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
jrn "front-end mixer enabled"

RC=0
n=1
while [ "$n" -le "$CYCLES" ]; do
	stream "$n" || { RC=3; break; }
	n=$((n + 1))
done

failsafe_disarm
watch_stop
[ "$(pin_get)" = "0" ] || { pin_set 0; jrn "pin forced OFF at the end"; }

D_POST=$(cat "$PGD/dapm_state" 2>/dev/null)
POST=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
DPOST=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
CPOST=$(cat "$PGD/clk_source_state" 2>/dev/null)
FLOG=$(cat "$PGD/forced_log" 2>/dev/null)
DMESG_FILE="/tmp/.wcd9320-dmesg-dapm-listen-$$"
snap_dmesg

open_output "$OUTDIR/wcd9320-dapm-listen-$STAMP.txt"
{
	hdr "what this run can and cannot establish"
	say "That plain playback, with the Headphones pin on, powers the proven"
	say "HPHL path through DAPM in the mapped order and takes it down when the"
	say "stream stops. WHETHER IT WAS HEARD is decided by tools/c3a-capture.py on"
	say "the PC recording and by the operator, not by this file."

	hdr "the run"
	say "aborted     : $ABORTED $ABORT_WHY"
	say "streams run : $((n - 1)) of $CYCLES"
	say "stimulus    : $DBFS dBFS, 1 kHz, tone/silence/tone/silence"
	say "gain field  : $WCD9320_PA_GAIN_FIELD"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_pi=\${S${c}_PINON:-}; _l=\${S${c}_LIVE:-}; _a=\${S${c}_AFTER:-}; _ms=\${S${c}_DOWN_MS:-?}; _hs=\${S${c}_HS:-?}"
		say "stream $c: held pin-on $(dapm_kv "$_pi" held) live $(dapm_kv "$_l" held) after $(dapm_kv "$_a" held) (~$_ms ms down) | hph $_hs"
		c=$((c + 1))
	done

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "card module version" "${CARDV:-}" "$DAPM_CARD_VERSION"
	check "the run was not aborted" "$ABORTED" "0"
	check "streams completed" "$((n - 1))" "$CYCLES"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_pi=\${S${c}_PINON:-}; _l=\${S${c}_LIVE:-}; _a=\${S${c}_AFTER:-}; _p=\${S${c}_PA:-}; _f=\${S${c}_PAOFF:-}; _cs=\${S${c}_CS:-}; _hs=\${S${c}_HS:-}; _t=\${S${c}_TRC:-}; _pin=\${S${c}_PIN:-}"
		say ""
		say "-- stream $c --"
		check "s$c pin alone powers nothing" "$(dapm_kv "$_pi" held)" "$DAPM_HELD_NONE"
		check "s$c DAPM holds the whole path live" "$(dapm_kv "$_l" held)" "$DAPM_HELD_ALL"
		check "s$c PA live masked" "$(pa_masked "$(rv "$_p" pa_0x1ab)")" "$WCD9320_PA_STATE_ON"
		_x=$(rv "$_p" pa_0x1ab)
		check "s$c HPHR stayed clear" "$(printf '%02x' $(( 0x${_x:-ff} & 0x10 )))" "00"
		check "s$c one MCLK user live" "$(rv "$_cs" mclk_users)" "1"
		check "s$c codec on MCLK live" "$(rv "$_cs" on_mclk)" "1"
		check "s$c 0x1b3 clocked live" "$(printf '%s' "$_hs" | sed -n 's/.*1b3=\([0-9a-f]*\).*/\1/p')" "08"
		check "s$c tone played" "$_t" "0"
		check "s$c DAPM holds nothing after" "$(dapm_kv "$_a" held)" "$DAPM_HELD_NONE"
		check "s$c PA off after" "$(pa_masked "$(rv "$_f" pa_0x1ab)")" "00"
		check "s$c pin OFF after" "$_pin" "0"
	done

	say ""
	say "-- DAPM's own accounting --"
	check "DAPM ups this run" "$(dapm_delta "$D_PRE" "$D_POST" ups)" "$((DAPM_STAGES * (n - 1)))"
	check "DAPM downs this run" "$(dapm_delta "$D_PRE" "$D_POST" downs)" "$((DAPM_STAGES * (n - 1)))"
	check "DAPM refusals this run" "$(dapm_delta "$D_PRE" "$D_POST" refusals)" "0"
	check "DAPM failures this run" "$(dapm_delta "$D_PRE" "$D_POST" failures)" "0"
	check "DAPM holds nothing at the end" "$(dapm_kv "$D_POST" held)" "$DAPM_HELD_NONE"
	check "nobody holds MCLK at the end" "$(rv "$CPOST" mclk_users)" "0"
	check "codec back on RCO" "$(rv "$CPOST" on_mclk)" "0"
	check "guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no OCP fault" "$(rv "$POST" ocp_seen)" "0"
	check "PA enables == disables" "$(rv "$POST" enables)" "$(rv "$POST" disables)"

	say ""
	say "-- the forced writes: 314 set, 30d set, 30d clear, 314 clear, per stream --"
	check "forced operations this run" "$(( $(rv "$FLOG" forced_n) - FORCED_START ))" \
	      "$(( WCD9320_PA_FORCED_PER_CYCLE * (n - 1) ))"
	_i=0
	while [ "$_i" -lt "$(( WCD9320_PA_FORCED_PER_CYCLE * (n - 1) ))" ]; do
		case $((_i % 4)) in
		0) _wr=314; _wd=set ;;
		1) _wr=30d; _wd=set ;;
		2) _wr=30d; _wd=clear ;;
		3) _wr=314; _wd=clear ;;
		esac
		_j=$(( FORCED_START + _i ))
		check "f$_j register" "$(rv "$FLOG" "f${_j}_reg")" "$_wr"
		check "f$_j direction" "$(rv "$FLOG" "f${_j}_dir")" "$_wd"
		_i=$((_i + 1))
	done

	say ""
	say "-- the teardown restored what it found --"
	check "gain restored" "$(rv "$POST" lgain_0x1ae)" "$(rv "$PRE" lgain_0x1ae)"
	check "wg ctl restored" "$(rv "$POST" wgctl_0x1ac)" "$(rv "$PRE" wgctl_0x1ac)"
	check "wg time restored" "$(rv "$POST" wgtime_0x1ad)" "$(rv "$PRE" wgtime_0x1ad)"
	check "wg ocp restored" "$(rv "$POST" wgocp_0x1a9)" "$(rv "$PRE" wgocp_0x1a9)"
	check "chopper restored" "$(rv "$POST" chop_0x1a5)" "$(rv "$PRE" chop_0x1a5)"
	check "DAC off" "$(rv "$DPOST" dac_0x1b1)" "00"
	check "DSM mux cleared" "$(rv "$DPOST" dsm_0x3b0)" "00"
	check "RX bias released" "$(rv "$DPOST" bias_refs)" "0"

	hdr "dapm events (dmesg)"
	dmesg | grep -E 'dapm: |mclk: (get|put)' | tail -n 40

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1
rm -f "$DMESG_FILE"
sync
jrn "evidence written to $OUT"

[ "$ABORTED" = "0" ] || exit 3
[ "$FAIL_N" -eq 0 ] || exit 1
exit "$RC"

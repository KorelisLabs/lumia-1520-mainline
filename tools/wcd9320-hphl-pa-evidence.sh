#!/bin/sh
#
# C3a: does a waveform appear at the HPHL pin that follows the digital content?
#
# THE CLAIM UNDER TEST
#
#   With the DAC path established at COMPANDER 1 OFF and the gain pinned at the
#   mapped minimum, the left headphone PA can be enabled by the mapped
#   sequence, a 1 kHz stimulus can be played through the unchanged stream, and
#   the analog output at the HPHL contact follows the DIGITAL CONTENT --
#   present during the tone segments, absent during the silent ones, twice --
#   and the whole thing reverses.
#
# WHAT IT DOES NOT CLAIM
#
# Correct PA register sequencing earns NOTHING. That is the same class of
# result D1 already provides, one stage further along, and this run can produce
# it while the analog stage is dead. The milestone is point 1 of section 24 and
# nothing less: an OBSERVED waveform tracking the stimulus. Everything else in
# here is a precondition for believing that observation, not a substitute for
# it.
#
# THIS RUN HAS NO SSH.
#
# Section 21 requires the phone off USB before scope ground is attached. So
# this is not driven interactively: it is armed, the operator disconnects USB,
# and from then on the ONLY channel is two hardware buttons and the evidence
# file on disk.
#
#   Volume Up   approve, advance exactly one state
#   Volume Down abort, full mapped teardown, from any point
#   timeout     ABORT. Never a proceed.
#   any error   ABORT. Never a proceed.
#
# FOUR THINGS MAKE THAT SAFE, AND ALL FOUR ARE INDEPENDENT
#
#   1. an INDEPENDENT abort watcher, started before the first hardware change
#      and alive until the final teardown. The approve gates are blind between
#      calls -- while registers are sequencing, while the tone plays, while
#      this script is stalled -- and the watcher is not.
#   2. a TRANSIENT SYSTEMD FAIL-SAFE TIMER, armed at the PA-enable boundary and
#      cancelled only once the PA is chip-verified off. It covers this script
#      dying without running its own trap.
#   3. the driver's teardown is ONE idempotent operation under a state lock, so
#      a normal teardown and an emergency abort cannot interleave.
#   4. the PA guard is never disabled. It becomes phase-dependent: 00 before,
#      exactly 20 while HPHL is deliberately on, 00 after. 0x10 or 0x30 always
#      trips.
#
# EVIDENCE IS FLUSHED AFTER EVERY TRANSITION. Not buffered to the end like the
# D1 gate: if the phone stops mid-run there is no ssh to go and look, so what
# reached the disk has to be the whole record up to that point.
#
# Exit: 0 sequence completed and checks passed, 1 checks failed, 2 invalid
#       setup, 3 aborted (by button, timeout or error).

set -u

MODE="wcd9320-hphl-pa"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"
. "$DIR/wcd9320-hphl-pa-expect.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')

#
# EVIDENCE GOES TO PERSISTENT STORAGE, not /tmp.
#
# The phone is RAM-booted, so /tmp is tmpfs -- which survives a run but not the
# power cycle that a wedged codec might need. The rootfs on eMMC is untouched
# by fastboot boot and is where a record has to live if it is going to be
# readable after anything goes wrong.
#
OUTDIR="${OUTDIR:-/var/log}"
JOURNAL="${C3A_JOURNAL:-$OUTDIR/wcd9320-c3a-journal.txt}"
export C3A_JOURNAL="$JOURNAL"
FLAG="${C3A_FLAG:-/run/wcd9320-c3a.abort}"
RUNLOCK="${C3A_LOCK:-/run/wcd9320-c3a.lock}"
GATELOCK="${C3A_GATELOCK:-/run/wcd9320-c3a-gate.lock}"
FAILSAFE="${C3A_FAILSAFE:-wcd9320-c3a-failsafe}"
UNIT="${C3A_UNIT:-wcd9320-c3a}"

TEARDOWN="$DIR/wcd9320-hphl-pa-teardown.sh"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
MIXER="${MIXER:-SLIMBUS_0_RX Audio Mixer MultiMedia1}"

#
# THE FROZEN HOLD LIMITS, and they are deliberately not one number.
#
# The PA is OFF during the first hold, so the operator can take as long as
# setting up a scope actually takes. The PA is LIVE during the second and
# third, into a jack, so those are short and expire into a teardown.
#
HOLD_PA_OFF="${HOLD_PA_OFF:-600}"	# 10 minutes, PA off, then abort
HOLD_PA_ON="${HOLD_PA_ON:-120}"		# 2 minutes, PA live, then teardown
HOLD_TONE="${HOLD_TONE:-120}"		# 2 minutes, PA live, then teardown
#
# THE ARM WINDOW, and it is the one hold that is not a safety limit.
#
# Nothing is armed and no register is written until the operator physically
# presses Volume Down, so this window costs nothing to make generous -- an
# expiry here refuses the run and leaves the codec untouched, which is exactly
# what happened on the first attempt when 120 s ran out while the operator was
# still reading the instructions.
#
# It is still bounded rather than infinite: a run left waiting forever for a
# press nobody is going to make holds the lock and looks armed.
#
HOLD_ARM="${HOLD_ARM:-300}"		# 5 minutes to press Volume Down
FAILSAFE_PAD="${FAILSAFE_PAD:-45}"	# the timer outlives the gate by this

DBFS="${DBFS:--40}"
CYCLES="${CYCLES:-2}"

#
# THE INSTRUMENT.
#
#   scope     the frozen design: DC measured at the pin, contract enforced
#             by the operator at the first two gates
#   acoustic  an earbud on the PC's USB microphone, recorded and analysed by
#             tools/c3a-capture.py. Proves or refutes that the output follows
#             the digital content; CANNOT see DC, so it runs only with the
#             operator's explicit waiver of the DC contract.
#
# CONTROL "pa-off" runs everything identically except the PA is never enabled.
#
INSTRUMENT="${C3A_INSTRUMENT:-scope}"
DC_WAIVER="${C3A_DC_WAIVER:-}"
CONTROL="${C3A_CONTROL:-}"
if [ "$CONTROL" = "pa-off" ]; then
	PA_LIVE_EXPECT="$WCD9320_PA_STATE_OFF"
else
	PA_LIVE_EXPECT="$WCD9320_PA_STATE_ON"
fi

#
# HOW THE OPERATOR APPROVES.
#
#   chat     acoustic runs (USB stays connected): ONE approval per cycle, to
#            turn the amplifier on, written as a file by tools/c3a-approve.sh
#            after the operator says so in chat. Everything after it is
#            automatic and short -- PA on, 2 s for any switch-on pop, the 1 s
#            tone, 1 s, PA off -- about 5 s live per cycle instead of minutes
#            held open at gates. Volume Down stays the always-on abort.
#   buttons  the frozen scope design (USB off, buttons the only channel).
#            Refused unless input-gate has the dwell, so a burst of presses
#            cannot chain through gates.
#
if [ "$INSTRUMENT" = "acoustic" ]; then
	APPROVE="${C3A_APPROVE:-chat}"
else
	APPROVE="${C3A_APPROVE:-buttons}"
fi
APPROVE_DIR="${C3A_APPROVE_DIR:-/run/wcd9320-c3a-approve}"
FAILSAFE_CHAT="${FAILSAFE_CHAT:-60}"	# covers the ~5 s automatic live window

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

ACTION="${1:-}"

# ---------------------------------------------------------------- journal --
#
# One line per transition, appended and SYNCED. Deliberately separate from the
# formatted evidence file: the journal is what survives a run that never
# reaches its report.
jrn() {
	printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"
	printf '%s %s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$*" >> "$JOURNAL" 2>/dev/null
	sync 2>/dev/null
}

# --------------------------------------------------------------- discovery --
#
# THE CODEC IS TWO SLIMBUS FUNCTIONS AND ONLY ONE OF THEM IS THE CODEC.
#
# 217:a0:0:0 is the interface function; 217:a0:1:0 is the control function.
# The attribute group is registered per device, so BOTH carry hphl_pa_test and
# hphl_pa_state -- the interface function's readers answer "interface
# function: not applicable" rather than being absent.
#
# So "the first device that has the attribute" picks the WRONG ONE, and its
# state file has no pa_0x1ab in it. The C3a preflight caught exactly that on
# its first run, before anything was written.
#
# find_devices() from the evidence library is used instead of a second
# implementation. It has distinguished the two since the coldboot runs, it
# fails closed if no control function is found, and it also sets PGD_NAME and
# IFD_NAME, which the report wants.
c3_find_codec() {
	find_devices
	[ -n "${PGD:-}" ] && [ -e "$PGD/hphl_pa_test" ] || return 1
	return 0
}

# rv <text> <key>
rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

# ------------------------------------------------------------------- abort --
ABORTED=0
ABORT_WHY=""

c3_abort() {	# c3_abort <reason>
	[ "$ABORTED" = "1" ] && return 0
	ABORTED=1
	ABORT_WHY="$1"
	jrn "ABORT reason=$1"
	#
	# THE RUNNER ABORTS ITS OWN, ALREADY-VERIFIED CONTROL FUNCTION FIRST.
	#
	# $PGD came from find_devices(), which tells the interface function from
	# the control function. The shared teardown script then runs as well --
	# the abort is idempotent, so the second one is a no-op -- because it is
	# also what the trap and the fail-safe timer use. Relying on the script
	# alone is what left the PA enabled on the first real run, when its own
	# discovery picked the interface function and every write was refused.
	#
	if [ -n "${PGD:-}" ] && [ -e "$PGD/hphl_pa_test" ]; then
		if echo abort > "$PGD/hphl_pa_test" 2>/dev/null; then
			jrn "abort written to $PGD"
		else
			jrn "ABORT WRITE TO $PGD FAILED"
		fi
	fi
	sh "$TEARDOWN" "$1" 2>&1 | while read -r _ab_l; do jrn "  $_ab_l"; done
	#
	# And the fail-safe is disarmed only AFTER a chip-verified PA-off, the
	# same rule the normal teardown follows. Disarming it first, as this
	# function used to, removed the last layer exactly when the teardown it
	# was meant to back up had just failed.
	#
	_ab_pa=$(rv "$(cat "$PGD/hphl_pa_state" 2>/dev/null)" pa_0x1ab)
	if [ -n "$_ab_pa" ] &&
	   [ "$(printf '%02x' $(( 0x$_ab_pa & 0x$WCD9320_PA_MASK )))" = "00" ]; then
		c3_failsafe_disarm
		jrn "PA chip-verified off after the abort (0x1ab=$_ab_pa); fail-safe disarmed"
	else
		jrn "PA NOT VERIFIED OFF AFTER THE ABORT (0x1ab=${_ab_pa:-unreadable}) -- fail-safe LEFT ARMED"
	fi
	c3_watch_stop
	jrn "ABORT complete"
}

# The watcher fired while we were not looking at a gate.
c3_flag_seen() { [ -e "$FLAG" ] && return 0; return 1; }

c3_check_flag() {	# c3_check_flag <where>
	if c3_flag_seen; then
		jrn "abort flag present at $1 -- the watcher saw Volume Down"
		c3_abort "volume-down at $1"
		return 1
	fi
	return 0
}

# ----------------------------------------------------------- the watcher --
WATCH_PID=""

c3_watch_start() {
	rm -f "$FLAG" 2>/dev/null
	#
	# No --timeout: it must stay armed for the whole run. It is stopped
	# explicitly at the end and dies with the unit if this script is killed.
	#
	"$GATE" --watch --flag "$FLAG" --lock "$GATELOCK" >>"$JOURNAL" 2>&1 &
	WATCH_PID=$!
	sleep 1
	if ! kill -0 "$WATCH_PID" 2>/dev/null; then
		jrn "THE ABORT WATCHER DID NOT STAY UP -- refusing to arm"
		return 1
	fi
	jrn "abort watcher armed, pid $WATCH_PID"
	return 0
}

c3_watch_stop() {
	[ -n "$WATCH_PID" ] || return 0
	kill "$WATCH_PID" 2>/dev/null
	WATCH_PID=""
}

# ------------------------------------------------------- the fail-safe timer --
#
# ARMED AT THE PA BOUNDARY, NOT AT LAUNCH.
#
# One global timer set when the run starts would either be too short for the
# scope setup or too long to be a fail-safe once the PA is live. So it is armed
# when the PA goes on, re-armed at each hold that happens with it on, and
# cancelled only after 0x1ab has been read back from the CHIP with both PA bits
# clear.
c3_failsafe_arm() {	# c3_failsafe_arm <seconds> <phase>
	c3_failsafe_disarm
	if systemd-run --unit="$FAILSAFE" --collect --on-active="$1" \
			sh "$TEARDOWN" "failsafe-$2" >/dev/null 2>&1; then
		jrn "fail-safe armed: $1 s, phase $2"
	else
		jrn "FAIL-SAFE COULD NOT BE ARMED for phase $2"
		return 1
	fi
	return 0
}

c3_failsafe_disarm() {
	systemctl stop "$FAILSAFE.timer" >/dev/null 2>&1
	systemctl stop "$FAILSAFE.service" >/dev/null 2>&1
	systemctl reset-failed "$FAILSAFE.service" >/dev/null 2>&1
	return 0
}

# ------------------------------------------------------------- the gates --
#
# THE DECISION, ISOLATED. Exit 0 is the ONLY proceed; everything else -- abort,
# timeout, setup error, busy, a code nobody has defined yet, or the binary
# missing entirely -- is an abort. The offline selftest exercises every one of
# those codes against this same rule.
c3_gate() {	# c3_gate <label> <timeout> -> 0 proceed, 1 abort
	if [ "$APPROVE" = "chat" ]; then
		jrn "GATE $1: waiting up to $2 s for the approval in chat -- Volume Down aborts"
		pa_chat_wait "$APPROVE_DIR" "$1" "$2" "$FLAG" >/dev/null
		_g_rc=$?
	else
		jrn "GATE $1: waiting up to $2 s -- Volume Up proceeds, Volume Down aborts"
		"$GATE" --ask --timeout "$2" --label "$1" >>"$JOURNAL" 2>&1
		_g_rc=$?
	fi
	case "$_g_rc" in
	0)	jrn "GATE $1: APPROVED ($APPROVE)" ;;
	1)	jrn "GATE $1: ABORT -- Volume Down" ;;
	2)	jrn "GATE $1: TIMEOUT after $2 s -- treated as abort" ;;
	*)	jrn "GATE $1: exit $_g_rc -- treated as abort" ;;
	esac
	if [ "$_g_rc" != "0" ]; then
		c3_abort "gate-$1-rc$_g_rc"
		return 1
	fi
	#
	# APPROVED AND THE FLAG IS STILL CHECKED. The watcher and the gate read
	# different descriptors, so an abort press that landed just as the
	# approve arrived would otherwise be lost. The abort wins.
	#
	if ! c3_check_flag "gate-$1"; then
		return 1
	fi
	return 0
}

# A flag-checked pause: the automatic steps of a chat cycle still honour
# Volume Down within a second.
c3_pause() {	# c3_pause <seconds> <where> -> 0, or 1 after aborting
	_ps_n=0
	while [ "$_ps_n" -lt "$1" ]; do
		sleep 1
		c3_check_flag "$2" || return 1
		_ps_n=$((_ps_n + 1))
	done
	return 0
}

# --------------------------------------------------------------- the modes --
c3_usage() {
	cat <<EOF
usage: $0 check     preflight only -- resolves devices, verifies the baseline,
                    writes nothing to the codec
       $0 launch    print (and run) the detached systemd-run command
       $0 detached  the run itself; started by launch, not by hand

Holds  : pa-off $HOLD_PA_OFF s, pa-on $HOLD_PA_ON s, tone $HOLD_TONE s
Signal : $DBFS dBFS, $CYCLES cycle(s)
Output : $OUTDIR
EOF
}

# ============================================================== preflight ==
c3_preflight() {	# c3_preflight <arming?>
	_pf_arm=$1
	_pf_bad=""

	[ -n "$GATE" ] || _pf_bad="$_pf_bad no-input-gate"
	[ -n "$TONE" ] || _pf_bad="$_pf_bad no-pcm-tone"
	[ -n "$SETCTL" ] || _pf_bad="$_pf_bad no-alsa-setctl"
	[ -f "$TEARDOWN" ] || _pf_bad="$_pf_bad no-teardown-script"

	_pf_dec=$(pa_instrument_decision "$INSTRUMENT" "$DC_WAIVER" "$CONTROL")
	if [ "$_pf_dec" != "OK" ]; then
		say "INVALID SETUP: ${_pf_dec#REFUSE:}"
		say "  The acoustic instrument cannot measure DC, so it runs only with"
		say "  C3A_DC_WAIVER=operator-waived, set deliberately by the operator."
		return 1
	fi
	case "$APPROVE" in
	chat)
		if [ "$INSTRUMENT" != "acoustic" ]; then
			say "INVALID SETUP: chat approval needs USB connected -- acoustic only"
			return 1
		fi ;;
	buttons)
		if ! "$GATE" --selftest-dwell >/dev/null 2>&1; then
			say "INVALID SETUP: button gates need an input-gate with the dwell."
			say "  Rebuild it: tools/build-c3a-helpers.sh --stage <dir> --force"
			return 1
		fi ;;
	*)
		say "INVALID SETUP: unknown approval mode '$APPROVE'"
		return 1 ;;
	esac
	jrn "instrument $INSTRUMENT  control ${CONTROL:-none}  pa-live-expect $PA_LIVE_EXPECT  approvals $APPROVE"
	if [ "$INSTRUMENT" = "acoustic" ]; then
		jrn "DC CONTRACT NOT MEASURED: waived by the operator ($DC_WAIVER)."
		jrn "  The waveform verdict is the PC-side recording, not this run."
	fi

	#
	# find_devices() exits 2 itself if there is no control function at all,
	# which is the right behaviour -- there is nothing to run against. What
	# is checked here is the r175 attribute, so an OLD module on a correct
	# device is caught by name rather than by a missing-file error later.
	#
	if ! c3_find_codec; then
		_pf_bad="$_pf_bad control-function-has-no-hphl_pa_test"
	fi

	if [ -n "$_pf_bad" ]; then
		say "INVALID SETUP:$_pf_bad"
		return 1
	fi

	require_module_version
	jrn "module version $RUNNING_VERSION (expected $EXPECT_VERSION)"

	#
	# BOTH INPUT DEVICES MUST RESOLVE, BY NAME, RIGHT NOW.
	#
	# Node numbering is not stable across boots -- the touchscreen has
	# re-ordered it before -- so this is done at arm time, every time, and
	# a missing device refuses the whole run rather than arming half an
	# interlock.
	#
	if ! "$GATE" --resolve >>"$JOURNAL" 2>&1; then
		say "INVALID SETUP: the approve and abort devices did not both resolve"
		return 1
	fi
	jrn "input devices resolved by name"

	#
	# THE STIMULUS IS DECLARED BEFORE IT IS USED, AND BEFORE THE PA EXISTS.
	#
	# Section 23 requires each amplitude step to be recorded in the evidence
	# before it is played, not chosen while looking at the scope. --dry-run
	# prints the whole plan without touching the sound card.
	#
	if ! "$TONE" --dbfs "$DBFS" --dry-run >>"$JOURNAL" 2>&1; then
		say "INVALID SETUP: the tone helper refused $DBFS dBFS"
		say "  Anything above -40 dBFS needs a separately armed run."
		return 1
	fi
	jrn "stimulus declared at $DBFS dBFS"

	_pf_g=$(pa_gain_ok "$WCD9320_PA_GAIN_FIELD")
	if [ "$_pf_g" != "OK" ]; then
		say "INVALID SETUP: C3A_GAIN_FIELD=$WCD9320_PA_GAIN_FIELD -- ${_pf_g#REFUSE:}"
		say "  Two lowercase hex digits, 00 (maximum) .. 14 (minimum, the default)."
		return 1
	fi
	if [ ! -e "$PGD/hphl_pa_gain" ]; then
		say "INVALID SETUP: this module has no hphl_pa_gain -- r176 (pa-rc2) or later"
		return 1
	fi
	jrn "gain field $WCD9320_PA_GAIN_FIELD (14 = minimum, 00 = maximum)"

	PRE=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
	DPRE=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
	_pf_pa=$(rv "$PRE" pa_0x1ab)
	[ -n "$_pf_pa" ] || { say "INVALID SETUP: cannot read 0x1ab"; return 1; }

	_pf_masked=$(printf '%02x' $(( 0x$_pf_pa & 0x$WCD9320_PA_MASK )))
	[ "$_pf_masked" = "$WCD9320_PA_STATE_OFF" ] ||
		_pf_bad="$_pf_bad PA_ALREADY_ON=$_pf_pa"
	[ "$(rv "$PRE" guard_tripped)" = "0" ] || _pf_bad="$_pf_bad guard_tripped"
	[ "$(rv "$PRE" pa_on)" = "0" ]         || _pf_bad="$_pf_bad pa_already_on"
	[ "$(rv "$PRE" prep_on)" = "0" ]       || _pf_bad="$_pf_bad prep_already_on"
	[ "$(rv "$DPRE" on)" = "0" ]           || _pf_bad="$_pf_bad dac_already_on"
	[ "$(rv "$DPRE" dac_0x1b1)" = "00" ]   || _pf_bad="$_pf_bad dac_0x1b1_dirty"
	[ "$(rv "$DPRE" dsm_0x3b0)" = "00" ]   || _pf_bad="$_pf_bad dsm_0x3b0_dirty"

	if [ -n "$_pf_bad" ]; then
		say "INVALID SETUP: the analog baseline is not pristine:$_pf_bad"
		say "  Power cycle and run this once."
		return 1
	fi
	jrn "baseline pristine: 0x1ab=$_pf_pa 0x1b1=00 0x3b0=00 guard clean"

	[ "$_pf_arm" = "arm" ] || return 0

	#
	# THE ABORT PATH IS PROVEN ON HARDWARE BEFORE ANYTHING ARMS.
	#
	# A live Volume Down press, read through the same device, stride and key
	# code the watcher will use. Not a simulation. Until this happens no
	# PA-capable run may start -- an interlock nobody has pressed is an
	# assumption, and this is the one assumption that cannot be allowed.
	#
	say ""
	say "  ==> PRESS VOLUME DOWN NOW to prove the abort path."
	say "      Nothing arms until you do. ${HOLD_ARM} s."
	say ""
	jrn "awaiting the arm-time Volume Down press, up to $HOLD_ARM s"
	if ! "$GATE" --selftest-abort --timeout "$HOLD_ARM" --label armtime \
		     >>"$JOURNAL" 2>&1; then
		say "INVALID SETUP: the abort self-test did not see a Volume Down press."
		say "  Nothing was armed and no register was written."
		return 1
	fi
	jrn "ABORT PATH PROVEN ON HARDWARE at arm time"
	return 0
}

# ================================================================= a cycle ==
c3_cycle() {	# c3_cycle <n>
	_cy=$1

	jrn "=== cycle $_cy: begin ==="

	c3_check_flag "cycle-$_cy-start" || return 1

	# P5-P7: gain source, minimum mapped gain, compander-OFF pop/click
	echo prep > "$PGD/hphl_pa_test" 2>/dev/null || {
		jrn "prep REFUSED"; c3_abort "prep-refused"; return 1; }
	jrn "prep applied"
	c3_check_flag "after-prep" || return 1

	# P8-P12 and the DAC, through the D1 path in register-gain mode
	echo on > "$PGD/cdc_clk_prereq" 2>/dev/null || {
		jrn "prereq REFUSED"; c3_abort "prereq-refused"; return 1; }
	jrn "forced 0x314 issued"

	echo rx1-on > "$PGD/rx1_digital_test" 2>/dev/null || {
		jrn "rx1-on REFUSED"; c3_abort "rx1-refused"; return 1; }
	jrn "RX1 digital chain on"

	echo dac-on-reggain > "$PGD/hphl_dac_test" 2>/dev/null || {
		jrn "dac-on-reggain REFUSED"; c3_abort "dac-refused"; return 1; }
	jrn "HPHL DAC path up in register-gain mode"

	eval "C${_cy}_DAC=\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)"
	eval "C${_cy}_DDAC=\$(cat \"\$PGD/hphl_dac_state\" 2>/dev/null)"
	eval "jrn \"state after DAC: \$(rv \"\$C${_cy}_DAC\" pa_0x1ab) \$(rv \"\$C${_cy}_DAC\" lgain_0x1ae) \$(rv \"\$C${_cy}_DAC\" dac_0x1b1)\""

	#
	# THE ABORT GATE OF SECTION 16, CHECKED BEFORE 0x1ab IS TOUCHED AT ALL.
	#
	# Every one of these must hold or the run tears down without ever
	# writing the PA register. The gain is checked as a FIELD, not a whole
	# register: 0x1ae carries bits this run does not own.
	#
	eval "_cy_st=\$C${_cy}_DAC"
	eval "_cy_dst=\$C${_cy}_DDAC"
	_cy_bad=""
	[ "$(printf '%02x' $(( 0x$(rv "$_cy_st" lgain_0x1ae) & 0x3f )))" = \
	  "$(printf '%02x' $(( 0x20 | 0x$WCD9320_PA_GAIN_FIELD )))" ] ||
		_cy_bad="$_cy_bad gain=$(rv "$_cy_st" lgain_0x1ae)"
	[ "$(rv "$_cy_st" dac_0x1b1)" = "c0" ] ||
		_cy_bad="$_cy_bad dac=$(rv "$_cy_st" dac_0x1b1)"
	[ "$(rv "$_cy_dst" dsm_0x3b0)" = "14" ] ||
		_cy_bad="$_cy_bad dsm=$(rv "$_cy_dst" dsm_0x3b0)"
	[ "$(printf '%02x' $(( 0x$(rv "$_cy_dst" bias_0x1a2) & 0x80 )))" = "80" ] ||
		_cy_bad="$_cy_bad bias=$(rv "$_cy_dst" bias_0x1a2)"
	[ "$(rv "$_cy_st" clsh_0x320)" = "$WCD9320_PA_CLSH_LIVE" ] ||
		_cy_bad="$_cy_bad clsh=$(rv "$_cy_st" clsh_0x320)"
	[ "$(rv "$_cy_st" wgctl_0x1ac)" = "db" ] ||
		_cy_bad="$_cy_bad wgctl=$(rv "$_cy_st" wgctl_0x1ac)"
	[ "$(rv "$_cy_st" wgtime_0x1ad)" = "58" ] ||
		_cy_bad="$_cy_bad wgtime=$(rv "$_cy_st" wgtime_0x1ad)"
	[ "$(rv "$_cy_st" wgocp_0x1a9)" = "1a" ] ||
		_cy_bad="$_cy_bad wgocp=$(rv "$_cy_st" wgocp_0x1a9)"
	[ "$(printf '%02x' $(( 0x$(rv "$_cy_st" chop_0x1a5) & 0x80 )))" = "00" ] ||
		_cy_bad="$_cy_bad chop=$(rv "$_cy_st" chop_0x1a5)"
	[ "$(printf '%02x' $(( 0x$(rv "$_cy_st" pa_0x1ab) & 0x$WCD9320_PA_MASK )))" \
	  = "$WCD9320_PA_STATE_OFF" ] || _cy_bad="$_cy_bad pa=$(rv "$_cy_st" pa_0x1ab)"
	[ "$(rv "$_cy_st" ocp_seen)" = "0" ] || _cy_bad="$_cy_bad ocp_already_seen"

	if [ -n "$_cy_bad" ]; then
		jrn "SECTION 16 ABORT GATE FAILED:$_cy_bad"
		jrn "the PA register was never written"
		c3_abort "abort-gate-failed"
		return 1
	fi
	jrn "section 16 abort gate PASSED -- the PA may now be enabled"

	# ---------------------------------------------- stage 1: DC, PA off --
	say ""
	if [ "$INSTRUMENT" = "acoustic" ]; then
		say "  ==> The PA is OFF. Earbuds OUT of everyone's ears, one earbud"
		say "      against the USB microphone, the PC recording running."
		[ "$CONTROL" = "pa-off" ] &&
			say "      CONTROL RUN: approving will NOT enable the PA."
		if [ "$APPROVE" = "chat" ]; then
			say "      Approve in chat to continue; Volume Down aborts."
		else
			say "      Volume Up to continue, Volume Down to abort."
		fi
		jrn "HOLD stage-1 ($INSTRUMENT) with the PA OFF, up to $HOLD_PA_OFF s"
	else
		say "  ==> MEASURE DC AT HPHL NOW. The PA is OFF."
		say "      Contract: |Voff| <= 100 mV. Record it; it is the reference."
		say "      Volume Up to enable the PA, Volume Down to abort."
		jrn "HOLD stage-1 DC with the PA OFF, up to $HOLD_PA_OFF s"
	fi
	say ""
	c3_gate "dc-pa-off-c$_cy" "$HOLD_PA_OFF" || return 1

	# ------------------------------------------------ the PA goes live --
	#
	# The fail-safe is armed BEFORE the enable, not after. The window it has
	# to cover includes the enable itself.
	#
	if [ "$CONTROL" = "pa-off" ]; then
		#
		# THE NEGATIVE CONTROL. Everything up to here is the real run --
		# prep, forced writes, DAC at 0xC0 -- and everything after it is
		# too, stimulus included. Only this write is withheld, so a tone
		# heard here would be reaching the jack some way other than the PA.
		#
		jrn "CONTROL: the PA is deliberately NOT enabled on this run"
	else
		if [ "$APPROVE" = "chat" ]; then
			_cy_fs=$FAILSAFE_CHAT
		else
			_cy_fs=$((HOLD_PA_ON + FAILSAFE_PAD))
		fi
		c3_failsafe_arm "$_cy_fs" "pa-on-c$_cy" || {
			c3_abort "failsafe-unavailable"; return 1; }

		echo pa-on > "$PGD/hphl_pa_test" 2>/dev/null || {
			jrn "pa-on REFUSED by the driver"; c3_abort "pa-on-refused"; return 1; }
		jrn "PA ENABLED"
	fi

	eval "C${_cy}_PA=\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)"
	eval "_cy_st=\$C${_cy}_PA"
	_cy_pa=$(printf '%02x' $(( 0x$(rv "$_cy_st" pa_0x1ab) & 0x$WCD9320_PA_MASK )))
	jrn "0x1ab=$(rv "$_cy_st" pa_0x1ab) masked=$_cy_pa expected=$PA_LIVE_EXPECT"
	jrn "INTR_STATUS2=$(rv "$_cy_st" intr2_0x09a) ocp_seen=$(rv "$_cy_st" ocp_seen)"

	if [ "$_cy_pa" != "$PA_LIVE_EXPECT" ]; then
		jrn "THE PA IS NOT IN THE ONE LEGAL LIVE STATE"
		c3_abort "pa-state-$_cy_pa"
		return 1
	fi
	if [ "$(rv "$_cy_st" ocp_seen)" != "0" ]; then
		jrn "OCP FAULT -- hard abort"
		c3_abort "ocp-fault"
		return 1
	fi
	c3_check_flag "after-pa-on" || return 1

	# ---------------------------------------------- stage 2: DC, PA on --
	if [ "$APPROVE" = "chat" ]; then
		#
		# AUTOMATIC FROM HERE. The amplifier is on because the operator
		# approved it; nothing after this needs a human, and holding the PA
		# open at a gate only lengthens the time it is live.
		#
		jrn "AUTO: ${CONTROL:+(control, PA off) }2 s for any switch-on pop, then the tone"
		c3_pause 2 "settle-c$_cy" || return 1
	else
	say ""
	if [ "$INSTRUMENT" = "acoustic" ]; then
		say "  ==> The PA is ${CONTROL:+NOT }LIVE. Listen at the earbud, not in"
		say "      the ear: a loud thump, buzz or hum now is a Volume Down."
		say "      Volume Up to play the tone, Volume Down to tear down."
		jrn "HOLD stage-2 ($INSTRUMENT) after the PA step, up to $HOLD_PA_ON s"
	else
		say "  ==> MEASURE DC AGAIN. The PA is LIVE."
		say "      Contract: |Von - Voff| <= 50 mV, drift <= 10 mV over 250 ms."
		say "      Hard abort at |DC| >= 250 mV."
		say "      Volume Up to play the tone, Volume Down to tear down."
		jrn "HOLD stage-2 DC with the PA ON, up to $HOLD_PA_ON s"
	fi
	say ""
	c3_gate "dc-pa-on-c$_cy" "$HOLD_PA_ON" || return 1
	fi

	# ------------------------------------------------------- the tone --
	if [ "$CONTROL" != "pa-off" ] && [ "$APPROVE" != "chat" ]; then
		c3_failsafe_arm $((HOLD_TONE + FAILSAFE_PAD)) "tone-c$_cy" || {
			c3_abort "failsafe-unavailable"; return 1; }
	fi

	jrn "tone: 1 kHz, $DBFS dBFS, 250 ms tone/silence/tone/silence, one stream"
	"$TONE" -D "${PCMDEV:-/dev/snd/pcmC0D0p}" --dbfs "$DBFS" >>"$JOURNAL" 2>&1
	eval "C${_cy}_TONE_RC=\$?"
	eval "jrn \"tone finished rc=\$C${_cy}_TONE_RC\""

	eval "C${_cy}_POST=\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)"
	eval "_cy_st=\$C${_cy}_POST"
	jrn "after tone: 0x1ab=$(rv "$_cy_st" pa_0x1ab) intr2=$(rv "$_cy_st" intr2_0x09a) ocp=$(rv "$_cy_st" ocp_seen)"
	if [ "$(rv "$_cy_st" ocp_seen)" != "0" ]; then
		jrn "OCP FAULT during the tone -- hard abort"
		c3_abort "ocp-fault-tone"
		return 1
	fi
	c3_check_flag "after-tone" || return 1

	if [ "$APPROVE" = "chat" ]; then
		jrn "AUTO: 1 s, then the PA off"
		c3_pause 1 "post-tone-c$_cy" || return 1
	else
		say ""
		say "  ==> The stimulus was tone / silence / tone / silence, one uninterrupted"
		say "      stream, with the PA and every register unchanged throughout."
		say "      Did the output follow it? Volume Up to tear down and continue."
		say ""
		jrn "HOLD post-tone, up to $HOLD_TONE s"
		c3_gate "post-tone-c$_cy" "$HOLD_TONE" || return 1
	fi

	# --------------------------------------------------------- teardown --
	echo pa-off > "$PGD/hphl_pa_test" 2>/dev/null
	jrn "PA disabled"
	eval "C${_cy}_PAOFF=\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)"
	eval "_cy_st=\$C${_cy}_PAOFF"
	_cy_pa=$(printf '%02x' $(( 0x$(rv "$_cy_st" pa_0x1ab) & 0x$WCD9320_PA_MASK )))
	jrn "0x1ab=$(rv "$_cy_st" pa_0x1ab) masked=$_cy_pa expected=$WCD9320_PA_STATE_OFF"

	#
	# THE FAIL-SAFE IS CANCELLED ONLY HERE, and only on a CHIP-VERIFIED
	# reading of both PA bits clear. Cancelling it on "the write returned 0"
	# would disarm the thing that exists because a write can return 0 and
	# the world still be wrong.
	#
	if [ "$_cy_pa" = "$WCD9320_PA_STATE_OFF" ]; then
		c3_failsafe_disarm
		jrn "fail-safe disarmed: the PA is chip-verified off"
	else
		jrn "PA NOT OFF AFTER pa-off -- leaving the fail-safe armed"
		c3_abort "pa-stuck-$_cy_pa"
		return 1
	fi

	echo dac-off-reggain > "$PGD/hphl_dac_test" 2>/dev/null
	echo off > "$PGD/cdc_clk_prereq" 2>/dev/null
	echo rx1-off > "$PGD/rx1_digital_test" 2>/dev/null
	echo unprep > "$PGD/hphl_pa_test" 2>/dev/null
	jrn "DAC, forced inverses, RX1 and prep all torn down"

	eval "C${_cy}_AFTER=\$(cat \"\$PGD/hphl_pa_state\" 2>/dev/null)"
	eval "C${_cy}_DAFTER=\$(cat \"\$PGD/hphl_dac_state\" 2>/dev/null)"
	jrn "=== cycle $_cy: complete ==="
	return 0
}

# =================================================================== main ==
case "$ACTION" in
check)
	resolve_expectations
	say "=== C3a preflight (nothing is written to the codec) ==="
	if c3_preflight noarm; then
		say ""
		say "READY. Helpers:"
		say "  input-gate : $GATE"
		say "  pcm-tone   : $TONE"
		say "  teardown   : $TEARDOWN"
		say "  codec      : $PGD"
		say "  evidence   : $OUTDIR"
		say ""
		say "Next: $0 launch"
		exit 0
	fi
	exit 2
	;;

launch)
	#
	# DETACHMENT, AND WHY IT IS THIS AND NOT nohup.
	#
	# PID 1 is systemd and logind kills the user session cgroup on logout,
	# so nohup AND setsid both die with the ssh session -- established on
	# this device, not assumed. A transient systemd-run unit survives, and
	# being transient it is also not a boot service: it exists only because
	# it was explicitly armed, and --collect makes it vanish when it exits.
	#
	CMD="systemd-run --unit=$UNIT --collect --setenv=OUTDIR=$OUTDIR"
	CMD="$CMD --setenv=DBFS=$DBFS --setenv=HOLD_PA_OFF=$HOLD_PA_OFF"
	CMD="$CMD --setenv=C3A_GAIN_FIELD=$WCD9320_PA_GAIN_FIELD"
	CMD="$CMD --setenv=HOLD_PA_ON=$HOLD_PA_ON --setenv=HOLD_TONE=$HOLD_TONE"
	CMD="$CMD --setenv=HOLD_ARM=$HOLD_ARM --setenv=CYCLES=$CYCLES"
	CMD="$CMD --setenv=C3A_INSTRUMENT=$INSTRUMENT"
	CMD="$CMD --setenv=C3A_DC_WAIVER=$DC_WAIVER --setenv=C3A_CONTROL=$CONTROL"
	CMD="$CMD --setenv=C3A_APPROVE=$APPROVE"
	CMD="$CMD --setenv=EXPECT_VERSION=${EXPECT_VERSION:-} sh $DIR/$(basename "$0") detached"
	say "The run detaches into a transient unit so it survives losing ssh."
	say ""
	say "  $CMD"
	say ""
	say "Follow it with:  journalctl -u $UNIT -f"
	say "Or read:         $JOURNAL"
	say ""
	if [ "${C3A_PRINT_ONLY:-0}" = "1" ]; then
		exit 0
	fi
	exec $CMD
	;;

detached)
	;;

*)
	c3_usage
	exit 2
	;;
esac

# ------------------------------------------------------------- the run --
resolve_expectations

#
# SINGLE ARM. Two runs would fight over the codec and two watchers would each
# independently trigger a teardown.
#
if command -v flock >/dev/null 2>&1; then
	exec 9>"$RUNLOCK"
	flock -n 9 || { say "INVALID SETUP: another C3a run holds $RUNLOCK"; exit 2; }
fi

jrn "================ C3a run $STAMP ================"
jrn "holds: pa-off $HOLD_PA_OFF s, pa-on $HOLD_PA_ON s, tone $HOLD_TONE s"
jrn "stimulus $DBFS dBFS, $CYCLES cycle(s)"

#
# THE TRAP IS INSTALLED BEFORE ANYTHING IS TOUCHED. If this script is killed
# from here on, the teardown runs.
#
trap 'jrn "SIGNAL -- running the teardown"; c3_abort signal; exit 3' \
	INT TERM HUP

if ! c3_preflight arm; then
	jrn "preflight refused -- nothing was armed and nothing was written"
	exit 2
fi

#
# THE GAIN FIELD, set BEFORE anything is armed and read back from the driver.
# If the driver refuses it, the run ends here with nothing powered.
#
if ! echo "$WCD9320_PA_GAIN_FIELD" > "$PGD/hphl_pa_gain" 2>/dev/null; then
	jrn "the driver REFUSED gain field $WCD9320_PA_GAIN_FIELD -- nothing was armed"
	exit 2
fi
_g_back=$(sed -n 's/^gain_field=\([0-9a-f]*\).*/\1/p' "$PGD/hphl_pa_gain" 2>/dev/null)
if [ "$_g_back" != "$WCD9320_PA_GAIN_FIELD" ]; then
	jrn "gain field reads back ${_g_back:-nothing}, not $WCD9320_PA_GAIN_FIELD -- nothing was armed"
	exit 2
fi
jrn "gain field $WCD9320_PA_GAIN_FIELD set and read back"

#
# THE FORCED-WRITE JOURNAL, MEASURED AT THE START OF THIS RUN.
#
# The report used to assume the journal began empty, which is true only on the
# first run of a boot. A control run followed by a real run on the same boot --
# exactly the sequence the acoustic plan uses -- would see 4 + 8 entries and
# fail a correct run. So this run's entries are checked from where the journal
# stood when it started: baseline-relative, like every other expectation here.
#
# The driver's ring holds 16 entries. If this run's would not all fit, the
# entries could not be checked at all, so the run refuses before arming.
#
FORCED_START=$(rv "$(cat "$PGD/forced_log" 2>/dev/null)" forced_n)
FORCED_START=${FORCED_START:-0}
FORCED_RING=$(sed -n 's/.*ring=\([0-9]*\).*/\1/p' "$PGD/forced_log" 2>/dev/null | head -n1)
FORCED_RING=${FORCED_RING:-16}
if [ $(( FORCED_START + WCD9320_PA_FORCED_PER_CYCLE * CYCLES )) -gt "$FORCED_RING" ]; then
	jrn "the forced-write journal holds $FORCED_START of $FORCED_RING -- this run's entries would not fit; power cycle first. Nothing was armed."
	exit 2
fi
jrn "forced-write journal starts this run at $FORCED_START of $FORCED_RING"

#
# The approval drop-box. Emptied at the start of every run, and each gate also
# deletes its own file as it opens, so nothing written before can count.
#
if [ "$APPROVE" = "chat" ]; then
	mkdir -p "$APPROVE_DIR" && rm -f "$APPROVE_DIR"/* 2>/dev/null
	jrn "chat approvals via $APPROVE_DIR"
fi

c3_watch_start || exit 2

"$SETCTL" -D "$CTLDEV" --set "$MIXER" 1 >/dev/null 2>&1
jrn "front-end mixer enabled"

RC=0
n=1
while [ "$n" -le "$CYCLES" ]; do
	if ! c3_cycle "$n"; then
		RC=3
		break
	fi
	n=$((n + 1))
done

c3_failsafe_disarm
c3_watch_stop

POST=$(cat "$PGD/hphl_pa_state" 2>/dev/null)
DPOST=$(cat "$PGD/hphl_dac_state" 2>/dev/null)
FLOG=$(cat "$PGD/forced_log" 2>/dev/null)

open_output "$OUTDIR/wcd9320-hphl-pa-$STAMP.txt"
{
	hdr "what this run can and cannot establish"
	say "The milestone is point 1 of section 24: a waveform at HPHL whose"
	say "frequency tracks the 1 kHz digital stimulus, present during the tone"
	say "segments and absent during the silent ones, across two cycles."
	say ""
	say "THAT IS AN OBSERVATION ON A SCOPE. It is not in this file, and no"
	say "check below can supply it. Everything here is a PRECONDITION for"
	say "believing that observation -- correct sequencing, a guard that never"
	say "tripped, a complete teardown. Correct PA register sequencing without"
	say "a measured waveform earns NO TAG."

	hdr "the run"
	say "aborted     : $ABORTED $ABORT_WHY"
	say "cycles run  : $((n - 1)) of $CYCLES"
	say "stimulus    : $DBFS dBFS, 1 kHz, tone/silence/tone/silence, one stream"
	say "gain field  : $WCD9320_PA_GAIN_FIELD  (0x1ae[4:0]; 14 = minimum, 00 = maximum)"
	say "instrument  : $INSTRUMENT"
	say "control     : ${CONTROL:-none (the PA is enabled)}"
	if [ "$INSTRUMENT" = "acoustic" ]; then
		say "DC contract : NOT MEASURED -- waived by the operator ($DC_WAIVER)"
		say "waveform    : decided by tools/c3a-capture.py on the PC recording"
	fi

	hdr "the PA, at every boundary"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_r=\$(rv \"\$C${c}_DAC\" pa_0x1ab)"
		eval "_o=\$(rv \"\$C${c}_PA\" pa_0x1ab)"
		eval "_f=\$(rv \"\$C${c}_PAOFF\" pa_0x1ab)"
		say "cycle $c   before $_r   live $_o   after $_f   (predicted 80 a0 80)"
		c=$((c + 1))
	done

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "the run was not aborted" "$ABORTED" "0"
	check "cycles completed" "$((n - 1))" "$CYCLES"

	say ""
	say "-- the PA reached its one legal live state, and came back --"
	c=1
	while [ "$c" -lt "$n" ]; do
		eval "_o=\$(rv \"\$C${c}_PA\" pa_0x1ab)"
		eval "_f=\$(rv \"\$C${c}_PAOFF\" pa_0x1ab)"
		check "c$c PA live masked" \
		      "$(printf '%02x' $(( 0x${_o:-00} & 0x$WCD9320_PA_MASK )))" \
		      "$PA_LIVE_EXPECT"
		check "c$c HPHR stayed clear" \
		      "$(printf '%02x' $(( 0x${_o:-00} & 0x10 )))" "00"
		check "c$c PA off after" \
		      "$(printf '%02x' $(( 0x${_f:-ff} & 0x$WCD9320_PA_MASK )))" \
		      "$WCD9320_PA_STATE_OFF"
		c=$((c + 1))
	done
	check "guard never tripped" "$(rv "$POST" guard_tripped)" "0"
	check "no OCP fault at any point" "$(rv "$POST" ocp_seen)" "0"
	check "PA enables == disables" "$(rv "$POST" enables)" "$(rv "$POST" disables)"

	say ""
	say "-- the class-H and POST_PA registers stay PROGRAMMED --"
	#
	# DERIVED FROM THE MEASURED BASELINE, PER MODE -- never hardcoded.
	#
	# The first version asserted 08/00/ce, the end state of a REAL run, and
	# the first CONTROL run failed it while doing exactly what the source
	# says: with the PA step skipped, only the class-H writes apply, and
	# those leave 28/02/c2. The real run's end state is column 6 of the
	# derivation (after POST_PA); a control run's is column 4 (after the DAC
	# step), because nothing after it touches these registers.
	#
	_pp_exp="/tmp/.c3a-postpa-$$"
	pa_derive "$PRE $DPRE" "$_pp_exp"
	if [ "$CONTROL" = "pa-off" ]; then _pp_col=4; else _pp_col=6; fi
	for _pp_k in ncps_0x194 buck5_0x185 buck3_0x183; do
		_pp_w=$(awk -v k="$_pp_k" -v c="$_pp_col" '$1 == k { print $c }' "$_pp_exp")
		check "$_pp_k stays programmed" "$(rv "$POST" "$_pp_k")" "$_pp_w"
	done
	rm -f "$_pp_exp"

	say ""
	say "-- the forced writes, both directions, every cycle --"
	note "journal start" "this run's entries begin at f$FORCED_START"
	check "forced operations this run" \
	      "$(( $(rv "$FLOG" forced_n) - FORCED_START ))" \
	      "$(( WCD9320_PA_FORCED_PER_CYCLE * (n - 1) ))"
	_i=0
	while [ "$_i" -lt "$(( WCD9320_PA_FORCED_PER_CYCLE * (n - 1) ))" ]; do
		case $((_i % 4)) in
		0) _wr=314; _wd=set   ;;
		1) _wr=30d; _wd=set   ;;
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
	check "OCP_CTL never written" "$(rv "$POST" ocpctl_0x1aa)" "$(rv "$PRE" ocpctl_0x1aa)"
	check "DAC off" "$(rv "$DPOST" dac_0x1b1)" "00"
	check "DSM mux cleared" "$(rv "$DPOST" dsm_0x3b0)" "00"
	check "RX bias released" "$(rv "$DPOST" bias_refs)" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ] && [ "$ABORTED" = "0" ]; then
		say "THE PA CONTROL PATH SEQUENCED AND REVERSED CLEANLY."
		say ""
		say "That is ALL this file establishes. It is the same class of"
		say "result as D1, one stage further along, and it earns no tag."
		say ""
		say "THE MILESTONE IS THE SCOPE TRACE, and it is not here:"
		say "  a waveform at HPHL at the stimulus frequency,"
		say "  present during the tone segments and ABSENT during the"
		say "  silent ones, with the stream and the PA unchanged,"
		say "  reproduced across both cycles, DC in band at every stage."
		say ""
		say "Award wcd9320-hphl-electrical-proven ONLY if the operator's"
		say "recorded measurements satisfy all of that. If the trace was"
		say "flat, this run is a clean negative: the control path is"
		say "correct and the conversion is still unproven."
	elif [ "$ABORTED" != "0" ]; then
		say "ABORTED: $ABORT_WHY"
		say ""
		say "The mapped teardown ran. Check PA_AFTER_TEARDOWN in the"
		say "journal before doing anything else -- if 0x1ab masked is not"
		say "00, power cycle the phone rather than starting another run."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "Every expectation here is derived in wcd9320-hphl-pa-expect.sh"
		say "and that derivation passes its own offline selftest. A"
		say "mismatch means the mapping is wrong -- revisit it rather than"
		say "adjusting the expectation to match what the hardware did."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

sync 2>/dev/null
jrn "evidence written to $OUT"

[ "$ABORTED" = "0" ] || exit 3
[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] ||
	exit 1
exit "$RC"

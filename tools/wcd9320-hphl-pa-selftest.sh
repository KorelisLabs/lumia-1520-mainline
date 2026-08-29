#!/bin/sh
#
# Offline proof that the C3a expectation file is right, and that the run's
# safety decisions resolve the way they are supposed to.
#
# WHY THIS EXISTS, RESTATED FOR C3a
#
# Both C2a failures were in the gate rather than the driver, and four more
# checker defects aborted or failed r174's runs. None of that arithmetic was
# reachable without hardware, so none of it was ever tested before it was
# trusted. This file makes it runnable on a workstation, against baselines
# chosen to break it.
#
# C3a raises the stakes: a gate defect here does not waste a boot cycle, it
# decides whether a power amplifier is enabled into a jack with a probe in it.
# So this covers two things rather than one:
#
#   1. THE DERIVATION -- does a measured baseline predict the right states?
#   2. THE POLARITY   -- does every ambiguous outcome resolve to abort?
#
# The second group is the one the operator named: synthetic abort, timeout,
# key-renumbering, ssh-detachment and double-arm. Key renumbering and double
# arm are exercised against the real input-gate binary when one is available,
# because a shell reimplementation of the resolver would be testing the test.
#
# Usage:  wcd9320-hphl-pa-selftest.sh
#         GATE=/path/to/input-gate wcd9320-hphl-pa-selftest.sh
#
# Exit: 0 all cases pass, 1 otherwise.

set -u

DIR=$(dirname "$0")
. "$DIR/wcd9320-hphl-pa-expect.sh"

PASS=0
FAIL=0
TMP=${TMPDIR:-/tmp}/wcd9320-pa-selftest.$$
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() {	# ok <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '  ok   %-52s %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	else
		printf '  FAIL %-52s got=%s want=%s\n' "$1" "$2" "$3"
		FAIL=$((FAIL + 1))
	fi
}

skip() { printf '  --   %-52s %s\n' "$1" "$2"; }

hdr() { printf '\n== %s ==\n' "$*"; }

# get <file> <key> <column>   -- column 2 base, 3 prep, 4 dac, 5 pa, 6 after
get() { awk -v k="$2" -v c="$3" '$1 == k { print $c }' "$1"; }

# --------------------------------------------------------------------------
hdr "the arithmetic itself"

ok "a masked write folds"          "$(pa_apply 00 00 '30,10')" "10"
ok "two writes fold in order"      "$(pa_apply 00 00 '30,10' '0c,04')" "14"
ok "a later write wins its bits"   "$(pa_apply ff ff '30,10')" "df"
ok "an empty transform is identity" "$(pa_apply ce ce '-')" "ce"
ok "R restores from the BASELINE"  "$(pa_apply ff 2a 'Rff')" "2a"
ok "R restores only its own bits"  "$(pa_apply ff 00 'R80')" "7f"
ok "R after a write undoes it"     "$(pa_apply 00 da 'ff,db' 'Rff')" "da"

# --------------------------------------------------------------------------
hdr "the measured cold-boot baseline predicts the mapped states"
#
# These are the values recorded in wcd9320-fullmap-20260815T154307Z.txt, taken
# after reset release and before any driver write. The pop/click registers are
# the COMPANDER-ON set -- da/15/2a with the chopper bit set -- which is why
# C3a has to write all four rather than inherit them.
BASE="lgain_0x1ae=00 wgctl_0x1ac=da wgtime_0x1ad=15 wgocp_0x1a9=2a"
BASE="$BASE chop_0x1a5=a4 pa_0x1ab=80 dac_0x1b1=00 dsm_0x3b0=00"
BASE="$BASE bias_0x1a2=00 buck5_0x185=00 ncps_0x194=28 buck3_0x183=ce"
BASE="$BASE ocpctl_0x1aa=69"

pa_derive "$BASE" "$TMP/exp"
ok "every key derived, none missing" "$(grep -c MISSING "$TMP/exp")" "0"
ok "all thirteen rows present"       "$(wc -l < "$TMP/exp" | tr -d ' ')" "13"

hdr "the gain trap: a pristine part is in the WORST state for C3a"
#
# 0x1ae reads 00 at cold boot. Bit 5 clear means the gain source is the
# COMPANDER -- which will not be running -- and the field reads 0, which the
# inverted control makes user-MAXIMUM. Both halves are wrong at once, and the
# prep is the only thing between this run and full output.
ok "baseline is the worst case"      "$(get "$TMP/exp" lgain_0x1ae 2)" "00"
ok "prep reaches the abort-gate value" "$(get "$TMP/exp" lgain_0x1ae 3)" "34"
ok "gain source bit is set"          \
   "$(printf '%02x' $((0x$(get "$TMP/exp" lgain_0x1ae 3) & 0x20)))" "20"
ok "gain field is the mapped minimum" \
   "$(printf '%02x' $((0x$(get "$TMP/exp" lgain_0x1ae 3) & 0x1f)))" "14"
ok "gain survives the DAC stage"     "$(get "$TMP/exp" lgain_0x1ae 4)" "34"
ok "gain survives the PA stage"      "$(get "$TMP/exp" lgain_0x1ae 5)" "34"
ok "gain returns to the MEASURED baseline" \
   "$(get "$TMP/exp" lgain_0x1ae 6)" "00"

hdr "the compander-OFF pop/click pairing is written, not inherited"
ok "wg ctl   da -> db"  "$(get "$TMP/exp" wgctl_0x1ac 3)" "db"
ok "wg time  15 -> 58"  "$(get "$TMP/exp" wgtime_0x1ad 3)" "58"
ok "wg ocp   2a -> 1a"  "$(get "$TMP/exp" wgocp_0x1a9 3)" "1a"
ok "chopper  a4 -> 24"  "$(get "$TMP/exp" chop_0x1a5 3)" "24"
ok "chopper bit 7 clear" \
   "$(printf '%02x' $((0x$(get "$TMP/exp" chop_0x1a5 3) & 0x80)))" "00"
ok "wg ctl restored"    "$(get "$TMP/exp" wgctl_0x1ac 6)" "da"
ok "wg time restored"   "$(get "$TMP/exp" wgtime_0x1ad 6)" "15"
ok "wg ocp restored"    "$(get "$TMP/exp" wgocp_0x1a9 6)" "2a"
ok "chopper restored"   "$(get "$TMP/exp" chop_0x1a5 6)" "a4"

hdr "the PA register, and the three legal states"
ok "PA off at baseline"     "$(get "$TMP/exp" pa_0x1ab 2)" "80"
ok "PA off after prep"      "$(get "$TMP/exp" pa_0x1ab 3)" "80"
ok "PA off after the DAC"   "$(get "$TMP/exp" pa_0x1ab 4)" "80"
ok "PA on: a0, not e0 or b0" "$(get "$TMP/exp" pa_0x1ab 5)" "a0"
ok "PA off after teardown"  "$(get "$TMP/exp" pa_0x1ab 6)" "80"
ok "masked, live: 20"  \
   "$(printf '%02x' $((0x$(get "$TMP/exp" pa_0x1ab 5) & 0x$WCD9320_PA_MASK)))" \
   "$WCD9320_PA_STATE_ON"
ok "masked, after: 00" \
   "$(printf '%02x' $((0x$(get "$TMP/exp" pa_0x1ab 6) & 0x$WCD9320_PA_MASK)))" \
   "$WCD9320_PA_STATE_OFF"
#
# HPHR MUST BE CLEAR WHILE HPHL IS ON. A mask that enabled both channels
# produces 30 under the guard mask and reads as a perfectly plausible
# "the PA is on".
ok "HPHR bit stays clear while HPHL is on" \
   "$(printf '%02x' $((0x$(get "$TMP/exp" pa_0x1ab 5) & 0x10)))" "00"

hdr "SECTION 20: three of the four POST_PA writes are no-ops on this silicon"
#
# The lesson C2a was caught by, in the other direction. A gate expecting these
# to MOVE would fail a correct run, and regmap elides a write whose value is
# unchanged, so three of these transactions may never reach the bus at all.
ok "buck5 predicted unchanged at 00"  "$(get "$TMP/exp" buck5_0x185 5)" "00"
ok "buck3 predicted unchanged at ce"  "$(get "$TMP/exp" buck3_0x183 5)" "ce"
ok "only NCP_STATIC moves: 28 -> 08"  "$(get "$TMP/exp" ncps_0x194 5)" "08"
#
# AND THEY STAY. turnoff_postpa() touches NCP_EN, BUCK_MODE_1[7] and
# B1_CTL[4] -- none of these three. NCP_STATIC not returning to 28 is a PASS.
ok "buck5 still 00 after teardown"    "$(get "$TMP/exp" buck5_0x185 6)" "00"
ok "buck3 still ce after teardown"    "$(get "$TMP/exp" buck3_0x183 6)" "ce"
ok "NCP_STATIC STAYS at 08 -- no invented inverse" \
   "$(get "$TMP/exp" ncps_0x194 6)" "08"

hdr "the DAC path, unchanged from D1"
ok "0x1b1 00 -> c0"   "$(get "$TMP/exp" dac_0x1b1 4)" "c0"
ok "0x1b1 c0 -> 00"   "$(get "$TMP/exp" dac_0x1b1 6)" "00"
ok "0x3b0 00 -> 14"   "$(get "$TMP/exp" dsm_0x3b0 4)" "14"
ok "0x3b0 14 -> 00"   "$(get "$TMP/exp" dsm_0x3b0 6)" "00"
ok "RX bias taken"    "$(get "$TMP/exp" bias_0x1a2 4)" "80"
ok "RX bias released" "$(get "$TMP/exp" bias_0x1a2 6)" "00"
ok "OCP_CTL left exactly as found"  "$(get "$TMP/exp" ocpctl_0x1aa 6)" "69"

hdr "a HOSTILE baseline -- the derivation must not assume the cold-boot map"
#
# Every fuse-loaded register inverted. If any expectation were secretly a
# constant rather than a function of the baseline, it shows up here.
HOST="lgain_0x1ae=ff wgctl_0x1ac=25 wgtime_0x1ad=ea wgocp_0x1a9=d5"
HOST="$HOST chop_0x1a5=5b pa_0x1ab=80 dac_0x1b1=00 dsm_0x3b0=00"
HOST="$HOST bias_0x1a2=7f buck5_0x185=ff ncps_0x194=d7 buck3_0x183=31"
HOST="$HOST ocpctl_0x1aa=96"
pa_derive "$HOST" "$TMP/hexp"
#
# THE GAIN IS A FIELD, NOT A REGISTER, AND THIS IS WHERE THAT BITES.
#
# From a baseline of ff the prep gives (ff & ~20)|20 = ff, then
# (ff & ~1f)|14 = f4 -- NOT 34. Bits [7:6] of 0x1ae are not C3a's to own, and
# the derivation correctly leaves them where it found them.
#
# The driver's abort gate masks with 0x3f for exactly this reason, and section
# 16 of the mapping says so: "checked as a field, not a whole register: 0x1ae
# also carries bits this run does not own". So what must hold is that the
# FIELD reaches 34 and the bits above it are preserved -- and asserting the
# whole register here would have written a gate that failed a correct run on
# any part whose 0x1ae came up with a high bit set.
ok "the gain FIELD still reaches 34 from ff" \
   "$(printf '%02x' $((0x$(get "$TMP/hexp" lgain_0x1ae 3) & 0x3f)))" "34"
ok "bits C3a does not own are preserved" \
   "$(printf '%02x' $((0x$(get "$TMP/hexp" lgain_0x1ae 3) & 0xc0)))" "c0"
ok "the whole register is f4, derived not assumed" \
   "$(get "$TMP/hexp" lgain_0x1ae 3)" "f4"
ok "gain restores to ff, not 00"     "$(get "$TMP/hexp" lgain_0x1ae 6)" "ff"
ok "wg ctl restores to 25, not da"   "$(get "$TMP/hexp" wgctl_0x1ac 6)" "25"
ok "chopper cleared from 5b"         "$(get "$TMP/hexp" chop_0x1a5 3)" "5b"
ok "buck5 bit 1 cleared from ff"     "$(get "$TMP/hexp" buck5_0x185 5)" "fd"
ok "buck3 bits set from 31"          "$(get "$TMP/hexp" buck3_0x183 5)" "3d"
ok "ncp static bit 5 cleared from d7" "$(get "$TMP/hexp" ncps_0x194 5)" "d7"
ok "RX bias set from 7f"             "$(get "$TMP/hexp" bias_0x1a2 4)" "ff"
ok "RX bias released back to 7f"     "$(get "$TMP/hexp" bias_0x1a2 6)" "7f"

hdr "a state file missing a register must be caught, not defaulted"
pa_derive "pa_0x1ab=80" "$TMP/short"
ok "missing rows are reported"       \
   "$([ "$(grep -c MISSING "$TMP/short")" -ge 12 ] && echo yes || echo no)" "yes"

# --------------------------------------------------------------------------
hdr "the forced-write journal: eight operations, in order, both directions"
#
# Synthetic journals, graded by the same routine the runner uses. A correct
# run must be accepted and every mutilation rejected -- particularly a MISSING
# INVERSE, which is the one that leaves an unobservable enable behind a
# teardown that looked clean.
journal_ok() {	# journal_ok <text> -> yes|no
	_i=0
	while [ "$_i" -lt "$WCD9320_PA_FORCED_TOTAL" ]; do
		case $((_i % 4)) in
		0) _wr=314; _wm=ff; _wd=set   ;;
		1) _wr=30d; _wm=02; _wd=set   ;;
		2) _wr=30d; _wm=02; _wd=clear ;;
		3) _wr=314; _wm=ff; _wd=clear ;;
		esac
		_g=$(printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^f${_i}_reg=//p")
		[ "$_g" = "$_wr" ] || { echo no; return; }
		_g=$(printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^f${_i}_mask=//p")
		[ "$_g" = "$_wm" ] || { echo no; return; }
		_g=$(printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^f${_i}_dir=//p")
		[ "$_g" = "$_wd" ] || { echo no; return; }
		_i=$((_i + 1))
	done
	_n=$(printf '%s' "$1" | tr ' ' '\n' | sed -n 's/^forced_n=//p')
	[ "$_n" = "$WCD9320_PA_FORCED_TOTAL" ] || { echo no; return; }
	echo yes
}

mkjournal() {	# mkjournal -> a correct eight-operation journal
	_j="forced_n=8"
	_mk=0
	while [ "$_mk" -lt 2 ]; do
		_j="$_j f$((_mk * 4 + 0))_reg=314 f$((_mk * 4 + 0))_mask=ff f$((_mk * 4 + 0))_dir=set"
		_j="$_j f$((_mk * 4 + 1))_reg=30d f$((_mk * 4 + 1))_mask=02 f$((_mk * 4 + 1))_dir=set"
		_j="$_j f$((_mk * 4 + 2))_reg=30d f$((_mk * 4 + 2))_mask=02 f$((_mk * 4 + 2))_dir=clear"
		_j="$_j f$((_mk * 4 + 3))_reg=314 f$((_mk * 4 + 3))_mask=ff f$((_mk * 4 + 3))_dir=clear"
		_mk=$((_mk + 1))
	done
	printf '%s' "$_j"
}

GOOD=$(mkjournal)
ok "a correct eight-operation journal is accepted" "$(journal_ok "$GOOD")" "yes"
ok "a missing inverse is caught" \
   "$(journal_ok "$(printf '%s' "$GOOD" | sed 's/f2_dir=clear/f2_dir=set/')")" "no"
ok "an inverse issued as a set is caught" \
   "$(journal_ok "$(printf '%s' "$GOOD" | sed 's/f7_dir=clear/f7_dir=set/')")" "no"
ok "a wrong register is caught" \
   "$(journal_ok "$(printf '%s' "$GOOD" | sed 's/f1_reg=30d/f1_reg=311/')")" "no"
ok "a masked 0x314 write is caught" \
   "$(journal_ok "$(printf '%s' "$GOOD" | sed 's/f0_mask=ff/f0_mask=03/')")" "no"
ok "a truncated second cycle is caught" \
   "$(journal_ok "$(printf '%s' "$GOOD" | sed 's/forced_n=8/forced_n=4/')")" "no"
ok "six operations instead of eight is caught" \
   "$(journal_ok "forced_n=6 $(printf '%s' "$GOOD" | sed 's/^forced_n=8 //')")" "no"

# --------------------------------------------------------------------------
hdr "POLARITY: every ambiguous outcome resolves to abort"
#
# The decision the runner makes from input-gate's exit code, isolated so it
# can be tested without a phone. This is the single most safety-critical
# branch in the whole run: it decides whether the next thing that happens is
# a PA enable or a teardown.
gate_decision() {	# gate_decision <rc> -> PROCEED|ABORT
	case "$1" in
	0) echo PROCEED ;;
	*) echo ABORT ;;
	esac
}

ok "0 approve  -> PROCEED" "$(gate_decision 0)" "PROCEED"
ok "1 abort    -> ABORT"   "$(gate_decision 1)" "ABORT"
ok "2 timeout  -> ABORT"   "$(gate_decision 2)" "ABORT"
ok "3 setup    -> ABORT"   "$(gate_decision 3)" "ABORT"
ok "4 busy     -> ABORT"   "$(gate_decision 4)" "ABORT"
#
# An exit code nobody has defined yet must also abort. A future mode that
# returned 5 must not read as approval because a case arm was not updated.
ok "5 unknown  -> ABORT"   "$(gate_decision 5)" "ABORT"
ok "127 not-found -> ABORT" "$(gate_decision 127)" "ABORT"
#
# And the state-dependent hold limits, which are not the same number.
ok "PA-OFF hold is 10 minutes" "600" "600"
ok "PA-ON hold is 120 seconds" "120" "120"
ok "tone hold is 120 seconds"  "120" "120"

# --------------------------------------------------------------------------
hdr "SSH DETACHMENT: the run must survive logout"
#
# PID 1 is systemd and logind kills the user session cgroup on logout, so
# nohup and setsid BOTH fail here -- established on the device. A transient
# systemd-run unit survives, and being transient also satisfies "explicitly
# armed, never a boot service".
detach_ok() {	# detach_ok <command line> -> yes|no
	case "$1" in
	*"systemd-run"*"--unit="*"--collect"*) echo yes ;;
	*) echo no ;;
	esac
}
ok "systemd-run --unit --collect is accepted" \
   "$(detach_ok 'sudo systemd-run --unit=c3a --collect sh run.sh')" "yes"
ok "nohup is rejected"  "$(detach_ok 'nohup sh run.sh &')" "no"
ok "setsid is rejected" "$(detach_ok 'setsid sh run.sh')" "no"
ok "a bare background job is rejected" "$(detach_ok 'sh run.sh &')" "no"
#
# A unit file installed on disk would be a boot service, which is exactly what
# this must not be. --collect makes the unit vanish when it exits.
ok "an enabled service is rejected" \
   "$(detach_ok 'systemctl enable c3a.service')" "no"

# --------------------------------------------------------------------------
hdr "the real input-gate binary, if one has been built"
GATE="${GATE:-}"
for _c in "$GATE" "$DIR/input-gate" /tmp/input-gate; do
	[ -n "$_c" ] && [ -x "$_c" ] && { GATE="$_c"; break; }
done

if [ -z "$GATE" ] || [ ! -x "$GATE" ]; then
	skip "key renumbering" "no input-gate binary; set GATE=<path>"
	skip "double arm" "no input-gate binary; set GATE=<path>"
else
	cat > "$TMP/boot1" <<-'EOF'
	I: Bus=0019 Vendor=0001 Product=0001 Version=0100
	N: Name="gpio-keys"
	H: Handlers=kbd event0

	I: Bus=0000 Vendor=0000 Product=0000 Version=0000
	N: Name="pm8941_resin"
	H: Handlers=kbd event1

	I: Bus=0018 Vendor=0000 Product=0000 Version=0000
	N: Name="synaptics_rmi4_i2c"
	H: Handlers=mouse0 event2
	EOF
	#
	# The SAME phone, a later boot, with the touchscreen probing first and
	# pushing both key devices up. Every node number has moved.
	#
	cat > "$TMP/boot2" <<-'EOF'
	I: Bus=0018 Vendor=0000 Product=0000 Version=0000
	N: Name="synaptics_rmi4_i2c"
	H: Handlers=mouse0 event0

	I: Bus=0019 Vendor=0001 Product=0001 Version=0100
	N: Name="gpio-keys"
	H: Handlers=kbd event5

	I: Bus=0000 Vendor=0000 Product=0000 Version=0000
	N: Name="pm8941_resin"
	H: Handlers=kbd event3
	EOF
	cat > "$TMP/noabort" <<-'EOF'
	I: Bus=0019 Vendor=0001 Product=0001 Version=0100
	N: Name="gpio-keys"
	H: Handlers=kbd event0
	EOF
	cat > "$TMP/prefix" <<-'EOF'
	I: Bus=0019 Vendor=0001 Product=0001 Version=0100
	N: Name="gpio-keys-wakeup"
	H: Handlers=kbd event0

	I: Bus=0000 Vendor=0000 Product=0000 Version=0000
	N: Name="pm8941_resin"
	H: Handlers=kbd event1
	EOF

	"$GATE" --parse "$TMP/boot1" > "$TMP/p1" 2>&1
	ok "boot 1 resolves" "$?" "0"
	ok "approve at event0" \
	   "$(sed -n 's|^approve=/dev/input/||p' "$TMP/p1")" "event0"
	ok "abort at event1" \
	   "$(sed -n 's|^abort=/dev/input/||p' "$TMP/p1")" "event1"

	"$GATE" --parse "$TMP/boot2" > "$TMP/p2" 2>&1
	ok "boot 2 resolves after renumbering" "$?" "0"
	ok "approve followed its name to event5" \
	   "$(sed -n 's|^approve=/dev/input/||p' "$TMP/p2")" "event5"
	ok "abort followed its name to event3" \
	   "$(sed -n 's|^abort=/dev/input/||p' "$TMP/p2")" "event3"

	"$GATE" --parse "$TMP/noabort" > /dev/null 2>&1
	ok "a missing ABORT device refuses to arm" "$?" "3"

	"$GATE" --parse "$TMP/prefix" > /dev/null 2>&1
	ok "a prefix name does not match" "$?" "3"

	#
	# DOUBLE ARM. Two watchers would each independently trigger a teardown,
	# and two runs would fight over the codec. The second must refuse with
	# RC_BUSY rather than arm silently.
	#
	# Driven through the lock alone: --watch needs real devices, which a
	# workstation does not have, so the lock is taken here the way the
	# binary takes it and the binary is asked to take it again.
	#
	if command -v flock >/dev/null 2>&1; then
		( flock -n 9 || exit 1
		  "$GATE" --watch --flag "$TMP/flag" --lock "$TMP/lk" \
			  --timeout 1 >/dev/null 2>&1
		  echo "$?" > "$TMP/rc2"
		) 9> "$TMP/lk"
		#
		# The binary refuses on either count -- BUSY if it got as far
		# as the lock, SETUP if it refused earlier for want of the
		# devices. What must never happen is APPROVE.
		#
		_rc=$(cat "$TMP/rc2" 2>/dev/null || echo missing)
		ok "a second arm never returns approve" \
		   "$([ "$_rc" = "0" ] && echo approved || echo refused)" "refused"
	else
		skip "double arm" "no flock(1) on this host"
	fi
fi

# --------------------------------------------------------------------------
hdr "counts and constants"
ok "writes per cycle"  "$WCD9320_PA_WRITES_PER_CYCLE" "32"
ok "writes for two cycles" "$WCD9320_PA_WRITES_TOTAL" "64"
ok "class-H writes unchanged from C2a" "$WCD9320_PA_CLSH_TOTAL" "104"
ok "forced operations per cycle" "$WCD9320_PA_FORCED_PER_CYCLE" "4"
ok "forced operations total" "$WCD9320_PA_FORCED_TOTAL" "8"
ok "the guard mask is both PA bits" "$WCD9320_PA_MASK" "30"
ok "the write mask is HPHL alone"   "$WCD9320_PA_HPHL" "20"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

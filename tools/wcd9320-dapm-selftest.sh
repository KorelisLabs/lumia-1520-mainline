#!/bin/sh
#
# r184 offline selftest: the DAPM expectation functions, and the DAPM
# emergency teardown against fakes. Runs on the workstation; touches no codec.
#
# The teardown is the safety path for every DAPM-powered PA, so it is tested
# the way it will fail: pin write refused, alsa-setctl missing, no player. In
# every case the driver's C3 abort must still be issued, after the pin, and
# the script must exit 0.
#
# Exit: 0 all pass, 1 otherwise.

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/wcd9320-dapm-expect.sh"

P=0; F=0
ok()  { P=$((P + 1)); printf '  PASS  %s\n' "$1"; }
bad() { F=$((F + 1)); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }

echo "=== expectation functions ==="
S_ALL="held=3f ups=6 downs=0 refusals=0 failures=0 mclk_users=1 pa_on=1"
S_NONE="held=00 ups=6 downs=6 refusals=0 failures=0 mclk_users=0 pa_on=0"
S_PART="held=07 ups=3 downs=0 refusals=3 failures=0 mclk_users=1 pa_on=0"
eq "whole path is 3f"           "$(dapm_held_is "$S_ALL" 3f)" "OK"
eq "nothing is 00"              "$(dapm_held_is "$S_NONE" 00)" "OK"
eq "a partial mask is refused"  "$(dapm_held_is "$S_PART" 3f)" "REFUSE:held=07 want 3f"
eq "partial is not idle either" "$(dapm_held_is "$S_PART" 00)" "REFUSE:held=07 want 00"
eq "no held= is refused"        "$(dapm_held_is "garbage" 00)" "REFUSE:no held= in dapm_state"
eq "delta ups"                  "$(dapm_delta "$S_ALL" "$S_NONE" ups)" "0"
eq "delta downs"                "$(dapm_delta "$S_ALL" "$S_NONE" downs)" "6"
eq "delta on a missing key"     "$(dapm_delta "$S_ALL" "x=1" downs)" "?"
eq "widget off, in 1 out 0"     "$(dapm_widget "HPHL: Off  in 1 out 0")" "Off 1 0"
eq "widget on with a register"  "$(dapm_widget "MCLK: On  in 1 out 1 - R-1(0x-1) mask 0x1")" "On 1 1"
eq "widget forced"              "$(dapm_widget "HPHL: On (forced)  in 0 out 0")" "On 0 0"
eq "widget name with spaces"    "$(dapm_widget "CLASS_H PREP: Off  in 0 out 0")" "Off 0 0"
eq "unparseable widget"         "$(dapm_widget "nonsense")" "? ? ?"
eq "pin readback 0"             "$(dapm_pin_value "$(printf 'name=x\nfound=1\nreadback=0\n')")" "0"
eq "pin readback 1"             "$(dapm_pin_value "$(printf 'write_rc=0\nreadback=1\n')")" "1"
eq "pin not found"              "$(dapm_pin_value "$(printf 'name=x\nfound=0\n')")" "?"
eq "card r184, pin off"         "$(dapm_card_ok q6-card-rc4 0)" "OK"
eq "old card refused"           "$(dapm_card_ok q6-card-rc3 0)" "REFUSE:card module is 'q6-card-rc3', not q6-card-rc4 -- no pin behind HEADPHONE"
eq "no card refused"            "$(dapm_card_ok "" "?")" "REFUSE:card module is 'absent', not q6-card-rc4 -- no pin behind HEADPHONE"
eq "pin on refused"             "$(dapm_card_ok q6-card-rc4 1)" "REFUSE:Headphones pin reads '1', not 0"
eq "pin unreadable refused"     "$(dapm_card_ok q6-card-rc4 "?")" "REFUSE:Headphones pin reads '?', not 0"

echo ""
echo "=== the DAPM teardown, against fakes ==="
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LOG="$T/calls.log"
cp "$DIR/wcd9320-dapm-teardown.sh" "$T/"
cat > "$T/wcd9320-hphl-pa-teardown.sh" <<EOF
#!/bin/sh
echo "abort \$1" >> "$LOG"
exit 0
EOF

setctl_ok() {
	cat > "$T/alsa-setctl" <<EOF
#!/bin/sh
echo "setctl \$*" >> "$LOG"
echo write_rc=0
echo readback=0
EOF
	chmod +x "$T/alsa-setctl"
}
setctl_refuses() {
	cat > "$T/alsa-setctl" <<EOF
#!/bin/sh
echo "setctl \$*" >> "$LOG"
echo write_rc=-1
echo readback=1
exit 1
EOF
	chmod +x "$T/alsa-setctl"
}

PL=dapmst-player
run_td() {	# run_td <reason> -> exit code
	: > "$LOG"
	C3A_JOURNAL="$T/journal" DAPM_PLAYER=$PL ALSA_SETCTL="" \
		sh "$T/wcd9320-dapm-teardown.sh" "$1" > "$T/out" 2>&1
}

# 1. the normal case: pin off, player killed, abort -- in that order
setctl_ok
# A script, not a copied binary: the kernel names a shebang process after the
# script file, which is what pkill -x matches. (A copied coreutils binary is
# multi-call and dies at once, which would pass the kill check vacuously.)
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$T/$PL"
chmod +x "$T/$PL"
"$T/$PL" &
PLPID=$!
sleep 0.3
if kill -0 "$PLPID" 2>/dev/null; then ok "normal: the fake player is running"
else bad "normal: the fake player is running" "it is not -- the kill check would be vacuous"; fi
run_td selftest; RC=$?
eq "normal: exit 0" "$RC" "0"
eq "normal: pin written off first" "$(sed -n 1p "$LOG")" "setctl -D /dev/snd/controlC0 --set Headphones Switch 0"
eq "normal: abort issued after the pin" "$(sed -n 2p "$LOG")" "abort dapm-selftest"
sleep 0.2
if kill -0 "$PLPID" 2>/dev/null; then bad "normal: player killed" "still running"; kill "$PLPID"
else ok "normal: player killed"; fi
wait "$PLPID" 2>/dev/null
grep -q "pin OFF (Headphones Switch), read back 0" "$T/journal" &&
	ok "normal: journal records the pin" || bad "normal: journal records the pin" "missing"

# 2. the pin write refused: abort still issued, still exit 0
setctl_refuses
run_td refused; RC=$?
eq "pin refused: exit 0" "$RC" "0"
eq "pin refused: abort still issued" "$(grep -c '^abort dapm-refused$' "$LOG")" "1"
grep -q "PIN OFF FAILED" "$T/journal" && ok "pin refused: journal says so" ||
	bad "pin refused: journal says so" "missing"

# 3. no alsa-setctl at all: abort still issued, still exit 0
rm -f "$T/alsa-setctl"
run_td nosetctl; RC=$?
eq "no setctl: exit 0" "$RC" "0"
eq "no setctl: abort still issued" "$(grep -c '^abort dapm-nosetctl$' "$LOG")" "1"
grep -q "NO alsa-setctl" "$T/journal" && ok "no setctl: journal says so" ||
	bad "no setctl: journal says so" "missing"

# 4. no player running: not an error
setctl_ok
run_td noplayer; RC=$?
eq "no player: exit 0" "$RC" "0"
grep -q "no $PL running" "$T/journal" && ok "no player: journal says so" ||
	bad "no player: journal says so" "missing"

echo ""
echo "=== syntax ==="
for s in wcd9320-dapm-expect.sh wcd9320-dapm-teardown.sh wcd9320-dapm-evidence.sh \
	 wcd9320-dapm-listen.sh wcd9320-hphl-pa-evidence.sh; do
	if sh -n "$DIR/$s" 2>"$T/err"; then ok "sh -n $s"; else bad "sh -n $s" "$(head -n1 "$T/err")"; fi
done
if [ -f "$DIR/sh-continuation-check.py" ]; then
	for s in wcd9320-dapm-teardown.sh wcd9320-dapm-evidence.sh wcd9320-dapm-listen.sh; do
		if python3 "$DIR/sh-continuation-check.py" "$DIR/$s" >"$T/err" 2>&1; then ok "continuations $s"
		else bad "continuations $s" "$(head -n1 "$T/err")"; fi
	done
fi

echo ""
echo "PASS $P   FAIL $F"
[ "$F" -eq 0 ]

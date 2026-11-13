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
# r185: nine stages, three hex digits
S_ALL="held=1ff ups=9 downs=0 refusals=0 failures=0 mclk_users=1 pa_on=1 pa_r_on=1"
S_NONE="held=000 ups=9 downs=9 refusals=0 failures=0 mclk_users=0 pa_on=0 pa_r_on=0"
S_PART="held=07f ups=7 downs=0 refusals=2 failures=0 mclk_users=1 pa_on=0 pa_r_on=0"
eq "the constants are r185's"   "$DAPM_HELD_ALL $DAPM_HELD_NONE $DAPM_STAGES" "1ff 000 9"
eq "whole path is 1ff"          "$(dapm_held_is "$S_ALL" "$DAPM_HELD_ALL")" "OK"
eq "nothing is 000"             "$(dapm_held_is "$S_NONE" "$DAPM_HELD_NONE")" "OK"
eq "r184's 3f is not the path"  "$(dapm_held_is "held=3f" "$DAPM_HELD_ALL")" "REFUSE:held=3f want 1ff"
eq "a partial mask is refused"  "$(dapm_held_is "$S_PART" 1ff)" "REFUSE:held=07f want 1ff"
eq "partial is not idle either" "$(dapm_held_is "$S_PART" 000)" "REFUSE:held=07f want 000"
eq "no held= is refused"        "$(dapm_held_is "garbage" 000)" "REFUSE:no held= in dapm_state"
eq "delta ups"                  "$(dapm_delta "$S_ALL" "$S_NONE" ups)" "0"
eq "delta downs"                "$(dapm_delta "$S_ALL" "$S_NONE" downs)" "9"
eq "delta on a missing key"     "$(dapm_delta "$S_ALL" "x=1" downs)" "?"
eq "widget off, in 1 out 0"     "$(dapm_widget "HPHL: Off  in 1 out 0")" "Off 1 0"
eq "widget on with a register"  "$(dapm_widget "MCLK: On  in 1 out 1 - R-1(0x-1) mask 0x1")" "On 1 1"
eq "widget forced"              "$(dapm_widget "HPHL: On (forced)  in 0 out 0")" "On 0 0"
eq "widget name with spaces"    "$(dapm_widget "CLASS_H PREP: Off  in 0 out 0")" "Off 0 0"
eq "unparseable widget"         "$(dapm_widget "nonsense")" "? ? ?"
eq "pin readback 0"             "$(dapm_pin_value "$(printf 'name=x\nfound=1\nreadback=0\n')")" "0"
eq "pin readback 1"             "$(dapm_pin_value "$(printf 'write_rc=0\nreadback=1\n')")" "1"
eq "pin not found"              "$(dapm_pin_value "$(printf 'name=x\nfound=0\n')")" "?"
eq "card r193, pin off"         "$(dapm_card_ok q6-card-rc11 0)" "OK"
eq "r192 card refused"          "$(dapm_card_ok q6-card-rc10 0)" "REFUSE:card module is 'q6-card-rc10', not q6-card-rc11 -- no pin behind HEADPHONE"
eq "no card refused"            "$(dapm_card_ok "" "?")" "REFUSE:card module is 'absent', not q6-card-rc11 -- no pin behind HEADPHONE"
eq "pin on refused"             "$(dapm_card_ok q6-card-rc11 1)" "REFUSE:Headphones pin reads '1', not 0"
eq "pin unreadable refused"     "$(dapm_card_ok q6-card-rc11 "?")" "REFUSE:Headphones pin reads '?', not 0"

echo ""
echo "=== r187: the three outputs ==="
dapm_out hph && eq "hph output" "$OUT_PIN|$OUT_KEY|$OUT_ALL|$OUT_NONE|$OUT_STAGES|$OUT_FORCED" "Headphones Switch|held|1ff|000|9|6"
dapm_out spk && eq "spk output" "$OUT_PIN|$OUT_KEY|$OUT_ALL|$OUT_NONE|$OUT_STAGES|$OUT_FORCED|$OUT_VMAX" "Speaker Switch|spk_held|3f|00|6|2|8"
dapm_out ear && eq "ear output" "$OUT_PIN|$OUT_KEY|$OUT_ALL|$OUT_NONE|$OUT_STAGES|$OUT_FORCED|$OUT_VMAX" "Earpiece Switch|ear_held|3f|00|6|2|6"
# r188
dapm_out lo && eq "lo output" "$OUT_PIN|$OUT_KEY|$OUT_ALL|$OUT_NONE|$OUT_STAGES|$OUT_FORCED|$OUT_VMAX" "Lineout Switch|lo_held|3f|00|6|2|20"
eq "lo spec at full gain"       "$(dapm_spec_ok_out lo B:20:84)" "OK"
eq "lo spec above max refused"  "$(dapm_spec_ok_out lo B:21:84)" "REFUSE:vol 21 above 20 for lo"
eq "lo held key"                "$(dapm_held_key_is "held=000 lo_held=3f" lo_held 3f)" "OK"
# r189
dapm_out i2s && eq "i2s output" "$OUT_PIN|$OUT_KEY|$OUT_ALL|$OUT_NONE|$OUT_STAGES|$OUT_FORCED|$OUT_VMAX" "Loudspeaker Switch|held|000|000|0|0|0"
eq "i2s spec, no gain"          "$(dapm_spec_ok_out i2s B:0:84)" "OK"
eq "i2s spec with a vol refused" "$(dapm_spec_ok_out i2s B:1:84)" "REFUSE:vol 1 above 0 for i2s"
eq "i2s spec with a dig refused" "$(dapm_spec_ok_out i2s B:0:78)" "REFUSE:dig must be 84 for i2s (no digital volume on this path)"
eq "i2s mixer"                  "$I2S_MIXER" "SEC_MI2S_RX Audio Mixer MultiMedia1"
PMX="pin 78 (GPIO_78): (MUX UNCLAIMED) (GPIO UNCLAIMED)
pin 79 (GPIO_79): audio-amplifier (GPIO UNCLAIMED) function sec_mi2s group gpio79
pin 80 (GPIO_80): audio-amplifier (GPIO UNCLAIMED) function sec_mi2s group gpio80
pin 81 (GPIO_81): audio-amplifier (GPIO UNCLAIMED) function gpio group gpio81
pin 82 (GPIO_82): audio-amplifier (GPIO UNCLAIMED) function sec_mi2s group gpio82
pin 83 (GPIO_83): (MUX UNCLAIMED) (GPIO UNCLAIMED)"
eq "mi2s mux parse, per pin"    "$(mi2s_mux_parse "$PMX")" "sec_mi2s sec_mi2s gpio sec_mi2s"
eq "mi2s mux parse, unclaimed"  "$(mi2s_mux_parse "pin 79 (GPIO_79): (MUX UNCLAIMED) (GPIO UNCLAIMED)")" "? ? ? ?"
eq "mi2s mux parse, pin 8 is not 80" "$(mi2s_mux_parse "pin 8 (GPIO_8): x (GPIO UNCLAIMED) function blsp group gpio8")" "? ? ? ?"
# r194: the per-stream RX_EAR_CMBUFF plan
ear_cmbuff_list_ok "clear" && ok "cmbuff list: clear" || bad "cmbuff list: clear" "refused"
ear_cmbuff_list_ok "clear,keep" && ok "cmbuff list: clear,keep" || bad "cmbuff list: clear,keep" "refused"
ear_cmbuff_list_ok "clear,on" && bad "cmbuff list: bad word refused" "accepted" || ok "cmbuff list: bad word refused"
ear_cmbuff_list_ok "" && bad "cmbuff list: empty refused" "accepted" || ok "cmbuff list: empty refused"
ear_cmbuff_list_ok "clear,,keep" && bad "cmbuff list: empty element refused" "accepted" || ok "cmbuff list: empty element refused"
ear_cmbuff_list_ok "keep," && bad "cmbuff list: trailing comma refused" "accepted" || ok "cmbuff list: trailing comma refused"
eq "cmbuff for stream 1 of clear,keep" "$(ear_cmbuff_for clear,keep 1)" "clear"
eq "cmbuff for stream 2 of clear,keep" "$(ear_cmbuff_for clear,keep 2)" "keep"
eq "cmbuff: the last repeats" "$(ear_cmbuff_for clear,keep 3)" "keep"
eq "cmbuff: one value for every stream" "$(ear_cmbuff_for keep 2)" "keep"
# r195: the per-stream EAR power-up order
ear_order_list_ok "windows,downstream" && ok "order list: windows,downstream" || bad "order list: windows,downstream" "refused"
ear_order_list_ok "downstream" && ok "order list: downstream" || bad "order list: downstream" "refused"
ear_order_list_ok "windows,clear" && bad "order list: bad word refused" "accepted" || ok "order list: bad word refused"
ear_order_list_ok "" && bad "order list: empty refused" "accepted" || ok "order list: empty refused"
ear_order_list_ok ",windows" && bad "order list: leading comma refused" "accepted" || ok "order list: leading comma refused"
eq "order for stream 2 of windows,downstream" "$(ear_cmbuff_for windows,downstream 2)" "downstream"
dapm_out xyz; eq "unknown output refused" "$?" "1"
S7="held=000 ups=6 downs=0 refusals=0 failures=0 mclk_users=1 pa_on=0 pa_r_on=0 spk_held=3f ear_held=00 spk_pa=1 ear_pa=0"
eq "spk path held whole"        "$(dapm_held_key_is "$S7" spk_held 3f)" "OK"
eq "ear path idle"              "$(dapm_held_key_is "$S7" ear_held 00)" "OK"
eq "hph untouched beside spk"   "$(dapm_held_key_is "$S7" held 000)" "OK"
eq "partial spk refused"        "$(dapm_held_key_is "held=000 spk_held=07" spk_held 3f)" "REFUSE:spk_held=07 want 3f"
eq "missing key refused"        "$(dapm_held_key_is "held=000" spk_held 3f)" "REFUSE:no spk_held= in dapm_state"
eq "spk forced pattern"         "$(dapm_forced_want_out spk 0 | tr ' ' /);$(dapm_forced_want_out spk 1 | tr ' ' /);$(dapm_forced_want_out spk 2 | tr ' ' /)" "314/ff/set;314/ff/clear;314/ff/set"
eq "hph forced pattern kept"    "$(dapm_forced_want_out hph 2 | tr ' ' /)" "30d/04/set"
eq "spk spec at the minimum"    "$(dapm_spec_ok_out spk B:0:84)" "OK"
eq "spk spec at the maximum"    "$(dapm_spec_ok_out spk B:8:84)" "OK"
eq "spk spec above 8"           "$(dapm_spec_ok_out spk B:9:84)" "REFUSE:vol 9 above 8 for spk"
eq "ear spec above 6"           "$(dapm_spec_ok_out ear B:7:84)" "REFUSE:vol 7 above 6 for ear"
eq "spk spec digital above 0 dB" "$(dapm_spec_ok_out spk B:0:85)" "REFUSE:dig 85 above 84 (0 dB)"
eq "spk spec bad side"          "$(dapm_spec_ok_out spk Q:0:84)" "REFUSE:side 'Q' is not L, R or B"
eq "hph spec unchanged"         "$(dapm_spec_ok_out hph R:21:84)" "REFUSE:hph 21 above 20"
eq "unknown output spec"        "$(dapm_spec_ok_out foo B:0:84)" "REFUSE:unknown output 'foo'"

echo ""
echo "=== r185: the stereo forced pattern and the listen specs ==="
eq "both PAs live is 30"        "$DAPM_PA_LIVE" "30"
eq "six forced per stream"      "$DAPM_FORCED_PER_STREAM" "6"
_fp=""; _i=0
while [ "$_i" -lt 12 ]; do _fp="$_fp$(dapm_forced_want "$_i" | tr ' ' '/');"; _i=$((_i + 1)); done
eq "two streams, DAPM's order" "$_fp" \
   "314/ff/set;30d/02/set;30d/04/set;30d/04/clear;30d/02/clear;314/ff/clear;314/ff/set;30d/02/set;30d/04/set;30d/04/clear;30d/02/clear;314/ff/clear;"
eq "spec L:20:84"               "$(dapm_spec_ok L:20:84)" "OK"
eq "spec B:0:0"                 "$(dapm_spec_ok B:0:0)" "OK"
eq "spec side X"                "$(dapm_spec_ok X:20:84)" "REFUSE:side 'X' is not L, R or B"
eq "spec analog above 20"       "$(dapm_spec_ok R:21:84)" "REFUSE:hph 21 above 20"
eq "spec digital above 0 dB"    "$(dapm_spec_ok R:20:85)" "REFUSE:dig 85 above 84 (0 dB)"
eq "spec missing a field"       "$(dapm_spec_ok R:20)" "REFUSE:dig '' is not a number"
eq "spec extra field"           "$(dapm_spec_ok R:20:84:1)" "REFUSE:'R:20:84:1' is not side:hph:dig"
eq "spec negative"              "$(dapm_spec_ok R:-1:84)" "REFUSE:hph '-1' is not a number"
eq "field at the loudest"       "$(dapm_spec_field 20)" "00"
eq "field at the minimum"       "$(dapm_spec_field 0)" "14"
eq "field 4 steps down"         "$(dapm_spec_field 16)" "04"
eq "digital 0 dB"               "$(dapm_spec_dig 84)" "00"
eq "digital -6 dB"              "$(dapm_spec_dig 78)" "fa"
eq "digital -84 dB"             "$(dapm_spec_dig 0)" "ac"

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
# r187: every output pin, in order, then the abort
eq "normal: speaker pin off next" "$(sed -n 2p "$LOG")" "setctl -D /dev/snd/controlC0 --set Speaker Switch 0"
eq "normal: earpiece pin off next" "$(sed -n 3p "$LOG")" "setctl -D /dev/snd/controlC0 --set Earpiece Switch 0"
eq "normal: line-out pin off next" "$(sed -n 4p "$LOG")" "setctl -D /dev/snd/controlC0 --set Lineout Switch 0"
eq "normal: loudspeaker pin off next" "$(sed -n 5p "$LOG")" "setctl -D /dev/snd/controlC0 --set Loudspeaker Switch 0"
eq "normal: abort issued after every pin" "$(sed -n 6p "$LOG")" "abort dapm-selftest"
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
	 wcd9320-dapm-listen.sh wcd9320-hphl-pa-evidence.sh wcd9320-dapm-postcheck.sh \
	 wcd9320-jack-evidence.sh wcd9320-evidence-lib.sh wcd9320-hphl-vm-evidence.sh \
	 wcd9320-hphl-zdet-evidence.sh wcd9320-mclk-own-evidence.sh; do
	if sh -n "$DIR/$s" 2>"$T/err"; then ok "sh -n $s"; else bad "sh -n $s" "$(head -n1 "$T/err")"; fi
done
if [ -f "$DIR/sh-continuation-check.py" ]; then
	for s in wcd9320-dapm-teardown.sh wcd9320-dapm-evidence.sh wcd9320-dapm-listen.sh \
		 wcd9320-jack-evidence.sh wcd9320-hphl-pa-evidence.sh; do
		if python3 "$DIR/sh-continuation-check.py" "$DIR/$s" >"$T/err" 2>&1; then ok "continuations $s"
		else bad "continuations $s" "$(head -n1 "$T/err")"; fi
	done
fi

echo ""
echo "PASS $P   FAIL $F"
[ "$F" -eq 0 ]

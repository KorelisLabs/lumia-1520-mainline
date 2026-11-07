#!/bin/sh
#
# r182: the driver owns the MCLK. Digital only -- the PA is never enabled.
#
# Design: docs/audio/wcd9320-mclk-ownership-mapping.md, sections 3-5.
#
# What changed in r182: the PM8941 divider (factor XO/2, gpio15 on DIV_CLK1)
# is board state applied at probe, and the RPM vote plus the codec-side r169
# switch live in one refcounted owner, wcd9320_mclk_get/_put, reached through
# clk_source_test ("mclk" = get, "rco" = put).
#
# This run asks five things:
#
#   1  board state at boot: factor 2, gpio15 src_sel 2 (FUNC1 = DIV_CLK; the
#      PMIC encoding is 0 normal, 1 paired, 2 func1), codec on RCO, no users
#   2  the count: get, get, put, put -- only 0 -> 1 and 1 -> 0 switch, and the
#      codec is on MCLK (CHIP_CTL declaring 9.6 MHz) exactly while users > 0
#   3  THE UNTESTED HAZARD: the factor survives every RPM vote transition.
#      Every run before r182 rewrote it just before voting. Read after each
#      vote on and each vote off, three cycles in one boot.
#   4  the RPM clock's enable count returns to its starting value
#   5  a put with no reference is refused and changes nothing
#
# Plus: cache_check 0 at the end, the forced-write journal untouched, the PA
# masked 00 at every sample.
#
# Usage:   sudo sh wcd9320-mclk-own-evidence.sh
# Exit:    0 PASS, 1 checks failed, 2 invalid setup.

set -u

MODE="wcd9320-mclk-own"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
CYCLES="${CYCLES:-3}"

require_module_version
find_devices

CSRC="$PGD/clk_source_test"
CSRS="$PGD/clk_source_state"
PAS="$PGD/hphl_pa_state"
DACS="$PGD/hphl_dac_state"
FLOG="$PGD/forced_log"
CCHK="$PGD/cache_check"
DIVS=""
for d in /sys/bus/platform/devices/*mclk-divider-experiment*; do
	[ -e "$d/mclk_div_state" ] && { DIVS="$d/mclk_div_state"; break; }
done

for f in "$CSRC" "$CSRS" "$PAS" "$DACS" "$FLOG" "$CCHK"; do
	[ -e "$f" ] || { say "INVALID RUN: $f does not exist (mclk-own-rc1 or later, as root)."; exit 2; }
done
[ -n "$DIVS" ] || { say "INVALID RUN: the PM8941 divider state is missing."; exit 2; }
[ -e "$PGD/mclk_test" ] && { say "INVALID RUN: mclk_test exists -- this is not an r182 module."; exit 2; }
[ "$(id -u)" = "0" ] || { say "INVALID RUN: need root."; exit 2; }

rv() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }
cs() { cat "$CSRS" 2>/dev/null; }
dv() { cat "$DIVS" 2>/dev/null; }
pa_masked() {
	_pm=$(rv "$(cat "$PAS" 2>/dev/null)" pa_0x1ab)
	[ -n "$_pm" ] || { echo "READ-FAILED"; return; }
	printf '%02x' $(( 0x$_pm & 0x30 ))
}
PA_SAMPLES=""
pa_sample() { PA_SAMPLES="$PA_SAMPLES $1:$(pa_masked)"; }

# The RPM clock(s) behind the vote. Names differ between kernels, so every
# DIV_CLK1 entry in clk debugfs is followed; at least one must move with the
# vote and all must come back. Absent debugfs is reported, not failed.
CLKS=""
for c in /sys/kernel/debug/clk/*div*clk1*; do
	[ -e "$c/clk_enable_count" ] && CLKS="$CLKS $c"
done
clk_counts() {
	_cc=""
	for c in $CLKS; do _cc="$_cc $(basename "$c")=$(cat "$c/clk_enable_count" 2>/dev/null)"; done
	printf '%s' "${_cc# }"
}
clk_sum() {
	_s=0
	for c in $CLKS; do _s=$(( _s + $(cat "$c/clk_enable_count" 2>/dev/null || echo 0) )); done
	echo "$_s"
}

# ------------------------------------------------------------ preconditions --
BAD=""
S0=$(cs)
[ "$(pa_masked)" = "00" ]                       || BAD="$BAD PA_ON"
[ "$(rv "$(cat "$PAS")" pa_on)" = "0" ]         || BAD="$BAD pa_on"
[ "$(rv "$(cat "$PAS")" prep_on)" = "0" ]       || BAD="$BAD prep_on"
[ "$(rv "$(cat "$DACS")" on)" = "0" ]           || BAD="$BAD dac_on"
[ "$(rv "$S0" on_mclk)" = "0" ]                 || BAD="$BAD already_on_mclk"
[ "$(rv "$S0" mclk_users)" = "0" ]              || BAD="$BAD mclk_already_held"
if [ -n "$BAD" ]; then
	say "INVALID RUN: the starting state is not clean:$BAD"
	say "  Nothing was written."
	exit 2
fi

open_output "$OUTDIR/wcd9320-mclk-own-$STAMP.txt"

# chip_ctl_on <before> -- CHIP_CTL with the 9.6 MHz rate field (bits 2:1 = 01)
# set and every other bit as measured. Baseline-relative, as in the driver.
chip_ctl_on() { printf '%02x' $(( (0x$1 & 0xf9) | 0x02 )); }

{
	say "WCD9320 r182: the driver owns the MCLK"
	say "mode              : $MODE"
	say "stamp             : $STAMP"
	say "module            : $RUNNING_VERSION (expect $EXPECT_VERSION, $EXPECT_SOURCE)"
	say "control function  : $PGD_NAME"
	say "divider state     : $DIVS"
	say "rpm clocks        : ${CLKS:-none found in debugfs}"
	say "design            : docs/audio/wcd9320-mclk-ownership-mapping.md"

	F0=$(rv "$(cat "$FLOG")" forced_n)
	C0=$(rv "$S0" chip_ctl_0x000)
	CTL_ON=$(chip_ctl_on "$C0")
	K0=$(clk_sum)
	pa_sample start

	hdr "1. board state at boot"
	D0=$(dv)
	say "  $(printf '%s' "$D0" | tr '\n' ' ')"
	check "divider applied at probe"      "$(rv "$D0" applied)" "1"
	check "DIV_CTL1 factor 2 (XO/2)"      "$(rv "$D0" factor)" "2"
	check "gpio15 src_sel 2 (FUNC1 = DIV_CLK)" "$(rv "$D0" function)" "2"
	check "codec on RCO"                  "$(rv "$S0" source)" "RCO"
	check "on_mclk 0"                     "$(rv "$S0" on_mclk)" "0"
	check "mclk_users 0"                  "$(rv "$S0" mclk_users)" "0"
	note  "CHIP_CTL at boot"              "$C0 (on MCLK it must read $CTL_ON)"
	note  "rpm clock enable counts"       "$(clk_counts)"

	k=1
	while [ "$k" -le "$CYCLES" ]; do
		hdr "2/3. cycle $k: get, get, put, put"
		B=$(cs); SW0=$(rv "$B" switches); RS0=$(rv "$B" restores)

		echo mclk > "$CSRC" 2>/dev/null; RC=$?
		S=$(cs); D=$(dv); pa_sample "c$k-get1"
		check "c$k get 1 rc"                  "$RC" "0"
		check "c$k users 0 -> 1"              "$(rv "$S" mclk_users)" "1"
		check "c$k on MCLK"                   "$(rv "$S" on_mclk)" "1"
		check "c$k CDC alive on MCLK"         "$(rv "$S" cdc_alive)" "1"
		check "c$k CHIP_CTL declares 9.6"     "$(rv "$S" chip_ctl_0x000)" "$CTL_ON"
		check "c$k switched once"             "$(rv "$S" switches)" "$((SW0 + 1))"
		check "c$k factor after vote ON"      "$(rv "$D" factor)" "2"
		note  "c$k rpm clocks, vote on"       "$(clk_counts)"
		if [ -n "$CLKS" ]; then
			check "c$k an rpm clock moved with the vote" \
			      "$([ "$(clk_sum)" -gt "$K0" ] && echo yes || echo no)" "yes"
		fi

		echo mclk > "$CSRC" 2>/dev/null; RC=$?
		S=$(cs); pa_sample "c$k-get2"
		check "c$k get 2 rc"                  "$RC" "0"
		check "c$k users 1 -> 2"              "$(rv "$S" mclk_users)" "2"
		check "c$k second get did not switch" "$(rv "$S" switches)" "$((SW0 + 1))"

		echo rco > "$CSRC" 2>/dev/null; RC=$?
		S=$(cs); pa_sample "c$k-put1"
		check "c$k put 1 rc"                  "$RC" "0"
		check "c$k users 2 -> 1"              "$(rv "$S" mclk_users)" "1"
		check "c$k still on MCLK"             "$(rv "$S" on_mclk)" "1"
		check "c$k first put did not restore" "$(rv "$S" restores)" "$RS0"

		echo rco > "$CSRC" 2>/dev/null; RC=$?
		S=$(cs); D=$(dv); pa_sample "c$k-put2"
		check "c$k put 2 rc"                  "$RC" "0"
		check "c$k users 1 -> 0"              "$(rv "$S" mclk_users)" "0"
		check "c$k back on RCO"               "$(rv "$S" on_mclk)" "0"
		check "c$k CDC alive on RCO"          "$(rv "$S" cdc_alive)" "1"
		check "c$k CHIP_CTL restored"         "$(rv "$S" chip_ctl_0x000)" "$C0"
		check "c$k restored once"             "$(rv "$S" restores)" "$((RS0 + 1))"
		check "c$k factor after vote OFF"     "$(rv "$D" factor)" "2"
		check "c$k gpio15 still DIV_CLK"      "$(rv "$D" function)" "2"
		if [ -n "$CLKS" ]; then
			check "c$k rpm clock count back to start" "$(clk_sum)" "$K0"
		fi
		k=$((k + 1))
	done

	hdr "5. a put with no reference"
	B=$(cs)
	echo rco > "$CSRC" 2>/dev/null; RC=$?
	S=$(cs)
	check "refused"                           "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
	check "users stay 0"                      "$(rv "$S" mclk_users)" "0"
	check "nothing restored"                  "$(rv "$S" restores)" "$(rv "$B" restores)"
	echo bogus > "$CSRC" 2>/dev/null; RC=$?
	check "an unknown word is refused"        "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"

	hdr "end state"
	S=$(cs); D=$(dv); CC=$(cat "$CCHK" 2>/dev/null | tr '\n' ' ')
	pa_sample end
	say "  cache_check: $CC"
	check "codec on RCO"                      "$(rv "$S" source)" "RCO"
	check "factor still 2"                    "$(rv "$D" factor)" "2"
	check "cache_check mismatches"            "$(rv "$CC" mismatches)" "0"
	check "cache_check read errors"           "$(rv "$CC" read_errors)" "0"
	check "forced journal untouched"          "$(rv "$(cat "$FLOG")" forced_n)" "$F0"
	PA_BAD=$(printf '%s' "$PA_SAMPLES" | tr ' ' '\n' | grep -v ':00$' | grep -c ':' || true)
	check "PA masked 00 at every sample"      "${PA_BAD:-0}" "0"
	note  "rpm clock enable counts"           "$(clk_counts)"
	say "PA samples:$PA_SAMPLES"
	say ""
	say "-- dmesg, mclk / clk-src / mclk-div lines --"
	dmesg 2>/dev/null | grep -E 'mclk: |mclk-div: |clk-src: |chip-ctl: |PA GUARD|WARNING|BUG' | tail -n 60

	emit_verdict
} > "$OUT" 2>&1
RC=$?
cat "$OUT"
say ""
say "evidence: $OUT"
exit $RC

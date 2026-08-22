#!/bin/sh
#
# Branch A build 1 of 2: does the QDSP6 graph instantiate?
#
# WHAT THIS PROVES, AND WHAT IT CANNOT
#
# Only that the DT nodes produce bound drivers, registered ASoC components and
# the expected DAIs. It says NOTHING about the firmware, because none of these
# probes sends a packet: q6afe and q6asm kzalloc, call
# q6core_get_svc_api_info() and populate children; q6routing registers a
# component. Binding is not evidence -- that is the C0 lesson from the
# inventory milestone, and it applies here unchanged.
#
# It is a separate build from the card on purpose. "The QDSP6 graph does not
# instantiate" and "the playback control plane does not work" are easy to
# conflate and are fixed in completely different places.
#
# THERE MUST BE NO SOUND CARD. If one exists, this is not build 1 and the
# separation the split exists to create has already been lost.
#
# Exit: 0 the graph is up, 1 checks failed, 2 invalid setup.

set -u

MODE="q6-graph"
DIR=$(dirname "$0")
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-q6graph-$$"
APR_BUS="${APR_BUS:-/sys/bus/aprbus}"
ASOC="${ASOC:-/sys/kernel/debug/asoc}"

require_module_version
find_devices

[ -r "$ASOC/dais" ] || {
	say "INVALID RUN: $ASOC/dais is not readable."
	say "  ASoC debugfs is root-only; run this with sudo."
	exit 2
}

snap_dmesg
open_output "$OUTDIR/msm8974-q6-graph-$STAMP.txt"

APR_DEVS=$(ls -1 "$APR_BUS/devices" 2>/dev/null | tr '\n' ' ')
APR_DRVS=$(ls -1 "$APR_BUS/drivers" 2>/dev/null | tr '\n' ' ')
COMPONENTS=$(cat "$ASOC/components" 2>/dev/null)
DAIS=$(cat "$ASOC/dais" 2>/dev/null)
# grep -c PRINTS 0 and EXITS 1 when nothing matches, so a trailing
# "|| echo 0" appends a SECOND zero and the check then compares a
# two-line value against "0". Let the assignment own the fallback.
CARDS=$(grep -c '^ *[0-9]' /proc/asound/cards 2>/dev/null) || CARDS=0
[ -n "$CARDS" ] || CARDS=0

bound() {	# bound <driver> -> 1 if some device is bound to it
	_l=$(ls -1 "$APR_BUS/drivers/$1" 2>/dev/null |
	     grep -v '^bind$\|^unbind$\|^uevent$\|^module$')
	[ -n "$_l" ] && echo 1 || echo 0
}

{
	hdr "APR devices and drivers"
	say "devices : ${APR_DEVS:-none}"
	say "drivers : ${APR_DRVS:-none}"

	hdr "q6 modules loaded"
	lsmod 2>/dev/null | grep -E '^q6|^snd_q6' | sed 's/^/  /' || say "  (none)"

	hdr "ASoC components"
	printf '%s\n' "${COMPONENTS:-  (none)}" | sed 's/^/  /'

	hdr "the DAIs that matter"
	for d in SLIMBUS_0_RX wcd9320-slim-rx1; do
		if printf '%s\n' "$DAIS" | grep -qx "$d"; then
			say "  present : $d"
		else
			say "  ABSENT  : $d"
		fi
	done
	say "total DAIs registered : $(printf '%s\n' "$DAIS" | grep -c .)"

	#
	# THE FRONT-END NAMING QUESTION, recorded rather than assumed.
	#
	# q6asm_fe_dai_component sets .legacy_dai_naming = 1. With a single DAI
	# declared, ASoC uses fmt_single_name(), which names the DAI after the
	# DEVICE rather than the driver's .name -- the same trap the codec
	# component hit earlier in this project. If "MultiMedia1" is absent and
	# the q6asm device name is present instead, then a name-based dai_link
	# for the front end cannot match, and build 2 must wire the links with
	# sound-dai phandles in DT rather than hardcoded names in C.
	#
	hdr "front-end DAI naming (decides how build 2 wires its links)"
	Q6ASM_DEV=$(printf '%s\n' "$COMPONENTS" | grep 'service@7:dais' | head -n1)
	MM1=$(printf '%s\n' "$DAIS" | grep -cx 'MultiMedia1')
	BYDEV=$(printf '%s\n' "$DAIS" | grep -cx "${Q6ASM_DEV:-__none__}")
	say "q6asm component     : ${Q6ASM_DEV:-absent}"
	say "DAI named MultiMedia1 : $MM1"
	say "DAI named after device: $BYDEV"
	if [ "$MM1" = "0" ] && [ "$BYDEV" = "1" ]; then
		say ""
		say "CONFIRMED: the FE DAI carries the DEVICE name, not MultiMedia1."
		say "Build 2 must use sound-dai phandles; a name-based FE dai_link"
		say "would silently fail to match."
	elif [ "$MM1" = "1" ]; then
		say ""
		say "The FE DAI is named MultiMedia1 after all -- name-based linking"
		say "would work. Prefer phandles anyway, but the hazard is absent."
	fi

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# The graph itself.
	for svc in 3 4 7 8; do
		_n=$(printf '%s' "$APR_DEVS" | grep -c "aprsvc:service:4:$svc")
		check "APR device for service $svc" "$_n" "1"
	done
	for drv in qcom-q6core qcom-q6afe qcom-q6asm qcom-q6adm; do
		check "$drv bound" "$(bound $drv)" "1"
	done
	for m in q6core q6afe q6afe_dai q6asm q6asm_dai q6adm q6routing snd_q6dsp_common; do
		_n=$(lsmod 2>/dev/null | grep -c "^$m ")
		check "module loaded: $m" "$_n" "1"
	done

	# The ASoC side.
	for c in 'service@4:dais' 'service@7:dais' 'service@8:routing'; do
		_n=$(printf '%s\n' "$COMPONENTS" | grep -c "$c")
		check "component: $c" "$_n" "1"
	done
	check_cond "SLIMBUS_0_RX DAI exists" \
		"$(printf '%s\n' "$DAIS" | grep -qx 'SLIMBUS_0_RX' && echo 1 || echo 0)" \
		"the AFE back-end DAI is missing" "present"
	check_cond "the codec DAI is still there" \
		"$(printf '%s\n' "$DAIS" | grep -qx 'wcd9320-slim-rx1' && echo 1 || echo 0)" \
		"wcd9320-slim-rx1 vanished" "present"

	# THE SEPARATION. Build 1 must have no card.
	check "NO sound card (this is build 1)" "$CARDS" "0"

	# Health, unchanged.
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check_cond "no kernel WARNING/BUG" \
		"$([ "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" -eq 0 ] && echo 1 || echo 0)" \
		"the log carries a WARNING or BUG" "none"
	check_cond "no APR or q6 error in the log" \
		"$([ "$(dmesg 2>/dev/null | grep -icE 'q6[a-z]*:.*(fail|error|timeout)|apr.*(fail|error)')" -eq 0 ] && echo 1 || echo 0)" \
		"an APR or q6 error was logged" "none"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE QDSP6 GRAPH INSTANTIATES."
		say ""
		say "Four APR services bound, eight modules loaded, three ASoC"
		say "components registered, and SLIMBUS_0_RX exists as a back-end"
		say "DAI alongside the codec's wcd9320-slim-rx1. No sound card,"
		say "which is what makes this build 1 rather than build 2."
		say ""
		say "WHAT THIS DOES NOT CLAIM. Nothing about the firmware. None of"
		say "these probes sends a packet -- q6afe and q6asm allocate, call"
		say "q6core_get_svc_api_info() and populate children; q6routing"
		say "registers a component. A bound driver is not evidence, which"
		say "is the C0 lesson from the inventory milestone."
		say ""
		say "SLIMBUS_0_RX existing as a DAI says nothing about whether the"
		say "ADSP accepts traffic on AFE port 0x4000. That is build 2."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
	fi

	collect_evidence
	emit_verdict
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	tail -n 6 "$OUT" >&2
	exit 7
fi

sed -n '/=== APR devices and drivers/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

[ "$(sed -n 's/^checks : \([0-9]*\) passed, \([0-9]*\) failed/\2/p' "$OUT")" = "0" ] || exit 1
exit 0

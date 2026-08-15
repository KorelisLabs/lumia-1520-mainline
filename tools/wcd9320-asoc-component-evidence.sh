#!/bin/sh
#
# The minimal ASoC component: does the codec present itself to the sound
# subsystem, and does everything already proven still hold underneath it?
#
# SCOPE, deliberately narrow
#
# The component registers with ZERO DAIs. It has no controls, no DAPM widgets
# and no routes, so it cannot be bound into a sound card and no audio path
# exists. This run proves registration and teardown in isolation and claims
# nothing about routing or PCM. A component with no DAIs is the smallest thing
# that can be said to have entered ASoC at all, which is the point: if entering
# ASoC breaks something, there is nothing else in the frame to blame.
#
# WHY THE GATE READS ASoC'S LIST AND NOT OUR OWN dmesg
#
# The driver prints "ASoC component registered". That line proves the call was
# made and returned zero -- it does not prove ASoC kept the component. So the
# gate reads /sys/kernel/debug/asoc/components, which the sound core populates
# from its own registration list, and requires our component to be in it. The
# dmesg line is collected as corroboration, never as the assertion.
#
# WHAT NAME TO LOOK FOR -- this was got wrong once
#
# ASoC names a component after the DEVICE, not after the .name field in
# snd_soc_component_driver: snd_soc_component_initialize() sets
#
#     component->name = fmt_single_name(dev, &component->id);
#
# so the string in that file is the slim_device's name, "217:a0:1:0", and
# "wcd9320-codec" never appears in it at all. The first version of this script
# matched on the driver's .name and failed a component that had registered
# perfectly well. Match on the control function's device name, which
# find_devices() already resolved.
#
# That also gives a sharper check than the original: the interface function is
# a second slim_device with its own name, so requiring IT to be absent is
# direct evidence that only the control function registered a component --
# something the driver-name match could not have shown either way.
#
# The same file also tells us the component registered NO DAIs, by their
# absence from /sys/kernel/debug/asoc/dais. At this stage that absence is a
# requirement, not an omission: a DAI appearing here would mean the scope grew
# without anyone deciding it should.
#
# Exit: 0 PASS, 1 FAIL, 2 INVALID RUN.

set -u

MODE="asoc-component"
DIR=$(dirname "$0")
EXPECT_VERSION="${EXPECT_VERSION:-asoc-component-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-asoc-$$"
MASK_ALL="ff ff 3f 7f"

ASOC_DEBUGFS="${ASOC_DEBUGFS:-/sys/kernel/debug/asoc}"
# The driver-supplied name, which appears in OUR log line but never in ASoC's
# component list. Kept only so the report can show both.
DRIVER_NAME="${DRIVER_NAME:-wcd9320-codec}"

require_module_version
find_devices
snap_dmesg

# Resolved after find_devices, because it is the device name ASoC records.
COMPONENT_NAME="${COMPONENT_NAME:-$PGD_NAME}"

open_output "$OUTDIR/wcd9320-asoc-component-$STAMP.txt"

# ASoC's own view. Read once, reused, so every assertion refers to the same
# observation.
COMPONENTS=""
DAIS=""
[ -r "$ASOC_DEBUGFS/components" ] && COMPONENTS=$(cat "$ASOC_DEBUGFS/components" 2>/dev/null)
[ -r "$ASOC_DEBUGFS/dais" ] && DAIS=$(cat "$ASOC_DEBUGFS/dais" 2>/dev/null)

# Exact whole-line, literal matches: the file lists one name per line, and the
# device name contains characters a regex would otherwise interpret.
MATCH=$(printf '%s\n' "$COMPONENTS" | grep -Fxc "$COMPONENT_NAME")
DAI_MATCH=$(printf '%s\n' "$DAIS" | grep -Fc "$COMPONENT_NAME")
# The interface function must NOT have registered a component of its own.
IFD_MATCH=0
if [ -n "${IFD_NAME:-}" ] && [ "$IFD_NAME" != "(none)" ]; then
	IFD_MATCH=$(printf '%s\n' "$COMPONENTS" | grep -Fxc "$IFD_NAME")
fi

# Any sound card at all would mean something bound this component, which cannot
# happen yet and would mean the scope grew.
# No /proc/asound means no cards, which is the same answer as an empty one --
# so default to 0 rather than leaving it unset and failing the check on a
# system that simply has no ALSA procfs.
CARDS=0
[ -d /proc/asound ] && CARDS=$(ls -1 /proc/asound 2>/dev/null | grep -c '^card[0-9]')

LIVE_MASK=$(sed -n 's/^status=[0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]* mask=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\).*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)
LIVE_STATUS=$(sed -n 's/^status=\([0-9a-f]* [0-9a-f]* [0-9a-f]* [0-9a-f]*\) mask=.*/\1/p' \
	"$PGD/irq_live" 2>/dev/null | head -n1)

{
	hdr "what ASoC says it has"
	say "debugfs           : $ASOC_DEBUGFS"
	say "components file   : $([ -r "$ASOC_DEBUGFS/components" ] && echo readable || echo MISSING)"
	say "looking for       : $COMPONENT_NAME   (the control function's device name)"
	say "driver .name      : $DRIVER_NAME   (appears in our log line; ASoC does NOT record it)"
	say "must be absent    : ${IFD_NAME:-(none)}   (the interface function)"
	say ""
	say "registered components:"
	printf '%s\n' "${COMPONENTS:-  (none)}" | sed 's/^/  /'
	say ""
	say "registered DAIs:"
	printf '%s\n' "${DAIS:-  (none)}" | sed 's/^/  /'
	say ""
	say "sound cards       : ${CARDS:-0}  (must be 0 -- nothing can bind a DAI-less component)"

	hdr "acceptance checks"

	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"

	# -- the component exists, per ASoC rather than per us --
	check_cond "asoc debugfs present" \
		"$([ -r "$ASOC_DEBUGFS/components" ] && echo 1 || echo 0)" \
		"$ASOC_DEBUGFS/components is not readable -- is debugfs mounted and SND_SOC built in?" \
		"$ASOC_DEBUGFS/components"
	check_cond "component in ASoC's list" \
		"$([ "$MATCH" -ge 1 ] && echo 1 || echo 0)" \
		"'$COMPONENT_NAME' is not in $ASOC_DEBUGFS/components -- the call returned 0 but ASoC did not keep it" \
		"$COMPONENT_NAME"
	check "component registered exactly once" "$MATCH" "1"

	# The control function only. The interface function is a second
	# slim_device; a component under its name would mean both functions
	# registered, and any card binding this codec would get a mute twin.
	check "interface function did NOT register" "$IFD_MATCH" "0"

	# -- and the scope has not grown --
	check "DAIs registered" "$DAI_MATCH" "0"
	check "sound cards" "${CARDS:-x}" "0"

	# Corroboration only: the driver's own line. Asserted after the real
	# check, and never in place of it.
	_line=$(count_lines 'ASoC component registered')
	check_cond "driver logged the registration" \
		"$([ "$_line" -ge 1 ] && echo 1 || echo 0)" \
		"no registration line in dmesg" "x$_line"
	check "component registration failures" \
		"$(count_lines 'failed to register ASoC component')" "0"

	# -- everything already proven still holds underneath --
	check "bring-up path" "$(kv "$PGD/bringup" path)" "fresh"
	check "codec was dark at probe" "$(kv "$PGD/rco_wake" nonzero_before)" "0"
	check "core_ready" "$(kv "$PGD/rco_wake" core_ready)" "1"
	check "core init ran once" "$(kv "$PGD/rco_wake" init_runs)" "1"
	check "registers after init" "$(kv "$PGD/rco_wake" nonzero_after)" "95"
	check_canary
	check "identity major" \
		"$(sed -n 's/.*major \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0102"
	check "identity minor" \
		"$(sed -n 's/.*minor \([^ ]*\).*/\1/p' "$PGD/identity" 2>/dev/null)" "0x0001"
	check "identity failures" "$(kv "$PGD/bringup" identity_failures)" "0"
	check "stale bus state" "$(kv "$PGD/bringup" stale_bus_state)" "0"

	# The cache, because a new subsystem holding a reference to the device
	# is exactly the kind of change that could disturb it.
	if [ -r "$PGD/cache_check" ]; then
		_cc="/tmp/.wcd9320-cc-$$"
		cat "$PGD/cache_check" > "$_cc" 2>/dev/null
		check "cacheable mismatches" "$(kv "$_cc" mismatches)" "0"
		check "cacheable registers checked" "$(kv "$_cc" cacheable_checked)" "460"
		check "read errors" "$(kv "$_cc" read_errors)" "0"
		rm -f "$_cc"
	else
		check_cond "cache_check present" 0 "no cache_check attribute"
	fi

	check "masks still initialised" "$LIVE_MASK" "$MASK_ALL"
	check "nothing asserted" "$LIVE_STATUS" "00 00 00 00"

	# -- and nothing complained --
	check "kernel WARNING/BUG" "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" "0"
	check "asoc errors" \
		"$(dmesg 2>/dev/null | grep -ci 'asoc:.*error\|snd_soc.*failed')" "0"
	check "regulator faults" "$(dmesg 2>/dev/null | grep -c '_regulator_put')" "0"
	check "slimbus errors" "$(dmesg 2>/dev/null | grep -c 'Error Interrupt received')" "0"
	check "slimbus timeouts" "$(dmesg 2>/dev/null | grep -c 'failed:-110')" "0"

	hdr "finding"
	if [ "$FAIL_N" -eq 0 ]; then
		say "THE CODEC IS PRESENT IN ASoC."
		say ""
		say "'$COMPONENT_NAME' appears in ASoC's own component list exactly"
		say "once. The interface function '${IFD_NAME:-(none)}' does not appear"
		say "at all, so the control function registered and the interface"
		say "function did not. It carries zero DAIs and no card exists, which"
		say "is what this milestone claims and the limit of what it claims."
		say ""
		say "Everything proven underneath is unchanged from the same boot:"
		say "fresh path, core init 0 -> 94 -> 95 with canary e4, identity"
		say "0x0102/0x0001, 460 cacheable registers still agreeing with the"
		say "chip, all 29 interrupt sources masked and nothing asserted."
		say ""
		say "What this does NOT cover: DAI routing, PCM, DAPM, controls, and"
		say "any audio path whatsoever. A component with no DAIs cannot be"
		say "bound into a card, so none of that is reachable from here and"
		say "none of it is claimed."
	else
		say "NOT PROVEN. $FAIL_N check(s) failed above."
		say ""
		say "If the component is missing from ASoC's list while the driver"
		say "logged a successful registration, the call returned 0 and the"
		say "component was dropped afterwards -- look for a later unregister,"
		say "or a devres unwind from a probe path that failed after this point."
		say ""
		say "If a DAI or a card appeared, the scope grew: this milestone is"
		say "registration only."
	fi

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1
RC=$?

rm -f "$DMESG_FILE"

sed -n '/=== what ASoC says it has/,$p' "$OUT"
printf '\nevidence: %s\n' "$OUT"
exit "$RC"

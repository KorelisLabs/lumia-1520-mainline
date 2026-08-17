#!/bin/sh
#
# Question 0: what audio services does this ADSP firmware actually have?
#
# The NGD work proved the DSP participates in SLIMbus satellite control. It
# proved nothing about AFE, ASM or ADM. Mainline's APR does not discover
# services -- of_register_apr_devices() creates a device per DT child with a
# "reg" and binds regardless of whether the firmware implements anything there
# -- so the inventory cannot be read out of DT or sysfs. It has to be asked.
#
# WHAT THE FIRST VERSION OF THIS SCRIPT GOT WRONG
#
# It assumed three things that source inspection disproved, and it reported C1
# on a boot where the transport was in fact working. Recorded here because the
# corrections are the whole reason this file looks the way it does.
#
#   1. It globbed /sys/bus/apr/devices. The bus is registered as "aprbus"
#      (drivers/soc/qcom/apr.c), so the glob silently returned nothing and a
#      bound APR device read as "none".
#
#   2. It assumed q6core would be loaded. CONFIG_SND_SOC_QDSP6=m makes q6core a
#      module, and apr.c:399 emits MODALIAS=apr:<name> while q6core.ko declares
#      only of: aliases -- so udev can never autoload it. It must be modprobed.
#      Worse, "fastboot boot" does not update /lib/modules at all, so a module
#      built into the package is not on the device until it is copied there.
#
#   3. It expected to read the inventory out of dmesg. q6core NEVER PRINTS IT.
#      The reply is kmemdup'd into a private struct behind a static g_core and
#      there is no sysfs, no debugfs and no printk of the service table. The
#      grep for num_services could not have matched on any boot, on any
#      firmware. An empty grep was not evidence of a silent DSP.
#
# The first two made a working transport look absent. The third meant the
# inventory was never obtainable by this mechanism in the first place. All
# three failed in the same direction -- toward a false negative about the
# firmware -- which is exactly the direction the four-verdict design existed to
# guard against, so the guard is now mechanical rather than editorial.
#
# HOW THE QUERY ACTUALLY WORKS (sound/soc/qcom/qdsp6/q6core.c)
#
#   q6core_probe() sends nothing. It kzallocs, sets drvdata, inits a mutex and
#   a waitqueue, returns 0. Binding q6core issues zero APR packets.
#
#   The query is lazy, behind q6core_get_svc_api_info(), whose only in-tree
#   callers are q6afe, q6asm and q6adm -- all deliberately out of scope here.
#
#   That call tries AVCS_CMD_GET_FWK_VERSION (0x0001292c) FIRST and only falls
#   through to AVCS_GET_VERSIONS (0x00012905) if the first returns -ENOTSUPP.
#   Note the mainline quirk: q6core_get_fwk_versions() returns wait_event_
#   timeout's rc, which is 0 on timeout, not -ENOTSUPP. So against a silent
#   ADSP, 0x00012905 is never put on the wire at all.
#
# THE VERDICTS, AND WHY THERE ARE SIX
#
#   A  INVENTORY_RECEIVED_AUDIO_PRESENT
#      a matching response arrived, the inventory is complete, and it contains
#      the services the conventional Q6 path needs.
#
#   B  INVENTORY_RECEIVED_AUDIO_ABSENT
#      the same successful transaction, a complete inventory, and the required
#      services are NOT in it. The meaningful architectural negative result.
#
#   C0 QUERY_MECHANISM_ABSENT                              <- new
#      transport and binding are fine but nothing ever triggered a query. Not
#      a firmware result at all. This is the state stock q6core sits in
#      forever, and the state the old script misreported as C1.
#
#   C1 APR_AUDIO_CHANNEL_ABSENT
#      the ADSP never exposes "apr_audio_svc", so APR cannot attach.
#
#   C2 CORE_QUERY_UNANSWERED
#      a query went out and no valid matching response arrived in the bound.
#
#   S  SETUP_INCOMPLETE                                    <- new
#      the module is missing from /lib/modules, or present and not bound.
#      An operator condition. Says nothing about anything.
#
# ONLY VERDICT B LICENSES SERVICE-ABSENCE LANGUAGE. Under C0/C1/C2/S this
# script refuses to emit "AFE absent", "ASM absent" or "Q6 audio unsupported":
# an absent inventory is not evidence about any individual service, and the
# refusal is enforced by refuse_absence_language() below, not by discipline.
#
# THE NEGATIVE CONTROL MUST BE A SEPARATE BUILD. q6core keeps its state in a
# file-scope "static struct q6core *g_core"; q6core_probe() overwrites it
# unconditionally and q6core_exit() NULLs it unconditionally regardless of
# which instance is leaving. Two simultaneous instances leak the first and let
# either one's removal blind the other. So the wrong-service-id control is a
# separate boot with the single node's reg changed -- never a second DT child.
#
# Exit: 0 A, 1 B, 2 C1, 3 C2, 4 INVALID IMAGE, 5 S, 6 C0.

set -u

MODE="q6-inventory"
DIR=$(dirname "$0")
#
# The codec driver is UNCHANGED by this experiment -- it differs only in
# config and DT -- so its MODULE_VERSION cannot tell us the right image is
# booted. The device tree itself is the gate: see the apr-node check below.
#
EXPECT_VERSION="${EXPECT_VERSION:-asoc-card-rc1}"
. "$DIR/wcd9320-evidence-lib.sh"

DT_BASE="${DT_BASE:-/sys/firmware/devicetree/base}"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-/tmp}"
DMESG_FILE="/tmp/.wcd9320-dmesg-q6-$$"

APR_CHANNEL="${APR_CHANNEL:-apr_audio_svc}"
# The bus is "aprbus", not "apr". apr.c registers it under that name and
# dev_set_name()s each child "aprsvc:<name>:<domain>:<svc>".
APR_BUS="${APR_BUS:-/sys/bus/aprbus}"
# The services the conventional QDSP6 playback path needs. From
# include/dt-bindings/soc/qcom,apr.h.
SVC_CORE=3
SVC_AFE=4
SVC_ASM=7
SVC_ADM=8

require_module_version
find_devices

#
# THE IMAGE GATE. Without this, "the channel never appeared" (C1) and "the old
# boot image was flashed" look identical -- and the first is a firmware
# finding while the second is an operator error. The DT node is present
# whether or not apr ever probes, so it distinguishes them exactly.
#
DT_APR=$(find "$DT_BASE" -maxdepth 6 -type d -name 'apr*' 2>/dev/null | head -n1)
DT_Q6CORE=$(find "$DT_BASE" -maxdepth 7 -type d -name 'service@3' 2>/dev/null | head -n1)
if [ -z "$DT_APR" ]; then
	say "INVALID RUN: no apr node in the booted device tree."
	say "  Looked under $DT_BASE."
	say "  This image does not carry the q6core probe DT, so a missing"
	say "  channel would be indistinguishable from a missing node."
	say "  Flash the q6-inventory image and run again."
	exit 4
fi

snap_dmesg
open_output "$OUTDIR/msm8974-q6-inventory-$STAMP.txt"

# ------------------------------------------------------ load what must load --
#
# q6core cannot autoload (apr: modalias vs of: aliases) and is not shipped in
# the device's /lib/modules by "fastboot boot". Both conditions are recorded,
# separately, because "module file missing" and "module present but refused to
# bind" are different problems and neither is a firmware result.
MODULE_FILE=0
MODULE_LOADED=0
MODPROBE_OUT=""
if modinfo q6core >/dev/null 2>&1; then
	MODULE_FILE=1
	MODPROBE_OUT=$(modprobe q6core 2>&1)
	sleep 1
fi
lsmod 2>/dev/null | grep -q '^q6core ' && MODULE_LOADED=1

# ------------------------------------------------- the transport boundary --
#
# Captured step by step so the verdicts are mechanically distinguishable
# rather than a matter of reading prose afterwards.
ADSP_STATE=$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)
# rpmsg devices for the lpass edge; the channel name is the device name.
RPMSG_DEVS=$(ls -1 /sys/bus/rpmsg/devices 2>/dev/null | tr '\n' ' ')
CHANNEL_PRESENT=0
printf '%s' "$RPMSG_DEVS" | grep -q "$APR_CHANNEL" && CHANNEL_PRESENT=1

# APR service devices are named aprsvc:<name>:<domain>:<svc>. Look on the real
# bus, and fall back to a scan so a future bus rename cannot silently zero this
# out the way the /sys/bus/apr assumption did.
APR_DEVS=$(ls -1 "$APR_BUS/devices" 2>/dev/null | tr '\n' ' ')
if [ -z "$APR_DEVS" ]; then
	APR_DEVS=$(ls -1d /sys/bus/*/devices/aprsvc:* 2>/dev/null |
		sed 's|.*/||' | tr '\n' ' ')
fi
APR_DEV_PRESENT=0
[ -n "$APR_DEVS" ] && APR_DEV_PRESENT=1
# The APR core also announces each child it creates. That log line is
# independent of any sysfs path assumption, so it is kept as a cross-check.
APR_ADDED=$(dmesg 2>/dev/null | grep -c 'Adding APR/GPR dev')

# Binding is the driver's link, not the device's existence.
Q6CORE_BOUND=0
if [ -d "$APR_BUS/drivers/qcom-q6core" ]; then
	_l=$(ls -1 "$APR_BUS/drivers/qcom-q6core" 2>/dev/null |
		grep -v '^bind$\|^unbind$\|^uevent$\|^module$')
	[ -n "$_l" ] && Q6CORE_BOUND=1
fi
# Cross-check via the device's own driver symlink.
if [ "$Q6CORE_BOUND" = "0" ]; then
	for d in $APR_DEVS; do
		_drv=$(readlink -f "$APR_BUS/devices/$d/driver" 2>/dev/null)
		case "$_drv" in *q6core*) Q6CORE_BOUND=1 ;; esac
	done
fi

MODULES=$(lsmod 2>/dev/null | grep -c '^q6core \|^snd_soc_qdsp6 ')

# ---------------------------------------------------- the query and reply --
#
# Stock q6core exposes NOTHING: no sysfs, no debugfs, no log of the service
# table. So the presence of a query is not inferred from silence -- it is
# asserted only if a probe mechanism that can trigger one is actually present.
# If none is, the verdict is C0 and no firmware claim is made.
QUERY_MECHANISM=0
QUERY_MECHANISM_NAME="none"
# The object is q6inventory_probe.o, so lsmod shows "q6inventory_probe" --
# no underscore after q6, and no dash for lsmod to translate.
if lsmod 2>/dev/null | grep -q '^q6inventory_probe '; then
	QUERY_MECHANISM=1
	QUERY_MECHANISM_NAME="q6inventory_probe.ko"
elif [ -r /sys/kernel/tracing/trace ] &&
	grep -q 'q6core_callback' /sys/kernel/tracing/kprobe_events 2>/dev/null; then
	QUERY_MECHANISM=1
	QUERY_MECHANISM_NAME="kprobe on q6core_callback"
fi

DMESG_APR=$(dmesg 2>/dev/null | grep -iE 'apr|q6core|adsp|avcs' | tail -40)
# Only the probe module reports an inventory; nothing in stock q6core does.
INVENTORY_RAW=$(dmesg 2>/dev/null | grep -iE 'q6-inventory|num_services|svc_api_info' | tail -20)
NUM_SERVICES=$(printf '%s\n' "$INVENTORY_RAW" |
	sed -n 's/.*num_services[=: ]*\([0-9]*\).*/\1/p' | tail -n1)
[ -n "${NUM_SERVICES:-}" ] || NUM_SERVICES=""

# ------------------------------------------------------------- classify ----
#
# Ordered so the earliest failure in the chain wins. Each branch names where
# the chain stopped; none of them may skip ahead to a claim about services.
VERDICT=""
if [ "$CHANNEL_PRESENT" = "0" ]; then
	VERDICT="C1"
elif [ "$MODULE_FILE" = "0" ] || [ "$MODULE_LOADED" = "0" ] || [ "$Q6CORE_BOUND" = "0" ]; then
	VERDICT="S"
elif [ "$QUERY_MECHANISM" = "0" ]; then
	VERDICT="C0"
elif [ -z "$NUM_SERVICES" ]; then
	VERDICT="C2"
else
	VERDICT="pending"
fi

#
# The enforcement the design asked for. Absence language is a function of the
# verdict, not of the author's mood, so it lives in a function that the
# non-B branches call and B does not.
#
refuse_absence_language() {
	say ""
	say "WHAT THIS DOES NOT ESTABLISH. Nothing about AFE, ASM, ADM or any"
	say "individual service. No inventory was received, so no service may be"
	say "called absent. The phrases 'AFE absent', 'ASM absent' and 'Q6 audio"
	say "unsupported' are NOT licensed by this run. This result is about"
	say "$1, not about the service table."
}

{
	hdr "the transport boundary, step by step"
	say "DT apr node             : $DT_APR"
	say "DT q6core node          : ${DT_Q6CORE:-absent}"
	say "ADSP remoteproc state   : ${ADSP_STATE:-unknown}"
	say "rpmsg devices           : ${RPMSG_DEVS:-none}"
	say "'$APR_CHANNEL' present  : $CHANNEL_PRESENT"
	say "APR bus                 : $APR_BUS"
	say "APR service devices     : ${APR_DEVS:-none}"
	say "APR device present      : $APR_DEV_PRESENT"
	say "'Adding APR/GPR dev' x  : $APR_ADDED"
	say "q6core.ko in /lib/modules: $MODULE_FILE"
	say "q6core loaded           : $MODULE_LOADED"
	say "q6core bound            : $Q6CORE_BOUND"
	say "q6/qdsp6 modules loaded : $MODULES"
	[ -n "$MODPROBE_OUT" ] && say "modprobe said           : $MODPROBE_OUT"

	hdr "the query"
	say "service   : APR_SVC_ADSP_CORE ($SVC_CORE), domain APR_DOMAIN_ADSP (4)"
	say "first req : AVCS_CMD_GET_FWK_VERSION  0x0001292c"
	say "  -> rsp  : AVCS_CMDRSP_GET_FWK_VERSION 0x0001292d"
	say "fallback  : AVCS_GET_VERSIONS         0x00012905"
	say "  -> rsp  : AVCS_GET_VERSIONS_RSP     0x00012906"
	say "  (reached only if the first returns -ENOTSUPP; a TIMEOUT on the"
	say "   first returns 0, so a silent ADSP never triggers the fallback)"
	say "bound     : Q6_READY_TIMEOUT_MS = 100 per request"
	say "trigger   : $QUERY_MECHANISM_NAME"
	say "num_services parsed : ${NUM_SERVICES:-none}"

	hdr "kernel log, apr/q6core/adsp"
	printf '%s\n' "${DMESG_APR:-  (nothing)}" | sed 's/^/  /'

	if [ -n "$INVENTORY_RAW" ]; then
		hdr "the inventory, verbatim"
		printf '%s\n' "$INVENTORY_RAW" | sed 's/^/  /'
	fi

	hdr "checks"
	check "module version" "$RUNNING_VERSION" "$EXPECT_VERSION"
	check "adsp state" "${ADSP_STATE:-x}" "running"
	check_cond "no kernel WARNING/BUG" \
		"$([ "$(dmesg 2>/dev/null | grep -c 'WARNING:\|BUG:')" -eq 0 ] && echo 1 || echo 0)" \
		"the log carries a WARNING or BUG" "none"

	# Scope: nothing beyond q6core may have instantiated.
	for svc in q6afe q6asm q6adm q6routing; do
		_n=$(printf '%s' "$APR_DEVS" | grep -ci "$svc")
		check "$svc NOT instantiated" "$_n" "0"
	done
	# And exactly one core instance, because g_core is a singleton.
	_ncore=$(printf '%s\n' "$APR_DEVS" | tr ' ' '\n' | grep -c ':3$')
	check_cond "exactly one q6core instance (g_core is a singleton)" \
		"$([ "$_ncore" -le 1 ] && echo 1 || echo 0)" \
		"$_ncore core devices -- g_core would be clobbered" "<=1"

	hdr "verdict"
	case "$VERDICT" in
	C1)
		say "C1  APR_AUDIO_CHANNEL_ABSENT"
		say ""
		say "The ADSP does not expose '$APR_CHANNEL' on the lpass SMD edge,"
		say "so APR could not attach and q6core was never created. No APR"
		say "transaction was attempted."
		refuse_absence_language "the channel"
		say ""
		say "Next: confirm the channel name and domain against the firmware,"
		say "and check whether the ADSP opens any audio channel at all."
		;;
	S)
		say "S   SETUP_INCOMPLETE -- not a result"
		say ""
		say "'$APR_CHANNEL' is present and APR created its device, but the"
		say "q6core driver is not bound to it:"
		say "  q6core.ko present in /lib/modules : $MODULE_FILE"
		say "  q6core loaded                     : $MODULE_LOADED"
		say "  q6core bound                      : $Q6CORE_BOUND"
		say ""
		say "Two standing traps produce this, and neither is a firmware fact:"
		say "  1. 'fastboot boot' does not update /lib/modules. A module built"
		say "     into the package is not on the device until it is copied."
		say "  2. q6core cannot autoload. apr.c emits MODALIAS=apr:<name> and"
		say "     q6core.ko declares only of: aliases, so udev never matches."
		say "     It must be modprobed explicitly on every boot."
		refuse_absence_language "driver binding"
		;;
	C0)
		say "C0  QUERY_MECHANISM_ABSENT -- not a result"
		say ""
		say "Transport, APR device and q6core binding are all good. No query"
		say "was issued, because nothing issued one."
		say ""
		say "q6core_probe() sends no packets. The inventory request is lazy,"
		say "behind q6core_get_svc_api_info(), whose only in-tree callers are"
		say "q6afe, q6asm and q6adm -- all out of scope for this milestone."
		say "And q6core never prints the reply: it is kmemdup'd into a private"
		say "struct behind a static g_core, with no sysfs and no debugfs."
		say ""
		say "So a bound q6core sits in this state indefinitely. Silence here"
		say "is the driver's design, NOT the firmware's answer."
		refuse_absence_language "the absence of a trigger"
		say ""
		say "Next: supply a trigger that uses only exported GPL symbols --"
		say "q6core_get_svc_api_info() -- and observe the reply opcode with a"
		say "kprobe on q6core_callback so that B and C2 stay distinguishable."
		;;
	C2)
		say "C2  CORE_QUERY_UNANSWERED"
		say ""
		say "'$APR_CHANNEL' exists, q6core is bound, a query was issued via"
		say "$QUERY_MECHANISM_NAME, and no valid matching response arrived"
		say "within the bound."
		refuse_absence_language "the core transaction"
		say ""
		say "Note before concluding: a timeout on AVCS_CMD_GET_FWK_VERSION"
		say "returns 0, not -ENOTSUPP, so AVCS_GET_VERSIONS was never sent as"
		say "a fallback. Silence on the first request is not silence on both."
		say ""
		say "Next: the negative control distinguishes addressing from"
		say "firmware -- a SEPARATE build with the q6core node's reg set to an"
		say "unused service id (never a second DT child; g_core is a"
		say "singleton). If the wrong address behaves identically to the right"
		say "one, addressing is not what is being tested."
		;;
	pending)
		say "INVENTORY RECEIVED -- num_services = $NUM_SERVICES"
		say ""
		say "Classify A vs B from the service table above:"
		say "  CORE = $SVC_CORE, AFE = $SVC_AFE, ASM = $SVC_ASM, ADM = $SVC_ADM"
		say ""
		say "A if the table contains the services the conventional Q6"
		say "playback path needs. B if the transaction succeeded and they are"
		say "genuinely not there -- which IS a licensed conclusion, because a"
		say "complete inventory was received."
		;;
	esac

	collect_evidence
	emit_verdict
} > "$OUT" 2>&1

rm -f "$DMESG_FILE"

sed -n '/=== the transport boundary/,$p' "$OUT" | sed -n '1,110p'
printf '\nevidence: %s\n' "$OUT"

case "$VERDICT" in
C1) exit 2 ;;
C2) exit 3 ;;
S)  exit 5 ;;
C0) exit 6 ;;
*)  exit 0 ;;
esac

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
# EXPECT_VERSION is resolved by the lib: environment, then the artefact
# manifest, then a hard failure. No stale default lives here any more.
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
DBG="${DBG:-/sys/kernel/debug/q6_inventory}"
TOKEN_ARM="arm-q6-inventory"
TOKEN_FIRE="fire-q6-inventory"

# The object is q6inventory_probe.o, so lsmod shows "q6inventory_probe" --
# no underscore after q6, and no dash for lsmod to translate. Like q6core it
# cannot autoload, so load it explicitly.
PROBE_FILE=0
PROBE_LOADED=0
if modinfo q6inventory_probe >/dev/null 2>&1; then
	PROBE_FILE=1
	modprobe q6inventory_probe 2>/dev/null
	sleep 1
fi
lsmod 2>/dev/null | grep -q '^q6inventory_probe ' && PROBE_LOADED=1

QUERY_MECHANISM=0
QUERY_MECHANISM_NAME="none"
if [ "$PROBE_LOADED" = "1" ] && [ -d "$DBG" ]; then
	QUERY_MECHANISM=1
	QUERY_MECHANISM_NAME="q6inventory_probe.ko"
fi

#
# FIRING IS IRREVERSIBLE AND THERE IS ONE QUERY PER BOOT, so it is opt-in.
# Without FIRE=1 this script observes and reports; it never spends the boot's
# only transaction as a side effect of someone looking at the state.
#
FIRE="${FIRE:-0}"
ARM_RESULT="not attempted"
FIRE_RESULT="not attempted"
FIRED_BY_THIS_RUN=0
if [ "$QUERY_MECHANISM" = "1" ] && [ "$FIRE" = "1" ]; then
	if printf '%s' "$TOKEN_ARM" > "$DBG/arm" 2>/dev/null; then
		ARM_RESULT="ok"
		# The module refuses ARM unless the observer is registered AND
		# q6core is bound, so reaching here means both held.
		if printf '%s' "$TOKEN_FIRE" > "$DBG/fire" 2>/dev/null; then
			FIRE_RESULT="ok"
			FIRED_BY_THIS_RUN=1
		else
			FIRE_RESULT="refused (errno $?)"
		fi
	else
		ARM_RESULT="refused -- observer unregistered or q6core unbound"
	fi
	sleep 1
fi

# ------------------------------------------------------- read the harness --
st() { sed -n "s/^$1=//p" /tmp/.q6inv-status-$$ 2>/dev/null | head -n1; }

STATUS_TEXT=""
if [ "$QUERY_MECHANISM" = "1" ] && [ -r "$DBG/status" ]; then
	cat "$DBG/status" > /tmp/.q6inv-status-$$ 2>/dev/null
	STATUS_TEXT=$(cat /tmp/.q6inv-status-$$ 2>/dev/null)
fi

HARNESS_STATE=$(st state)
PROBE_REGISTERED=$(st probe_registered)
RESOLVED_ADDR=$(st resolved_address)
CALLBACK_HITS=$(st callback_hits)
FWK_SEEN=$(st fwk_response_seen)
BASIC_SEEN=$(st basic_rsp_seen)
BASIC_OPCODE=$(st basic_rsp_original_opcode)
BASIC_STATUS=$(st basic_rsp_status)
BASIC_UNSUPP=$(st basic_rsp_is_unsupported)
LEGACY_SEEN=$(st legacy_response_seen)
PAYLOAD_SEEN=$(st inventory_payload_seen)
INV_OPCODE=$(st inventory_opcode)
PAYLOAD_SIZE=$(st payload_size)
CAPTURED_SIZE=$(st captured_size)
TRUNCATED=$(st truncated)
: "${HARNESS_STATE:=unknown}" "${PROBE_REGISTERED:=0}" "${CALLBACK_HITS:=0}"
: "${FWK_SEEN:=0}" "${BASIC_SEEN:=0}" "${LEGACY_SEEN:=0}" "${PAYLOAD_SEEN:=0}"
: "${TRUNCATED:=0}" "${PAYLOAD_SIZE:=0}" "${CAPTURED_SIZE:=0}"

# --------------------------------------------------- decode the raw table --
#
# od -tu4 prints 32-bit words in HOST byte order, which on this ARM is the
# same little-endian the ADSP wrote -- so the words come out directly and no
# byte-swapping is needed. Decoding here rather than in the kernel keeps the
# firmware's actual bytes in inventory_raw, so a parser found wrong later can
# be re-run against them.
#
#   AVCS_CMDRSP_GET_FWK_VERSION 0x0001292d
#       w0..w3 build major/minor/branch/subbranch, w4 num_services,
#       then triples {service_id, api_version, api_branch_version}
#   AVCS_GET_VERSIONS_RSP       0x00012906
#       w0 build_id, w1 num_services,
#       then pairs {service_id, version}
#
#
# Decoding lives in q6-decode-inventory.sh, which q6-decode-selftest.sh proves
# against nine synthetic payloads -- six of them malformed -- with no hardware
# involved. The inventory cannot be asked for twice, so the parser is proven
# before it is used, and the code proven is the code called.
#
NUM_SERVICES=""
SVC_TABLE=""
TABLE_CONSISTENT=0
TABLE_REASON=""
RAW_BYTES=0
if [ "$QUERY_MECHANISM" = "1" ] && [ -r "$DBG/inventory_raw" ]; then
	cat "$DBG/inventory_raw" > /tmp/.q6inv-raw-$$ 2>/dev/null
	RAW_BYTES=$(wc -c < /tmp/.q6inv-raw-$$ 2>/dev/null || echo 0)
fi

if [ "${RAW_BYTES:-0}" -gt 0 ] 2>/dev/null; then
	DECODED=$(sh "$DIR/q6-decode-inventory.sh" "/tmp/.q6inv-raw-$$" \
		"${INV_OPCODE:-none}" "${PAYLOAD_SIZE:-0}" 2>/dev/null)
	NUM_SERVICES=$(printf '%s\n' "$DECODED" | sed -n 's/^num_services=//p' | head -n1)
	TABLE_CONSISTENT=$(printf '%s\n' "$DECODED" | sed -n 's/^consistent=//p' | head -n1)
	TABLE_REASON=$(printf '%s\n' "$DECODED" | sed -n 's/^reason=//p' | head -n1)
	SVC_TABLE=$(printf '%s\n' "$DECODED" | grep '^service_id=')
fi
: "${TABLE_CONSISTENT:=0}"

# Which of the required services the firmware itself listed.
has_svc() {
	printf '%s\n' "$SVC_TABLE" | grep -q "^service_id=$1 "
}
AFE_PRESENT=0; ASM_PRESENT=0; ADM_PRESENT=0
[ "$TABLE_CONSISTENT" = "1" ] && {
	has_svc "$SVC_AFE" && AFE_PRESENT=1
	has_svc "$SVC_ASM" && ASM_PRESENT=1
	has_svc "$SVC_ADM" && ADM_PRESENT=1
}

DMESG_APR=$(dmesg 2>/dev/null | grep -iE 'apr|q6core|adsp|avcs|q6inventory' | tail -40)

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
elif [ "$PROBE_REGISTERED" != "1" ]; then
	# The observer could not be registered. A query may or may not have gone
	# out, but nothing could have seen the answer -- so this is a setup
	# failure and NEVER C2. Reporting an unobserved query as "the DSP was
	# silent" is the single worst outcome this experiment can produce.
	VERDICT="S"
elif [ "$HARNESS_STATE" != "FIRED" ]; then
	VERDICT="C0"
elif [ "$TRUNCATED" = "1" ]; then
	# A partial capture cannot establish that a service is absent, only that
	# it was not in the part that was kept. Not a firmware result either way.
	VERDICT="S"
elif [ "$PAYLOAD_SEEN" != "1" ] || [ "$TABLE_CONSISTENT" != "1" ]; then
	VERDICT="C2"
elif [ "$AFE_PRESENT" = "1" ] && [ "$ASM_PRESENT" = "1" ] && [ "$ADM_PRESENT" = "1" ]; then
	VERDICT="A"
else
	VERDICT="B"
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

	#
	# PROVENANCE. Derived, not declared: the only way this reads "live" is if
	# THIS run's write to the fire token succeeded. A run that finds the
	# harness already FIRED is reporting a measurement someone else took, and
	# says so -- which matters because the reporter once died on a run whose
	# measurement was perfect, and the formatted evidence had to be produced
	# afterwards. That distinction must survive into the artefact rather than
	# living in someone's memory of the session.
	#
	if [ "$HARNESS_STATE" = "FIRED" ] && [ "$FIRED_BY_THIS_RUN" = "0" ]; then
		_origin="reconstructed"
	else
		_origin="live"
	fi
	hdr "provenance"
	say "evidence_origin   : $_origin"
	say "source_status     : captured-live-debugfs ($DBG/status)"
	say "source_raw        : $DBG/inventory_raw"
	say "raw_size          : $RAW_BYTES"
	say "measurement_rerun : $FIRED_BY_THIS_RUN"
	if [ "$_origin" = "reconstructed" ]; then
		say ""
		say "The measurement was live and genuine -- the ADSP was queried once,"
		say "on this boot, and the harness captured the reply. This FILE was"
		say "generated afterwards from that captured state, because the"
		say "reporter aborted on its first attempt. No query was re-issued:"
		say "fire_count is still 1 and q6core's is_version_requested has been"
		say "latched since. Nothing here was re-measured."
	fi

	hdr "the harness"
	say "probe module in /lib/modules : $PROBE_FILE"
	say "probe module loaded          : $PROBE_LOADED"
	say "observer registered          : $PROBE_REGISTERED"
	say "observer address             : ${RESOLVED_ADDR:-none}"
	say "FIRE requested               : $FIRE"
	say "arm                          : $ARM_RESULT"
	say "fire                         : $FIRE_RESULT"
	say "state                        : $HARNESS_STATE"
	say "callback hits                : $CALLBACK_HITS"
	if [ -n "$STATUS_TEXT" ]; then
		hdr "status, verbatim"
		printf '%s\n' "$STATUS_TEXT" | sed 's/^/  /'
	fi

	hdr "what came back"
	say "fwk response seen      : $FWK_SEEN   (0x0001292d)"
	say "legacy response seen   : $LEGACY_SEEN   (0x00012906)"
	say "basic rsp seen         : $BASIC_SEEN   (0x000110E8)"
	say "  original opcode      : ${BASIC_OPCODE:-none}"
	say "  status               : ${BASIC_STATUS:-none}"
	say "  is ADSP_EUNSUPPORTED : ${BASIC_UNSUPP:-0}"
	if [ "${BASIC_UNSUPP:-0}" = "1" ]; then
		say "  -> the legacy fallback was LICENSED, not skipped"
	fi
	say "inventory payload seen : $PAYLOAD_SEEN"
	say "inventory opcode       : ${INV_OPCODE:-none}"
	say "payload_size           : $PAYLOAD_SIZE"
	say "captured_size          : $CAPTURED_SIZE"
	say "raw bytes read back    : $RAW_BYTES"
	say "truncated              : $TRUNCATED"
	say "num_services           : ${NUM_SERVICES:-none}"
	say "table consistent       : $TABLE_CONSISTENT"
	[ -n "$TABLE_REASON" ] && say "  refused because      : $TABLE_REASON"

	if [ -n "$SVC_TABLE" ]; then
		hdr "the inventory, as the firmware reported it"
		printf '%s\n' "$SVC_TABLE"
		say ""
		say "required services: AFE($SVC_AFE)=$AFE_PRESENT"
		say "                   ASM($SVC_ASM)=$ASM_PRESENT"
		say "                   ADM($SVC_ADM)=$ADM_PRESENT"
	fi

	hdr "the helper, cross-checked against that table"
	say "(these are lookups into one cached transaction, not four probes;"
	say " disagreement with the table above is itself a finding)"
	printf '%s\n' "$STATUS_TEXT" | grep '^svc[0-9]*_' | sed 's/^/  /'

	hdr "kernel log, apr/q6core/adsp"
	printf '%s\n' "${DMESG_APR:-  (nothing)}" | sed 's/^/  /'

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
		say "  probe module loaded               : $PROBE_LOADED"
		say "  observer registered               : $PROBE_REGISTERED"
		say "  capture truncated                 : $TRUNCATED"
		say ""
		if [ "$PROBE_REGISTERED" != "1" ] && [ "$PROBE_LOADED" = "1" ]; then
			say "The observer could not be registered on q6core_callback, so"
			say "nothing could have seen a reply. A query may or may not have"
			say "gone out. This is NOT C2: reporting an unobserved query as a"
			say "silent DSP would look exactly like a real firmware finding."
			say ""
		fi
		if [ "$TRUNCATED" = "1" ]; then
			say "The reply exceeded the capture buffer ($PAYLOAD_SIZE >"
			say "$CAPTURED_SIZE bytes). A partial table cannot establish that"
			say "a service is absent, only that it was not in the part kept."
			say "Raise Q6INV_CAP and take a fresh boot."
			say ""
		fi
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
	A)
		say "A   INVENTORY_RECEIVED_REQUIRED_AUDIO_PRESENT"
		say ""
		say "The ADSP answered on the core service and reported a complete,"
		say "self-consistent inventory of $NUM_SERVICES services. AFE($SVC_AFE),"
		say "ASM($SVC_ASM) and ADM($SVC_ADM) are all in it."
		say ""
		say "The conventional Qualcomm Q6 ASoC stack is physically possible on"
		say "this firmware. This does NOT establish that any of it works, only"
		say "that the services the stack addresses exist to be addressed."
		say ""
		say "Next: Branch A -- map the CPU DAI taxonomy and the per-component"
		say "DT requirements, then attempt the real CPU-DAI milestone. Data"
		say "movement stays a separate milestone after that."
		;;
	B)
		say "B   INVENTORY_RECEIVED_REQUIRED_AUDIO_ABSENT"
		say ""
		say "The ADSP answered on the core service and reported a complete,"
		say "self-consistent inventory of $NUM_SERVICES services. One or more of"
		say "the services the conventional Q6 path needs is NOT in it:"
		say "  AFE($SVC_AFE) present = $AFE_PRESENT"
		say "  ASM($SVC_ASM) present = $ASM_PRESENT"
		say "  ADM($SVC_ADM) present = $ADM_PRESENT"
		say ""
		say "THIS IS THE ONE VERDICT THAT LICENSES SERVICE-ABSENCE LANGUAGE,"
		say "because the firmware itself enumerated what it has. It is an"
		say "architectural finding, not a failed experiment:"
		say ""
		say "  This ADSP firmware provides the satellite/SLIMbus control"
		say "  functionality already observed, but does not provide the"
		say "  conventional Qualcomm audio-service interface that mainline's"
		say "  Q6 ASoC stack expects."
		say ""
		say "Next: Branch B -- freeze the finding. Do NOT invent shims. The"
		say "choice between a different DSP interface, reverse-engineering the"
		say "WP audio path, and a non-Q6 route is a separate decision made on"
		say "this evidence, not under it."
		;;
	esac

	collect_evidence
	emit_verdict

	# Written last, on purpose. Everything above is inside a block whose
	# stdout AND stderr go to the evidence file, so a shell abort in here --
	# set -u on a stale variable, say -- kills the script with its complaint
	# buried in a file nobody is looking at yet, and the terminal shows
	# NOTHING AT ALL. That happened on the run that answered Question 0: the
	# measurement succeeded and the reporter died mute. This marker is how the
	# caller can tell "finished" from "died halfway".
	say "REPORT_COMPLETE"
} > "$OUT" 2>&1

if ! grep -q '^REPORT_COMPLETE$' "$OUT" 2>/dev/null; then
	printf '\nREPORTER FAILED -- the evidence block aborted before finishing.\n' >&2
	printf 'The measurement may still be intact; this is a reporting fault.\n' >&2
	printf 'Tail of %s:\n' "$OUT" >&2
	tail -n 6 "$OUT" >&2 | sed 's/^/  /' >&2
	printf '\nThe harness state is authoritative and survives this:\n' >&2
	printf '  cat %s/status\n' "$DBG" >&2
	printf '  cat %s/inventory_raw > /tmp/q6.raw\n' "$DBG" >&2
	exit 7
fi

rm -f "$DMESG_FILE" /tmp/.q6inv-status-$$

# The firmware's own bytes are kept beside the evidence file, not only parsed
# into it: if this parser is later found wrong, the payload survives to be
# re-read. Named after the same stamp so the two cannot drift apart.
if [ -s /tmp/.q6inv-raw-$$ ]; then
	cp /tmp/.q6inv-raw-$$ "$OUTDIR/msm8974-q6-inventory-$STAMP.raw"
fi
rm -f /tmp/.q6inv-raw-$$

#
# The head of the report, then ALWAYS the checks and the verdict. A flat line
# cap put the verdict off the bottom of the terminal as soon as the report
# grew -- printing everything EXCEPT the conclusion is barely better than
# printing nothing, and it happened on the run that answered Question 0.
#
sed -n '/=== the transport boundary/,/^=== checks ===$/p' "$OUT" | sed '$d'
sed -n '/^=== checks ===$/,/^=== run identity ===$/p' "$OUT" | sed '$d'
tail -n 4 "$OUT"
printf '\nevidence: %s\n' "$OUT"

case "$VERDICT" in
A)  exit 0 ;;
B)  exit 1 ;;
C1) exit 2 ;;
C2) exit 3 ;;
S)  exit 5 ;;
C0) exit 6 ;;
*)  exit 4 ;;
esac

#!/bin/sh
#
# Decode an AVCS version-reply payload into a service table.
#
# Separate from the evidence script for one reason: the inventory arrives once
# per boot and cannot be asked for again, so the parser must be provable
# BEFORE it is used. Here it takes a file and prints a table, which means
# q6-decode-selftest.sh can drive it with synthetic payloads -- including the
# malformed ones -- on any machine, with no hardware involved.
#
# The kernel side deliberately captures bytes and interprets nothing. This is
# where interpretation happens, and it is kept honest by refusing to report a
# table the payload could not actually have contained.
#
# Usage: q6-decode-inventory.sh <rawfile> <inventory_opcode> <payload_size>
#
# Prints, on stdout:
#   num_services=N        (empty when nothing could be decoded)
#   consistent=0|1        1 only if payload_size accommodates N entries
#   reason=...            present only when consistent=0
#   service_id=S version=V branch=B     ... one line per entry
#
# Layouts, from sound/soc/qcom/qdsp6/q6core.c:
#
#   AVCS_CMDRSP_GET_FWK_VERSION 0x0001292d
#       w0..w3  build major / minor / branch / subbranch
#       w4      num_services
#       w5..    triples { service_id, api_version, api_branch_version }
#
#   AVCS_GET_VERSIONS_RSP       0x00012906
#       w0      build_id
#       w1      num_services
#       w2..    pairs   { service_id, version }
#
# od -tu4 emits 32-bit words in HOST byte order. Both the ADSP and this ARM
# are little-endian, so the words come out as written and nothing is swapped.

set -u

RAW="${1:-}"
OPCODE="${2:-}"
PSIZE="${3:-0}"

# A reply claiming more services than an APR packet could carry is malformed,
# not a large inventory. Bounded so a corrupt word cannot spin the loop.
MAX_SERVICES=256

fail() {	# fail <reason>
	echo "num_services="
	echo "consistent=0"
	echo "reason=$1"
	exit 0
}

case "$OPCODE" in
0x0001292d|0x1292d)	HDR=5; STRIDE=3 ;;
0x00012906|0x12906)	HDR=2; STRIDE=2 ;;
*)			fail "unknown or absent inventory opcode: ${OPCODE:-none}" ;;
esac

[ -n "$RAW" ] && [ -s "$RAW" ] || fail "no captured payload"

WORDS=$(od -An -tu4 -v "$RAW" 2>/dev/null)
[ -n "$WORDS" ] || fail "payload could not be read as 32-bit words"

# From here $1.. are the payload words, not the script's arguments.
# shellcheck disable=SC2086
set -- $WORDS

[ "$#" -ge "$HDR" ] || fail "payload holds $# words, need at least $HDR for a header"

eval "N=\${$HDR}"

case "$N" in
''|*[!0-9]*)	fail "num_services is not a number" ;;
esac
[ "$N" -gt 0 ]              || fail "num_services is 0 -- the firmware reported an empty table"
[ "$N" -le "$MAX_SERVICES" ] || fail "num_services=$N exceeds the sane bound ($MAX_SERVICES)"

echo "num_services=$N"

#
# THE CONSISTENCY RULE. payload_size is what the ADSP actually sent; the words
# available are what survived capture. A table is reported as consistent only
# if BOTH could hold N entries -- otherwise a truncated or corrupt reply could
# present a short table as a complete one, and "service absent" would be a
# statement about the capture rather than the firmware.
#
NEED_WORDS=$(( HDR + STRIDE * N ))
NEED_BYTES=$(( NEED_WORDS * 4 ))
if [ "$#" -lt "$NEED_WORDS" ]; then
	echo "consistent=0"
	echo "reason=captured $# words, need $NEED_WORDS for $N entries"
elif [ "${PSIZE:-0}" -lt "$NEED_BYTES" ] 2>/dev/null; then
	echo "consistent=0"
	echo "reason=payload_size $PSIZE < $NEED_BYTES required for $N entries"
else
	echo "consistent=1"
fi

i=0
while [ "$i" -lt "$N" ]; do
	b=$(( HDR + i * STRIDE ))
	[ "$#" -ge "$(( b + STRIDE ))" ] || break
	eval "sid=\${$(( b + 1 ))}"
	eval "ver=\${$(( b + 2 ))}"
	if [ "$STRIDE" = "3" ]; then
		eval "br=\${$(( b + 3 ))}"
	else
		br=0
	fi
	echo "service_id=$sid version=$ver branch=$br"
	i=$(( i + 1 ))
done

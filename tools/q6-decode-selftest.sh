#!/bin/sh
#
# Offline proof that q6-decode-inventory.sh reads a firmware reply correctly --
# and, just as importantly, that it REFUSES the malformed ones.
#
# The inventory arrives once per boot. If the parser were wrong we would not
# find out by re-asking; we would find out by drawing a false architectural
# conclusion from a table that was never really there. So every case below
# that must be refused is here because refusing it is the point.
#
# No hardware, no root, no kernel. Run it anywhere:
#   sh tools/q6-decode-selftest.sh
#
# Exit: 0 all cases pass, 1 otherwise.

set -u

DIR=$(dirname "$0")
DEC="$DIR/q6-decode-inventory.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0

# Little-endian u32, POSIX-portable: no python, no perl.
u32() {
	_v=$1
	printf "\\$(printf '%03o' $(( _v & 255 )))"
	printf "\\$(printf '%03o' $(( (_v >> 8) & 255 )))"
	printf "\\$(printf '%03o' $(( (_v >> 16) & 255 )))"
	printf "\\$(printf '%03o' $(( (_v >> 24) & 255 )))"
}

check() {	# check <label> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '    PASS  %-40s %s\n' "$1" "$2"
		PASS=$((PASS + 1))
	else
		printf '    FAIL  %-40s got=%s want=%s\n' "$1" "$2" "$3"
		FAIL=$((FAIL + 1))
	fi
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1; }

# ---------------------------------------------------------------- case 1 --
echo "case 1: FWK reply, 4 services including AFE/ASM/ADM  -> full table"
{
	u32 1; u32 2; u32 3; u32 4       # build major/minor/branch/subbranch
	u32 4                            # num_services
	u32 3; u32 100; u32 1            # core
	u32 4; u32 200; u32 2            # AFE
	u32 7; u32 300; u32 3            # ASM
	u32 8; u32 400; u32 4            # ADM
} > "$W/fwk.bin"
OUT=$(sh "$DEC" "$W/fwk.bin" 0x0001292d "$(wc -c < "$W/fwk.bin")")
check "num_services"      "$(field "$OUT" num_services)" "4"
check "consistent"        "$(field "$OUT" consistent)"   "1"
check "entry count"       "$(printf '%s\n' "$OUT" | grep -c '^service_id=')" "4"
check "AFE present"       "$(printf '%s\n' "$OUT" | grep -c 'service_id=4 version=200 branch=2')" "1"
check "ADM present"       "$(printf '%s\n' "$OUT" | grep -c 'service_id=8 version=400 branch=4')" "1"

# ---------------------------------------------------------------- case 2 --
echo "case 2: legacy reply, 2 services, 8-byte stride"
{
	u32 305419896                    # build_id
	u32 2                            # num_services
	u32 3; u32 11
	u32 4; u32 22
} > "$W/leg.bin"
OUT=$(sh "$DEC" "$W/leg.bin" 0x00012906 "$(wc -c < "$W/leg.bin")")
check "num_services"      "$(field "$OUT" num_services)" "2"
check "consistent"        "$(field "$OUT" consistent)"   "1"
check "stride is 2 words" "$(printf '%s\n' "$OUT" | grep -c 'service_id=4 version=22 branch=0')" "1"

# ---------------------------------------------------------------- case 3 --
echo "case 3: FWK reply WITHOUT AFE -- must decode cleanly (this is verdict B)"
{
	u32 1; u32 0; u32 0; u32 0
	u32 2
	u32 3; u32 100; u32 1
	u32 7; u32 300; u32 3
} > "$W/noafe.bin"
OUT=$(sh "$DEC" "$W/noafe.bin" 0x0001292d "$(wc -c < "$W/noafe.bin")")
check "num_services"      "$(field "$OUT" num_services)" "2"
check "consistent"        "$(field "$OUT" consistent)"   "1"
check "AFE absent"        "$(printf '%s\n' "$OUT" | grep -c '^service_id=4 ')" "0"
check "ASM present"       "$(printf '%s\n' "$OUT" | grep -c '^service_id=7 ')" "1"

# ---------------------------------------------------------------- case 4 --
echo "case 4: num_services claims more than the payload holds -> REFUSED"
{
	u32 1; u32 0; u32 0; u32 0
	u32 9                            # claims 9, carries 1
	u32 3; u32 100; u32 1
} > "$W/short.bin"
OUT=$(sh "$DEC" "$W/short.bin" 0x0001292d "$(wc -c < "$W/short.bin")")
check "num_services read"  "$(field "$OUT" num_services)" "9"
check "consistent"         "$(field "$OUT" consistent)"   "0"
check "gives a reason"     "$([ -n "$(field "$OUT" reason)" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------- case 5 --
echo "case 5: truncated capture -- payload_size larger than bytes kept -> REFUSED"
# The firmware sent 4 services; only 2 entries' worth survived capture.
{
	u32 1; u32 0; u32 0; u32 0
	u32 4
	u32 3; u32 100; u32 1
	u32 4; u32 200; u32 2
} > "$W/trunc.bin"
# payload_size says the real reply was bigger than what we hold.
OUT=$(sh "$DEC" "$W/trunc.bin" 0x0001292d 200)
check "consistent"         "$(field "$OUT" consistent)"   "0"
check "reason names words" "$(printf '%s\n' "$OUT" | grep -c '^reason=captured ')" "1"

# ---------------------------------------------------------------- case 6 --
echo "case 6: an APR_BASIC_RSP_RESULT is not an inventory -> REFUSED"
{ u32 76589; u32 3; } > "$W/basic.bin"
OUT=$(sh "$DEC" "$W/basic.bin" 0x000110E8 8)
check "num_services empty" "$(field "$OUT" num_services)" ""
check "consistent"         "$(field "$OUT" consistent)"   "0"

# ---------------------------------------------------------------- case 7 --
echo "case 7: nothing captured at all -> REFUSED"
: > "$W/empty.bin"
OUT=$(sh "$DEC" "$W/empty.bin" 0x0001292d 0)
check "consistent"         "$(field "$OUT" consistent)"   "0"
check "no entries"         "$(printf '%s\n' "$OUT" | grep -c '^service_id=')" "0"

# ---------------------------------------------------------------- case 8 --
echo "case 8: absurd num_services -> REFUSED, and does not hang"
{
	u32 0; u32 0; u32 0; u32 0
	u32 4294967295
} > "$W/absurd.bin"
OUT=$(sh "$DEC" "$W/absurd.bin" 0x0001292d 4096)
check "consistent"         "$(field "$OUT" consistent)"   "0"
check "no entries emitted" "$(printf '%s\n' "$OUT" | grep -c '^service_id=')" "0"

# ---------------------------------------------------------------- case 9 --
echo "case 9: empty table (num_services=0) is refused, not read as 'no services'"
{ u32 0; u32 0; u32 0; u32 0; u32 0; } > "$W/zero.bin"
OUT=$(sh "$DEC" "$W/zero.bin" 0x0001292d 20)
check "consistent"         "$(field "$OUT" consistent)"   "0"
check "num_services empty" "$(field "$OUT" num_services)" ""

echo
echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "decoder proven against 9 cases, 6 of them malformed."

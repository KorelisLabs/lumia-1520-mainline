#!/bin/sh
#
# r184: the DAPM emergency teardown. One implementation, three triggers --
# the listen runner's abort, its signal trap, and the transient fail-safe
# timer -- exactly as wcd9320-hphl-pa-teardown.sh is for C3a.
#
# THREE INDEPENDENT WAYS DOWN, IN THIS ORDER:
#
#   1. the Headphones pin OFF. DAPM runs the mapped reverse sequence at once
#      (PA, DAC, RX1, prereq, prep, MCLK), synchronously inside the control
#      write, whether or not the stream is still playing.
#   2. the player killed. The stream stopping also powers the path down, and
#      it is the only thing that does if the pin write failed.
#   3. the driver's C3 abort (wcd9320-hphl-pa-teardown.sh), UNCONDITIONALLY.
#      If DAPM did its job this is a no-op. If it did not, this takes the PA,
#      the DAC, both forced inverses and the prep down under c3_lock, and the
#      DAPM events later find them already off and tolerate it.
#
# ALWAYS EXITS 0, for the same reason the C3a teardown does: this IS the
# fallback, and a caller has nothing useful to do with a failure.
#
# Usage:  wcd9320-dapm-teardown.sh [reason]

set -u

REASON="${1:-unspecified}"
DIR=$(dirname "$0")
STAMP=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || echo unknown)
JOURNAL="${C3A_JOURNAL:-/var/log/wcd9320-c3a-journal.txt}"
CTLDEV="${CTLDEV:-/dev/snd/controlC0}"
PIN="${DAPM_PIN:-Headphones Switch}"
PLAYER="${DAPM_PLAYER:-pcm-tone}"

note() {
	printf '%s dapm-teardown: %s\n' "$STAMP" "$*"
	printf '%s dapm-teardown: %s\n' "$STAMP" "$*" >> "$JOURNAL" 2>/dev/null
	sync 2>/dev/null
}

note "invoked, reason=$REASON"

SETCTL=""
for c in "${ALSA_SETCTL:-}" "$DIR/alsa-setctl" /tmp/alsa-setctl; do
	[ -n "$c" ] && [ -x "$c" ] && { SETCTL="$c"; break; }
done

# 1. the pin
if [ -z "$SETCTL" ]; then
	note "NO alsa-setctl -- the pin could not be switched off"
elif _td_out=$("$SETCTL" -D "$CTLDEV" --set "$PIN" 0 2>&1) &&
     printf '%s\n' "$_td_out" | grep -q '^readback=0$'; then
	note "pin OFF ($PIN), read back 0"
else
	note "PIN OFF FAILED ($PIN): $(printf '%s' "$_td_out" | tr '\n' ' ')"
fi

# 2. the player
if pkill -x "$PLAYER" 2>/dev/null; then
	note "player $PLAYER killed"
else
	note "no $PLAYER running"
fi

# 3. the driver's C3 abort, whatever happened above
sh "$DIR/wcd9320-hphl-pa-teardown.sh" "dapm-$REASON" >/dev/null 2>&1
note "C3 abort issued"

exit 0

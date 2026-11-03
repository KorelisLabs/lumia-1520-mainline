#!/bin/bash
#
# Approve ONE C3a gate, by name, from the workstation.
#
# In acoustic runs the operator approves turning the amplifier on in chat, and
# this is how that approval reaches the phone: a file in the runner's drop-box,
# named for the gate and containing its name.
#
# IT REFUSES unless the phone is waiting at EXACTLY the gate named here. The
# person approving says which gate they mean, so an approval meant for cycle 1
# can never land on cycle 2, and nothing is approved when no gate is open. The
# runner adds its own guard on the other end: any approval that exists before a
# gate opens is deleted, so an early one never counts.
#
# Usage (from WSL, where the `lumia` ssh host is defined):
#   tools/c3a-approve.sh dc-pa-off-c1
#
# Exit: 0 approved, 2 refused.

set -u
WANT="${1:-}"
[ -n "$WANT" ] || { echo "usage: $0 <gate-label>   e.g. dc-pa-off-c1" >&2; exit 2; }
case "$WANT" in
*[!a-z0-9-]*) echo "REFUSED: '$WANT' is not a gate label" >&2; exit 2 ;;
esac

ssh -o ConnectTimeout=10 lumia "WANT=$WANT sh -s" <<'REMOTE'
J=/var/log/wcd9320-c3a-journal.txt
D=/run/wcd9320-c3a-approve
systemctl is-active -q wcd9320-c3a.service ||
	{ echo "REFUSED: no C3a run is active"; exit 2; }
[ -d "$D" ] || { echo "REFUSED: no approval drop-box -- not a chat-approval run"; exit 2; }
last=$(grep -E "GATE [a-z0-9-]+: " "$J" | tail -n 1)
case "$last" in
*": waiting up to"*) ;;
*) echo "REFUSED: no gate is open (last gate line: ${last:-none})"; exit 2 ;;
esac
open=$(printf '%s' "$last" | sed -n 's/.*GATE \([a-z0-9-]*\): waiting.*/\1/p')
if [ "$open" != "$WANT" ]; then
	echo "REFUSED: the open gate is '$open', not '$WANT'"
	exit 2
fi
echo "$WANT" | sudo tee "$D/$WANT" >/dev/null &&
	echo "APPROVED gate $WANT" ||
	{ echo "REFUSED: could not write the approval"; exit 2; }
REMOTE

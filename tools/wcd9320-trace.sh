#!/bin/sh
#
# r202: switch the codec driver's debug messages (its normal-path register,
# stage and stream lines) on or off by hand. They are dev_dbg since r202, so
# they appear in dmesg only while this is on. Off is the daily default.
#
# Usage (as root): sh wcd9320-trace.sh on|off|status
# Exit: 0 done, 2 bad argument or dynamic debug unavailable.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/wcd9320-trace-lib.sh"

case "${1:-status}" in
on)	echo 'module wcd9320 +p' > "$WCD_DYNDBG" || exit 2 ;;
off)	echo 'module wcd9320 -p' > "$WCD_DYNDBG" || exit 2 ;;
status)	;;
*)	echo "usage: $0 on|off|status"; exit 2 ;;
esac
_s=$(wcd_trace_state)
echo "wcd9320 debug messages: $_s"
[ "$_s" = unavailable ] && exit 2
exit 0

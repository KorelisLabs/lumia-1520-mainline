#!/bin/sh
#
# r202: the codec's normal-path messages are dev_dbg (docs/audio/
# wcd9320-logging-mapping.md). A run that reads them from dmesg switches the
# module's dynamic debug on first and puts the setting back at the end -- the
# message text is unchanged, only its level. One implementation, sourced by
# wcd9320-evidence-lib.sh, wcd9320-capture.sh, wcd9320-duplex-probe.sh and
# wcd9320-trace.sh.
#
#   wcd_trace_on        enable (once per run); notes whether it already was
#   wcd_trace_restore   disable again only if this run enabled it
#   wcd_trace_state     on | off | partial | unavailable
#
# WCD_TRACE=0 in the environment skips enabling (the quiet check), and is
# inherited by any runner started from this one.

WCD_DYNDBG="${WCD_DYNDBG:-/sys/kernel/debug/dynamic_debug/control}"

wcd_trace_state() {
	[ -r "$WCD_DYNDBG" ] || { echo unavailable; return 0; }
	_wt=$(grep '\[wcd9320\]' "$WCD_DYNDBG" 2>/dev/null)
	[ -n "$_wt" ] || { echo unavailable; return 0; }
	_won=$(printf '%s\n' "$_wt" | grep -c ' =p')
	_wall=$(printf '%s\n' "$_wt" | grep -c .)
	if [ "$_won" = 0 ]; then echo off
	elif [ "$_won" = "$_wall" ]; then echo on
	else echo partial; fi
}

wcd_trace_on() {
	[ -n "${WCD_TRACE_WAS:-}" ] && return 0
	if [ "${WCD_TRACE:-1}" = 0 ]; then
		WCD_TRACE_WAS=skipped
		return 0
	fi
	WCD_TRACE_WAS=$(wcd_trace_state)
	case "$WCD_TRACE_WAS" in
	off|partial) echo 'module wcd9320 +p' > "$WCD_DYNDBG" 2>/dev/null ;;
	esac
	return 0
}

wcd_trace_restore() {
	case "${WCD_TRACE_WAS:-}" in
	off) echo 'module wcd9320 -p' > "$WCD_DYNDBG" 2>/dev/null ;;
	esac
	WCD_TRACE_WAS=""
	return 0
}

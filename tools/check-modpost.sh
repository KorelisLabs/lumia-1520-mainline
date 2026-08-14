#!/bin/sh
#
# Scan a pmbootstrap build log for unresolved symbols.
#
# Why this exists: nested-irq-rc1 compiled cleanly and then died at modpost
# with
#
#   ERROR: modpost: "devm_regmap_add_irq_chip" [drivers/slimbus/wcd9320.ko] undefined!
#
# because CONFIG_REGMAP_IRQ was not set. The symbol lives in
# drivers/base/regmap/regmap-irq.c, which that option gates, and REGMAP_IRQ
# has no prompt -- drivers using it are expected to select it, and ours did
# not.
#
# No amount of source checking finds this. The code is correct; the symbol
# simply does not exist in the configured kernel. It is a Kconfig dependency
# error, and it surfaces only at link time.
#
# The build script's existing guard catches the consequence -- no package is
# produced -- but reports it as "no package at rN", which says nothing about
# why. This turns that into the actual cause.
#
# Usage: check-modpost.sh [logfile]
# Exit:  0 clean, 1 unresolved symbols found.

LOG="${1:-$HOME/.local/var/pmbootstrap/log.txt}"
[ -r "$LOG" ] || { echo "cannot read $LOG"; exit 1; }

# Only the tail matters: the log is append-only across every build ever run,
# so older failures would otherwise be reported as current ones.
TAIL=$(tail -6000 "$LOG")

UNDEF=$(printf '%s\n' "$TAIL" | grep -i 'modpost:.*undefined\|No rule to make target.*\.ko\|undefined reference')
if [ -n "$UNDEF" ]; then
	echo "UNRESOLVED SYMBOLS:"
	printf '%s\n' "$UNDEF" | sed 's/^/  /'
	echo
	echo "Almost always a missing Kconfig select. For each symbol, find the"
	echo "file that defines it and the CONFIG_ option gating that file, then"
	echo "add a 'select' to the driver's Kconfig entry -- not just a line in"
	echo "the config, which a regenerated config would silently drop."
	exit 1
fi

if printf '%s\n' "$TAIL" | grep -q 'Module.symvers.*Error\|modpost.*Error'; then
	echo "modpost failed but no symbol name was matched; inspect manually:"
	printf '%s\n' "$TAIL" | grep -n -B3 'Module.symvers.*Error\|modpost.*Error' |
		tail -20 | sed 's/^/  /'
	exit 1
fi

echo "no unresolved symbols in the last 6000 log lines"
exit 0

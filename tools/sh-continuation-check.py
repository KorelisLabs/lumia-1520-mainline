#!/usr/bin/env python3
"""Find a backslash-continued shell line followed by a blank or comment line.

THE r174 DEFECT. Stripping stale references from the D1 gate line by line left

    check "..." \\
    <blank line>

so check() ran with one argument and died on $2 under set -u. `sh -n` cannot
see it -- the syntax stays valid, only the arguments vanish.

This lived in a session scratchpad during C3a and was lost with it, which is
the reason it is a repo tool now rather than a one-off.

Usage:  sh-continuation-check.py <script.sh> [more.sh ...]
Exit:   0 clean, 1 if any dangling continuation is found.
"""
import sys

bad = 0
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").read().split("\n")
    for i, ln in enumerate(lines[:-1]):
        if not ln.endswith("\\"):
            continue
        nxt = lines[i + 1]
        if nxt.strip() == "" or nxt.lstrip().startswith("#"):
            print("  DANGLING %s:%d  continuation followed by %s"
                  % (path, i + 1,
                     "a blank line" if not nxt.strip() else "a comment"))
            bad += 1
print("  %d dangling continuation(s)" % bad)
sys.exit(1 if bad else 0)

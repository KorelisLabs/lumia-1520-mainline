#!/usr/bin/env python3
"""Find shell helpers that clobber a variable their caller is still using.

WHY THIS EXISTS

POSIX sh has no local variables. Every name a function assigns is global, so a
helper and its caller sharing a loop variable is a silent, action-at-a-distance
bug -- not a syntax error, not a runtime error, just wrong values.

It cost a hardware run on this project. wcd9320-hphl-dac-evidence.sh had:

    run_cycle()   { _n=$1; ...; arm_probes; ...; eval "C${_n}_AFTER=..." }
    arm_probes()  { for _p in $PROBES; do _n=${_p%%:*}; ... done }

After arm_probes(), "$_n" was "c2b_slimen" rather than the cycle number, so
every capture after the first stream landed in Cc2b_slimen_AFTER and the gate
graded unset variables. The register sequence itself was correct; only the
bookkeeping was wrong, which is the hardest kind of failure to see in a log.

WHAT IT FLAGS, AND WHAT IT DELIBERATELY DOES NOT

The condition that actually bites is a CALLER/CALLEE pair sharing a name. Two
helpers that merely happen to use the same loop variable and never call one
another are fine, and flagging them trains people to ignore the tool. So this
walks the call graph -- transitively -- and reports only real collisions.

The first version of this script did flag those, and also missed the bug it was
written for: its assignment regex was not multiline, so a tab-indented "_n=" at
the start of a line never matched. Both are fixed; the self-test below exists
so a regression in either direction is caught here rather than on hardware.

Usage:
  wcd9320-sh-scope-lint.py <script.sh> [more.sh ...]
  wcd9320-sh-scope-lint.py --self-test

Exit: 0 clean, 1 if any caller/callee collision is found.
"""
import re
import sys

# Names the scripts intentionally share across scopes.
SHARED = {
    "PASS_N", "FAIL_N", "OUT", "EXPECT_VERSION", "EXPECT_SHA",
    "EXPECT_SOURCE", "EXPECT_SHA_SOURCE", "MANIFEST_PATH",
    "RUNNING_VERSION", "PGD", "PGD_NAME", "PA_SAMPLES", "STALE",
    # C3a: run-wide state that the trap, the gates and the report all read.
    # ABORTED in particular MUST be global -- a teardown triggered from a
    # signal handler and one triggered from a gate have to see the same flag,
    # or the run can tear down twice.
    "ABORTED", "ABORT_WHY", "WATCH_PID",
    # selftest counters, deliberately accumulated by the check helpers
    "PASS", "FAIL",
}

FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)
# Multiline, and tolerant of leading whitespace -- the two things the first
# version got wrong.
ASSIGN = re.compile(
    r"(?m)(?:^|[;&|(]|\bfor\b|\bdo\b|\bthen\b|\belse\b)\s*"
    r"([A-Za-z_][A-Za-z0-9_]*)=")
FORVAR = re.compile(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b")


def strip_comments(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)


def bodies(text):
    """Yield (name, body) for each shell function, by brace matching."""
    out = []
    for m in FUNC.finditer(text):
        i = text.index("{", m.start())
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((m.group(1), text[i:j]))
    return out


def analyse(text):
    text = strip_comments(text)
    funcs = bodies(text)
    names = [n for n, _ in funcs]

    assigns, calls = {}, {}
    for fname, body in funcs:
        assigns[fname] = ((set(ASSIGN.findall(body)) | set(FORVAR.findall(body)))
                          - SHARED)
        calls[fname] = {o for o in names
                        if o != fname
                        and re.search(r"(?m)(?:^|[;&|(\s])%s(?:\s|;|$|\))"
                                      % re.escape(o), body)}

    def reachable(start, seen=None):
        seen = seen if seen is not None else set()
        for c in calls.get(start, ()):
            if c not in seen:
                seen.add(c)
                reachable(c, seen)
        return seen

    findings = []
    for f in names:
        for g in reachable(f):
            shared = assigns[f] & assigns[g]
            for v in sorted(shared):
                findings.append((v, f, g))

    # A helper assigning a name the top level also assigns is the same bug.
    top = text
    for _, body in funcs:
        top = top.replace(body, "")
    top_names = (set(ASSIGN.findall(top)) | set(FORVAR.findall(top))) - SHARED
    top_findings = []
    for f in names:
        for v in sorted(assigns[f] & top_names):
            top_findings.append((v, f))

    return findings, top_findings


def check(path):
    findings, top_findings = analyse(open(path, encoding="utf-8").read())
    print("=== %s ===" % path)
    if findings:
        for v, caller, callee in findings:
            print("  FAIL  %-12s %s() calls %s(), both assign it"
                  % (v, caller, callee))
    else:
        print("  PASS  no caller/callee pair shares a variable")
    if top_findings:
        for v, f in top_findings:
            print("  WARN  %-12s assigned at top level and in %s()" % (v, f))
    return len(findings)


SELF_BUGGY = """
arm_probes() {
\tfor _p in $PROBES; do
\t\t_n=${_p%%:*}; _s=${_p#*:}
\tdone
}
run_cycle() {
\t_n=$1
\tarm_probes
\teval "C${_n}_AFTER=x"
}
"""

SELF_FIXED = """
arm_probes() {
\tfor _pr_p in $PROBES; do
\t\t_pr_n=${_pr_p%%:*}; _pr_s=${_pr_p#*:}
\tdone
}
run_cycle() {
\t_cyc=$1
\tarm_probes
\teval "C${_cyc}_AFTER=x"
}
"""

SELF_INDEPENDENT = """
arm_probes()   { for _pr_p in $PROBES; do echo "$_pr_p"; done; }
clear_probes() { for _pr_p in $PROBES; do echo "$_pr_p"; done; }
"""


def self_test():
    ok = True
    bad, _ = analyse(SELF_BUGGY)
    hit = any(v == "_n" for v, _, _ in bad)
    print("  %s the known real bug is caught (_n via run_cycle -> arm_probes)"
          % ("PASS " if hit else "FAIL "))
    ok &= hit

    good, _ = analyse(SELF_FIXED)
    print("  %s the fixed version is clean" % ("PASS " if not good else "FAIL "))
    ok &= not good

    ind, _ = analyse(SELF_INDEPENDENT)
    print("  %s helpers that never call each other are NOT flagged"
          % ("PASS " if not ind else "FAIL "))
    ok &= not ind

    print()
    print("self-test: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--self-test":
        sys.exit(self_test())
    total = sum(check(p) for p in sys.argv[1:])
    print()
    print("scope lint: %s" % ("CLEAN" if not total else "%d collision(s)" % total))
    sys.exit(1 if total else 0)

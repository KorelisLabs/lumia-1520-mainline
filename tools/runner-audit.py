#!/usr/bin/env python3
"""Audit pcm-run-measured.c. Its constraints are the INVERSE of the oracle's.

pcm-helper-audit.py exists to prove pcm-prepare-only cannot start a stream.
This tool must start one -- that is its whole job -- so requiring the same
things would be nonsense. What matters here instead is that it is BOUNDED and
that it stays on the PCM device it was pointed at.

An instrument that can spin forever against a wedged DSP is not an instrument:
it turns a failed measurement into a hung phone and an evidence file that never
gets written.

Comments and string literals are stripped FIRST. The file documents that it
never touches the control device, and that sentence contains the words it would
be checked for -- a guard satisfied by prose is worse than no guard, because it
reports success.

Exit: 0 clean, 1 rejected, 2 usage/selftest failure.
"""
import re
import sys

FORBIDDEN = [
    (r"\bwhile\s*\(\s*1\s*\)", "while (1): the run must be bounded"),
    (r"\bfor\s*\(\s*;\s*;\s*\)", "for (;;): the run must be bounded"),
    (r"\bSNDRV_CTL_IOCTL_\w+", "a control ioctl: this tool drives a PCM only"),
    (r"\bsystem\s*\(", "system(): no shelling out"),
    (r"\bpopen\s*\(", "popen(): no shelling out"),
    (r"\bexecl?[epv]*\s*\(", "exec*(): no handing off"),
    (r"\bfork\s*\(", "fork(): no child processes"),
]

REQUIRED = [
    (r"\bSNDRV_PCM_IOCTL_WRITEI_FRAMES\b", "write frames (it must supply data)"),
    (r"\bSNDRV_PCM_IOCTL_START\b", "an EXPLICIT start, so RUN is observable"),
    (r"\bSNDRV_PCM_IOCTL_STATUS\b", "read status, to observe progression"),
    (r"\bSNDRV_PCM_IOCTL_DROP\b", "stop cleanly at the end"),
    (r"NEVER_START_THRESHOLD", "a start threshold that prevents implicit start"),
]

# The measurement loop must be governed by a deadline, not merely be finite.
DEADLINE = re.compile(r"while\s*\([^)]*now_s\s*\(\s*\)[^)]*\)", re.S)


def strip(src: str) -> str:
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src[i] in "\"'":
            q, i = src[i], i + 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                i += 1
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def audit(src: str):
    code = strip(src)
    bad = [why for pat, why in FORBIDDEN if re.search(pat, code)]
    missing = [why for pat, why in REQUIRED if not re.search(pat, code)]
    if not DEADLINE.search(code):
        missing.append("a loop condition governed by a wall-clock deadline")
    return bad, missing


def selftest() -> int:
    ok = """
    ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf);
    ioctl(fd, SNDRV_PCM_IOCTL_START, 0);
    while (started && (now_s() - t0) < secs) {
        ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st);
    }
    ioctl(fd, SNDRV_PCM_IOCTL_DROP, 0);
    x = NEVER_START_THRESHOLD;
    """
    cases = [
        ("clean source", ok, True),
        ("while (1) rejected", ok + "while (1) { }", False),
        ("for (;;) rejected", ok + "for (;;) { }", False),
        ("control ioctl rejected", ok + "ioctl(c, SNDRV_CTL_IOCTL_ELEM_WRITE, &v);", False),
        ("system() rejected", ok + "system(cmd);", False),
        ("missing explicit START rejected",
         ok.replace("SNDRV_PCM_IOCTL_START", "SNDRV_PCM_IOCTL_PREPARE"), False),
        ("unbounded loop rejected",
         ok.replace("while (started && (now_s() - t0) < secs)", "while (going)"), False),
        ("prose cannot rescue a bad file",
         "/* there is no while (1) here */" + ok + "for (;;) { }", False),
        ("a string literal cannot satisfy a requirement",
         'const char *s = "SNDRV_PCM_IOCTL_WRITEI_FRAMES SNDRV_PCM_IOCTL_START '
         'SNDRV_PCM_IOCTL_STATUS SNDRV_PCM_IOCTL_DROP NEVER_START_THRESHOLD";', False),
    ]
    fails = 0
    for name, body, want in cases:
        bad, missing = audit(body)
        got = not bad and not missing
        if got != want:
            fails += 1
        print("  %s %s" % ("ok  " if got == want else "FAIL", name))
    reject = sum(1 for _, _, w in cases if not w)
    print("  %d cases, %d of which must be rejected, %d wrong"
          % (len(cases), reject, fails))
    return 1 if fails else 0


def main() -> int:
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    if len(args) != 1:
        print(__doc__.strip())
        return 2
    with open(args[0], encoding="utf-8") as fh:
        bad, missing = audit(fh.read())
    for why in bad:
        print("REJECTED: contains " + why)
    for why in missing:
        print("REJECTED: missing " + why)
    if bad or missing:
        return 1
    print("audit: %s is clean (drives a PCM, bounded by a deadline)" % args[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())

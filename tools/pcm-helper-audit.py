#!/usr/bin/env python3
"""Audit pcm-prepare-only.c for the calls it must and must not contain.

This tool's entire value is what it does NOT do: it must drive an ALSA PCM to
PREPARED and stop, so that a Q6 control-plane run can prove the DSP
acknowledges setup commands without a single sample moving.

A plain grep cannot check that.  The source documents the prohibition in its
own comments, so `grep SNDRV_PCM_IOCTL_START` matches the very sentence saying
it is never used -- the first version of this check would have refused to build
a correct program.  So comments and string literals are stripped first and only
real code is examined.

Kept as a separate file rather than inlined in the build script because it is
worth testing on its own: --selftest feeds it deliberately bad sources and
requires that it rejects them.

Exit: 0 the source is acceptable, 1 it is not, 2 usage error.
"""

import re
import sys
import tempfile
import os

FORBIDDEN = [
    ("SNDRV_PCM_IOCTL_START", r"SNDRV_PCM_IOCTL_START\b"),
    ("SNDRV_PCM_IOCTL_DRAIN", r"SNDRV_PCM_IOCTL_DRAIN\b"),
    ("SNDRV_PCM_IOCTL_WRITEI", r"SNDRV_PCM_IOCTL_WRITEI"),
    ("SNDRV_PCM_IOCTL_WRITEN", r"SNDRV_PCM_IOCTL_WRITEN"),
    ("write() syscall", r"(?<![_A-Za-z])write\s*\("),
    ("writev() syscall", r"(?<![_A-Za-z])writev\s*\("),
    ("pwrite() syscall", r"(?<![_A-Za-z])pwrite\s*\("),
    ("mmap() syscall", r"(?<![_A-Za-z])mmap\s*\("),
]

REQUIRED = [
    "SNDRV_PCM_IOCTL_HW_PARAMS",
    "SNDRV_PCM_IOCTL_SW_PARAMS",
    "SNDRV_PCM_IOCTL_PREPARE",
    "SNDRV_PCM_IOCTL_DROP",
]


def strip_noncode(src: str) -> str:
    """Remove block comments, line comments and string literals.

    Deliberately errs toward removing too much: a forbidden name appearing
    inside a string is not a call, and neither is one inside a comment.  What
    remains is close enough to 'code' for this audit's purpose.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif c == "/" and nxt == "/":
            j = src.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
        elif c == "'":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            out.append("''")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def audit(path: str, quiet: bool = False) -> int:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        print("cannot read %s: %s" % (path, e), file=sys.stderr)
        return 2

    code = strip_noncode(src)
    bad = 0

    for name, pat in FORBIDDEN:
        if re.search(pat, code):
            if not quiet:
                print("  PRESENT IN CODE (forbidden): %s" % name)
            bad = 1
        elif not quiet:
            print("  absent : %s" % name)

    for name in REQUIRED:
        if re.search(r"%s\b" % name, code):
            if not quiet:
                print("  present: %s" % name)
        else:
            if not quiet:
                print("  MISSING: %s" % name)
            bad = 1

    return bad


def selftest() -> int:
    """The audit must reject sources that should be rejected.

    A checker that cannot fail is worth nothing, and this one guards the only
    property that makes the helper a valid instrument.
    """
    good = """
        /* never SNDRV_PCM_IOCTL_START, never write() -- documented only */
        // also not SNDRV_PCM_IOCTL_DRAIN
        int main(void) {
            const char *s = "write( and SNDRV_PCM_IOCTL_START in a string";
            ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw);
            ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw);
            ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, NULL);
            ioctl(fd, SNDRV_PCM_IOCTL_DROP, NULL);
            return 0;
        }
    """
    cases = [
        ("comments and strings do not trip it", good, 0),
        ("a real START ioctl is caught", good.replace(
            "ioctl(fd, SNDRV_PCM_IOCTL_DROP, NULL);",
            "ioctl(fd, SNDRV_PCM_IOCTL_START, NULL);"), 1),
        ("a real write() is caught", good.replace(
            "return 0;", "write(fd, buf, 4); return 0;"), 1),
        ("a real mmap() is caught", good.replace(
            "return 0;", "mmap(0,0,0,0,fd,0); return 0;"), 1),
        ("a missing required ioctl is caught", good.replace(
            "ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, NULL);", ""), 1),
    ]

    failures = 0
    for label, body, want in cases:
        fd, path = tempfile.mkstemp(suffix=".c")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(body)
            got = audit(path, quiet=True)
        finally:
            os.unlink(path)
        ok = got == want
        print("  %-42s got=%d want=%d  %s" %
              (label, got, want, "PASS" if ok else "FAIL"))
        if not ok:
            failures += 1

    print()
    if failures:
        print("SELFTEST FAILED: %d case(s)" % failures)
        return 1
    print("SELFTEST PASSED: %d cases, including 4 that must be rejected"
          % len(cases))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(audit(sys.argv[1]))

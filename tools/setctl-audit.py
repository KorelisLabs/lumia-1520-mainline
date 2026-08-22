#!/usr/bin/env python3
"""Audit alsa-setctl.c: it must be able to set a control and nothing more.

The build-2 milestone's central claim is that no samples moved. Every tool the
gate runs has to be incapable of moving them, not merely trusted not to. This
checks the source before it is allowed to become a binary.

Comments and string literals are stripped FIRST. A naive grep matches the file's
own documentation -- the sentence explaining that there is no PCM ioctl contains
the words "PCM ioctl" -- and a guard that passes by matching prose is worse than
no guard, because it reports success.

Exit: 0 clean, 1 rejected, 2 usage/selftest failure.
"""
import re
import sys

FORBIDDEN = [
    (r"\bSNDRV_PCM_IOCTL_\w+", "a PCM ioctl: this tool must not touch a stream"),
    (r"\bpcmC\w*", "a PCM device path"),
    (r"\bwrite\s*\(", "write(): the helper must never push samples"),
    (r"\bsystem\s*\(", "system(): no shelling out"),
    (r"\bpopen\s*\(", "popen(): no shelling out"),
    (r"\bexecl?[epv]*\s*\(", "exec*(): no handing off to another program"),
    (r"\bfork\s*\(", "fork(): no child processes"),
]

REQUIRED = [
    (r"\bSNDRV_CTL_IOCTL_ELEM_LIST\b", "enumerate controls (proves the name exists)"),
    (r"\bSNDRV_CTL_IOCTL_ELEM_INFO\b", "read type/count before writing"),
    (r"\bSNDRV_CTL_IOCTL_ELEM_WRITE\b", "set the control"),
    (r"\bSNDRV_CTL_IOCTL_ELEM_READ\b", "read back (a write returning 0 is not proof)"),
]


def strip(src: str) -> str:
    """Remove block comments, line comments, and string/char literals."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif c in "\"'":
            q, i = c, i + 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def audit(src: str):
    code = strip(src)
    bad = [why for pat, why in FORBIDDEN if re.search(pat, code)]
    missing = [why for pat, why in REQUIRED if not re.search(pat, code)]
    return bad, missing


def selftest() -> int:
    ok_body = """
    ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &l);
    ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &i);
    ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &v);
    ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &v);
    """
    cases = [
        ("clean source", ok_body, True),
        ("prose-only mention must NOT rescue a bad file",
         '/* no PCM ioctl here */\n' + ok_body + "ioctl(f, SNDRV_PCM_IOCTL_PREPARE, 0);", False),
        ("comment claiming safety must not itself pass the required check",
         "/* SNDRV_CTL_IOCTL_ELEM_LIST INFO WRITE READ */ int main(void){return 0;}", False),
        ("write() rejected", ok_body + "write(fd, b, 4);", False),
        ("pcm device path rejected", ok_body + 'x = open(pcmC0D0p_ident);', False),
        ("missing readback rejected",
         "ioctl(f,SNDRV_CTL_IOCTL_ELEM_LIST,0);ioctl(f,SNDRV_CTL_IOCTL_ELEM_INFO,0);"
         "ioctl(f,SNDRV_CTL_IOCTL_ELEM_WRITE,0);", False),
        ("string literal cannot satisfy a requirement",
         'const char *s = "SNDRV_CTL_IOCTL_ELEM_LIST SNDRV_CTL_IOCTL_ELEM_INFO '
         'SNDRV_CTL_IOCTL_ELEM_WRITE SNDRV_CTL_IOCTL_ELEM_READ";', False),
    ]
    fails = 0
    for name, body, want_pass in cases:
        bad, missing = audit(body)
        got_pass = not bad and not missing
        mark = "ok  " if got_pass == want_pass else "FAIL"
        if got_pass != want_pass:
            fails += 1
        print(f"  {mark} {name}")
    rejecting = sum(1 for _, _, w in cases if not w)
    print(f"  {len(cases)} cases, {rejecting} of which must be rejected, {fails} wrong")
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
        print(f"REJECTED: contains {why}")
    for why in missing:
        print(f"REJECTED: missing {why}")
    if bad or missing:
        return 1
    print(f"audit: {args[0]} is clean (control plane only, reads back what it writes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

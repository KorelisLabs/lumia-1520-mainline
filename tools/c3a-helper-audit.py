#!/usr/bin/env python3
"""Audit the two C3a helpers. Each one's fence is a different kind of promise.

pcm-tone's promise is about AMPLITUDE. It enables nothing itself, but it is the
only thing that puts a signal into a live power amplifier, and the mapping
freezes that signal at 1 kHz and -40 dBFS with -20 dBFS as an absolute ceiling.
The fence proves the ceiling is compiled in, that the escalation steps require
an explicit act, and that no full-scale or ramp stimulus can be produced at all.

input-gate's promise is about POLARITY. It is a safety interlock driven by two
hardware buttons on a phone with no ssh, and every ambiguous outcome -- a
timeout, a missing device, a read error, a node that moved -- must resolve to
ABORT. A gate that failed open would enable a PA because a file could not be
opened. The fence proves each of those paths returns a non-approve code, that
neither device node is hardcoded, and that the on-device event layout is the
measured one rather than the host header's.

COMMENTS AND STRING LITERALS ARE STRIPPED BEFORE THE STRUCTURAL CHECKS.

Both files document what they refuse to do, in prose that necessarily contains
the words a naive checker would look for. pcm-tone's header block says "It
cannot emit a ramp"; input-gate's says "a timeout is an abort". A guard
satisfied by a comment is worse than no guard, because it reports success.

Definitions are checked against the RAW source instead, anchored to a #define
at the start of a line, because that is a form prose cannot accidentally take.

Usage:
  c3a-helper-audit.py --pcm-tone   tools/pcm-tone.c
  c3a-helper-audit.py --input-gate tools/input-gate.c
  c3a-helper-audit.py --selftest

Exit: 0 clean, 1 rejected, 2 usage/selftest failure.
"""
import re
import sys


def strip(src: str) -> str:
    """Remove comments and string/char literals, preserving line structure."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
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
            out.append(' "" ')
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def strip_comments(src: str) -> str:
    """Remove comments but KEEP string literals.

    THE THIRD VIEW, AND IT EARNS ITS PLACE.

    Some forbidden things are string literals by their nature: a hardcoded
    "event3", a sysfs path handed to open(). Checking those against the fully
    stripped source cannot work -- the literal is gone before the check runs,
    so the check passes on exactly the file it exists to reject. Checking them
    against the raw source cannot work either, because this file's own header
    block explains what it must not contain and would match itself.

    Removing comments and keeping literals catches both: prose cannot satisfy
    it, and a bad literal cannot hide from it. The selftest has a case for each
    direction.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
        elif src[i] in "\"'":
            q = src[i]
            out.append(src[i])
            i += 1
            while i < n:
                if src[i] == "\\":
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i])
                if src[i] == q:
                    i += 1
                    break
                i += 1
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def defined_as(raw: str, name: str):
    """Every '#define NAME value' in the raw source, as a list of values."""
    pat = re.compile(r"^#define\s+%s\s+(.+?)\s*(?:/\*.*)?$" % re.escape(name),
                     re.M)
    return [m.strip() for m in pat.findall(raw)]


# --------------------------------------------------------------- pcm-tone --

TONE_DEFINES = [
    ("DBFS_CEILING", "(-20.0)", "the compiled amplitude ceiling"),
    ("DBFS_DEFAULT", "(-40.0)", "the frozen starting amplitude"),
    ("DBFS_ESCALATION", "(-40.0)", "louder than this needs an explicit act"),
    ("TONE_RATE", "48000", "the frozen sample rate"),
    ("TONE_CHANNELS", "1", "HPHL only, mono"),
    ("TONE_HZ", "1000", "the frozen stimulus frequency"),
    ("SEG_MS", "250", "the frozen segment length"),
    ("N_SEGMENTS", "4", "tone, silence, tone, silence"),
]

TONE_FORBIDDEN = [
    # The ramp. Its two signatures, either of which would reproduce
    # pcm-run-measured's full-scale sawtooth inside this tool.
    (r"\*\s*37\b", "the counting-ramp multiplier from pcm-run-measured"),
    (r"0x7fff\b", "a full-scale mask -- this tool must not reach full scale"),
    (r"\bwhile\s*\(\s*1\s*\)", "while (1): the stimulus must be bounded"),
    (r"\bfor\s*\(\s*;\s*;\s*\)", "for (;;): the stimulus must be bounded"),
    (r"\bSNDRV_CTL_IOCTL_\w+", "a control ioctl: this drives a PCM only"),
    (r"\bsystem\s*\(", "system(): no shelling out"),
    (r"\bgetenv\s*\(", "getenv(): the amplitude must come from the command "
                       "line, never from the environment"),
]

TONE_REQUIRED = [
    (r"dbfs\s*<=\s*DBFS_CEILING", "the ceiling comparison itself"),
    (r"dbfs\s*>\s*DBFS_ESCALATION\s*&&\s*!\s*armed",
     "the escalation gate, which needs the explicit arming flag"),
    (r"\bSNDRV_PCM_IOCTL_WRITEI_FRAMES\b", "writing frames"),
    (r"\bSNDRV_PCM_IOCTL_START\b", "an explicit start"),
    (r"NEVER_START_THRESHOLD", "a threshold preventing an implicit start"),
    (r"frames_written\s*<\s*total_frames", "a bounded frame count"),
    (r"now_s\s*\(\s*\)\s*-\s*t0\s*\)\s*<", "a deadline as well as a count"),
]


def audit_tone(raw: str):
    src = strip(raw)
    bad, missing = [], []

    for pat, why in TONE_FORBIDDEN:
        if re.search(pat, src):
            bad.append(why)
    for pat, why in TONE_REQUIRED:
        if not re.search(pat, src):
            missing.append(why)

    for name, want, why in TONE_DEFINES:
        got = defined_as(raw, name)
        if got != [want]:
            missing.append("%s defined as %s (%s); found %s"
                           % (name, want, why, got or "nothing"))

    # THE CEILING MUST BE REFUSED BEFORE THE DEVICE IS OPENED.
    #
    # A refusal after the PCM is configured would leave a prepared stream on a
    # codec whose PA may already be live. Position is the check: the ceiling
    # comparison has to appear earlier in the file than the open().
    mc = re.search(r"dbfs\s*<=\s*DBFS_CEILING", src)
    mo = re.search(r"\bopen\s*\(\s*dev\b", src)
    if mc and mo and mc.start() > mo.start():
        bad.append("a ceiling check that runs AFTER the device is opened")
    elif not mo:
        missing.append("an open() of the PCM device to order the check against")

    # The amplitude must be derived from the checked variable and nothing else.
    if not re.search(r"peak\s*=.*\bdbfs\b", src, re.S | re.M):
        missing.append("a peak amplitude derived from the checked dbfs value")
    return bad, missing


# ------------------------------------------------------------- input-gate --

GATE_DEFINES = [
    ("APPROVE_KEY", "115", "KEY_VOLUMEUP, confirmed by a real press"),
    ("ABORT_KEY", "114", "KEY_VOLUMEDOWN, confirmed by a real press"),
    ("EV_STRIDE", "16", "the measured on-device input_event size"),
    ("EV_OFF_TYPE", "8", "type at offset 8"),
    ("EV_OFF_CODE", "10", "code at offset 10"),
    ("EV_OFF_VALUE", "12", "value at offset 12"),
    ("VAL_PRESS", "1", "presses only; releases and autorepeat are ignored"),
]

GATE_STRING_DEFINES = [
    ("APPROVE_DEV", '"gpio-keys"', "the approve device, resolved by name"),
    ("ABORT_DEV", '"pm8941_resin"', "the abort device, a DIFFERENT device"),
]

GATE_FORBIDDEN = [
    # struct input_event is 24 bytes on a 64-bit-time build and 16 here. A
    # reader using the host layout finds `type` where `usec` is and concludes
    # nothing was ever pressed: an interlock that silently never fires.
    (r"\bstruct\s+input_event\b",
     "struct input_event -- the on-device layout is 16 bytes and is parsed "
     "at fixed offsets instead"),
    (r"\bsystem\s*\(", "system(): the interlock does not shell out"),
]

# Checked with comments removed and STRING LITERALS KEPT: both of these are
# literals in any file that actually commits the sin, and both are discussed in
# prose by any file that does not.
GATE_FORBIDDEN_LITERAL = [
    # THE NODE NUMBERS MOVE BETWEEN BOOTS. Anything of the form eventN is a
    # hardcoded node, and the Synaptics touchscreen has already re-ordered
    # them once. "eventN" and "event%" are not matched -- only a real digit.
    (r"event[0-9]", "a hardcoded eventN node -- numbering is not stable"),
    # One writer to the codec. The watcher signals; the runner acts.
    (r"/sys/", "a sysfs path -- the watcher must not touch the codec itself"),
]

GATE_REQUIRED = [
    (r"EVIOCGNAME", "the EVIOCGNAME confirmation after resolving by name"),
    (r"flock\s*\(", "a lock, so a second concurrent arm is refused"),
    (r"le32\s*\(\s*e\s*\+\s*EV_OFF_VALUE\s*\)\s*!=\s*VAL_PRESS",
     "presses only -- releases and autorepeat must be ignored"),
]

# Every ambiguous outcome resolves to something other than approve.
GATE_POLARITY = [
    (r"hit\s*==\s*-1", "RC_TIMEOUT", "a timeout must return the timeout code"),
]


def audit_gate(raw: str):
    src = strip(raw)
    bad, missing = [], []

    for pat, why in GATE_FORBIDDEN:
        if re.search(pat, src):
            bad.append(why)
    lit = strip_comments(raw)
    for pat, why in GATE_FORBIDDEN_LITERAL:
        if re.search(pat, lit):
            bad.append(why)
    for pat, why in GATE_REQUIRED:
        if not re.search(pat, src):
            missing.append(why)

    # CHECKED AGAINST THE RAW SOURCE, and anchored to an assignment.
    #
    # The kernel's device list is named by a STRING LITERAL, and strip()
    # removes string literals -- so a requirement written against the stripped
    # source could never be satisfied by any file, however correct. Requiring
    # the assignment form keeps prose from standing in for it.
    if not re.search(r'=\s*"/proc/bus/input/devices"', raw):
        missing.append("resolution by name from the kernel's device list, "
                       "assigned from /proc/bus/input/devices")

    for name, want, why in GATE_DEFINES + GATE_STRING_DEFINES:
        got = defined_as(raw, name)
        if got != [want]:
            missing.append("%s defined as %s (%s); found %s"
                           % (name, want, why, got or "nothing"))

    # THE EXIT CODES ARE THE INTERFACE. The runner branches on every one.
    for name, want in (("RC_APPROVE", "0"), ("RC_ABORT", "1"),
                       ("RC_TIMEOUT", "2"), ("RC_SETUP", "3"),
                       ("RC_BUSY", "4")):
        if not re.search(r"\b%s\s*=\s*%s\b" % (name, want), src):
            missing.append("%s = %s in the exit-code enum" % (name, want))

    # POLARITY: the timeout branch must not return approve. Checked as a
    # relation between the condition and the value returned under it, not by
    # the presence of the words.
    for cond, want, why in GATE_POLARITY:
        for m in re.finditer(cond, src):
            tail = src[m.end():m.end() + 400]
            ret = re.search(r"return\s+(RC_\w+)", tail)
            if ret and ret.group(1) == "RC_APPROVE":
                bad.append("a path where %s returns RC_APPROVE -- %s"
                           % (cond, why))

    # Refusing to arm when EITHER device is missing. An approve button that
    # works with an abort button that does not is worse than neither, because
    # it looks armed.
    if not re.search(r"afd\s*<\s*0\s*\|\|\s*bfd\s*<\s*0", src):
        missing.append("a refusal to arm unless BOTH devices are present")
    return bad, missing


# ---------------------------------------------------------------- selftest --

TONE_OK = """
#define DBFS_CEILING\t(-20.0)
#define DBFS_DEFAULT\t(-40.0)
#define DBFS_ESCALATION\t(-40.0)
#define TONE_RATE\t48000
#define TONE_CHANNELS\t1
#define TONE_HZ\t1000
#define SEG_MS\t250
#define N_SEGMENTS\t4
#define NEVER_START_THRESHOLD 0x7ffffffUL
int main(void) {
\tif (!(dbfs <= DBFS_CEILING)) return 2;
\tif (dbfs > DBFS_ESCALATION && !armed) return 2;
\tpeak = lround(FULL * pow(10.0, dbfs / 20.0));
\tfd = open(dev, O_RDWR);
\twhile (frames_written < total_frames && (now_s() - t0) < 10.0) {
\t\tioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf);
\t\tioctl(fd, SNDRV_PCM_IOCTL_START, 0);
\t}
}
"""

GATE_OK = """
#define APPROVE_DEV\t"gpio-keys"
#define APPROVE_KEY\t115
#define ABORT_DEV\t"pm8941_resin"
#define ABORT_KEY\t114
#define EV_STRIDE\t16
#define EV_OFF_TYPE\t8
#define EV_OFF_CODE\t10
#define EV_OFF_VALUE\t12
#define VAL_PRESS\t1
enum rc { RC_APPROVE = 0, RC_ABORT = 1, RC_TIMEOUT = 2, RC_SETUP = 3,
\t  RC_BUSY = 4 };
static const char *p = "/proc/bus/input/devices";
int main(void) {
\tioctl(fd, EVIOCGNAME(255), got);
\tflock(fd, LOCK_EX | LOCK_NB);
\tif (le32(e + EV_OFF_VALUE) != VAL_PRESS) continue;
\tif (afd < 0 || bfd < 0) return RC_SETUP;
\tif (hit == -1) return RC_TIMEOUT;
}
"""


def selftest() -> int:
    cases = [
        ("a correct pcm-tone is accepted", audit_tone, TONE_OK, True),
        ("the ceiling cannot be raised",
         audit_tone, TONE_OK.replace("(-20.0)", "(-6.0)"), False),
        ("the ceiling check cannot move after open()",
         audit_tone,
         TONE_OK.replace("\tif (!(dbfs <= DBFS_CEILING)) return 2;\n", "")
                .replace("\tfd = open(dev, O_RDWR);",
                         "\tfd = open(dev, O_RDWR);\n"
                         "\tif (!(dbfs <= DBFS_CEILING)) return 2;"), False),
        ("dropping the escalation gate is rejected",
         audit_tone,
         TONE_OK.replace("if (dbfs > DBFS_ESCALATION && !armed) return 2;",
                         "if (0) return 2;"), False),
        ("the ramp multiplier is rejected",
         audit_tone, TONE_OK + "\nshort v = (short)((i * 37) & 0x7fff);", False),
        ("a moved segment length is rejected",
         audit_tone, TONE_OK.replace("#define SEG_MS\t250",
                                     "#define SEG_MS\t500"), False),
        ("reading the amplitude from the environment is rejected",
         audit_tone, TONE_OK + "\nchar *e = getenv(\"DBFS\");", False),
        ("prose cannot rescue pcm-tone",
         audit_tone,
         "/* it never uses i * 37 or 0x7fff */" + TONE_OK
         + "\nshort v = (short)((i * 37) & 0x7fff);", False),

        ("a correct input-gate is accepted", audit_gate, GATE_OK, True),
        ("a hardcoded event node is rejected",
         audit_gate, GATE_OK + '\nfd = open_node(3, "event3");', False),
        ("struct input_event is rejected",
         audit_gate, GATE_OK + "\nstruct input_event ev;", False),
        ("a timeout that returns approve is rejected",
         audit_gate, GATE_OK.replace("if (hit == -1) return RC_TIMEOUT;",
                                     "if (hit == -1) return RC_APPROVE;"), False),
        ("swapped key codes are rejected",
         audit_gate, GATE_OK.replace("#define APPROVE_KEY\t115",
                                     "#define APPROVE_KEY\t114"), False),
        ("arming on one device only is rejected",
         audit_gate, GATE_OK.replace("if (afd < 0 || bfd < 0) return RC_SETUP;",
                                     "if (afd < 0) return RC_SETUP;"), False),
        ("dropping the EVIOCGNAME confirmation is rejected",
         audit_gate, GATE_OK.replace("ioctl(fd, EVIOCGNAME(255), got);", ""),
         False),
        ("accepting releases as presses is rejected",
         audit_gate,
         GATE_OK.replace("if (le32(e + EV_OFF_VALUE) != VAL_PRESS) continue;",
                         "if (0) continue;"), False),
        ("a watcher that pokes sysfs is rejected",
         audit_gate, GATE_OK + '\nw = open("/sys/bus/slimbus/x", O_WRONLY);',
         False),
        ("a comment naming event0 does not itself fail the file",
         audit_gate, "/* eventN moves; never write event0 here */" + GATE_OK,
         True),
        ("prose cannot rescue input-gate",
         audit_gate,
         "/* no struct input_event and no event0 here */" + GATE_OK
         + "\nstruct input_event ev;", False),
    ]
    fails = 0
    for name, fn, body, want in cases:
        bad, missing = fn(body)
        got = not bad and not missing
        if got != want:
            fails += 1
            for why in bad:
                print("      contains: " + why)
            for why in missing:
                print("      missing : " + why)
        print("  %s %s" % ("ok  " if got == want else "FAIL", name))
    reject = sum(1 for _, _, _, w in cases if not w)
    print("  %d cases, %d of which must be rejected, %d wrong"
          % (len(cases), reject, fails))
    return 1 if fails else 0


def main() -> int:
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    if len(args) != 2 or args[0] not in ("--pcm-tone", "--input-gate"):
        print(__doc__.strip())
        return 2
    fn = audit_tone if args[0] == "--pcm-tone" else audit_gate
    with open(args[1], encoding="utf-8") as fh:
        bad, missing = fn(fh.read())
    for why in bad:
        print("REJECTED: contains " + why)
    for why in missing:
        print("REJECTED: missing " + why)
    if bad or missing:
        return 1
    what = ("the amplitude ceiling is compiled in and unreachable"
            if args[0] == "--pcm-tone"
            else "every ambiguous outcome resolves to abort")
    print("audit: %s is clean (%s)" % (args[1], what))
    return 0


if __name__ == "__main__":
    sys.exit(main())

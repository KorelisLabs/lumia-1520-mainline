#!/usr/bin/env python3
"""Verify a built wcd9320 module against the regcache acceptance criteria.

Every check reads the built artefact, not the build log. pmbootstrap's exit
code is untrustworthy on this machine (it returns non-zero when a post-run
umount fails despite a good build) and a stale package will otherwise pass
silently, so nothing here trusts that a build "succeeded".

The ELF is parsed directly rather than through binutils: the host toolchain is
x86 and refuses the ARM object outright.

Usage:
  wcd9320-verify-artifact.py                     find and check the r<pkgrel> apk
  wcd9320-verify-artifact.py --ko path/to.ko     check a loose module
  wcd9320-verify-artifact.py --pkgrel 144 --expect-version regcache-rc9

Exit: 0 all checks pass, 1 something failed.
"""
import argparse
import glob
import hashlib
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

# Derived from the evidence, and the reason each number is what it is lives in
# docs/audio/wcd9320-reg-defaults.md.
EXPECT = {
    "readable": 669,
    "volatile": 401,
    "defaults": 460,
    "zero_defaults": 230,
    "bypass_calls": 10,      # five bypass(true)/bypass(false) pairs
}

REPO = pathlib.Path(__file__).resolve().parent.parent
PATCH = REPO / "patches/0002-slimbus-wcd9320-codec-core.patch"

PASS, FAIL = [], []


def check(label, ok, detail=""):
    (PASS if ok else FAIL).append(label)
    print("  %s %-46s %s" % ("PASS " if ok else "FAIL ", label, detail))
    return ok


# --------------------------------------------------------------- ELF reading --

class Elf:
    def __init__(self, path):
        self.blob = open(path, "rb").read()
        b = self.blob
        if b[:4] != b"\x7fELF":
            raise ValueError("not an ELF: %s" % path)
        if b[4] != 1 or b[5] != 1:
            raise ValueError("expected little-endian ELF32")
        e_shoff, = struct.unpack_from("<I", b, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", b, 0x2e)
        self.sections = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            f = struct.unpack_from("<IIIIIIIIII", b, off)
            self.sections.append(dict(
                name=f[0], type=f[1], addr=f[3], off=f[4], size=f[5],
                link=f[6], info=f[7], entsize=f[9], idx=i))
        shstr = self.sections[e_shstrndx]
        for s in self.sections:
            s["sname"] = self._str(shstr["off"], s["name"])
        self.by_name = {s["sname"]: s for s in self.sections}
        self._load_syms()

    def _str(self, base, n):
        end = self.blob.index(b"\0", base + n)
        return self.blob[base + n:end].decode(errors="replace")

    def _load_syms(self):
        self.syms = {}
        self.sym_by_index = {}
        st = self.by_name.get(".symtab")
        if not st:
            return
        strt = self.sections[st["link"]]
        for i in range(st["size"] // 16):
            off = st["off"] + i * 16
            st_name, st_value, st_size, st_info, st_other, st_shndx = \
                struct.unpack_from("<IIIBBH", self.blob, off)
            nm = self._str(strt["off"], st_name)
            rec = dict(name=nm, value=st_value, size=st_size, shndx=st_shndx)
            self.sym_by_index[i] = rec
            if nm:
                self.syms[nm] = rec

    def sym_bytes(self, name):
        s = self.syms[name]
        sec = self.sections[s["shndx"]]
        start = sec["off"] + s["value"]
        return self.blob[start:start + s["size"]]

    def is_undefined(self, name):
        return name in self.syms and self.syms[name]["shndx"] == 0

    def count_relocs_to(self, name):
        """How many relocation entries reference this symbol (call sites)."""
        if name not in self.syms:
            return 0
        target = None
        for i, rec in self.sym_by_index.items():
            if rec["name"] == name:
                target = i
                break
        if target is None:
            return 0
        n = 0
        for s in self.sections:
            if s["type"] != 9:        # SHT_REL
                continue
            for i in range(s["size"] // 8):
                _off, info = struct.unpack_from("<II", self.blob, s["off"] + i * 8)
                if (info >> 8) == target:
                    n += 1
        return n


def bitset(raw):
    out = set()
    for i, byte in enumerate(raw):
        for b in range(8):
            if byte & (1 << b):
                out.add(i * 8 + b)
    return out


# ------------------------------------------------------------------ locating --

def find_apk(pkgrel):
    pats = [
        os.path.expanduser("~/.local/var/pmbootstrap/packages/*/armv7/"
                           "linux-postmarketos-qcom-msm8974-*-r%d.apk" % pkgrel),
    ]
    hits = []
    for p in pats:
        hits.extend(glob.glob(p))
    return sorted(hits)


def extract_ko(apk, workdir):
    subprocess.run(["tar", "-xzf", apk, "-C", workdir], check=True,
                   stderr=subprocess.DEVNULL)
    for root, _dirs, files in os.walk(workdir):
        for f in files:
            if f in ("wcd9320.ko", "wcd9320.ko.zst", "wcd9320.ko.gz",
                     "wcd9320.ko.xz"):
                full = os.path.join(root, f)
                if f.endswith(".zst"):
                    out = full[:-4]
                    subprocess.run(["zstd", "-dqf", full, "-o", out], check=True)
                    return out, f
                if f.endswith(".gz"):
                    out = full[:-3]
                    subprocess.run(["sh", "-c", "gzip -dc %s > %s" % (full, out)],
                                   check=True)
                    return out, f
                if f.endswith(".xz"):
                    out = full[:-3]
                    subprocess.run(["sh", "-c", "xz -dc %s > %s" % (full, out)],
                                   check=True)
                    return out, f
                return full, f
    return None, None


def modinfo(ko):
    """Read .modinfo without needing the modinfo binary (wrong arch here)."""
    e = Elf(ko)
    s = e.by_name.get(".modinfo")
    if not s:
        return {}
    raw = e.blob[s["off"]:s["off"] + s["size"]]
    out = {}
    for item in raw.split(b"\0"):
        if b"=" in item:
            k, v = item.split(b"=", 1)
            out.setdefault(k.decode(errors="replace"),
                           v.decode(errors="replace"))
    return out


# --------------------------------------------------------------------- main --

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ko")
    ap.add_argument("--apk")
    ap.add_argument("--pkgrel", type=int, default=144)
    ap.add_argument("--expect-version", default="regcache-rc9")
    # Relative by default and derived from --expect-version, not a literal:
    # the image is staged outside this repo, where it lives differs per
    # machine, and its name tracks the milestone. The build script passes an
    # absolute path.
    ap.add_argument("--bootimg", default=None,
                    help="boot image to check "
                         "(default: ./boot-1520-<expect-version>.img)")
    ap.add_argument("--skip-bootimg", action="store_true")
    ap.add_argument("--expect-asoc", action="store_true",
                    help="also assert the ASoC component symbols (rc from "
                         "asoc-component-rc1 onwards)")
    args = ap.parse_args()
    if args.bootimg is None:
        args.bootimg = "boot-1520-%s.img" % args.expect_version

    tmp = tempfile.mkdtemp(prefix="wcd9320-verify-")
    apk = None
    ko = args.ko

    print("=== 1. the artefact exists, and postdates the patch ===")
    if not ko:
        apks = [args.apk] if args.apk else find_apk(args.pkgrel)
        if not apks:
            check("pkgrel %d package exists" % args.pkgrel, False,
                  "no linux-postmarketos-qcom-msm8974-*-r%d.apk found" % args.pkgrel)
            print("\nNothing to verify. Run the build first.")
            return 1
        apk = apks[-1]
        check("pkgrel %d package exists" % args.pkgrel, True, os.path.basename(apk))
        if PATCH.exists():
            a, p = os.path.getmtime(apk), os.path.getmtime(PATCH)
            check("package postdates the patch", a > p,
                  "apk %s  patch %s" % (
                      __import__("time").strftime("%H:%M:%S", __import__("time").localtime(a)),
                      __import__("time").strftime("%H:%M:%S", __import__("time").localtime(p))))
        ko, koname = extract_ko(apk, tmp)
        if not ko:
            check("wcd9320.ko present in the package", False, "not found in apk")
            return 1
        check("wcd9320.ko present in the package", True, koname)
    else:
        check("module file given", os.path.exists(ko), ko)

    kosha = hashlib.sha256(open(ko, "rb").read()).hexdigest()
    kosize = os.path.getsize(ko)

    print()
    print("=== 2. it is the module we think it is ===")
    mi = modinfo(ko)
    check("module version", mi.get("version") == args.expect_version,
          "%s (want %s)" % (mi.get("version"), args.expect_version))
    check("module name", mi.get("name") == "wcd9320", mi.get("name", "?"))
    print("  ....  %-46s %s" % ("vermagic", mi.get("vermagic", "?")))
    print("  ....  %-46s %s" % ("size", kosize))
    print("  ....  %-46s %s" % ("sha256", kosha))

    print()
    print("=== 3. the cache is configured, and the tables are the reviewed ones ===")
    if PATCH.exists():
        ptext = PATCH.read_text(errors="replace")
        check("REGCACHE_MAPLE in the patch that was built",
              ".cache_type = REGCACHE_MAPLE" in ptext,
              "source-level; the runtime proof is the debugfs check on device")
        check("MODULE_VERSION in patch matches",
              'MODULE_VERSION("%s")' % args.expect_version in ptext,
              args.expect_version)

    e = Elf(ko)
    for sym in ("wcd9320_readable_bitmap", "wcd9320_volatile_bitmap",
                "wcd9320_reg_defaults"):
        if sym not in e.syms:
            check("symbol %s present" % sym, False, "missing")
            return 1

    readable = bitset(e.sym_bytes("wcd9320_readable_bitmap"))
    volatile = bitset(e.sym_bytes("wcd9320_volatile_bitmap"))
    raw = e.sym_bytes("wcd9320_reg_defaults")
    defs = {}
    for i in range(len(raw) // 8):
        reg, val = struct.unpack_from("<II", raw, i * 8)
        defs[reg] = val
    zero_defaults = sum(1 for v in defs.values() if v == 0)

    check("readable count", len(readable) == EXPECT["readable"],
          "%d (want %d)" % (len(readable), EXPECT["readable"]))
    check("volatile count", len(volatile) == EXPECT["volatile"],
          "%d (want %d)" % (len(volatile), EXPECT["volatile"]))
    check("reg_defaults count", len(defs) == EXPECT["defaults"],
          "%d (want %d)" % (len(defs), EXPECT["defaults"]))
    check("zero-valued defaults", zero_defaults == EXPECT["zero_defaults"],
          "%d (want %d)" % (zero_defaults, EXPECT["zero_defaults"]))

    print()
    print("=== 4. classification invariants ===")
    check("0x1fd RC_OSC_TUNER volatile", 0x1fd in volatile,
          "measured hardware-populated")
    check("0x14b MBHC_INSERT_DET_STATUS volatile", 0x14b in volatile)
    check("INTR_CLEAR 0x09c-0x09f not readable",
          not (set(range(0x9c, 0xa0)) & readable))
    check("INTR_STATUS 0x098-0x09b volatile",
          set(range(0x98, 0x9c)) <= volatile)
    check("all reg < 0x100 volatile", set(range(0x100)) <= volatile)
    check("all reg >= 0x3c0 volatile", set(range(0x3c0, 0x400)) <= volatile)
    check("no volatile register carries a default",
          not (volatile & set(defs)))
    check("every default is readable", not (set(defs) - readable))
    cacheable = readable - volatile
    check("every cacheable register has a default",
          not (cacheable - set(defs)),
          "%d cacheable, %d without a default"
          % (len(cacheable), len(cacheable - set(defs))))

    print()
    print("=== 5. the bypass discipline survived the build ===")
    nb = e.count_relocs_to("regcache_cache_bypass")
    check("regcache_cache_bypass linked (undefined import)",
          e.is_undefined("regcache_cache_bypass"),
          "resolved by regmap at load time")
    check("regcache_cache_bypass call sites", nb == EXPECT["bypass_calls"],
          "%d (want %d -- five true/false pairs)" % (nb, EXPECT["bypass_calls"]))
    for sym, why in (("wcd9320_snapshot_range", "shared snapshot helper, bypass-wrapped"),
                     ("cache_check_show", "the runtime cache/hardware comparison"),
                     ("dev_attr_cache_check", "sysfs attribute the gate reads")):
        check("%s present" % sym, sym in e.syms, why)

    if args.expect_asoc:
        print()
        print("=== 5b. the ASoC component ===")
        check("wcd9320_soc_component present", "wcd9320_soc_component" in e.syms,
              "the snd_soc_component_driver")
        check("devm_snd_soc_register_component linked",
              e.is_undefined("devm_snd_soc_register_component"),
              "resolved by SND_SOC at load time")
        nreg = e.count_relocs_to("devm_snd_soc_register_component")
        check("registered from exactly one site", nreg == 1,
              "%d call site(s) -- the control function only" % nreg)
        # Zero DAIs is the scope of this milestone, and it is checkable:
        # a DAI array would appear as its own symbol.
        dai_syms = [s for s in e.syms if "dai" in s.lower() and "wcd9320" in s.lower()]
        check("no DAI table in the module", not dai_syms,
              "found: %s" % dai_syms)
        if PATCH.exists():
            ptext = PATCH.read_text(errors="replace")
            check("registered with NULL dais, count 0",
                  "&wcd9320_soc_component,\n+\t\t\t\t\t      NULL, 0)" in ptext
                  or "NULL, 0)" in ptext,
                  "source-level")
            check("Kconfig depends on SND_SOC",
                  "depends on SND_SOC" in ptext)

    print()
    print("=== 6. modpost ===")
    mp = REPO / "tools/check-modpost.sh"
    if mp.exists():
        r = subprocess.run(["sh", str(mp)], capture_output=True, text=True)
        check("no unresolved symbols", r.returncode == 0,
              r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "")
        if r.returncode != 0:
            print(r.stdout)
    else:
        check("check-modpost.sh present", False, "missing")

    print()
    print("=== 7. boot image ===")
    if args.skip_bootimg:
        print("  ....  skipped by request")
    else:
        bi = pathlib.Path(args.bootimg)
        if not check("boot image exists", bi.exists(), str(bi)):
            print("        (build the image, then re-run with the same flags)")
        else:
            head = bi.read_bytes()[:4096]
            want = [b"pmos_boot_uuid=a9d9c6cd-eda8-4246-8a5d-2ff04682aa95",
                    b"pmos_root_uuid=de214b3a-0811-4b22-a5f7-095ac1f8d676"]
            for w in want:
                check("cmdline carries %s" % w.decode().split("=")[0],
                      w in head, w.decode().split("=")[1])
            # Derived from the expected version, never hardcoded: the build
            # script names the image boot-1520-$WANT_VERSION.img for exactly
            # the reason this check exists, and a literal here goes stale on
            # the next milestone and fails a perfectly good artefact.
            want_img = "boot-1520-%s.img" % args.expect_version
            check("image name matches the build", bi.name == want_img,
                  "%s (want %s)" % (bi.name, want_img))

    print()
    print("=" * 72)
    print("PASS %d   FAIL %d" % (len(PASS), len(FAIL)))
    if FAIL:
        print("\nfailed:")
        for f in FAIL:
            print("  - " + f)
        return 1

    print("\nARTEFACT VERIFIED.")
    print("\nUse these in the run:")
    print("  EXPECT_VERSION=%s" % args.expect_version)
    print("  EXPECT_SHA=%s" % kosha)
    print("  module size: %d bytes" % kosize)
    if apk:
        print("  package: %s" % apk)
    print("  module:  %s" % ko)
    return 0


if __name__ == "__main__":
    sys.exit(main())

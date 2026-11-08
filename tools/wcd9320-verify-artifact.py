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
import re
import struct
import subprocess
import sys
import tempfile

# Derived from the evidence, and the reason each number is what it is lives in
# docs/audio/wcd9320-reg-defaults.md.
EXPECT = {
    "readable": 669,
    # r180: 401 -> 403 and 460 -> 458: 0x2b5 / 0x2bd became volatile (bit 3
    # is chip-set, measured by the r179 rxb6 trace) and lost their defaults.
    # r181: 403 -> 405, 458 -> 456, 230 -> 229: CLSH_K_ADDR (0x328, measured
    # auto-increment) and CLSH_K_DATA (0x329, its data port) became volatile.
    "volatile": 405,
    "defaults": 456,
    "zero_defaults": 229,
    "bypass_calls": 10,      # five bypass(true)/bypass(false) pairs
    # C2b reads the CHIP instead of the cache. Every register that branch
    # touches -- 0x1a2, 0x1ab, 0x1ae, 0x1b1, 0x1b4, 0x30d, 0x3b0 and the 0x370
    # block -- is non-volatile in our regmap, so a plain regmap_read() after a
    # write is answered by the cache. That would confirm 0x1b1 = c0 for a write
    # that never left the SoC, and a DAC-power milestone cannot rest on that.
    #
    # regmap_read_bypassed() rather than more regcache_cache_bypass() pairs:
    # it reads the device without moving the regmap's bypass flag, so it opens
    # no window in which a concurrent reader -- MBHC, an IRQ, another sysfs
    # reader -- sees the whole map in bypass.
    #
    # r164: 21 = 16 in hphl_dac_state_show, 3 in wcd9320_hphl_dac_path,
    #            1 in wcd9320_c2b_write, 1 in wcd9320_pa_guard.
    # r165: 28 = 18 in hphl_dac_state_show (0x001 and 0x314 added as
    #            observations), 4 in wcd9320_hphl_dac_path (the prerequisite
    #            check), 3 in wcd9320_rdac_probe, 1 in wcd9320_cdc_clk_prereq,
    #            1 in wcd9320_c2b_write, 1 in wcd9320_pa_guard.
    # r166: 32 = the above plus 4 in mclk_state_show -- 0x108, 0x109, 0x1fa and
    #            0x311, the codec's clock source, READ and never written.
    # r167: 39 = those 32 in wcd9320-core.c, plus 7 from
    #            lumia-mclk-experiment.o, which is now linked into the same
    #            module. That file names regmap_read_bypassed once, inside the
    #            one-line lumia_read() wrapper, and calls it from 7 places;
    #            lumia_read has no standalone symbol in the built module, so it
    #            inlined at every one. 32 + 7 = 39, confirmed against
    #            readelf -rW on the r167 artefact.
    #
    # A CONSTANT OFFSET OF 2 BETWEEN SOURCE AND ARTEFACT, NOW CORROBORATED.
    #
    # The "32" above does not match the source. wcd9320-core.c at r167 contains
    # 34 regmap_read_bypassed() call sites, not 32: the r165 enumeration omits
    # one in rx1_digital_state_show and one in hphl_dac_test_store. 39 was
    # confirmed against the artefact, so the ARTEFACT carries two fewer
    # relocations than the source has call sites.
    #
    # r168 measured the same offset independently: 49 source call sites in
    # wcd9320-core.c, expectation 54 = 47 core + 7 experiment, and it PASSED.
    # 49 - 47 = 2 again. So the offset is stable at exactly 2 across two
    # builds, and WHY is still not established -- most likely two call sites
    # compile to something count_relocs_to does not count. Recorded rather
    # than quietly re-derived, because a delta computed from the source alone
    # is two out and looks like a defect.
    #
    #   expectation = (source call sites in core.c) - 2 + 7
    #
    # r168: 54 = 49 - 2 + 7. Confirmed on the artefact, and it also settled
    #            the open question there: wcd9320_clk_read_control did NOT
    #            inline, so its three callers share one relocation.
    # r169: 56 = 51 - 2 + 7. The +2 over r168 is wcd9320_chip_ctl_probe, which
    #            reads either side of its write. Confirmed on the artefact, and
    #            wcd9320_chip_ctl_probe did not inline either.
    # r170: 58 = 53 - 2 + 7. The +2 over r169 is one read in
    #            chip_ctl_test_store (the baseline measurement) and one in
    #            hphl_dac_state_show (CHIP_STATUS, now reported beside
    #            CHIP_CTL so the pair that was transposed for five builds is
    #            visible side by side).
    #
    # r171: 66 = 61 - 2 + 7. The +8 over r170 is the writability
    #            characterisation: 2 in wcd9320_probe_bits, 4 in
    #            wcd9320_writability_run (two baselines and two final
    #            re-reads), 2 in writability_state_show.
    #
    # r172: 70 = 65 - 2 + 7. The +4 over r171 is the HPH status observable:
    #            3 in wcd9320_hs_sample (0x30d, 0x1b3, 0x1b9) and 1 in
    #            wcd9320_hs_channel (the latch check).
    #
    # r174: 71 = 66 - 2 + 7. The +1 over r172 is the readback inside
    #            wcd9320_forced_write(), which is evidence only.
    #
    # r175: 90 = 83 + 7. The +19 over r174 is the C3a work: 1 in the DAC
    #            path's register-gain precondition, 1 in the PA prep baseline
    #            loop, 3 in wcd9320_hphl_pa_path (0x1b1 before the PA, then
    #            0x1ab after the enable and after the teardown), 1 in
    #            wcd9320_pa_irq_sample, and 13 in hphl_pa_state_show.
    #
    # THE "CONSTANT OFFSET OF 2" IS NOT A MYSTERY ANY MORE, AND THE FORMULA
    # ABOVE WAS WRONG IN A WAY THAT HAPPENED TO CANCEL.
    #
    # Every derivation from r167 onwards counted source call sites with a
    # bare `grep -c regmap_read_bypassed`, which also matches the TWO PLACES
    # THE COMMENTS NAME THE FUNCTION IN PROSE -- "regmap_read_bypassed()
    # rather than more regcache_cache_bypass() pairs", and the one in
    # hphl_dac_state_show explaining why the cache is not trusted. Neither is
    # a call, so neither emits a relocation.
    #
    # Counting calls instead of mentions:
    #
    #   grep -c 'regmap_read_bypassed([a-z]'   83    real call sites
    #   grep -c 'regmap_read_bypassed()'        2    prose
    #   grep -c 'regmap_read_bypassed'         85    what the old note used
    #
    # 85 - 2 = 83, which is why subtracting two worked. At r174 the same
    # arithmetic was 66 - 2 = 64, and 64 + 7 = 71 -- the number that was
    # confirmed against the artefact. So there was never an unexplained
    # discrepancy between source and object; there was a grep that counted
    # comments.
    #
    #   expectation = (real call sites in core.c) + (7 in the experiment file)
    #
    # The subtraction is gone. A future delta computed from a bare grep will
    # be two out, and now the reason is written down.
    #
    # r177: 90, unchanged -- slim_port_status reads the interface regmap,
    #            which is REGCACHE_NONE, with plain regmap_read().
    # r178: 93 = 86 + 7. The +3 is the voltmeter, one call site each: the
    #            precondition loop, the S1 snapshot loop and the S5
    #            restore-verify loop in wcd9320_hphl_vm().
    # r179: 97 = 90 + 7. The +4 is the zdet: the snapshot and the
    #            restore-verify loop for each of its two tables (the
    #            voltmeter's set and the static-PA set) in wcd9320_hphl_zdet().
    # r180-r184: 97, unchanged.
    # r185: 116 = 109 + 7. The +19 is the right channel and the jack: 3 in
    #            wcd9320_hphr_dac_path (the 0x1b4 gain check, 0x1b7 after the
    #            enable and after the teardown), 3 in wcd9320_hphr_pa_path
    #            (0x1b7 before the PA, 0x1ab after the enable and after the
    #            teardown), 10 in hphr_state_show, 1 in wcd9320_jack_level and
    #            2 in jack_detect_show (0x14a, 0x14b).
    "read_bypassed_calls": 116,
}

REPO = pathlib.Path(__file__).resolve().parent.parent
PATCH = REPO / "patches/0002-slimbus-wcd9320-codec-core.patch"

# r182: sha256 of wcd9320_clk_source_switch()'s body as func_body() extracts it,
# measured on r181 clshk-rc1 (the last build that ran it on hardware). The 5h
# fence fails if r182 or later changes a byte of the proven switch.
R169_SWITCH_SHA = "757fa0dfb29e848270e0f9749b9aaa8cf7781c2c424fe2d9edb6eff8a0ca435c"

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

    def has_string(self, text):
        """Is this literal present anywhere in the object?

        Needed because a `static` function called from exactly one place may be
        INLINED, which legally removes its standalone symbol while leaving its
        code and its string literals in the binary. Asserting on the symbol
        alone therefore fails correct builds at the compiler's discretion --
        wcd9320_rdac_probe did exactly that at r165, where the symbol was gone,
        rdac_probe_store had grown from 136 to 528 bytes, and every string
        unique to the probe body was present.
        """
        return text.encode() in self.blob

    def code_present(self, name, witness):
        """The function shipped: either its symbol survived, or a literal that
        exists only inside its body is in the binary."""
        return name in self.syms or self.has_string(witness)

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
    ap.add_argument("--expect-dais", type=int, default=0,
                    help="how many DAIs the component must declare "
                         "(0 for asoc-component-rc1, 1 from rx-dai-rc1)")
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
    # r180: bit 3 of RX1/RX2_B6 is set by the chip when the chain runs and
    # does not clear on write -- measured by the r179 rxb6 trace.
    check("0x2b5 CDC_RX1_B6_CTL volatile", 0x2b5 in volatile,
          "measured hardware-populated (bit 3)")
    check("0x2bd CDC_RX2_B6_CTL volatile", 0x2bd in volatile,
          "measured hardware-populated (bit 3)")
    # r181: the class-H K table is an indirect port; the index auto-increments.
    check("0x328 CDC_CLSH_K_ADDR volatile", 0x328 in volatile,
          "measured auto-incrementing index")
    check("0x329 CDC_CLSH_K_DATA volatile", 0x329 in volatile,
          "the data port behind it")
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

    print()
    print("=== 5c. the C2b readbacks reach the chip ===")
    nrb = e.count_relocs_to("regmap_read_bypassed")
    check("regmap_read_bypassed linked (undefined import)",
          e.is_undefined("regmap_read_bypassed"),
          "resolved by regmap at load time")
    check("regmap_read_bypassed call sites",
          nrb == EXPECT["read_bypassed_calls"],
          "%d (want %d)" % (nrb, EXPECT["read_bypassed_calls"]))
    # Static functions: symbol OR a witness literal from inside the body.
    #
    # These are all `static`, and any of them called from exactly one place may
    # be inlined away as a symbol. What matters is that the CODE shipped, so
    # each carries a literal that exists nowhere else in the driver. A build
    # where both the symbol and the witness are gone really has lost the
    # function.
    for sym, witness, why in (
            ("wcd9320_c2b_write", "did not take on the chip",
             "chip-verified write helper"),
            ("wcd9320_pa_guard", "PA GUARD TRIPPED at %s",
             "the PA guard, read bypassed"),
            ("wcd9320_rx_bias", "RX bias on (refs 0 -> 1)",
             "refcounted RX bias"),
            ("wcd9320_hphl_dac_path", "HPHL DAC enable, map stages 3-7",
             "the DAC sequence"),
            ("wcd9320_hphl_pa_path", "HPHL PA enable, map steps 9-11",
             "the r175 mapped PA sequence"),
            ("wcd9320_c3_abort", "C3 ABORT: full mapped teardown",
             "the one idempotent emergency teardown"),
            ("wcd9320_pa_guard_expect", "PA GUARD TRIPPED at %s",
             "the phase-dependent PA guard"),
            ("wcd9320_cdc_clk_prereq", "CDC_CLK_POWER_CTL = 0x03",
             "the r165 prerequisite toggle"),
            ("wcd9320_rdac_probe", "rdac-probe: 0x314 = %02x",
             "the r165 RDAC bit probe"),
            ("wcd9320_mclk_get", "mclk: get, users 0 -> 1, codec on MCLK (cdc_alive %d)",
             "the r182 MCLK owner: vote, then switch"),
            ("wcd9320_mclk_put", "mclk: put, users 1 -> 0, codec %s, vote released",
             "the r182 MCLK owner: switch back, then unvote"),
            ("lumia_mclk_probe", "Lumia MCLK experiment ready",
             "the r167 PM8941 divider experiment"),
            ("lumia_mclk_apply", "mclk-div: DIV_CTL1 did not take",
             "the r167 divider write, chip-verified"),
    ):
        present = e.code_present(sym, witness)
        how = ("symbol" if sym in e.syms
               else "inlined, witness literal present")
        check("%s shipped" % sym, present, "%s -- %s" % (how, why))

    # Data objects are never inlined away; the symbol is the right assertion.
    for sym, why in (("dev_attr_hphl_dac_test", "sysfs trigger the gate drives"),
                     ("dev_attr_hphl_dac_state", "sysfs state the gate reads"),
                     ("dev_attr_hphl_pa_gain", "sysfs, the r176 C3a gain field"),
                     ("dev_attr_hphl_pa_test", "sysfs, the r175 PA trigger"),
                     ("dev_attr_hphl_pa_state", "sysfs, the C3a register set"),
                     ("dev_attr_cdc_clk_prereq", "sysfs, 0x314 only"),
                     ("dev_attr_rdac_probe", "sysfs, the causal experiment"),
                     ("dev_attr_mclk_div_state", "sysfs, DIV_CTL1 + gpio15 mux"),
                     ("dev_attr_clk_source_test", "sysfs, r182: MCLK get/put")):
        check("%s present" % sym, sym in e.syms, why)

    # r182: the two runtime writers that split MCLK ownership are gone. The
    # vote is the codec driver's (get/put) and the divider is board state.
    for sym, why in (("dev_attr_mclk_test", "the r166 vote attribute"),
                     ("dev_attr_mclk_div_test", "the r167 divider attribute")):
        check("%s absent" % sym, sym not in e.syms, why + ", removed in r182")

    # r166 broke the boot by registering a second CCF provider for a clock RPM
    # already owns. The module must contain no clock-provider registration at
    # all: the divider is programmed directly, and RPM keeps the enable vote.
    for sym in ("clk_hw_register", "devm_clk_hw_register",
                "of_clk_add_hw_provider", "devm_of_clk_add_hw_provider",
                "clk_register"):
        check("%s absent (no second clock provider)" % sym,
              sym not in e.syms,
              "r166 registered div_clk1 twice and took the eMMC down with it")

    # Registers whose write sites are pinned by number, in both of the two ways
    # this driver writes a register.
    #
    # A DEFECT IN THIS CHECK, FOUND AT r168 AND FIXED HERE.
    #
    # It used to look only for "update_bits" or "regmap_write" on the same
    # line. That misses BOTH of the mechanisms actually used:
    #
    #   - wcd9320_c2b_write(reg, mask, val, why), the chip-verified helper,
    #     which is how every C2b write is made. A c2b_write to the PA would
    #     have passed this check silently.
    #   - a wcd9320_wake_step table row, "{ REG, mask, val, delay, ... }",
    #     which is how every clock-sequence write is made. So the r166/r167
    #     assertion that 0x108 had "0 write sites" was true of direct calls and
    #     vacuous about the tables -- wcd9320_rco_wake[] and
    #     wcd9320_rco_sleep[] were writing 0x108 the whole time.
    #
    # Both forms are counted now, and separately, because the counts mean
    # different things.
    ptext_c2b = PATCH.read_text(errors="replace") if PATCH.exists() else ""
    added = [ln[1:] for ln in ptext_c2b.splitlines()
             if ln.startswith("+") and not ln.startswith("+++")]

    CALLS = ("update_bits", "regmap_write", "c2b_write", "logged_update",
             "rx1_write", "clsh_one")

    def write_sites(symbol):
        return [ln for ln in added
                if symbol in ln and any(c in ln for c in CALLS)]

    def table_sites(symbol):
        return [ln for ln in added
                if re.match(r"\s*\{\s*%s\s*," % re.escape(symbol), ln)]

    # ------------------------------------------------------------------
    # THE ADDRESSES THEMSELVES, ASSERTED IN SOURCE.
    #
    # r165 to r169 defined WCD9320_A_CHIP_CTL as 0x001. 0x001 is CHIP_STATUS;
    # the real CHIP_CTL is 0x000. Five builds wrote a status register and
    # reported its refusal as a silicon finding, and the whole "three refusing
    # registers" grouping rested partly on that.
    #
    # The two are only ever separated in the COMMON wcd9xxx header --
    # wcd9320_registers.h just aliases TAIKO_A_CHIP_CTL to WCD9XXX_A_CHIP_CTL
    # -- which is how they were transposed. Three independent downstream
    # generations agree on 0x00 / 0x01, and our own low dump decodes correctly
    # only that way.
    #
    # Pinned here so the transcription error cannot recur silently.
    for sym, want in (("WCD9320_A_CHIP_CTL", "0x000"),
                      ("WCD9320_A_CHIP_STATUS", "0x001")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall("\n".join(added))
        check("%s is defined as %s" % (sym, want),
              found == [want],
              "found %s" % (found or "no definition"))

    # ------------------------------------------------------------------
    # r174: THE WRITE-EFFECT-UNVERIFIABLE EXCEPTION MUST NOT SPREAD.
    #
    # 0x314 and 0x30d are the only registers whose readback is treated as
    # evidence rather than as a verdict, and the only ones written with a
    # FORCED transaction so the mandatory inverse cannot be optimised away.
    # That exception costs the verification every other write depends on, so
    # it is confined three ways: the helper rejects any other register at
    # runtime, and these two checks prove the confinement in the source.
    ALLOWED_FORCED = {"WCD9320_CDC_CLK_POWER_CTL",
                      "WCD9320_CDC_CLK_RDAC_CLK_EN_CTL"}
    forced = re.findall(r"wcd9320_forced_write\(wcd,\s*([A-Za-z0-9_]+)",
                        "\n".join(added))
    out_of_class = sorted(set(forced) - ALLOWED_FORCED)
    check("forced writes are confined to 0x314 and 0x30d",
          forced and not out_of_class,
          "%d call site(s), out of class: %s"
          % (len(forced), out_of_class or "none"))

    # regmap_write_bits() is the forcing primitive. It must appear exactly
    # once, as a statement, inside the helper -- never scattered. Comment
    # lines mentioning it by name are excluded by requiring a statement start.
    wb = [ln for ln in added
          if re.match(r"\s*(?:\w+\s*=\s*)?regmap_write_bits\(", ln)]
    check("regmap_write_bits used from exactly one site", len(wb) == 1,
          "%d call site(s) -- the forced-write helper only" % len(wb))

    # And the ordinary path must NOT have been weakened to get here.
    ptext_all = "\n".join(added)
    if "static int wcd9320_c2b_write" in ptext_all:
        body = ptext_all[ptext_all.index("static int wcd9320_c2b_write"):]
        body = body[:body.index("\n}")] if "\n}" in body else body
        check("wcd9320_c2b_write still refuses on mismatch",
              "return -EIO;" in body,
              "the verifying path is intact for every other register")

    # ==================================================================
    # 5d. r175: THE PA FENCE.
    #
    # Everything from C2a to r174 rested on one structural fact -- the driver
    # could not write 0x1ab, so no build could enable the headphone PA even by
    # accident. C3a removes that. What replaces it has to be at least as
    # strong, and it cannot be "the sequence looks right", because a sequence
    # that looks right is exactly what a wrong mask produces.
    #
    # So the relaxation is bounded from five directions at once:
    #
    #   1. exactly two write sites, checked above by the count
    #   2. both masked to HPHL alone -- never 0x30, never the HPHR bit
    #   3. both inside one named function
    #   4. the guard's allowed states are exactly {00, 20} and nothing else
    #   5. D1's own contract is byte-for-byte unchanged
    #
    # (5) is not decoration. D1 is a proven result, and C3a is allowed to add
    # a second mode rather than to redefine the first. A COMP1-ON DAC run
    # after r175 must take the same path it took at r174, or the r174 evidence
    # stops describing the shipping driver.
    # ==================================================================
    print()
    print("=== 5d. the r175 PA fence ===")

    def func_body(name):
        """The body of a C function definition, by brace matching.

        Braces inside string literals are ignored -- the driver has several
        log messages containing them, and a naive counter walks off the end of
        the function and swallows the rest of the file, which turns every
        containment check below into a vacuous pass.
        """
        # A forward DECLARATION matches the same signature, and the next "{"
        # after it belongs to some other function. r185 added two, and the
        # HPHR fence read the wrong bodies until declarations were skipped:
        # a definition reaches its "{" before any ";".
        i = -1
        for m in re.finditer(r"^static\s+[A-Za-z_][\w \t*]*\b%s\s*\("
                             % re.escape(name), ptext_all, re.M):
            b = ptext_all.find("{", m.start())
            s = ptext_all.find(";", m.start())
            if b >= 0 and (s < 0 or b < s):
                i = b
                break
        if i < 0:
            return ""
        depth, j, instr, esc = 0, i, False, False
        while j < len(ptext_all):
            c = ptext_all[j]
            if instr:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    instr = False
            elif c == '"':
                instr = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return ptext_all[i:j + 1]
            j += 1
        return ""

    pa_path = func_body("wcd9320_hphl_pa_path")
    dac_path = func_body("wcd9320_hphl_dac_path")
    # r185: the right channel, and the POST_PA writes moved into one helper
    # that both PA paths call (downstream runs enable_post_pa for every PA).
    r_pa_path = func_body("wcd9320_hphr_pa_path")
    r_dac_path = func_body("wcd9320_hphr_dac_path")
    post_pa = func_body("wcd9320_clsh_post_pa")
    guard_exp = func_body("wcd9320_pa_guard_expect")
    guard_old = func_body("wcd9320_pa_guard")
    abort_body = func_body("wcd9320_c3_abort")

    # A missing function must fail loudly rather than making every
    # containment check below trivially true. This is the check that stops a
    # rename from turning the whole fence into a vacuous pass.
    for nm, bd in (("wcd9320_hphl_pa_path", pa_path),
                   ("wcd9320_hphl_dac_path", dac_path),
                   ("wcd9320_hphr_pa_path", r_pa_path),
                   ("wcd9320_hphr_dac_path", r_dac_path),
                   ("wcd9320_clsh_post_pa", post_pa),
                   ("wcd9320_pa_guard_expect", guard_exp),
                   ("wcd9320_pa_guard", guard_old),
                   ("wcd9320_c3_abort", abort_body)):
        check("%s found in source" % nm, len(bd) > 0,
              "%d bytes of body" % len(bd))

    # ---- the bit names themselves ------------------------------------
    #
    # Pinned by value, for the same reason CHIP_CTL is: a transposed constant
    # is invisible at every other layer. HPHL is bit 5 and HPHR is bit 4, and
    # getting them the wrong way round would enable the channel that is NOT
    # being measured, into a jack the operator has a probe in.
    for sym, want in (("WCD9320_HPH_PA_HPHL", "0x20"),
                      ("WCD9320_HPH_PA_HPHR", "0x10"),
                      ("WCD9320_HPH_PA_MASK", "0x30")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))

    # ---- the two writes, in full -------------------------------------
    PA_WRITE = re.compile(
        r"wcd9320_c2b_write\(\s*wcd,\s*WCD9320_A_RX_HPH_CNP_EN,\s*"
        r"([A-Za-z0-9_]+),\s*([A-Za-z0-9_]+),")
    pw = PA_WRITE.findall(ptext_all)
    # r179 RELAXES THIS TO FOUR, AND NO FURTHER. The operator decided
    # (2026-11-07) that the HPH-scale measurement copies downstream zdet
    # faithfully, both channels: wcd9xxx_enable_static_pa() writes 0x1ab
    # mask 0x30. Those two writes are confined to wcd9320_zdet_static_pa()
    # and fenced again in 5g. The two C3a writes are unchanged, HPHL alone,
    # in wcd9320_hphl_pa_path(). docs/audio/wcd9320-hph-zdet-mapping.md s5.
    # r185: SIX, AND NO FURTHER -- the HPHR PA's enable and disable, masked to
    # HPHR alone, inside wcd9320_hphr_pa_path(), which refuses unless the HPHL
    # PA is already on. docs/audio/wcd9320-r185-stereo-volume-jack-mapping.md.
    zsp = func_body("wcd9320_zdet_static_pa")
    pw_pa = PA_WRITE.findall(pa_path)
    pw_r = PA_WRITE.findall(r_pa_path)
    pw_z = PA_WRITE.findall(zsp)
    check("the PA writes go through the chip-verified helper", len(pw) == 6,
          "%d matched wcd9320_c2b_write(0x1ab, mask, val) (want 6)" % len(pw))
    check("every PA write is in one of the three mapped functions",
          len(pw_pa) + len(pw_r) + len(pw_z) == len(pw),
          "%d in hphl_pa_path, %d in hphr_pa_path, %d in zdet_static_pa, %d total"
          % (len(pw_pa), len(pw_r), len(pw_z), len(pw)))
    check("the HPHR PA writes are masked to HPHR alone",
          sorted(pw_r) == [("WCD9320_HPH_PA_HPHR", "0"),
                           ("WCD9320_HPH_PA_HPHR", "WCD9320_HPH_PA_HPHR")],
          "%s" % (pw_r or "none"))
    i_r_on = r_pa_path.find("WCD9320_HPH_PA_HPHR, WCD9320_HPH_PA_HPHR,")
    check("the HPHR PA refuses unless the HPHL PA is already on",
          0 <= r_pa_path.find("if (!wcd->hphl_pa_on)") < i_r_on,
          "stereo only, HPHL first: the legal states stay {00, 20, 30}")
    check("the HPHR PA checks 0x1b7 = c0 and OCP before its write",
          0 <= r_pa_path.find("WCD9320_HPHR_DAC_PWR | WCD9320_HPHR_DAC_SWITCH") < i_r_on
          and 0 <= r_pa_path.find("WCD9320_INTR2_OCP_ANY") < i_r_on,
          "as 0x1b1 and OCPL are checked for HPHL")
    check("the C3a PA writes are masked to HPHL alone",
          len(pw_pa) == 2 and all(m == "WCD9320_HPH_PA_HPHL" for m, _ in pw_pa),
          "masks: %s" % ([m for m, _ in pw_pa] or "none"))
    check("the C3a PA writes are exactly one enable and one disable",
          sorted(v for _, v in pw_pa) == ["0", "WCD9320_HPH_PA_HPHL"],
          "values: %s" % (sorted(v for _, v in pw_pa) or "none"))
    check("the zdet PA writes are one both-channel enable and one disable",
          sorted(pw_z) == [("WCD9320_HPH_PA_MASK", "0"),
                           ("WCD9320_HPH_PA_MASK", "WCD9320_HPH_PA_MASK")],
          "%s" % (pw_z or "none"))

    # THE TWO-BIT MASK IS A GUARD MASK, NEVER A WRITE MASK -- with one fenced
    # exception: the two writes inside wcd9320_zdet_static_pa().
    #
    # WCD9320_HPH_PA_MASK is 0x30. A write masked with it would set or clear
    # HPHR alongside HPHL from a single statement that reads perfectly well.
    mask_writes = [ln for ln in added
                   if "WCD9320_HPH_PA_MASK" in ln
                   and any(c in ln for c in CALLS)]
    zsp_lines = set(zsp.splitlines())
    check("0x30 is a write mask only inside wcd9320_zdet_static_pa",
          len(mask_writes) == 2 and all(ln in zsp_lines for ln in mask_writes),
          "%d write call(s) naming WCD9320_HPH_PA_MASK, %d of them inside it"
          % (len(mask_writes), sum(ln in zsp_lines for ln in mask_writes)))
    hphr_writes = [ln for ln in added
                   if "WCD9320_HPH_PA_HPHR" in ln
                   and any(c in ln for c in CALLS)]
    r_pa_lines = set(r_pa_path.splitlines())
    # c2b_write puts the mask on its own continuation line, so the line that
    # names the bit is what is matched; all of them must be inside the path.
    hphr_named = [ln for ln in added if "WCD9320_HPH_PA_HPHR" in ln
                  and not ln.lstrip().startswith(("*", "/*", "#define"))]
    check("the HPHR PA bit is written only inside wcd9320_hphr_pa_path",
          len(pw_r) == 2 and all(ln in r_pa_lines or "hphr_pa_on ?" in ln
                                 for ln in hphr_named),
          "%d line(s) name WCD9320_HPH_PA_HPHR, %d write call(s) on one line"
          % (len(hphr_named), len(hphr_writes)))
    check("the HPHL PA teardown takes HPHR down first",
          0 <= pa_path.find("if (wcd->hphr_pa_on)\n\t\twcd9320_hphr_pa_path(wcd, false);")
          < pa_path.find("WCD9320_HPH_PA_HPHL, 0,"),
          "so the C3 abort, unchanged, takes both PAs down, right then left")
    check("the HPHL DAC teardown takes the HPHR DAC down first",
          0 <= dac_path.find("if (wcd->hphr_dac_on)\n\t\twcd9320_hphr_dac_path(wcd, false);")
          < dac_path.find("WCD9320_HPHL_DAC_PWR, 0,"),
          "nothing can leave the right DAC running on a left teardown")

    # ---- the guard: allowed states are exactly {00, 20} --------------
    #
    # The comparison must be EQUALITY against the expected value. A subset
    # test -- "(pa & expect) == expect" -- would accept 0x30 while expecting
    # 0x20, which is precisely the both-channels-enabled state the fence
    # exists to catch.
    check("the guard compares for equality, not subset",
          "!= expect" in guard_exp,
          "(pa & WCD9320_HPH_PA_MASK) != expect")
    check("the guard still latches once tripped",
          "pa_guard_tripped = true" in guard_exp
          and "if (wcd->pa_guard_tripped)" in guard_exp,
          "set on violation, refused on re-entry")
    check("the guard reads the PA bypassed",
          "regmap_read_bypassed" in guard_exp
          and "WCD9320_A_RX_HPH_CNP_EN" in guard_exp,
          "a cached PA register is the last thing a guard should trust")

    # The legacy guard is now a wrapper, and it must still mean "expect 00" so
    # that every D1-era call site keeps the behaviour it was proven with.
    check("wcd9320_pa_guard() is a wrapper expecting 00",
          re.search(r"wcd9320_pa_guard_expect\(wcd,\s*where,\s*0\)",
                    guard_old) is not None,
          "every pre-r175 call site is unchanged in meaning")

    # Non-zero expectations: only HPHL, only from the mapped PA sequence.
    GEXP = re.compile(
        r"wcd9320_pa_guard_expect\(\s*wcd,[^;]*?,\s*([A-Za-z0-9_]+)\s*\)")
    nz_all = [v for v in GEXP.findall(ptext_all) if v not in ("0", "where")]
    # r178: the voltmeter samples the guard against the state the mapped PA
    # sequence left -- pa_expect = hphl_pa_on ? HPHL : 0, pinned in 5f. It
    # introduces no new expected state, so it is excluded here by name, and
    # only for the occurrences that are inside wcd9320_hphl_vm().
    vm_pa = [v for v in GEXP.findall(func_body("wcd9320_hphl_vm"))
             if v == "pa_expect"]
    named = [v for v in nz_all if v == "pa_expect"]
    check("pa_expect is used only inside the voltmeter",
          len(named) == len(vm_pa),
          "%d in the driver, %d inside wcd9320_hphl_vm" % (len(named), len(vm_pa)))
    nz_all = [v for v in nz_all if v != "pa_expect"]
    # r185: the HPHR PA's teardown expects whatever HPHL is (l_expect, 20 or
    # 00), named once, and only there.
    r_named = [v for v in nz_all if v == "l_expect"]
    check("l_expect is used only inside the HPHR PA path",
          len(r_named) == 1 and "l_expect" in r_pa_path
          and "l_expect = wcd->hphl_pa_on ? WCD9320_HPH_PA_HPHL : 0;" in r_pa_path,
          "%d use(s)" % len(r_named))
    nz_all = [v for v in nz_all if v != "l_expect"]
    # r179: the zdet expects 0x30 while its static PA is on; r185: so does the
    # HPHR PA path once both PAs are up. Nowhere else.
    zd_pa = [v for v in GEXP.findall(func_body("wcd9320_hphl_zdet"))
             if v == "WCD9320_HPH_PA_MASK"]
    r_mask = [v for v in GEXP.findall(r_pa_path) if v == "WCD9320_HPH_PA_MASK"]
    zd_named = [v for v in nz_all if v == "WCD9320_HPH_PA_MASK"]
    check("a 0x30 guard expectation exists only in the zdet and HPHR PA",
          len(zd_named) == len(zd_pa) + len(r_mask) and len(zd_pa) >= 1
          and len(r_mask) == 2,
          "%d in the driver, %d inside the zdet, %d inside hphr_pa_path"
          % (len(zd_named), len(zd_pa), len(r_mask)))
    nz_all = [v for v in nz_all if v != "WCD9320_HPH_PA_MASK"]
    nz_pa = [v for v in GEXP.findall(pa_path) if v != "0"]
    nz_r = [v for v in GEXP.findall(r_pa_path)
            if v not in ("0", "WCD9320_HPH_PA_MASK", "l_expect")]
    check("the remaining non-zero guard expectation is HPHL",
          nz_all and all(v == "WCD9320_HPH_PA_HPHL" for v in nz_all),
          "expectations: %s" % (sorted(set(nz_all)) or "none"))
    check("non-zero expectations come only from the PA sequences",
          len(nz_all) == len(nz_pa) + len(nz_r) and len(nz_pa) > 0
          and nz_r == ["WCD9320_HPH_PA_HPHL"],
          "%d in the driver, %d in hphl_pa_path, %d in hphr_pa_path"
          % (len(nz_all), len(nz_pa), len(nz_r)))

    # ---- D1's contract survives --------------------------------------
    #
    # C3a needs register-controlled gain; D1 was proven with the compander as
    # the gain source. Two MODES, selected explicitly by the caller. The COMP1
    # mode must still demand comp1_on -- if the new mode had simply replaced
    # that check, the r174 evidence would no longer describe the shipping
    # driver, and a proven result would have been silently invalidated to make
    # room for an unproven one.
    for sym in ("WCD9320_GAIN_SRC_COMPANDER", "WCD9320_GAIN_SRC_REGISTER"):
        check("%s declared" % sym, sym in ptext_all, "an explicit mode")
    check("the COMP1 gain mode still requires comp1_on",
          "comp1_on" in dac_path and "WCD9320_GAIN_SRC_COMPANDER" in dac_path,
          "D1's prerequisite is intact")
    check("the register gain mode chip-verifies 0x1ae",
          "WCD9320_A_RX_HPH_L_GAIN" in dac_path
          and "regmap_read_bypassed" in dac_path
          and "WCD9320_HPHL_GAIN_SRC" in dac_path
          and "pa_gain_field" in dac_path,
          "bit 5 set and the field the operator set, read from the chip")
    for sym, want in (("WCD9320_HPHL_GAIN_CHECK", "0x3f"),
                      ("WCD9320_HPHL_GAIN_MIN", "0x14")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))
    # D1's own trigger must still ask for the compander mode.
    dac_store = func_body("hphl_dac_test_store")
    check('"dac-on" still selects the COMP1 mode',
          re.search(r'sysfs_streq\(buf,\s*"dac-on"\)(.{0,200}?)'
                    r"WCD9320_GAIN_SRC_COMPANDER", dac_store, re.S) is not None,
          "the r174 trigger is unchanged in meaning")

    # ---- r176: THE GAIN FIELD IS A SETTING, AND ITS DEFAULT IS THE MINIMUM --
    #
    # The C3a gain field moved from a constant to hphl_pa_gain so a run can
    # raise it. The danger in that is specific: struct wcd9320 is zeroed at
    # allocation, and a field of 0x00 is the MAXIMUM on this inverted control.
    # A build that forgot to initialise it would default to full analog gain
    # with nothing anywhere saying so. So the default, the cap and the lock are
    # all pinned here, in the source, before a build can reach the phone.
    gain_store = func_body("hphl_pa_gain_store")
    prep_body = func_body("wcd9320_pa_prep")
    probe_body = func_body("wcd9320_probe")
    check("hphl_pa_gain_store found in source", len(gain_store) > 0,
          "%d bytes of body" % len(gain_store))
    check("the gain field defaults to the MINIMUM at probe",
          re.search(r"wcd->pa_gain_field\s*=\s*WCD9320_HPHL_GAIN_MIN\s*;",
                    probe_body) is not None,
          "a zeroed struct would otherwise mean 0x00, the maximum")
    check("the gain store refuses anything outside 0x00..0x14",
          "> WCD9320_HPHL_GAIN_MIN" in gain_store,
          "the 20-step field and nothing beyond it")
    check("the gain cannot change while the path is up",
          all(s in gain_store for s in ("pa_prep_on", "hphl_pa_on",
                                        "hphl_dac_on")),
          "prep, PA and DAC must all be off")
    check("the gain store serialises on c3_lock",
          "mutex_lock(&wcd->c3_lock)" in gain_store,
          "it cannot race a sequence")
    check("the prep refuses an out-of-range field itself",
          "pa_gain_field > WCD9320_HPHL_GAIN_MIN" in prep_body,
          "defence in depth: the store is not the only guard")
    #
    # CODE lines only. The first form of this check searched the whole source,
    # and failed r176 on the comment that explains why the constant was
    # removed -- a guard satisfied or defeated by prose is the checker defect
    # this project keeps having to fix.
    stale = [ln for ln in added
             if "WCD9320_HPHL_GAIN_C3A" in ln
             and not ln.lstrip().startswith(("*", "/*", "//"))]
    check("WCD9320_HPHL_GAIN_C3A is gone from the code",
          not stale,
          "%d code line(s) still name it -- prose mentions are allowed"
          % len(stale))

    # ---- POST_PA is PROGRAMMED state, not a reversible pair ----------
    #
    # Section 20 of the C3 mapping: three of the four writes are no-ops on
    # this silicon and only NCP_STATIC visibly moves. turnoff_postpa() touches
    # none of them, so C3a must NOT write their inverses -- inventing an
    # inverse downstream does not have is the thing this branch does not do.
    POSTPA = (("WCD9320_A_BUCK_MODE_5", "0x02", "0x00"),
              ("WCD9320_A_NCP_STATIC", "0x20", "0x00"),
              ("WCD9320_A_BUCK_MODE_3", "0x04", "0x04"),
              ("WCD9320_A_BUCK_MODE_3", "0x08", "0x08"))
    for reg, mask, val in POSTPA:
        pat = re.compile(r"wcd9320_c2b_write\(\s*wcd,\s*%s,\s*%s,\s*%s,"
                         % (re.escape(reg), mask, val))
        check("POST_PA %s mask %s <- %s" % (reg[10:], mask, val),
              len(pat.findall(post_pa)) == 1 and not pat.findall(pa_path),
              "%d site(s) in wcd9320_clsh_post_pa" % len(pat.findall(post_pa)))
    # And their inverses must not exist anywhere in the PA sequence.
    for reg, mask, bad in (("WCD9320_A_BUCK_MODE_5", "0x02", "0x02"),
                           ("WCD9320_A_NCP_STATIC", "0x20", "0x20"),
                           ("WCD9320_A_BUCK_MODE_3", "0x04", "0x00"),
                           ("WCD9320_A_BUCK_MODE_3", "0x08", "0x00")):
        pat = re.compile(r"wcd9320_c2b_write\(\s*wcd,\s*%s,\s*%s,\s*%s,"
                         % (re.escape(reg), mask, bad))
        check("no invented inverse for %s mask %s" % (reg[10:], mask),
              not pat.findall(pa_path + r_pa_path + post_pa),
              "turnoff_postpa() does not touch it, so neither do we")
    for nm, bd in (("hphl", pa_path), ("hphr", r_pa_path)):
        check("the %s PA path runs POST_PA through the helper, once" % nm,
              bd.count("wcd9320_clsh_post_pa(wcd)") == 1,
              "downstream's enable_post_pa, for every PA")
    check("the PA teardown uses the C2a class-H path",
          "wcd9320_clsh_hphl(wcd, false)" in pa_path,
          "the proven turnoff_postpa() equivalent, not a re-implementation")

    # ---- the abort is ONE operation, ordered, and serialised ---------
    #
    # Volume Down must do the whole mapped teardown from wherever the run has
    # got to, in the mapped order, best-effort. Assembling that order in ash
    # would put the safety path in the least reliable component in the system.
    # THE ORDER IS ASSERTED OVER CALLS, NOT OVER REGISTER SYMBOLS.
    #
    # Each step of the teardown already exists as a mapped function that was
    # proven separately -- the PA sequence, the D1 DAC path, the forced 0x314
    # inverse, the C3a gain and pop/click restore. Re-issuing their registers
    # inside the abort would be a SECOND copy of the teardown, and the two
    # copies would drift the first time either was corrected. So the abort is
    # a composition, and what is checked here is that it composes them in the
    # mapped order and reaches all four.
    ORDER = ("wcd9320_hphl_pa_path(wcd, false)",   # PA off, settle, class-H
             "wcd9320_hphl_dac_path(wcd, false",   # DAC, then forced 0x30d
             "wcd9320_cdc_clk_prereq(wcd, false)", # forced 0x314 inverse
             "wcd9320_pa_prep(wcd, false)")        # gain and pop/click back
    pos, ordered = -1, True
    for tok in ORDER:
        nxt = abort_body.find(tok, pos + 1)
        if nxt < 0:
            ordered = False
            break
        pos = nxt
    check("the abort teardown is in the mapped order", ordered,
          "PA off, DAC + forced 0x30d, forced 0x314, gain and pop/click")

    # And the register-level order lives in the step that owns it. There is no
    # PRE_PMD on this widget: downstream drops the PA bit FIRST and only then
    # waits, so a settle placed before the write would be an invention. The
    # class-H POST_PA teardown comes last of the three.
    pa_teardown = (pa_path[pa_path.index("teardown:"):]
                   if "teardown:" in pa_path else "")
    check("the PA teardown has a teardown label to check", bool(pa_teardown),
          "%d bytes after the label" % len(pa_teardown))
    pos, ordered = -1, bool(pa_teardown)
    for tok in ("WCD9320_HPH_PA_HPHL, 0,",        # the bit drops first
                "pa_settle_us",                    # THEN the mapped settle
                "wcd9320_clsh_hphl(wcd, false)"):  # then the real class-H
        nxt = pa_teardown.find(tok, pos + 1)
        if nxt < 0:
            ordered = False
            break
        pos = nxt
    check("the PA teardown drops the bit before it settles", ordered,
          "0x1ab bit 5 clear, settle, class-H POST_PA down")
    # BEST-EFFORT MEANS NO EARLY EXIT. A conditional return between the PA
    # write and the class-H teardown would leave the analog stage half torn
    # down with nobody able to ssh in and finish the job.
    check("the abort has no early return",
          abort_body.count("return") <= 1,
          "%d return statement(s) -- one tail return at most"
          % abort_body.count("return"))
    pa_store = func_body("hphl_pa_test_store")
    check('hphl_pa_test accepts "abort"', '"abort"' in pa_store,
          "one sysfs write performs the whole mapped teardown")
    check("abort and normal teardown share one implementation",
          "wcd9320_c3_abort" in pa_store and "wcd9320_c3_abort" in ptext_all,
          "no second copy of the teardown order")

    # SERIALISATION. A normal teardown racing an emergency abort could
    # interleave two individually correct sequences into one incoherent one.
    nlock = len(re.findall(r"mutex_lock\(&wcd->c3_lock\)", ptext_all))
    nunlock = len(re.findall(r"mutex_unlock\(&wcd->c3_lock\)", ptext_all))
    check("the C3 state lock is balanced", nlock == nunlock and nlock >= 3,
          "%d lock / %d unlock" % (nlock, nunlock))
    for store in ("hphl_pa_test_store", "hphl_dac_test_store",
                  "cdc_clk_prereq_store"):
        b = func_body(store)
        check("%s serialises on c3_lock" % store,
              "mutex_lock(&wcd->c3_lock)" in b,
              "no two C3 sequences can interleave")

    # ---- the IRQ observation changes nothing -------------------------
    #
    # INTR_STATUS2 carries HPH_L_PA_STARTUP (bit 3) and HPH_PA_OCPL_FAULT
    # (bit 0). They are read as opportunistic evidence. The mask configuration
    # is certified by wcd9320-irq-parent-idle-validated and r175 does not
    # touch it -- an observation that had to change the system to be made
    # would be a different experiment.
    for fn, b in (("wcd9320_hphl_pa_path", pa_path),
                  ("wcd9320_c3_abort", abort_body),
                  ("hphl_pa_state_show", func_body("hphl_pa_state_show"))):
        check("%s writes no interrupt mask" % fn,
              "WCD9320_A_INTR_MASK0" not in b,
              "the certified IRQ configuration is untouched")
    status_writes = [ln for ln in added
                     if "WCD9320_A_INTR_STATUS0" in ln
                     and any(c in ln for c in CALLS)]
    check("INTR_STATUS is read, never written", not status_writes,
          "%d write call(s) naming INTR_STATUS0" % len(status_writes))

    for sym, addr, ncall, ntable, why in (
            # THE PA. Zero write sites from C2a through r174 -- that milestone
            # was defined by it staying off, and neither mechanism could name
            # it at all.
            #
            # r175 RELAXES THIS TO EXACTLY TWO, AND ONLY TWO.
            #
            # C3a enables the left headphone PA deliberately, once, and
            # disables it again: bit 5 set, bit 5 clear, both chip-verified.
            # This is the most dangerous change in the branch, so the
            # relaxation is fenced in section 5d below -- both sites masked to
            # HPHL alone, both inside wcd9320_hphl_pa_path(), and the HPHR bit
            # named by nothing. A THIRD write site fails here, before section
            # 5d is even reached.
            # r179: FOUR -- the two C3a sites plus the zdet static PA's two
            # (both channels, operator decision), fenced in 5d and 5g.
            # r185: SIX -- plus the HPHR PA's on/off in wcd9320_hphr_pa_path.
            ("WCD9320_A_RX_HPH_CNP_EN", "0x1ab", 6, 0,
             "the PA -- HPHL on/off, HPHR on/off, zdet static PA on/off"),

            # CHIP_CTL, at its real address from r170. ONE write site, inside
            # wcd9320_chip_ctl_probe(), reached both to attempt the 9.6 MHz
            # rate and to put it back. It stays out of every table, and
            # nothing else in the driver may write it.
            ("WCD9320_A_CHIP_CTL", "0x000", 1, 0,
             "the rate declaration -- probed, never a prerequisite"),

            # CHIP_STATUS. A status register. It is READ in the state
            # readers and must never be written again by anything.
            ("WCD9320_A_CHIP_STATUS", "0x001", 0, 0,
             "a status register -- read only, never written"),

            # The codec clock source. r166 and r167 supplied an external MCLK
            # and deliberately did not select it. r168 selects it, and only
            # through the mapped sequence tables: three rows for the RCO wake
            # and sleep that were always there, and four for the switch
            # (block-off, deselect, and the external source and buffer enable).
            # A DIRECT write to 0x108 would be a clock transition outside the
            # mapped sequences, which is the thing that must not exist.
            ("WCD9320_A_CLK_BUFF_EN1", "0x108", 0, 7,
             "the codec clock source -- table rows only, never a direct write"),
    ):
        calls = write_sites(sym)
        tables = table_sites(sym)
        check("%s direct write sites (%s)" % (addr, why),
              len(calls) == ncall,
              "%d (want %d)" % (len(calls), ncall))
        check("%s sequence-table rows" % addr,
              len(tables) == ntable,
              "%d (want %d)" % (len(tables), ntable))

    # ==================================================================
    # 5e. r177: THE PORT-STATUS FENCE.
    #
    # r177 adds the first write this driver has ever made to the SLIMbus
    # port-interrupt block on the interface function: one clear, 0x038 <- 01,
    # so that RX port 16's OVERFLOW/UNDERFLOW status can be watched during a
    # steady stream. See docs/audio/wcd9320-rx-port-flow-mapping.md.
    #
    # Bounded four ways:
    #
    #   1. the three addresses and the three source bits pinned by value
    #   2. exactly one write site naming the clear register, in one function,
    #      on the interface regmap -- never the control function's
    #   3. no write anywhere naming PORT_INT_EN: enabling a source would route
    #      into the codec's main interrupt line, whose mask set is certified
    #   4. the reader writes nothing, and the store accepts "clear" only
    # ==================================================================
    print()
    print("=== 5e. the r177 port-status fence ===")
    for sym, want in (("WCD9320_IFD_PORT_INT_STATUS_RX_0", "0x034"),
                      ("WCD9320_IFD_PORT_INT_CLR_RX_0", "0x038"),
                      ("WCD9320_IFD_PORT_INT_RX_SOURCE0", "0x060"),
                      ("WCD9320_PORT_IRQ_OVERFLOW", "0x01"),
                      ("WCD9320_PORT_IRQ_UNDERFLOW", "0x02"),
                      ("WCD9320_PORT_IRQ_CLOSED", "0x04")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))

    ps_clear = func_body("wcd9320_port_status_clear")
    ps_read = func_body("wcd9320_port_status_read")
    ps_store = func_body("slim_port_status_store")
    ps_show = func_body("slim_port_status_show")
    for nm, bd in (("wcd9320_port_status_clear", ps_clear),
                   ("wcd9320_port_status_read", ps_read),
                   ("slim_port_status_store", ps_store),
                   ("slim_port_status_show", ps_show)):
        check("%s found in source" % nm, len(bd) > 0,
              "%d bytes of body" % len(bd))

    clr_sites = write_sites("WCD9320_IFD_PORT_INT_CLR")
    check("the clear register has exactly one write site", len(clr_sites) == 1,
          "%d write call(s) naming WCD9320_IFD_PORT_INT_CLR" % len(clr_sites))
    clr_in_fn = re.findall(
        r"regmap_write\(\s*ifd->regmap,\s*WCD9320_IFD_PORT_INT_CLR_RX_0\b",
        ps_clear)
    check("that write is in wcd9320_port_status_clear, on the interface regmap",
          len(clr_in_fn) == 1,
          "%d regmap_write(ifd->regmap, CLR_RX_0 ...) inside the function"
          % len(clr_in_fn))
    nwr = sum(ps_clear.count(c + "(") for c in CALLS)
    check("wcd9320_port_status_clear makes no other write", nwr == 1,
          "%d write call(s) in the body (want 1)" % nwr)
    check("wcd9320_port_status_clear never touches the control regmap",
          "wcd->regmap" not in ps_clear and "forced_write" not in ps_clear,
          "the codec register file is not this function's business")
    en_writes = [ln for ln in added
                 if "PORT_INT_EN" in ln and any(c in ln for c in CALLS)]
    check("no write names PORT_INT_EN", not en_writes,
          "%d write call(s) -- the interrupt enables stay at reset"
          % len(en_writes))
    rd_writes = [c for c in CALLS if c + "(" in ps_read + ps_show]
    check("the status reader and show path write nothing", not rd_writes,
          "write calls found: %s" % (rd_writes or "none"))
    check('slim_port_status accepts "clear" and nothing else',
          '"clear"' in ps_store and ps_store.count("sysfs_streq") == 1
          and "wcd9320_port_status_clear" in ps_store,
          "one verb, one helper")
    check("slim_port_status is registered",
          "&dev_attr_slim_port_status.attr" in ptext_all,
          "listed in wcd9320_attrs[]")
    check("dev_attr_slim_port_status present", "dev_attr_slim_port_status" in e.syms,
          "the sysfs attribute the r177 gate drives")
    check("port-status witness literal shipped",
          e.code_present("wcd9320_port_status_clear",
                         "port-status: CLEARED port %u"),
          "the clear helper, symbol or witness")

    # ==================================================================
    # 5f. r178: THE VOLTMETER FENCE.
    #
    # The first writes this driver makes to the MBHC measurement engine, the
    # mic-bias block and the HPH-to-MBHC path. Mapped in
    # docs/audio/wcd9320-hphl-dc-vm-mapping.md. Bounded five ways:
    #
    #   1. every address pinned by value, and the mux value is HPHL WITHOUT
    #      ical (0xf0); 0xf8, the current-injecting variant, appears nowhere
    #   2. one write path, wcd9320_vm_wr(), which refuses at runtime any
    #      register outside the closed table, and the table is exactly the
    #      mapped set
    #   3. no voltmeter function names the PA, insert detect, the interrupt
    #      masks, the PA ramp or the two forced registers in a write
    #   4. preconditions refuse rather than supply: MCLK, insert detect off,
    #      the certified masks, the 1800 mV reference path
    #   5. every snapshotted register is restored and read back from the chip
    # ==================================================================
    print()
    print("=== 5f. the r178 voltmeter fence ===")
    VM_ADDR = (("WCD9320_A_LDO_H_MODE_1", "0x110"),
               ("WCD9320_A_MICB_CFILT_1_CTL", "0x128"),
               ("WCD9320_A_MICB_CFILT_1_VAL", "0x129"),
               ("WCD9320_A_MICB_2_CTL", "0x131"),
               ("WCD9320_A_MICB_2_MBHC", "0x133"),
               ("WCD9320_A_MICB_4_MBHC", "0x13f"),
               ("WCD9320_A_MBHC_SCALING_MUX_1", "0x14e"),
               ("WCD9320_A_MBHC_SCALING_MUX_2", "0x14f"),
               ("WCD9320_A_MAD_ANA_CTRL", "0x150"),
               ("WCD9320_A_TX_7_MBHC_EN", "0x171"),
               ("WCD9320_A_TX_7_MBHC_TEST_CTL", "0x174"),
               ("WCD9320_A_MBHC_HPH", "0x1fe"),
               ("WCD9320_A_CDC_MBHC_EN_CTL", "0x3c0"),
               ("WCD9320_A_CDC_MBHC_FIR_B1_CFG", "0x3c1"),
               ("WCD9320_A_CDC_MBHC_FIR_B2_CFG", "0x3c2"),
               ("WCD9320_A_CDC_MBHC_TIMER_B1_CTL", "0x3c3"),
               ("WCD9320_A_CDC_MBHC_TIMER_B4_CTL", "0x3c6"),
               ("WCD9320_A_CDC_MBHC_TIMER_B5_CTL", "0x3c7"),
               ("WCD9320_A_CDC_MBHC_TIMER_B6_CTL", "0x3c8"),
               ("WCD9320_A_CDC_MBHC_B2_STATUS", "0x3ca"),
               ("WCD9320_A_CDC_MBHC_B3_STATUS", "0x3cb"),
               ("WCD9320_A_CDC_MBHC_B1_CTL", "0x3ce"),
               ("WCD9320_A_CDC_MBHC_B2_CTL", "0x3cf"),
               ("WCD9320_A_CDC_MBHC_CLK_CTL", "0x3dc"),
               ("WCD9320_VM_MUX2_HPHL_NO_ICAL", "0xf0"),
               ("WCD9320_VM_CFILT_VAL_1800", "0x80"),
               ("WCD9320_VM_CFILT_VAL_1200", "0x50"))
    for sym, want in VM_ADDR:
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))
    for sym, want in (("WCD9320_VM_MICB_MV", "1800"),
                      ("WCD9320_VM_MICB_MV_ALT", "1200"),
                      ("WCD9320_VM_N_READY", "68"),
                      ("WCD9320_VM_N_CIC", "47"),
                      ("WCD9320_VM_NAVG", "4"),
                      ("WCD9320_VM_T_STA_US", "316"),
                      ("WCD9320_VM_T_STA_DCE_US", "1778")):
        pat = re.compile(r"^#define\s+%s\s+(\d+)\b" % re.escape(sym), re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))

    vm_wr = func_body("wcd9320_vm_wr")
    vm_sta = func_body("wcd9320_vm_sta")
    vm_main = func_body("wcd9320_hphl_vm")
    vm_store = func_body("hphl_vm_store")
    vm_show = func_body("hphl_vm_show")
    vm_allowed = func_body("wcd9320_vm_reg_allowed")
    for nm, bd in (("wcd9320_vm_wr", vm_wr), ("wcd9320_vm_sta", vm_sta),
                   ("wcd9320_hphl_vm", vm_main), ("hphl_vm_store", vm_store),
                   ("hphl_vm_show", vm_show),
                   ("wcd9320_vm_reg_allowed", vm_allowed)):
        check("%s found in source" % nm, len(bd) > 0,
              "%d bytes of body" % len(bd))

    # ---- the closed table is exactly the mapped write set -----------
    m = re.search(r"static const u16 wcd9320_vm_regs\[\] = \{(.*?)\};",
                  ptext_all, re.S)
    table = re.findall(r"(WCD9320_A_[A-Z0-9_]+)", m.group(1)) if m else []
    MAPPED = {"WCD9320_A_LDO_H_MODE_1", "WCD9320_A_MICB_CFILT_1_CTL",
              "WCD9320_A_MICB_CFILT_1_VAL", "WCD9320_A_MICB_2_CTL",
              "WCD9320_A_MICB_2_MBHC", "WCD9320_A_MBHC_SCALING_MUX_1",
              "WCD9320_A_MBHC_SCALING_MUX_2", "WCD9320_A_MAD_ANA_CTRL",
              "WCD9320_A_TX_7_MBHC_EN", "WCD9320_A_TX_7_MBHC_TEST_CTL",
              "WCD9320_A_MBHC_HPH", "WCD9320_A_CDC_MBHC_FIR_B1_CFG",
              "WCD9320_A_CDC_MBHC_TIMER_B1_CTL",
              "WCD9320_A_CDC_MBHC_TIMER_B4_CTL",
              "WCD9320_A_CDC_MBHC_TIMER_B5_CTL",
              "WCD9320_A_CDC_MBHC_TIMER_B6_CTL", "WCD9320_A_CDC_MBHC_B1_CTL",
              "WCD9320_A_CDC_MBHC_B2_CTL", "WCD9320_A_CDC_MBHC_CLK_CTL",
              "WCD9320_A_CDC_MBHC_EN_CTL"}
    check("the voltmeter table is exactly the mapped write set",
          set(table) == MAPPED and len(table) == len(MAPPED),
          "%d entries; extra %s; missing %s"
          % (len(table), sorted(set(table) - MAPPED) or "none",
             sorted(MAPPED - set(table)) or "none"))
    check("EN_CTL and CLK_CTL are last, so the restore stops the engine first",
          table[-2:] == ["WCD9320_A_CDC_MBHC_CLK_CTL",
                         "WCD9320_A_CDC_MBHC_EN_CTL"],
          "tail: %s" % table[-2:])
    check("the only register outside the table is the FIR data port",
          re.findall(r"reg == (WCD9320_A_[A-Z0-9_]+)", vm_allowed)
          == ["WCD9320_A_CDC_MBHC_FIR_B2_CFG"],
          "wcd9320_vm_reg_allowed")
    check("wcd9320_vm_wr refuses outside the set before writing",
          "wcd9320_vm_reg_allowed(reg)" in vm_wr and "return -EPERM;" in vm_wr
          and vm_wr.index("wcd9320_vm_reg_allowed") < vm_wr.index("regmap_"),
          "runtime confinement")

    # ---- one write path ---------------------------------------------
    for nm, bd in (("wcd9320_hphl_vm", vm_main), ("wcd9320_vm_sta", vm_sta),
                   ("hphl_vm_store", vm_store), ("hphl_vm_show", vm_show)):
        direct = [c for c in ("regmap_write(", "regmap_update_bits(",
                              "c2b_write(", "forced_write(",
                              "regmap_write_bits(", "regmap_bulk_write(")
                  if c in bd]
        check("%s writes only through wcd9320_vm_wr" % nm, not direct,
              "direct write calls: %s" % (direct or "none"))

    # ---- the passive mux, never the current source ------------------
    # Every write to SCALING_MUX_2 is the full byte HPHL-without-ical. The
    # first version of this check looked for any "0xf8" in the body and so
    # failed a correct build on the CDC_MBHC_B1_CTL field mask, which is also
    # 0xf8 -- the mux value is what matters, so the mux writes are parsed.
    mux2 = re.findall(
        r"wcd9320_vm_wr\(\s*wcd,\s*WCD9320_A_MBHC_SCALING_MUX_2,\s*"
        r"([A-Za-z0-9_]+),\s*([A-Za-z0-9_]+)\s*\)", vm_main + vm_sta)
    check("every SCALING_MUX_2 write is HPHL WITHOUT ical",
          mux2 == [("0xff", "WCD9320_VM_MUX2_HPHL_NO_ICAL")],
          "%s" % (mux2 or "no mux-2 write found"))
    check("the ical mux value 0xf8 is not defined for the voltmeter",
          not re.search(r"^#define\s+WCD9320_VM_\w+\s+0x[fF]8\b", ptext_all, re.M),
          "no constant for the current-injecting mux setting")
    check("no PA ramp register named by the voltmeter",
          "PA_RAMP" not in vm_main + vm_sta and "PA_RAMP" not in
          " ".join(table), "the zdet ramp drives the headphone; not used")

    # ---- what the voltmeter must never touch ------------------------
    for sym, why in (("WCD9320_A_RX_HPH_CNP_EN", "the PA"),
                     ("WCD9320_A_MBHC_INSERT_DETECT", "insert detect"),
                     ("WCD9320_A_INTR_MASK0", "the certified masks"),
                     ("WCD9320_CDC_CLK_POWER_CTL", "forced 0x314"),
                     ("WCD9320_CDC_CLK_RDAC_CLK_EN_CTL", "forced 0x30d")):
        wl = [ln for ln in (vm_main + vm_sta).splitlines()
              if sym in ln and "vm_wr(" in ln]
        check("the voltmeter never writes %s (%s)" % (sym, why), not wl,
              "%d write line(s)" % len(wl))
    check("insert detect and the masks are READ as preconditions",
          "WCD9320_A_MBHC_INSERT_DETECT" in ptext_all.split(
              "wcd9320_vm_pre[] = {")[1].split("};")[0]
          if "wcd9320_vm_pre[] = {" in ptext_all else False,
          "in the precondition table")

    # ---- preconditions refuse ----------------------------------------
    for wit, why in (("vm: refusing -- the codec is not on MCLK",
                      "MCLK required"),
                     ("vm: refusing -- insert detection is on",
                      "insert detect off"),
                     ("vm: refusing -- interrupt masks are not the certified set",
                      "masks"),
                     ("the reference path is not the mapped one",
                      "1800 mV path")):
        check("precondition: %s" % why, wit in vm_main, "witness in source")
    pre = re.search(r"wcd9320_vm_pre\[\] = \{(.*?)\};", ptext_all, re.S)
    pre_regs = re.findall(r"(WCD9320_A_[A-Z0-9_]+)", pre.group(1)) if pre else []
    check("the reference preconditions are the mapped four plus insert detect",
          sorted(pre_regs) == sorted(["WCD9320_A_MBHC_INSERT_DETECT",
                                      "WCD9320_A_MICB_4_MBHC",
                                      "WCD9320_A_MICB_2_CTL",
                                      "WCD9320_A_LDO_H_MODE_1",
                                      "WCD9320_A_MICB_CFILT_1_VAL"]),
          "%s" % pre_regs)
    check("the PA guard is sampled before and after, against its live state",
          vm_main.count("wcd9320_pa_guard_expect(") == 2
          and "hphl_pa_on ? WCD9320_HPH_PA_HPHL : 0" in vm_main
          and "hphr_pa_on ? WCD9320_HPH_PA_HPHR : 0" in vm_main,
          "phase-dependent guard, both channels (r185)")
    # r185: HPHR is downstream's R0 -- MUX_1 = a0 over the same passive MUX_2.
    mux1 = re.findall(r"wcd9320_vm_wr\(\s*wcd,\s*WCD9320_A_MBHC_SCALING_MUX_1,\s*0xff,"
                      r"\s*([^;]*?)\)\s*;", vm_main)
    check("the HPHR reading is MUX_1 = a0, chosen by vm_right, nothing else",
          any("wcd->vm_right ? WCD9320_ZDET_MUX1_HPHR" in m and
              "WCD9320_VM_MUX1_HPH_ADC7" in m for m in mux1),
          "%d full-byte MUX_1 write(s)" % len(mux1))

    # ---- the restore ------------------------------------------------
    check("every table register is restored and read back from the chip",
          re.search(r"for \(i = WCD9320_VM_NREGS; i-- > 0; \)", vm_main) is not None
          and "RESTORE MISMATCH" in vm_main
          and vm_main.count("regmap_read_bypassed(") == 3,
          "reverse-order restore, bypassed readback")
    check("the restore runs on every path past the first write",
          vm_main.count("goto restore;") >= 8 and "\nrestore:" in vm_main,
          "%d goto restore" % vm_main.count("goto restore;"))
    check("only the FIR coefficients actually read are written back",
          "for (i = 0; i < fir_read; i++)" in vm_main, "fir_read bound")

    # ---- the sysfs surface ------------------------------------------
    check('hphl_vm accepts measure / window / measure-1200, and -r',
          sorted(set(re.findall(r'sysfs_streq\(buf, "([a-z0-9-]+)"\)', vm_store)))
          == ["measure", "measure-1200", "measure-r", "window", "window-r"],
          "three verbs, two of them also on HPHR (r185)")
    check("hphl_vm serialises on c3_lock",
          "mutex_lock(&wcd->c3_lock)" in vm_store, "with every C3 sequence")
    check("hphl_vm is registered",
          "&dev_attr_hphl_vm.attr" in ptext_all, "in wcd9320_attrs[]")
    check("dev_attr_hphl_vm present", "dev_attr_hphl_vm" in e.syms,
          "the sysfs attribute the r178 gate drives")
    check("voltmeter witness literal shipped",
          e.code_present("wcd9320_hphl_vm",
                         "vm: RESTORE MISMATCH at 0x%03x"),
          "the measurement, symbol or witness")

    # ==================================================================
    # 5g. r179: THE ZDET FENCE.
    #
    # Downstream impedance detection, copied faithfully, both channels
    # (operator decision 2026-11-07), to get the HPH channel's scale.
    # docs/audio/wcd9320-hph-zdet-mapping.md. Bounded:
    #
    #   1. new addresses pinned; the closed static-PA + ramp table is exactly
    #      the mapped set
    #   2. one write path for registers, refusing outside (voltmeter set +
    #      zdet set) and refusing the PA register outright; the PA goes only
    #      through wcd9320_zdet_static_pa(), called only from the zdet
    #   3. the PAs are switched off BEFORE the register restore begins
    #   4. preconditions refuse: MCLK, and the whole analog path idle
    #   5. never 0x314, 0x30d, insert detect or the masks
    # ==================================================================
    print()
    print("=== 5g. the r179 zdet fence ===")
    for sym, want in (("WCD9320_A_RX_HPH_L_TEST", "0x1af"),
                      ("WCD9320_A_RX_HPH_R_TEST", "0x1b5"),
                      ("WCD9320_A_CDC_RX2_B6_CTL", "0x2bd"),
                      ("WCD9320_A_NCP_CLK", "0x193"),
                      ("WCD9320_A_CDC_PA_RAMP_B1_CTL", "0x361"),
                      ("WCD9320_A_CDC_PA_RAMP_B2_CTL", "0x362"),
                      ("WCD9320_A_CDC_PA_RAMP_B3_CTL", "0x363"),
                      ("WCD9320_A_CDC_PA_RAMP_B4_CTL", "0x364"),
                      ("WCD9320_ZDET_RAMP_B4_50MV", "0xc0"),
                      # ZDET_, never VM_: 5f forbids any VM_ constant at 0xf8
                      ("WCD9320_ZDET_MUX2_HPHL_ICAL", "0xf8"),
                      ("WCD9320_ZDET_MUX1_HPHR", "0xa0")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym),
                         re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))
    for sym, want in (("WCD9320_ZDET_RAMP_MV", "50"),
                      ("WCD9320_ZDET_WG_US", "5040"),
                      ("WCD9320_ZDET_RAMP_WAIT_US", "18000"),
                      ("WCD9320_ZDET_T_STA16_US", "477")):
        pat = re.compile(r"^#define\s+%s\s+(\d+)\b" % re.escape(sym), re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))

    z_main = func_body("wcd9320_hphl_zdet")
    z_wr = func_body("wcd9320_zdet_wr")
    z_rd = func_body("wcd9320_zdet_read")
    z_store = func_body("hphl_zdet_store")
    z_show = func_body("hphl_zdet_show")
    for nm, bd in (("wcd9320_hphl_zdet", z_main), ("wcd9320_zdet_wr", z_wr),
                   ("wcd9320_zdet_read", z_rd),
                   ("wcd9320_zdet_static_pa", zsp),
                   ("hphl_zdet_store", z_store), ("hphl_zdet_show", z_show)):
        check("%s found in source" % nm, len(bd) > 0,
              "%d bytes of body" % len(bd))

    m = re.search(r"static const u16 wcd9320_zdet_regs\[\] = \{(.*?)\};",
                  ptext_all, re.S)
    ztab = re.findall(r"(WCD9320_[A-Z0-9_]+)", m.group(1)) if m else []
    ZMAPPED = {"WCD9320_A_RX_HPH_OCP_CTL", "WCD9320_A_RX_HPH_L_TEST",
               "WCD9320_A_RX_HPH_R_TEST", "WCD9320_A_RX_HPH_BIAS_WG_OCP",
               "WCD9320_A_RX_HPH_CNP_WG_CTL", "WCD9320_A_RX_HPH_CNP_WG_TIME",
               "WCD9320_CDC_RX1_B6_CTL", "WCD9320_CDC_CLK_RX_B1_CTL",
               "WCD9320_A_RX_HPH_CHOP_CTL", "WCD9320_A_RX_HPH_L_GAIN",
               "WCD9320_A_CDC_RX2_B6_CTL", "WCD9320_A_RX_HPH_R_GAIN",
               "WCD9320_A_NCP_CLK", "WCD9320_A_BUCK_CTRL_CCL_3",
               "WCD9320_A_RX_COM_BIAS", "WCD9320_A_BUCK_MODE_3",
               "WCD9320_A_BUCK_MODE_4", "WCD9320_A_BUCK_MODE_5",
               "WCD9320_A_BUCK_MODE_1", "WCD9320_A_NCP_EN",
               "WCD9320_A_CDC_CLSH_B1_CTL", "WCD9320_A_RX_HPH_L_DAC_CTL",
               "WCD9320_A_RX_HPH_R_DAC_CTL", "WCD9320_A_CDC_PA_RAMP_B1_CTL",
               "WCD9320_A_CDC_PA_RAMP_B2_CTL", "WCD9320_A_CDC_PA_RAMP_B3_CTL",
               "WCD9320_A_CDC_PA_RAMP_B4_CTL"}
    check("the zdet table is exactly the mapped static-PA + ramp set",
          set(ztab) == ZMAPPED and len(ztab) == len(ZMAPPED),
          "%d entries; extra %s; missing %s"
          % (len(ztab), sorted(set(ztab) - ZMAPPED) or "none",
             sorted(ZMAPPED - set(ztab)) or "none"))
    check("the PA register is not in the zdet table",
          "WCD9320_A_RX_HPH_CNP_EN" not in ztab, "PA only via the static-PA function")
    check("wcd9320_zdet_wr refuses the PA register and anything unmapped",
          "WCD9320_A_RX_HPH_CNP_EN" in z_wr and "return -EPERM;" in z_wr
          and "wcd9320_vm_reg_allowed(reg)" in z_wr
          and z_wr.index("return -EPERM;") < z_wr.index("regmap_"),
          "runtime confinement")
    for nm, bd in (("wcd9320_hphl_zdet", z_main), ("wcd9320_zdet_read", z_rd),
                   ("hphl_zdet_store", z_store), ("hphl_zdet_show", z_show)):
        direct = [c for c in ("regmap_write(", "regmap_update_bits(",
                              "c2b_write(", "forced_write(",
                              "regmap_write_bits(", "regmap_bulk_write(")
                  if c in bd]
        check("%s writes only through the zdet/vm write paths" % nm,
              not direct, "direct write calls: %s" % (direct or "none"))
    check("wcd9320_zdet_static_pa is called only from the zdet",
          len(re.findall(r"wcd9320_zdet_static_pa\(wcd,", ptext_all))
          == len(re.findall(r"wcd9320_zdet_static_pa\(wcd,", z_main)) >= 2,
          "%d call(s), %d inside wcd9320_hphl_zdet"
          % (len(re.findall(r"wcd9320_zdet_static_pa\(wcd,", ptext_all)),
             len(re.findall(r"wcd9320_zdet_static_pa\(wcd,", z_main))))
    off_i = z_main.find("wcd9320_zdet_static_pa(wcd, false)")
    rst_i = z_main.find("for (i = WCD9320_ZDET_NREGS; i-- > 0; )")
    check("the PAs are switched off before the register restore",
          0 <= off_i < rst_i, "static PA off at %d, restore loop at %d"
          % (off_i, rst_i))
    check("the ramp is taken back to zero before the PAs go off",
          0 <= z_main.find("WCD9320_ZDET_RAMP_DOWN") < off_i,
          "PA_RAMP_B2 <- 0x0a precedes the PA disable")
    for wit, why in (("zdet: refusing -- the codec is not on MCLK", "MCLK"),
                     ("zdet: refusing -- the analog path is not idle", "idle path"),
                     ("zdet: refusing -- insert detection is on", "insert detect off"),
                     ("zdet: refusing -- interrupt masks are not the certified set",
                      "masks")):
        check("zdet precondition: %s" % why, wit in z_main, "witness in source")
    for flag in ("hphl_pa_on", "pa_prep_on", "hphl_dac_on", "rx1_digital_on",
                 "comp1_on", "clsh_on", "clk_prereq_on"):
        check("zdet refuses with %s" % flag, "wcd->%s" % flag in z_main,
              "part of the idle check")
    for sym, why in (("WCD9320_CDC_CLK_POWER_CTL", "forced 0x314"),
                     ("WCD9320_CDC_CLK_RDAC_CLK_EN_CTL", "forced 0x30d"),
                     ("WCD9320_A_MBHC_INSERT_DETECT", "insert detect"),
                     ("WCD9320_A_INTR_MASK0", "the masks")):
        wl = [ln for ln in (z_main + z_rd + zsp).splitlines()
              if sym in ln and ("_wr(" in ln or "c2b_write(" in ln)]
        check("the zdet never writes %s (%s)" % (sym, why), not wl,
              "%d write line(s)" % len(wl))
    check("every zdet table register is restored and read back",
          rst_i >= 0 and "ZDET RESTORE MISMATCH" in z_main, "reverse restore")
    # r180: the restore check excuses chip-owned bits, and ONLY RX1/RX2_B6 bit 3
    # (measured by the r179 rxb6 trace). A wider excuse would hide real
    # restore failures, so its body is pinned.
    hwo = func_body("wcd9320_hw_owned_bits")
    hw_regs = sorted(set(re.findall(r"reg == (WCD9320_[A-Z0-9_]+)", hwo)))
    check("chip-owned bits excused only for RX1/RX2_B6",
          hw_regs == ["WCD9320_A_CDC_RX2_B6_CTL", "WCD9320_CDC_RX1_B6_CTL"]
          and "return WCD9320_RX_B6_HW_STATUS;" in hwo,
          "%s" % (hw_regs or "no wcd9320_hw_owned_bits()"))
    pat = re.compile(r"^#define\s+WCD9320_RX_B6_HW_STATUS\s+(0x[0-9a-fA-F]+)", re.M)
    check("the excused bit is bit 3 only",
          pat.findall(ptext_all) == ["0x08"], "found %s" % pat.findall(ptext_all))
    check("the zdet restore compare masks only the chip-owned bits",
          "wcd9320_hw_owned_bits(wcd9320_zdet_regs[i])" in z_main
          and "& 0xff & ~hw" in z_main, "per-register excuse")
    check('hphl_zdet accepts exactly "measure"',
          re.findall(r'sysfs_streq\(buf, "([a-z0-9-]+)"\)', z_store) == ["measure"],
          "one verb")
    check("hphl_zdet serialises on c3_lock",
          "mutex_lock(&wcd->c3_lock)" in z_store, "with every C3 sequence")
    check("hphl_zdet is registered", "&dev_attr_hphl_zdet.attr" in ptext_all,
          "in wcd9320_attrs[]")
    check("dev_attr_hphl_zdet present", "dev_attr_hphl_zdet" in e.syms,
          "the sysfs attribute the r179 gate drives")
    check("zdet witness literal shipped",
          e.code_present("wcd9320_hphl_zdet", "zdet: ZDET RESTORE MISMATCH at 0x%03x"),
          "symbol or witness")

    # ==================================================================
    # 5h. r182: THE MCLK OWNERSHIP FENCE.
    #
    # MCLK moves from a runner-sequenced trio (divider, vote, switch) to one
    # driver owner. docs/audio/wcd9320-mclk-ownership-mapping.md. Bounded:
    #
    #   1. the RPM vote is taken and released only inside get/put, in
    #      downstream's order (vote -> switch; switch back -> unvote)
    #   2. only the first get and the last put switch; the switch is called
    #      from nowhere else except its own restore
    #   3. the r169 switch body is byte-for-byte the proven one (pinned hash)
    #   4. get/put run under c3_lock, the lock every C3 sequence holds
    #   5. the divider is board state: written once at probe, factor before
    #      pin, never restored, no runtime write path
    # ==================================================================
    print()
    print("=== 5h. the r182 MCLK ownership fence ===")
    m_get = func_body("wcd9320_mclk_get")
    m_put = func_body("wcd9320_mclk_put")
    m_sw = func_body("wcd9320_clk_source_switch")
    m_st = func_body("clk_source_test_store")
    m_ss = func_body("clk_source_state_show")
    l_apply = func_body("lumia_mclk_apply")
    l_probe = func_body("lumia_mclk_probe")
    for nm, bd in (("wcd9320_mclk_get", m_get), ("wcd9320_mclk_put", m_put),
                   ("wcd9320_clk_source_switch", m_sw),
                   ("clk_source_test_store", m_st),
                   ("clk_source_state_show", m_ss),
                   ("lumia_mclk_apply", l_apply), ("lumia_mclk_probe", l_probe)):
        check("%s found in source" % nm, len(bd) > 0, "%d bytes of body" % len(bd))

    VOTE_ON = "clk_prepare_enable(wcd->mclk)"
    VOTE_OFF = "clk_disable_unprepare(wcd->mclk)"
    SW_ON = "wcd9320_clk_source_switch(wcd, true)"
    SW_OFF = "wcd9320_clk_source_switch(wcd, false)"
    check("the RPM vote is taken only in wcd9320_mclk_get",
          ptext_all.count(VOTE_ON) == m_get.count(VOTE_ON) == 1,
          "%d site(s) in the module, %d in get"
          % (ptext_all.count(VOTE_ON), m_get.count(VOTE_ON)))
    check("the vote is released only in get (unwind) and put",
          ptext_all.count(VOTE_OFF) == 2 and m_get.count(VOTE_OFF) == 1
          and m_put.count(VOTE_OFF) == 1,
          "%d site(s): get %d, put %d" % (ptext_all.count(VOTE_OFF),
                                          m_get.count(VOTE_OFF),
                                          m_put.count(VOTE_OFF)))
    n_sw = len(re.findall(r"wcd9320_clk_source_switch\(wcd,", ptext_all))
    check("the switch is called only from get, put and its own restore",
          m_get.count(SW_ON) == 1 and m_put.count(SW_OFF) == 1
          and m_sw.count(SW_OFF) == 1 and n_sw == 3,
          "%d call(s): get %d, put %d, self-restore %d"
          % (n_sw, m_get.count(SW_ON), m_put.count(SW_OFF), m_sw.count(SW_OFF)))
    check("get votes BEFORE it switches (downstream order)",
          0 <= m_get.find(VOTE_ON) < m_get.find(SW_ON), "vote, then switch")
    check("a failed get releases the vote",
          m_get.find(SW_ON) < m_get.find(VOTE_OFF), "unwind after the switch")
    check("put switches back BEFORE it unvotes",
          0 <= m_put.find(SW_OFF) < m_put.find(VOTE_OFF), "switch back, then unvote")
    check("only the first get votes and switches",
          0 <= m_get.find("if (wcd->mclk_users) {") < m_get.find(VOTE_ON),
          "users > 0 counts and returns")
    check("only the last put switches and unvotes",
          0 <= m_put.find("if (--wcd->mclk_users) {") < m_put.find(SW_OFF),
          "users > 1 counts and returns")
    check("put refuses without a reference",
          0 <= m_put.find("if (!wcd->mclk_users) {") < m_put.find("--wcd->mclk_users"),
          "no underflow")
    for nm, bd in (("wcd9320_mclk_get", m_get), ("wcd9320_mclk_put", m_put)):
        check("%s asserts c3_lock" % nm,
              "lockdep_assert_held(&wcd->c3_lock);" in bd, "serialised with C3")
    check("clk_source_test takes c3_lock and goes through get/put only",
          "mutex_lock(&wcd->c3_lock);" in m_st and "wcd9320_mclk_get(wcd)" in m_st
          and "wcd9320_mclk_put(wcd)" in m_st
          and "wcd9320_clk_source_switch" not in m_st, "no direct switch")
    check('clk_source_test accepts exactly "mclk" and "rco"',
          re.findall(r'sysfs_streq\(buf, "([a-z0-9-]+)"\)', m_st) == ["mclk", "rco"],
          "the r168 words, now get/put")
    check("clk_source_state reports mclk_users", "mclk_users=%u" in m_ss,
          "the gate checks the count")
    # The r169 switch is proven on hardware; r182 must not touch it. Pinned by
    # the sha256 of its body as extracted here, measured on r181 clshk-rc1.
    sw_sha = hashlib.sha256(m_sw.encode()).hexdigest()
    check("the r169 switch body is unchanged", sw_sha == R169_SWITCH_SHA,
          "sha256 %s" % sw_sha[:16])
    # The divider: board state, once.
    check("lumia_mclk_apply is called only from probe",
          ptext_all.count("lumia_mclk_apply(m)") == l_probe.count("lumia_mclk_apply(m)") == 1,
          "%d call(s)" % ptext_all.count("lumia_mclk_apply(m)"))
    div_w = [ln for ln in ptext_all.splitlines()
             if "LUMIA_DIV_CTL1" in ln and "regmap_" in ln and "regmap_read" not in ln]
    check("DIV_CTL1 is written from exactly one site, inside apply",
          len(div_w) == 1 and div_w[0].strip() in l_apply,
          "%d write site(s)" % len(div_w))
    check("the factor is written BEFORE the pin is muxed",
          0 <= l_apply.find("regmap_update_bits(")
          < l_apply.find("DIV_CTL1 did not take")
          < l_apply.find("pinctrl_select_state("),
          "factor chip-verified, then divclk")
    check("pinctrl_select_state only inside apply",
          ptext_all.count("pinctrl_select_state(") == l_apply.count("pinctrl_select_state(") == 1,
          "%d site(s)" % ptext_all.count("pinctrl_select_state("))
    check("the divider is never restored",
          "restored to factor" not in ptext_all and "state_off" not in ptext_all,
          "no off path")
    check("a failed apply refuses the bind",
          "board state NOT applied" in l_probe, "dev_err_probe on failure")

    # ==================================================================
    # 5i. r184: THE DAPM FENCE.
    #
    # Ordinary playback powers the HPHL path through DAPM.
    # docs/audio/wcd9320-dapm-hphl-mapping.md. Bounded:
    #
    #   1. every codec widget is SND_SOC_NOPM -- DAPM itself writes no
    #      register, so the 0x1ab / 0x1b1 / forced-write counts fenced above
    #      are the whole story and stay unchanged
    #   2. the widget set is exactly the mapped one: five ordered supplies,
    #      one PGA, no HPHR
    #   3. one event function, under c3_lock, calling one dispatcher whose
    #      only calls are the six proven path functions
    #   4. ownership: a stage powers only when DAPM holds every stage below
    #      it, the first only on an idle codec, and any failure runs the full
    #      C3 abort
    #   5. the card's Headphones pin exists and is disabled at card init
    #
    # The ORDER comes from the widget TYPES, not from the route graph:
    # mainline powers supplies before PGAs, SUPPLY_S subsequences ascending on
    # the way up and descending on the way down. (Mainline powers DACs BEFORE
    # mixers, which is why RX1 and the DAC are supplies here and not a MIXER
    # and a DAC -- the DAC path refuses without RX1.)
    # ==================================================================
    print()
    print("=== 5i. the r184 DAPM fence ===")
    d_ev = func_body("wcd9320_dapm_event")
    d_call = func_body("wcd9320_dapm_stage_call")
    d_idle = func_body("wcd9320_dapm_idle")
    for nm, bd in (("wcd9320_dapm_event", d_ev),
                   ("wcd9320_dapm_stage_call", d_call),
                   ("wcd9320_dapm_idle", d_idle)):
        check("%s found in source" % nm, len(bd) > 0, "%d bytes of body" % len(bd))

    def array_body(decl):
        m = re.search(re.escape(decl) + r"\s*=\s*\{(.*?)\n\};", ptext_all, re.S)
        return m.group(1) if m else ""

    w_body = array_body("static const struct snd_soc_dapm_widget wcd9320_dapm_widgets[]")
    r_body = array_body("static const struct snd_soc_dapm_route wcd9320_dapm_routes[]")
    # OUTPUT takes the name alone, so the argument tail is optional.
    widgets = re.findall(r"SND_SOC_DAPM_(\w+)\(\s*\"([^\"]+)\"\s*((?:,[^;]*?)?)\)\s*,",
                         w_body, re.S)
    w_names = [(t, n) for t, n, _ in widgets]
    # r185: nine ordered supplies feeding one event-less PGA.
    check("the widget set is exactly the mapped one",
          w_names == [("AIF_IN", "AIF1 PB"),
                      ("SUPPLY_S", "MCLK"), ("SUPPLY_S", "CLASS_H PREP"),
                      ("SUPPLY_S", "CDC PREREQ"), ("SUPPLY_S", "RX1 CHAIN"),
                      ("SUPPLY_S", "RX2 CHAIN"),
                      ("SUPPLY_S", "HPHL DAC"), ("SUPPLY_S", "HPHR DAC"),
                      ("SUPPLY_S", "HPHL PA"), ("SUPPLY_S", "HPHR PA"),
                      ("PGA", "HPH"), ("OUTPUT", "HEADPHONE")],
          "%s" % w_names)
    check("every widget is SND_SOC_NOPM",
          widgets and all("SND_SOC_NOPM" in a for t, n, a in widgets
                          if t != "OUTPUT"),
          "%d widget(s); OUTPUT takes no register argument" % len(widgets))
    check("no register-backed widget macro",
          not re.search(r"SND_SOC_DAPM_\w+\([^)]*WCD9320_(?!DS_)", w_body),
          "no WCD9320_* register named in the widget table (WCD9320_DS_* is the stage)")
    check("AIF1 PB is fed by the RX1 DAI's stream",
          re.search(r'SND_SOC_DAPM_AIF_IN\(\s*"AIF1 PB"\s*,\s*'
                    r'"WCD9320 SLIM RX1 Playback"', w_body) is not None,
          "sname = the DAI's playback stream_name")
    want_stage = [("MCLK", "0", "WCD9320_DS_MCLK"),
                  ("CLASS_H PREP", "1", "WCD9320_DS_PREP"),
                  ("CDC PREREQ", "2", "WCD9320_DS_PREREQ"),
                  ("RX1 CHAIN", "3", "WCD9320_DS_RX1"),
                  ("RX2 CHAIN", "4", "WCD9320_DS_RX2"),
                  ("HPHL DAC", "5", "WCD9320_DS_DACL"),
                  ("HPHR DAC", "6", "WCD9320_DS_DACR"),
                  ("HPHL PA", "7", "WCD9320_DS_PAL"),
                  ("HPHR PA", "8", "WCD9320_DS_PAR")]
    got_stage = re.findall(r'SND_SOC_DAPM_SUPPLY_S\(\s*"([^"]+)"\s*,\s*(\d+)\s*,'
                           r'\s*SND_SOC_NOPM\s*,\s*(\w+)\s*,\s*0\s*,'
                           r'\s*wcd9320_dapm_event\s*,', w_body)
    check("the supplies are ordered by subsequence 0..8, stage in .shift",
          got_stage == want_stage, "%s" % got_stage)
    check("HPH is a NOPM PGA with no event",
          re.search(r'SND_SOC_DAPM_PGA\(\s*"HPH"\s*,\s*SND_SOC_NOPM\s*,'
                    r'\s*0\s*,\s*0\s*,\s*NULL\s*,\s*0\s*\)', w_body) is not None,
          "the PAs are supplies 7 and 8; this only joins the path")
    n_evt = w_body.count("wcd9320_dapm_event")
    check("every event widget has PRE_PMU and POST_PMD only",
          n_evt == 9 and w_body.count("SND_SOC_DAPM_PRE_PMU | SND_SOC_DAPM_POST_PMD") == 9
          and "POST_PMU" not in w_body and "PRE_PMD" not in w_body,
          "%d event widget(s)" % n_evt)
    routes = re.findall(r'\{\s*"([^"]+)"\s*,\s*(NULL|"[^"]*")\s*,\s*"([^"]+)"\s*\}',
                        r_body)
    routes = sorted((s, c.strip('"') if c != "NULL" else None, src)
                    for s, c, src in routes)
    want_routes = sorted([("HPH", None, "AIF1 PB"),
                          ("HEADPHONE", None, "HPH")] +
                         [("HPH", None, s) for s, _, _ in want_stage])
    check("the routes are exactly the mapped ones", routes == want_routes,
          "%d route(s)" % len(routes))
    comp = array_body("static const struct snd_soc_component_driver wcd9320_soc_component")
    check("the component declares the widgets and routes",
          all(s in comp for s in (".dapm_widgets = wcd9320_dapm_widgets",
                                  ".num_dapm_widgets = ARRAY_SIZE(wcd9320_dapm_widgets)",
                                  ".dapm_routes = wcd9320_dapm_routes",
                                  ".num_dapm_routes = ARRAY_SIZE(wcd9320_dapm_routes)")),
          "wcd9320_soc_component")
    # r185: four volume controls and the jack, nothing else.
    check("the component declares the controls and the jack",
          all(s in comp for s in (".controls = wcd9320_controls",
                                  ".num_controls = ARRAY_SIZE(wcd9320_controls)",
                                  ".set_jack = wcd9320_set_jack",
                                  ".remove = wcd9320_component_remove")),
          "wcd9320_soc_component")
    ctl = array_body("static const struct snd_kcontrol_new wcd9320_controls[]")
    check("the controls are exactly the four mapped ones",
          re.findall(r'SOC_SINGLE_EXT(?:_TLV)?\(\s*"([^"]+)"', ctl)
          == ["HPHL Volume", "HPHR Volume", "RX1 Digital Volume",
              "RX2 Digital Volume"], "analog x2, digital x2")

    # ---- the dispatcher: the six proven functions, nothing else --------
    want_calls = ["wcd9320_mclk_get(wcd)", "wcd9320_mclk_put(wcd)",
                  "wcd9320_pa_prep(wcd, on)", "wcd9320_cdc_clk_prereq(wcd, on)",
                  "wcd9320_rx_digital_path(wcd, 0, on)",
                  "wcd9320_rx_digital_path(wcd, 1, on)",
                  "wcd9320_hphl_dac_path(wcd, on, true,",
                  "wcd9320_hphr_dac_path(wcd, on)",
                  "wcd9320_hphl_pa_path(wcd, on)",
                  "wcd9320_hphr_pa_path(wcd, on)"]
    check("the dispatcher calls each proven function exactly once",
          all(d_call.count(c) == 1 for c in want_calls),
          ", ".join("%s%d" % (c.split("(")[0][8:], d_call.count(c)) for c in want_calls))
    all_calls = [c for c in re.findall(r"\b(\w+)\s*\(", d_call)
                 if c not in ("switch", "if", "return", "sizeof")]
    check("the dispatcher calls nothing else",
          sorted(set(all_calls)) == sorted({c.split("(")[0] for c in want_calls}),
          "%s" % sorted(set(all_calls)))
    check("the DAC stage is register-gain mode, DAC powered",
          "wcd9320_hphl_dac_path(wcd, on, true,\n\t\t\t\t\t     WCD9320_GAIN_SRC_REGISTER)" in d_call
          or re.search(r"wcd9320_hphl_dac_path\(wcd, on, true,\s*WCD9320_GAIN_SRC_REGISTER\)",
                       d_call) is not None, "the C3a mode, never compander")
    for nm, bd in (("wcd9320_dapm_event", d_ev),
                   ("wcd9320_dapm_stage_call", d_call),
                   ("wcd9320_dapm_idle", d_idle)):
        direct = [c for c in ("regmap_", "c2b_write(", "forced_write(",
                              "rx1_write(", "clk_prepare", "clk_disable",
                              "clk_source_switch(")
                  if c in bd]
        check("%s writes nothing itself" % nm, not direct,
              "direct register/clock calls: %s" % (direct or "none"))

    # ---- the event: lock, ownership chain, idle start, abort on failure ---
    check("the event takes and releases c3_lock",
          d_ev.count("mutex_lock(&wcd->c3_lock);") == 1
          and d_ev.count("mutex_unlock(&wcd->c3_lock);") == 1, "one critical section")
    check("the event calls the path only through the dispatcher",
          d_ev.count("wcd9320_dapm_stage_call(") == 2
          and not any(f in d_ev for f in ("wcd9320_mclk_get", "wcd9320_pa_prep",
                                          "wcd9320_hphl_pa_path", "wcd9320_hphl_dac_path",
                                          "wcd9320_hphr_pa_path", "wcd9320_hphr_dac_path",
                                          "wcd9320_rx1_digital_path",
                                          "wcd9320_rx_digital_path",
                                          "wcd9320_cdc_clk_prereq")),
          "power up once, power down once")
    i_on = d_ev.find("wcd9320_dapm_stage_call(wcd, stage, true)")
    check("power-up requires DAPM to hold exactly the stages below",
          0 <= d_ev.find("wcd->dapm_held != below") < i_on, "checked before the call")
    check("the first stage requires an idle codec",
          0 <= d_ev.find("!wcd9320_dapm_idle(wcd)") < i_on, "checked before the call")
    up_branch = d_ev[i_on:d_ev.find("} else {", i_on)] if i_on >= 0 else ""
    check("a failed power-up runs the full C3 abort",
          "wcd9320_c3_abort(wcd);" in up_branch
          and "wcd->dapm_held &= ~WCD9320_DS_ABORTED;" in up_branch,
          "in the power-up branch, after the failed call")
    check("power-down undoes only what DAPM holds",
          0 <= d_ev.find("!(wcd->dapm_held & BIT(stage))")
          < d_ev.find("wcd9320_dapm_stage_call(wcd, stage, false)"),
          "a stage DAPM never powered is never torn down by it")
    for flag in ("wcd->mclk_users", "wcd->pa_prep_on", "wcd->clk_prereq_on",
                 "wcd->rx1_digital_on", "wcd->hphl_dac_on", "wcd->hphl_pa_on",
                 "wcd->rx2_digital_on", "wcd->hphr_dac_on", "wcd->hphr_pa_on",
                 "wcd->comp1_on", "wcd->clsh_on", "wcd->clsh_r_on",
                 "wcd->rx_bias_refs"):
        check("idle means %s is clear" % flag.split("->")[1], "!" + flag in d_idle,
              "wcd9320_dapm_idle")
    check("the event is called from nothing but the widget table",
          ptext_all.count("wcd9320_dapm_event") == 1 + n_evt,
          "%d mention(s): the definition and %d widget(s)"
          % (ptext_all.count("wcd9320_dapm_event"), n_evt))

    # ---- the card: the Headphones pin, off at init ---------------------
    P5 = REPO / "patches/0005-asoc-qcom-lumia1520-q6-sndcard.patch"
    card = "\n".join(ln[1:] for ln in
                     (P5.read_text(errors="replace") if P5.exists() else "").splitlines()
                     if ln.startswith("+") and not ln.startswith("+++"))
    check("card patch found", len(card) > 0, str(P5.name))
    check("the card declares the Headphones widget",
          'SND_SOC_DAPM_HP("Headphones", NULL)' in card, "an HP endpoint")
    check("the card routes Headphones <- HEADPHONE",
          re.search(r'\{\s*"Headphones"\s*,\s*NULL\s*,\s*"HEADPHONE"\s*\}', card)
          is not None, "the codec output reaches the pin")
    check("the card exposes the pin switch",
          'SOC_DAPM_PIN_SWITCH("Headphones")' in card, '"Headphones Switch"')
    check("the card disables the pin at init",
          'snd_soc_dapm_disable_pin(&card->dapm, "Headphones")' in card
          and "card->late_probe = lumia_q6_late_probe;" in card,
          "late_probe, before the first sync")
    check("the card never enables the pin itself",
          "enable_pin" not in card and "force_enable" not in card,
          "only the jack and the operator's control do")
    # r185: the jack drives the pin, through ASoC's jack core.
    check("the card's Headphone Jack drives the Headphones pin",
          re.search(r'\{\s*\.pin\s*=\s*"Headphones"\s*,\s*\.mask\s*=\s*SND_JACK_HEADPHONE\s*\}',
                    card) is not None
          and 'snd_soc_card_jack_new_pins(card, "Headphone Jack"' in card
          and "snd_soc_component_set_jack(codec, &lumia_q6_jack, NULL)" in card,
          "headphone only")
    li = card.find("lumia_q6_late_probe(struct snd_soc_card *card)\n{")
    check("the pin is disabled before the jack is handed over",
          0 <= card.find('snd_soc_dapm_disable_pin(&card->dapm, "Headphones")', li)
          < card.find("snd_soc_component_set_jack(", li), "off until a report")
    check("the back end is pinned to two channels",
          "channels->min = channels->max = 2;" in card, "SLIM RX1 + RX2")

    # ==================================================================
    # 5j. r185: STEREO, VOLUME, JACK.
    #
    # docs/audio/wcd9320-r185-stereo-volume-jack-mapping.md. The PA count and
    # the guard states are fenced in 5d, the stages in 5i. This pins the rest:
    #
    #   1. the RX2 chain is RX1's table row, the same function, the same steps
    #   2. the HPHR DAC: refused prerequisites, downstream's order both ways,
    #      the mandatory forced inverse, and nothing but 0x1b7 / 0x30d bit 2
    #   3. class-H: HPHR joins and leaves by CLSH_B1 bits 3/2 <- 0, nothing else
    #   4. the prep: HPHR's gain rows, boot default minimum
    #   5. stereo transport: ports 16 + 17, payload of the whole set, 2 slots
    #   6. volume: analog capped at the 20-step field, digital at 0 dB
    #   7. jack: JACK_SWITCH only, headphone only, polarity re-armed, and the
    #      research hooks refuse while it owns 0x14a
    # ==================================================================
    print()
    print("=== 5j. the r185 stereo / volume / jack fence ===")
    for sym, want in (("WCD9320_CDC_CONN_RX2_B1_CTL", "0x383"),
                      ("WCD9320_CDC_RX2_VOL_CTL_B2_CTL", "0x2bf"),
                      ("WCD9320_CDC_RX2_B6_CTL", "0x2bd"),
                      ("WCD9320_CDC_RX2_B5_CTL", "0x2bc"),
                      ("WCD9320_RX_MIX1_INP_RX2", "0x06"),
                      ("WCD9320_RDAC_HPHR_CLK", "0x04"),
                      ("WCD9320_INTR2_OCPR_FAULT", "0x02"),
                      ("WCD9320_HPHR_DAC_PWR", "0x80"),
                      ("WCD9320_HPHR_DAC_SWITCH", "0x40"),
                      ("WCD9320_A_RX_HPH_R_GAIN", "0x1b4"),
                      ("WCD9320_A_RX_HPH_R_DAC_CTL", "0x1b7"),
                      ("WCD9320_ZDET_MUX1_HPHR", "0xa0")):
        pat = re.compile(r"^#define\s+%s\s+(0x[0-9a-fA-F]+)" % re.escape(sym), re.M)
        found = pat.findall(ptext_all)
        check("%s is %s" % (sym, want), found == [want],
              "found %s" % (found or "no definition"))
    check("WCD9320_RX2_INTERP_BIT is BIT(1)",
          re.search(r"^#define\s+WCD9320_RX2_INTERP_BIT\s+BIT\(1\)", ptext_all, re.M)
          is not None, "0x301 / 0x30f bit 1")
    check("the forced-write ring holds 64",
          re.search(r"^#define\s+WCD9320_FORCED_LOG\s+64\b", ptext_all, re.M)
          is not None, "6 per stereo stream")

    rxd = func_body("wcd9320_rx_digital_path")
    rx1w = func_body("wcd9320_rx1_digital_path")
    chains = array_body("static const struct wcd9320_rx_chain wcd9320_rx_chains[2]")
    check("RX1 is channel 0 of the one RX function",
          "return wcd9320_rx_digital_path(wcd, 0, enable);" in rx1w
          and len(rx1w.strip("{} \n\t").splitlines()) == 1, "a one-line wrapper")
    check("the RX table rows are RX1's and RX2's",
          chains.count("WCD9320_CDC_CONN_RX1_B1_CTL") == 1
          and chains.count("WCD9320_CDC_CONN_RX2_B1_CTL") == 1
          and chains.index("RX1_B1") < chains.index("RX2_B1")
          and "WCD9320_RX_MIX1_INP_RX2, WCD9320_RX2_INTERP_BIT" in chains,
          "row 0 RX1, row 1 RX2")
    seq = ("c->conn, WCD9320_RX_MIX1_INP_MASK", "c->bit, c->bit, \"interpolator reset asserted\"",
           "c->bit, 0, \"interpolator reset released\"", "WCD9320_CDC_CLK_RX_B1_CTL,\n\t\t\t       c->bit, c->bit",
           "c->vol, 0xff, gain & 0xff", "c->b6, WCD9320_RX1_CHAIN_BIT,\n\t\t\t       WCD9320_RX1_CHAIN_BIT")
    pos, ok = -1, bool(rxd)
    for tok in seq:
        nxt = rxd.find(tok, pos + 1)
        if nxt < 0:
            ok = False
            break
        pos = nxt
    check("the RX sequence is the proven one, in order", ok,
          "mux, reset pulse, clock, gain latch, chain")
    check("the RX rate is asserted from the table, never written",
          "regmap_read(wcd->regmap, c->b5, &fs);" in rxd
          and "c->b5, 0x" not in rxd.replace("c->b5, fs", ""), "0x2b4 / 0x2bc")

    rdac = r_dac_path
    i_en = rdac.find("if (!enable)\n\t\tgoto teardown;")
    i_td = rdac.find("teardown:")
    up = rdac[i_en:i_td] if 0 <= i_en < i_td else ""
    down = rdac[i_td:] if i_td >= 0 else ""
    for cond, why in (("!wcd->hphl_dac_on || !wcd->clsh_on || !wcd->clk_prereq_on", "HPHL DAC path first"),
                      ("!wcd->rx2_digital_on", "RX2 first"),
                      ("wcd->hphl_pa_on || wcd->hphr_pa_on", "before any PA"),
                      ("wcd->comp1_on", "register gain mode only")):
        check("the HPHR DAC refuses: %s" % why, cond in up, "checked before any write")
    check("the HPHR DAC verifies 0x1b4 on the chip first",
          0 <= up.find("regmap_read_bypassed(wcd->regmap, WCD9320_A_RX_HPH_R_GAIN")
          < up.find("wcd9320_rx_bias(wcd, true)")
          and "WCD9320_HPHL_GAIN_SRC | wcd->pa_gain_field_r" in up,
          "source bit and the HPHR field")
    pos, ok = -1, bool(up)
    for tok in ("wcd9320_rx_bias(wcd, true)",
                "WCD9320_RDAC_HPHR_CLK, WCD9320_RDAC_HPHR_CLK",
                "WCD9320_HPHR_DAC_SWITCH, WCD9320_HPHR_DAC_SWITCH",
                "wcd9320_clsh_hphr(wcd, true)",
                "WCD9320_HPHR_DAC_PWR, WCD9320_HPHR_DAC_PWR"):
        nxt = up.find(tok, pos + 1)
        if nxt < 0:
            ok = False
            break
        pos = nxt
    check("the HPHR DAC enable is downstream's order", ok,
          "bias, RDAC clock, bit 6, class-H join, bit 7")
    pos, ok = -1, bool(down)
    for tok in ("WCD9320_HPHR_DAC_PWR, 0,",
                "WCD9320_RDAC_HPHR_CLK, 0,",
                "WCD9320_HPHR_DAC_SWITCH, 0,",
                "wcd9320_clsh_hphr(wcd, false)",
                "wcd9320_rx_bias(wcd, false)"):
        nxt = down.find(tok, pos + 1)
        if nxt < 0:
            ok = False
            break
        pos = nxt
    check("the HPHR DAC teardown is the reverse, inverse mandatory", ok,
          "bit 7, forced RDAC clear, bit 6, class-H leave, bias")
    check("the HPHR teardown has no early return",
          down.count("return") == 1 and r_pa_path[r_pa_path.find("teardown:"):].count("return") == 1,
          "best-effort, every step attempted")
    fr = [ln for ln in added if "WCD9320_RDAC_HPHR_CLK" in ln
          and not ln.lstrip().startswith(("*", "/*", "#define"))]
    check("the HPHR RDAC bit is named only in the HPHR DAC path",
          len(fr) == 2 and all(ln in set(rdac.splitlines()) for ln in fr),
          "%d line(s): one set, one forced clear" % len(fr))
    r_dac_named = [ln for ln in added if "WCD9320_A_RX_HPH_R_DAC_CTL" in ln
                   and any(c in ln for c in CALLS)]
    check("0x1b7 is written only by the HPHR DAC path",
          all(ln in set(rdac.splitlines()) for ln in r_dac_named) and len(r_dac_named) == 4,
          "%d write line(s); the zdet's table rows are counted in 5g" % len(r_dac_named))

    clr = func_body("wcd9320_clsh_hphr")
    cw = re.findall(r"wcd9320_clsh_one\(wcd,\s*WCD9320_A_CDC_CLSH_B1_CTL,\s*(0x[0-9a-f]+),\s*(0x[0-9a-f]+),", clr)
    check("the class-H join and leave write only CLSH_B1 bits 3/2 <- 0",
          sorted(cw) == [("0x04", "0x00"), ("0x04", "0x00"), ("0x08", "0x00")]
          and "regmap_update_bits" not in clr and "c2b_write" not in clr,
          "COND_HPH clear: comp_req L/R write 0 both ways")
    check("HPHR joins only an HPHL class-H state",
          0 <= clr.find("if (!wcd->clsh_on)") < clr.find("clsh_one("), "never from IDLE")

    prep_tab = array_body("static const struct wcd9320_pa_prep_reg\nwcd9320_pa_prep_set[WCD9320_PA_PREP_N]")
    check("the prep has 8 rows, HPHR's two appended",
          re.search(r"^#define\s+WCD9320_PA_PREP_N\s+8\b", ptext_all, re.M) is not None
          and prep_tab.count("WCD9320_A_RX_HPH_R_GAIN") == 2
          and prep_tab.rfind("WCD9320_A_RX_HPH_CHOP_CTL") < prep_tab.find("WCD9320_A_RX_HPH_R_GAIN"),
          "rows 0..5 keep their indices")
    check("the HPHR gain field defaults to the MINIMUM at probe",
          re.search(r"wcd->pa_gain_field_r\s*=\s*WCD9320_HPHL_GAIN_MIN\s*;", probe_body) is not None,
          "0x00 would be the maximum")
    check("the prep refuses an out-of-range HPHR field",
          "pa_gain_field_r > WCD9320_HPHL_GAIN_MIN" in prep_body, "defence in depth")
    check("the prep writes the per-channel field",
          "wcd->pa_gain_field_r : wcd->pa_gain_field" in prep_body, "0x1b4 takes the R setting")

    rpp = func_body("wcd9320_rx_ports_program")
    check("a set of ports carries the payload of the whole set",
          "mask = GENMASK(n - 1, 0);" in rpp
          and "WCD9320_RX_PORT_FIRST + i,\n\t\t\t\t\t      mask, true)" in rpp,
          "01 mono, 03 on 16 and 17 for stereo")
    check("the set is torn down in reverse, best-effort",
          "for (i = n; i-- > 0; )" in rpp, "17 then 16")
    hwp = func_body("wcd9320_rx_hw_params")
    check("hw_params programs one port per channel",
          "wcd9320_rx_ports_program(wcd, params_channels(params), true)" in hwp
          and "params_channels(params));" in hwp, "and configures that many channels")
    gcm = func_body("wcd9320_get_channel_map")
    check("the codec reports SLIM RX1 and RX2",
          "rx_slot[1] = WCD9320_SLIM_RX1_CH + 1;" in gcm and "*rx_num = 2;" in gcm,
          "144, 145")
    check("the RX DAI takes up to two channels",
          ".channels_max = 2," in ptext_all, "stereo")
    scf = func_body("__wcd9320_slim_config")
    check("the SLIMbus config spans consecutive ports",
          "GENMASK(port + nch - 1, port)" in scf and "wcd->sconfig.ch_count = nch;" in scf,
          "port_mask and ch_count from the channel count")

    hvp = func_body("wcd9320_hph_vol_put")
    dvp = func_body("wcd9320_dig_vol_put")
    check("analog volume is bounded to the 20-step field",
          "v > WCD9320_HPH_VOL_STEPS" in hvp and "want = WCD9320_HPHL_GAIN_MIN - v;" in hvp
          and re.search(r"^#define\s+WCD9320_HPH_VOL_STEPS\s+WCD9320_HPHL_GAIN_MIN\b",
                        ptext_all, re.M) is not None, "inverted, 0 = minimum")
    check("analog volume moves the chip only while the prep is live",
          0 <= hvp.find("if (wcd->pa_prep_on)") < hvp.find("wcd9320_c2b_write(")
          and "regmap_" not in hvp, "through the chip-verified helper")
    check("digital volume is capped at 0 dB",
          re.search(r"^#define\s+WCD9320_DIG_VOL_STEPS\s+84\b", ptext_all, re.M) is not None
          and "v > WCD9320_DIG_VOL_STEPS" in dvp
          and "want = (u8)(s8)(v - WCD9320_DIG_VOL_STEPS);" in dvp
          and "DECLARE_TLV_DB_SCALE(wcd9320_digital_tlv, -8400, 100, 0)" in ptext_all,
          "-84..0 dB, cut only")
    for nm in ("wcd9320_hph_vol_get", "wcd9320_hph_vol_put",
               "wcd9320_dig_vol_get", "wcd9320_dig_vol_put"):
        check("%s serialises on c3_lock" % nm,
              "mutex_lock(&wcd->c3_lock)" in func_body(nm), "with every path stage")

    jen = func_body("wcd9320_jack_enable")
    jth = func_body("wcd9320_jack_thread")
    jdis = func_body("wcd9320_jack_disable")
    jrep = func_body("wcd9320_jack_report")
    ids = func_body("wcd9320_insert_detect_set")
    check("insert detect takes the polarity as an argument",
          "base | (ins ? WCD9320_MBHC_DET_INS : 0)" in ids, "wcd9xxx_insert_detect_setup(ins)")
    # r186: 0x14b carries no level until detection is enabled -- r185 read it
    # first, always got the unconfigured 0e, and missed a headset in at boot.
    check("the boot level is read only after detection is armed",
          0 <= jen.find("false, true);") < jen.find("msleep(WCD9320_JACK_ARM_SETTLE_MS)")
          < jen.find("wcd9320_jack_level(") < jen.find("if (!ret && ins)")
          and re.search(r"^#define\s+WCD9320_JACK_ARM_SETTLE_MS\s+50\b", ptext_all, re.M)
          is not None, "arm for insertion, settle, read, re-arm for removal if in")
    check("jack detection requests JACK_SWITCH and nothing else",
          "regmap_irq_get_virq(wcd->irq_data, WCD9320_IRQ_MBHC_JACK_SWITCH)" in jen
          and jen.count("regmap_irq_get_virq(") == 1, "the source rc6 proved")
    check("the jack reports headphone only",
          "SND_JACK_HEADPHONE : 0,\n\t\t\t    SND_JACK_HEADPHONE);" in jrep
          and "MICROPHONE" not in ptext_all.split("r185: jack detection")[-1].split("static int wcd9320_set_jack")[0],
          "no mic, no buttons")
    check("the handler debounces, then re-arms for the other state",
          0 <= jth.find("usleep_range(WCD9320_JACK_DEBOUNCE_US") < jth.find("wcd9320_jack_level(")
          < jth.find("false, !ins);")
          and re.search(r"^#define\s+WCD9320_JACK_DEBOUNCE_US\s+5000\b", ptext_all, re.M) is not None,
          "5 ms, as SWCH_IRQ_DEBOUNCE_TIME_US")
    check("the report is made after wake_lock is dropped",
          jth.rfind("mutex_unlock(&wcd->wake_lock);") < jth.find("wcd9320_jack_report(")
          and "c3_lock" not in jth + jen + jdis + jrep,
          "the report takes the DAPM mutex, which takes c3_lock")
    check("the jack source is freed outside wake_lock",
          0 <= jdis.find("mutex_unlock(&wcd->wake_lock);") < jdis.find("free_irq(virq, wcd);")
          < jdis.rfind("mutex_lock(&wcd->wake_lock);"), "the thread takes wake_lock")
    check("the research hooks refuse while the jack owns 0x14a",
          "if (wcd->jack_on) {" in func_body("mbhc_detect_store")
          and "if (wcd->jack_on && !sysfs_streq(buf, \"disarm\")) {" in func_body("mbhc_test_store")
          and "wcd->mbhc_armed || wcd->mbhc_detect_on" in jen, "and the jack refuses while they do")
    check("the jack is freed on remove, before the irq chip goes",
          "wcd9320_jack_disable(wcd, false);" in func_body("wcd9320_remove"),
          "and on component remove")
    for sym in ("hphr_test", "hphr_state", "jack_detect"):
        check("%s is registered" % sym, "&dev_attr_%s.attr" % sym in ptext_all, "in wcd9320_attrs[]")
        check("dev_attr_%s present" % sym, "dev_attr_%s" % sym in e.syms, "in the artefact")

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
        ptext = PATCH.read_text(errors="replace") if PATCH.exists() else ""
        check("Kconfig depends on SND_SOC", "depends on SND_SOC" in ptext)

        if args.expect_dais == 0:
            dai_syms = [s for s in e.syms
                        if "dai" in s.lower() and "wcd9320" in s.lower()]
            check("no DAI table in the module", not dai_syms,
                  "found: %s" % dai_syms)
            check("registered with NULL dais, count 0", "NULL, 0)" in ptext,
                  "source-level")
        else:
            check("wcd9320_dais present", "wcd9320_dais" in e.syms,
                  "the DAI table")
            # One DAI, and it is a playback DAI. Counted from the source of
            # the array rather than guessed from a symbol size, because
            # snd_soc_dai_driver's layout is kernel-version dependent.
            m = re.search(r'static struct snd_soc_dai_driver wcd9320_dais\[\]'
                          r' = \{(.*?)\n\+\};', ptext, re.S)
            body = m.group(1) if m else ""
            nstream = body.count(".stream_name")
            check("exactly %d DAI declared" % args.expect_dais,
                  nstream == args.expect_dais,
                  "%d stream_name(s) in wcd9320_dais[]" % nstream)
            # check() prints its detail on pass and fail alike, so the detail
            # states a fact rather than explaining a failure -- a PASS line
            # reading "found a .capture member" would be actively misleading.
            check("no capture stream (no TX DAI)", ".capture" not in body,
                  "playback only")
            check("DAI registered with ARRAY_SIZE(wcd9320_dais)",
                  "ARRAY_SIZE(wcd9320_dais)" in ptext)

        # The interface function must have its own regmap config -- different
        # register space, and it must not inherit the codec's cache.
        check("wcd9320_ifd_regmap_config present",
              "wcd9320_ifd_regmap_config" in e.syms,
              "the interface function's own config")
        check("IFD config is REGCACHE_NONE",
              re.search(r'wcd9320_ifd_regmap_config = \{.*?REGCACHE_NONE',
                        ptext, re.S) is not None,
              "source-level")
        check("IFD probe uses the IFD config",
              "&wcd9320_ifd_regmap_config" in ptext)
        check("IFD max_register is 0x1b0",
              "WCD9320_IFD_MAX_REGISTER\t0x1b0" in ptext
              or "WCD9320_IFD_MAX_REGISTER		0x1b0" in ptext,
              "source-level")

        # The register sequence must exist once. The research hook may call
        # the production helper but must not re-implement it.
        #
        # Count DEFINITIONS, not declarations: there is one forward
        # declaration so the research hook (which appears earlier in the file)
        # can call the helper. A definition's parameter list is followed by an
        # opening brace; a declaration by a semicolon.
        #
        # ANCHORED ON THE FUNCTION NAME, and it has to be. The original pattern
        # was a bare r'bool enable\)\n\+\{', which matches ANY function whose
        # last parameter is `bool enable` -- so it silently started counting
        # wcd9320_rx1_digital_path, wcd9320_comp1_enable and wcd9320_clsh_hphl
        # as port-programming helpers as each milestone landed. It read 4 at
        # r163 and 6 at r164, having last been correct at r160. A check whose
        # subject drifts as unrelated code is added is not checking anything;
        # it just happened to be dormant because 5b only runs under
        # --expect-asoc.
        PORT_HELPER = r'\+static int wcd9320_rx_port_program\([^;]*?bool enable\)'
        ndef = len(re.findall(PORT_HELPER + r'\n\+\{', ptext))
        ndecl = len(re.findall(PORT_HELPER + r';', ptext))
        # A rename must not turn this into a vacuous pass at zero.
        check("the port-programming helper was found at all", ndef >= 1,
              "%d definition(s) of wcd9320_rx_port_program" % ndef)
        check("one production port-programming helper", ndef == 1,
              "%d definition(s)" % ndef)
        check("at most one forward declaration of it", ndecl <= 1,
              "%d declaration(s)" % ndecl)
        hook = re.search(r'static ssize_t rx_port_test_store\(.*?\n\+\}',
                         ptext, re.S)
        hb = hook.group(0) if hook else ""
        check("hook calls the production helper",
              "wcd9320_rx_port_program(" in hb)
        check("hook does not duplicate the register sequence",
              "regmap_write" not in hb,
              "no regmap_write in the hook body")

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

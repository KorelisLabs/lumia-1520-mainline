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
    "volatile": 401,
    "defaults": 460,
    "zero_defaults": 230,
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
    "read_bypassed_calls": 90,
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
            ("wcd9320_mclk_enable", "mclk: ENABLED, rate %lu Hz",
             "the r166 external MCLK consumer"),
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
                     ("dev_attr_hphl_pa_test", "sysfs, the r175 PA trigger"),
                     ("dev_attr_hphl_pa_state", "sysfs, the C3a register set"),
                     ("dev_attr_cdc_clk_prereq", "sysfs, 0x314 only"),
                     ("dev_attr_rdac_probe", "sysfs, the causal experiment"),
                     ("dev_attr_mclk_div_test", "sysfs, the r167 divider"),
                     ("dev_attr_mclk_div_state", "sysfs, DIV_CTL1 + gpio15 mux")):
        check("%s present" % sym, sym in e.syms, why)

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
        m = re.search(r"^static\s+[A-Za-z_][\w \t*]*\b%s\s*\("
                      % re.escape(name), ptext_all, re.M)
        if not m:
            return ""
        i = ptext_all.find("{", m.start())
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
    guard_exp = func_body("wcd9320_pa_guard_expect")
    guard_old = func_body("wcd9320_pa_guard")
    abort_body = func_body("wcd9320_c3_abort")

    # A missing function must fail loudly rather than making every
    # containment check below trivially true. This is the check that stops a
    # rename from turning the whole fence into a vacuous pass.
    for nm, bd in (("wcd9320_hphl_pa_path", pa_path),
                   ("wcd9320_hphl_dac_path", dac_path),
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
    check("both PA writes go through the chip-verified helper", len(pw) == 2,
          "%d matched wcd9320_c2b_write(0x1ab, mask, val)" % len(pw))
    check("both PA writes are masked to HPHL alone",
          bool(pw) and all(m == "WCD9320_HPH_PA_HPHL" for m, _ in pw),
          "masks: %s" % ([m for m, _ in pw] or "none"))
    check("the PA writes are exactly one enable and one disable",
          sorted(v for _, v in pw) == ["0", "WCD9320_HPH_PA_HPHL"],
          "values: %s" % (sorted(v for _, v in pw) or "none"))
    check("both PA writes live in wcd9320_hphl_pa_path",
          len(PA_WRITE.findall(pa_path)) == 2,
          "%d of 2 inside the mapped PA sequence"
          % len(PA_WRITE.findall(pa_path)))

    # THE TWO-BIT MASK IS A GUARD MASK, NEVER A WRITE MASK.
    #
    # WCD9320_HPH_PA_MASK is 0x30. A write masked with it would set or clear
    # HPHR alongside HPHL from a single statement that reads perfectly well.
    mask_writes = [ln for ln in added
                   if "WCD9320_HPH_PA_MASK" in ln
                   and any(c in ln for c in CALLS)]
    check("0x30 is never used as a write mask", not mask_writes,
          "%d write call(s) naming WCD9320_HPH_PA_MASK" % len(mask_writes))
    hphr_writes = [ln for ln in added
                   if "WCD9320_HPH_PA_HPHR" in ln
                   and any(c in ln for c in CALLS)]
    check("the HPHR PA bit is never written", not hphr_writes,
          "%d write call(s) naming WCD9320_HPH_PA_HPHR" % len(hphr_writes))

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
    nz_pa = [v for v in GEXP.findall(pa_path) if v != "0"]
    check("the only non-zero guard expectation is HPHL",
          nz_all and all(v == "WCD9320_HPH_PA_HPHL" for v in nz_all),
          "expectations: %s" % (sorted(set(nz_all)) or "none"))
    check("non-zero expectations come only from the PA sequence",
          len(nz_all) == len(nz_pa) and len(nz_pa) > 0,
          "%d in the driver, %d of them in wcd9320_hphl_pa_path"
          % (len(nz_all), len(nz_pa)))

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
          and "WCD9320_HPHL_GAIN_C3A" in dac_path,
          "bit 5 set and the field at 0x14, read from the chip")
    for sym, want in (("WCD9320_HPHL_GAIN_CHECK", "0x3f"),
                      ("WCD9320_HPHL_GAIN_C3A", "0x34")):
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
              len(pat.findall(pa_path)) == 1,
              "%d site(s) in the PA sequence" % len(pat.findall(pa_path)))
    # And their inverses must not exist anywhere in the PA sequence.
    for reg, mask, bad in (("WCD9320_A_BUCK_MODE_5", "0x02", "0x02"),
                           ("WCD9320_A_NCP_STATIC", "0x20", "0x20"),
                           ("WCD9320_A_BUCK_MODE_3", "0x04", "0x00"),
                           ("WCD9320_A_BUCK_MODE_3", "0x08", "0x00")):
        pat = re.compile(r"wcd9320_c2b_write\(\s*wcd,\s*%s,\s*%s,\s*%s,"
                         % (re.escape(reg), mask, bad))
        check("no invented inverse for %s mask %s" % (reg[10:], mask),
              not pat.findall(pa_path),
              "turnoff_postpa() does not touch it, so neither do we")
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
            ("WCD9320_A_RX_HPH_CNP_EN", "0x1ab", 2, 0,
             "the PA -- r175, exactly one enable and one disable"),

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

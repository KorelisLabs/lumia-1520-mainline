#!/usr/bin/env python3
"""Classify measured register volatility against downstream's taiko_volatile(),
and propose reg_defaults from a measured dump.

    wcd9320-volatility-analyse.py EVIDENCE.txt [--defaults]

EVIDENCE.txt is the artefact from wcd9320-volatility-evidence.sh, which embeds
the raw dumps so the analysis can be recomputed rather than trusted.

WHY THE CLASSIFICATION IS THREE-WAY

Measurement can only prove volatility positively: a register that moved is
volatile, a register that did not move is unexamined, not constant. So the
output is deliberately split into

    observed volatile, and downstream agrees
    observed volatile, and downstream does NOT mark it   <- the dangerous case
    downstream marks volatile, and this test never exercised it

and the third bucket is expected to be the large one. It is not a criticism of
the measurement; it is the reason a measured list must never be used as the
volatile predicate on its own.

The downstream predicate is reimplemented from wcd9320.c's taiko_volatile().
Addresses come from the cached headers, so the reimplementation is checked
against real symbols rather than transcribed by hand.
"""
import argparse
import os
import re
import sys

CACHE = os.path.expanduser('~/.cache/wcd9320-hdr')
MAX_REGISTER = 0x3FF


def load_addresses():
    """name -> address, and name -> __POR, from the downstream headers."""
    addr, por = {}, {}
    for fn in ('wcd9320_registers.h', 'wcd9xxx_registers.h'):
        p = os.path.join(CACHE, fn)
        if not os.path.exists(p):
            continue
        for line in open(p, errors='replace'):
            m = re.match(r'#define\s+((?:TAIKO|WCD9XXX)_A_\w+)\s+\(?(0x[0-9A-Fa-f]+)',
                         line)
            if not m:
                continue
            name, val = m.group(1), int(m.group(2), 16)
            if name.endswith('__POR'):
                por[name[:-5]] = val
            elif val <= MAX_REGISTER:
                addr[name] = val
    return addr, por


def build_volatile(addr):
    """Reimplement taiko_volatile(). Returns (predicate, description list)."""
    def A(name, default=None):
        if name in addr:
            return addr[name]
        if default is not None:
            return default
        raise KeyError(name)

    MBHC_EN_CTL = A('TAIKO_A_CDC_MBHC_EN_CTL', 0x3C0)
    IIR1_COEF = A('TAIKO_A_CDC_IIR1_COEF_B1_CTL', 0x34A)
    IIR2_COEF = A('TAIKO_A_CDC_IIR2_COEF_B2_CTL', 0x35B)
    ANC1_IIR = A('TAIKO_A_CDC_ANC1_IIR_B1_CTL', 0x202)
    ANC1_LPF = A('TAIKO_A_CDC_ANC1_LPF_B2_CTL', 0x207)
    ANC2_IIR = A('TAIKO_A_CDC_ANC2_IIR_B1_CTL', 0x282)
    ANC2_LPF = A('TAIKO_A_CDC_ANC2_LPF_B2_CTL', 0x287)

    # taiko_is_digital_gain_register(): RX1-7 volume and TX1-10 gain.
    gain = set()
    for n, a in addr.items():
        if re.match(r'TAIKO_A_CDC_RX\d_VOL_CTL_B2_CTL$', n):
            gain.add(a)
        if re.match(r'TAIKO_A_CDC_TX\d+_VOL_CTL_GAIN$', n):
            gain.add(a)

    singles = {
        A('TAIKO_A_RX_HPH_L_STATUS', 0x1B3),
        A('TAIKO_A_RX_HPH_R_STATUS', 0x1B9),
        A('TAIKO_A_MBHC_INSERT_DET_STATUS', 0x14B),
        A('TAIKO_A_CDC_VBAT_GAIN_MON_VAL', 0x2FB),
    }
    for i in range(8):
        singles.add(A(f'TAIKO_A_CDC_SPKR_CLIPDET_VAL{i}', 0x270 + i))

    def why(reg):
        if reg < 0x100:
            return 'reg < 0x100 (top level, core-driver written)'
        if reg >= MBHC_EN_CTL:
            return f'reg >= 0x{MBHC_EN_CTL:03x} (MBHC/MAD)'
        if IIR1_COEF <= reg <= IIR2_COEF:
            return 'IIR coefficient'
        if ANC1_IIR <= reg <= ANC1_LPF or ANC2_IIR <= reg <= ANC2_LPF:
            return 'ANC filter'
        if reg in gain:
            return 'digital gain'
        if reg in singles:
            return 'status / clip-detect / vbat'
        return None

    return why, {
        'MBHC_EN_CTL': MBHC_EN_CTL, 'gain': len(gain), 'singles': len(singles),
    }


def parse_dumps(path):
    """Pull the embedded raw dumps out of the evidence file."""
    dumps, cur, name = {}, None, None
    for line in open(path, errors='replace'):
        m = re.match(r'=== raw dump: (\w+) ===', line)
        if m:
            name = m.group(1)
            cur = dumps.setdefault(name, {})
            continue
        if cur is not None:
            m = re.match(r'^([0-9a-f]{3}):\s*([0-9a-f]{2})\s*$', line)
            if m:
                cur[int(m.group(1), 16)] = int(m.group(2), 16)
            elif line.startswith('==='):
                cur = None
    return dumps


def parse_observed(path):
    """The registers the run reported as having moved without being written."""
    obs, inside = [], False
    for line in open(path, errors='replace'):
        if line.startswith('=== positively volatile'):
            inside = True
            continue
        if inside:
            if line.startswith('==='):
                break
            m = re.match(r'\s*0x([0-9a-f]{3})\s*$', line)
            if m:
                obs.append(int(m.group(1), 16))
    return obs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('evidence')
    ap.add_argument('--defaults', action='store_true',
                    help='also emit a candidate reg_defaults table')
    args = ap.parse_args()

    addr, por = load_addresses()
    if not addr:
        sys.exit(f'no headers in {CACHE}; run wcd9320-regmap-derive.py --fetch')
    why, info = build_volatile(addr)
    by_addr = {}
    for n, a in addr.items():
        by_addr.setdefault(a, n)

    dumps = parse_dumps(args.evidence)
    observed = parse_observed(args.evidence)

    print(f"evidence   : {os.path.basename(args.evidence)}")
    print(f"dumps      : {', '.join(sorted(dumps))}")
    print(f"registers  : {len(dumps[sorted(dumps)[0]]) if dumps else 0}")
    print(f"downstream : MBHC_EN_CTL=0x{info['MBHC_EN_CTL']:03x}, "
          f"{info['gain']} gain regs, {info['singles']} singles")
    print()

    volatile_all = [r for r in range(MAX_REGISTER + 1) if why(r)]
    print(f"taiko_volatile() marks {len(volatile_all)} of {MAX_REGISTER + 1} "
          f"registers volatile "
          f"({100 * len(volatile_all) // (MAX_REGISTER + 1)}%)")
    print()

    print("=== observed volatile, downstream AGREES ===")
    agree = [r for r in observed if why(r)]
    for r in agree:
        print(f"  0x{r:03x}  {by_addr.get(r, '?'):<38} {why(r)}")
    if not agree:
        print("  (none)")

    print()
    print("=== observed volatile, downstream does NOT mark it ===")
    disagree = [r for r in observed if not why(r)]
    for r in disagree:
        print(f"  0x{r:03x}  {by_addr.get(r, '?'):<38} "
              f"NOT in taiko_volatile() -- caching by that predicate is unsafe")
    if not disagree:
        print("  (none) -- no conflict with downstream")

    print()
    print("=== downstream marks volatile, this test did NOT exercise ===")
    unexercised = [r for r in volatile_all if r not in observed]
    print(f"  {len(unexercised)} registers. Not evidence of anything: they were")
    print("  never made to move, so this run says nothing about them either way.")
    print("  They stay volatile on downstream's authority, not on measurement.")

    if not args.defaults:
        return

    print()
    print("=== candidate reg_defaults ===")
    base = dumps.get('d0') or dumps.get('first')
    if not base:
        sys.exit("no d0/first dump in the evidence; cannot build defaults")

    # The dump is taken AFTER automatic core init, which writes these. Their
    # measured values are this driver's own doing, not the part's reset state,
    # and must not be published as defaults.
    DRIVER_WRITES = {
        0x080: 'bring-up CDC_CTL',
        0x088: 'bring-up LEAKAGE_CTL',
        0x101: 'rco-wake BIAS_CENTRAL_BG_CTL',
        0x105: 'rco-wake BIAS_OSC_BG_CTL',
        0x108: 'rco-wake CLK_BUFF_EN1',
        0x109: 'rco-wake CLK_BUFF_EN2',
        0x1fa: 'rco-wake RC_OSC_FREQ',
        0x1fb: 'rco-wake RC_OSC_TEST',
        0x311: 'rco-wake CDC_CLK_MCLK_CTL',
        0x094: 'irq setup INTR_MASK0', 0x095: 'irq setup INTR_MASK1',
        0x096: 'irq setup INTR_MASK2', 0x097: 'irq setup INTR_MASK3',
    }

    cacheable = [r for r in sorted(base) if not why(r)]
    nonzero = [r for r in cacheable if base[r]]
    print(f"  cacheable (not volatile) : {len(cacheable)}")
    print(f"  of those, non-zero       : {len(nonzero)}")
    print()

    mismatch, ours = [], []
    for r in cacheable:
        n = by_addr.get(r)
        p = por.get(n) if n else None
        if p is None or p == base[r]:
            continue
        (ours if r in DRIVER_WRITES else mismatch).append((r, p, base[r], n))

    print(f"  Differs from __POR because THIS DRIVER wrote it: {len(ours)}")
    print("  (core init runs before the dump, so these are not reset values")
    print("   and must not become reg_defaults)")
    for r, p, m, n in ours:
        print(f"    0x{r:03x}  __POR {p:02x}  measured {m:02x}  "
              f"{n}  <- {DRIVER_WRITES[r]}")

    print()
    print(f"  Differs from __POR with NO write from us: {len(mismatch)}")
    print("  (candidate revision-dependent defaults for this die)")
    for r, p, m, n in mismatch:
        print(f"    0x{r:03x}  __POR {p:02x}  measured {m:02x}  {n}")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Derive a defensible reg_defaults table from the full-map fresh capture.

    wcd9320-defaults-derive.py EVIDENCE.txt [--table] [--csv OUT]

Builds, per register:

    address | __POR | fresh pre-init | after core release | final | driver
    write? | classification

and classifies every mismatch as one of:

    reset-default    fresh pre-init differs from __POR and nothing wrote it.
                     A revision-dependent default for this die.
    driver-write     this driver wrote it during core init.
    hw-side-effect   changed across a stage boundary the driver did not write.
                     Hardware populated it; not a default and not cacheable.
    external         non-zero before this driver touched anything AND not
                     explicable as a reset value -- something else wrote it.
                     The ADSP runs and owns the NGD.
    volatile         taiko_volatile(), or measured volatile on this hardware.
    unresolved       anything left. Never eligible for reg_defaults.

THE CDC CAVEAT

0x200-0x3bf reads all-zero at pre-init because the digital core is held in
reset and its register file returns zero rather than its defaults. So for that
range the reset state is taken from the after-core-release stage, which the
three-stage finding already established: the RCO sequence changes exactly one
register in 448, so post-release values are this die's reset state. The table
records which source each default came from rather than blurring them.
"""
import argparse
import csv
import os
import re
import sys

CACHE = os.path.expanduser('~/.cache/wcd9320-hdr')
LOW_FIRST, LOW_COUNT = 0x000, 512
CDC_FIRST, CDC_COUNT = 0x200, 448
MAX_REGISTER = 0x3FF

# Written by this driver during core init, with the stage that does it.
DRIVER_WRITES = {
    0x080: 'bring-up', 0x088: 'bring-up',
    0x101: 'rco-wake', 0x105: 'rco-wake', 0x108: 'rco-wake',
    0x109: 'rco-wake', 0x1fa: 'rco-wake', 0x1fb: 'rco-wake',
    0x311: 'rco-wake',
    0x094: 'irq-setup', 0x095: 'irq-setup',
    0x096: 'irq-setup', 0x097: 'irq-setup',
}

# Measured volatile on this hardware (wcd9320-volatility-*.txt).
MEASURED_VOLATILE = {0x14b}


def load_headers():
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
            n, v = m.group(1), int(m.group(2), 16)
            if n.endswith('__POR'):
                por[n[:-5]] = v
            elif v <= MAX_REGISTER:
                addr.setdefault(n, v)
    return addr, por


def volatile_fn(addr):
    def A(n, d):
        return addr.get(n, d)
    MBHC = A('TAIKO_A_CDC_MBHC_EN_CTL', 0x3C0)
    I1, I2 = A('TAIKO_A_CDC_IIR1_COEF_B1_CTL', 0x34A), A('TAIKO_A_CDC_IIR2_COEF_B2_CTL', 0x35B)
    A1, A1E = A('TAIKO_A_CDC_ANC1_IIR_B1_CTL', 0x202), A('TAIKO_A_CDC_ANC1_LPF_B2_CTL', 0x207)
    A2, A2E = A('TAIKO_A_CDC_ANC2_IIR_B1_CTL', 0x282), A('TAIKO_A_CDC_ANC2_LPF_B2_CTL', 0x287)
    gain = {v for n, v in addr.items()
            if re.match(r'TAIKO_A_CDC_(RX\d_VOL_CTL_B2_CTL|TX\d+_VOL_CTL_GAIN)$', n)}
    singles = {A('TAIKO_A_RX_HPH_L_STATUS', 0x1B3), A('TAIKO_A_RX_HPH_R_STATUS', 0x1B9),
               A('TAIKO_A_MBHC_INSERT_DET_STATUS', 0x14B),
               A('TAIKO_A_CDC_VBAT_GAIN_MON_VAL', 0x2FB)}
    singles |= {A(f'TAIKO_A_CDC_SPKR_CLIPDET_VAL{i}', 0x270 + i) for i in range(8)}

    def why(r):
        if r < 0x100:
            return 'top-level (<0x100)'
        if r >= MBHC:
            return 'MBHC/MAD (>=0x3c0)'
        if I1 <= r <= I2:
            return 'IIR coeff'
        if A1 <= r <= A1E or A2 <= r <= A2E:
            return 'ANC filter'
        if r in gain:
            return 'digital gain'
        if r in singles:
            return 'status/clipdet/vbat'
        return None
    return why


def parse_blocks(path):
    """Return {label: {addr: value}} for each hex block in the evidence."""
    out, cur, base, idx = {}, None, 0, 0
    for line in open(path, errors='replace'):
        m = re.match(r'=== (\S+)\s', line)
        if m:
            lbl = m.group(1)
            if lbl.startswith('low_'):
                cur, base, idx = out.setdefault(lbl, {}), LOW_FIRST, 0
            elif lbl.startswith('sentinel_'):
                cur, base, idx = out.setdefault(lbl, {}), CDC_FIRST, 0
            elif lbl == 'final,':
                cur, base, idx = out.setdefault('final', {}), 0, 0
            else:
                cur = None
            continue
        if cur is None:
            continue
        if base == 0 and re.match(r'^[0-9a-f]{3}:', line):     # debugfs form
            a, v = line.split(':')
            cur[int(a, 16)] = int(v.strip(), 16)
            continue
        if re.fullmatch(r'[0-9a-f]{2,64}', line.strip()):      # packed hex rows
            row = line.strip()
            for i in range(0, len(row), 2):
                cur[base + idx] = int(row[i:i + 2], 16)
                idx += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('evidence')
    ap.add_argument('--table', action='store_true')
    ap.add_argument('--csv')
    args = ap.parse_args()

    addr, por = load_headers()
    if not addr:
        sys.exit(f'no headers in {CACHE}')
    why = volatile_fn(addr)
    by_addr = {}
    for n, a in addr.items():
        by_addr.setdefault(a, n)

    b = parse_blocks(args.evidence)
    pre = {**b.get('low_before', {}), **b.get('sentinel_before', {})}
    rel = {**b.get('low_after_bringup', {}), **b.get('sentinel_after_bringup', {})}
    fin = {**b.get('low_after', {}), **b.get('sentinel_after', {})}
    live = b.get('final', {})

    print(f"evidence : {os.path.basename(args.evidence)}")
    for nm, d in (('fresh pre-init', pre), ('after core release', rel),
                  ('after RCO', fin), ('final live', live)):
        print(f"  {nm:<20} {len(d)} registers")
    print()

    rows, counts = [], {}
    for r in range(MAX_REGISTER + 1):
        name = by_addr.get(r, '')
        p = por.get(name) if name else None
        vpre, vrel, vfin = pre.get(r), rel.get(r), fin.get(r)
        vlive = live.get(r, vfin)
        vol = why(r) or ('measured' if r in MEASURED_VOLATILE else None)
        drv = DRIVER_WRITES.get(r)

        in_cdc = r >= CDC_FIRST
        # For the CDC half the pre-init read is zero by construction; the
        # reset state there is the after-release stage.
        reset_src = 'after-release' if in_cdc else 'pre-init'
        reset_val = vrel if in_cdc else vpre

        if vol:
            cls = 'volatile'
        elif drv:
            cls = 'driver-write'
        elif reset_val is None or vfin is None:
            cls = 'unresolved'
        elif not in_cdc and vpre != vrel:
            cls = 'hw-side-effect'      # moved across a boundary we did not write
        elif not in_cdc and vrel != vfin:
            cls = 'hw-side-effect'
        elif p is not None and reset_val != p:
            cls = 'reset-default'
        elif p is None:
            cls = 'unresolved'
        else:
            cls = 'matches-por'
        counts[cls] = counts.get(cls, 0) + 1
        rows.append((r, name, p, vpre, vrel, vfin, vlive, drv, reset_src, cls))

    print("classification of all 1024 registers")
    for k in sorted(counts, key=lambda x: -counts[x]):
        print(f"  {k:<16} {counts[k]}")
    print()

    interesting = [x for x in rows
                   if x[9] in ('reset-default', 'hw-side-effect', 'unresolved')
                   and not (x[9] == 'unresolved' and x[2] is None and not x[3] and not x[5])]

    print("=== registers needing a decision ===")
    print(f"{'addr':<6}{'__POR':<7}{'pre':<5}{'rel':<5}{'fin':<5}{'class':<16}name")
    for r, name, p, vpre, vrel, vfin, vlive, drv, src, cls in interesting:
        fp = f"{p:02x}" if p is not None else '--'
        print(f"0x{r:03x}  {fp:<7}{vpre if vpre is None else format(vpre, '02x'):<5}"
              f"{vrel if vrel is None else format(vrel, '02x'):<5}"
              f"{vfin if vfin is None else format(vfin, '02x'):<5}{cls:<16}{name}")

    if args.csv:
        with open(args.csv, 'w', newline='') as fh:
            w = csv.writer(fh)
            w.writerow(['address', 'name', '__POR', 'fresh_pre_init',
                        'after_core_release', 'after_rco', 'final_live',
                        'driver_write', 'reset_source', 'classification'])
            for r, name, p, vpre, vrel, vfin, vlive, drv, src, cls in rows:
                w.writerow([f'0x{r:03x}', name,
                            '' if p is None else f'{p:02x}',
                            '' if vpre is None else f'{vpre:02x}',
                            '' if vrel is None else f'{vrel:02x}',
                            '' if vfin is None else f'{vfin:02x}',
                            '' if vlive is None else f'{vlive:02x}',
                            drv or '', src, cls])
        print(f"\nfull table written to {args.csv}")


if __name__ == '__main__':
    main()

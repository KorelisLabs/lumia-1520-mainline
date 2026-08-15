#!/usr/bin/env python3
"""Generate the regmap cache tables from measured evidence.

    wcd9320-gen-cache-tables.py FULLMAP-EVIDENCE.txt > tables.c

Emits, as C:

  wcd9320_readable_bitmap[]  documented addresses, minus write-only
  wcd9320_reg_defaults[]     measured power-on values for every eligible
                             cacheable register

THE RULES, AND WHY EACH ONE

readable: an address documented in the downstream headers, minus INTR_CLEAR
    (0x09c-0x09f) which is write-1-to-clear. The 163 undocumented addresses
    are map holes -- 35 runs between documented blocks, every one reading zero
    at every captured stage -- and regmap should reject them rather than let
    something read a hole and cache the answer. That all 673 documented
    registers returned stable, sensible values across four stages is the
    evidence they are genuinely readable.

default: eligible means readable, not volatile, and with a KNOWN measured
    power-on value. That is the criterion -- not "non-zero". Zero-valued
    defaults are included deliberately: reg_defaults participates in sync
    decisions (regcache_reg_needs_sync skips a register only when its value
    equals a REGISTERED default), so an absent entry and a registered zero
    are not the same thing. Omitting zeros is a size optimisation that must be
    argued separately from the evidence, and this generator does not make it.

    The reset value comes from the fresh pre-init capture for 0x000-0x1ff. For
    0x200-0x3bf it comes from the after-core-release stage, because the
    digital core is held in reset before that and its register file reads zero
    rather than its defaults -- measured, 0 of 448 non-zero at pre-init.

excluded from defaults, with cause:
    volatile        never cached, so a default would be meaningless
    hw-side-effect  0x1fd RC_OSC_TUNER moved 14 -> 15 with no write from us
    unresolved      undocumented; also not readable
    unreadable      INTR_CLEAR

The 7 registers this driver writes during core init ARE included, at their
measured pre-init values. Those values are the real power-on state; that the
driver changes them later does not make them any less the hardware default,
and regcache tracks our writes normally from there.
"""
import os
import re
import sys

CACHE = os.path.expanduser('~/.cache/wcd9320-hdr')
MAX_REGISTER = 0x3FF
LOW_FIRST, CDC_FIRST = 0x000, 0x200
WRITE_ONLY = set(range(0x09C, 0x0A0))       # INTR_CLEAR0-3, write-1-to-clear
HW_POPULATED = {0x1FD}                       # RC_OSC_TUNER, measured

# Status registers taiko_volatile() does not cover.
#
# Downstream's predicate is address-range based and misses these; the standard
# for this port is that a cacheable register needs a defensible reason to be
# cached, and "the hardware writes this to tell software something" is a
# defensible reason NOT to. Three of them are not even theoretical: the COMP
# shut-down status registers measurably moved 00 -> 03 across the core release
# with no write from us.
#
# Named by semantics, confirmed against the header symbol names.
SEMANTIC_VOLATILE = {
    0x15B, 0x15C,                    # TX_1_2_SAR_ERR_CH1/2
    0x165, 0x166,                    # TX_3_4_SAR_ERR_CH3/4
    0x16F, 0x170,                    # TX_5_6_SAR_ERR_CH5/6
    0x175,                           # TX_7_MBHC_SAR_ERR
    0x1C5,                           # RX_EAR_STATUS
    0x1D0, 0x1D4, 0x1D8, 0x1DC,      # RX_LINE_1..4_STATUS
    0x1EB, 0x1EC,                    # SPKR_DRV_STATUS_OCP / _PA
    0x1F5, 0x1F6,                    # SPKR_PROT_V/I_SAR_ERR
    0x1FC,                           # RC_OSC_STATUS
    0x2FA,                           # CDC_VBAT_GAIN_UPD_MON
    0x36E, 0x376, 0x37E,             # CDC_COMP0/1/2_SHUT_DOWN_STATUS -- measured moving
}


def load_headers():
    addr = {}
    for fn in ('wcd9320_registers.h', 'wcd9xxx_registers.h'):
        p = os.path.join(CACHE, fn)
        if not os.path.exists(p):
            continue
        for line in open(p, errors='replace'):
            m = re.match(r'#define\s+((?:TAIKO|WCD9XXX)_A_\w+)\s+\(?(0x[0-9A-Fa-f]+)', line)
            if m and not m.group(1).endswith('__POR'):
                v = int(m.group(2), 16)
                if v <= MAX_REGISTER:
                    addr.setdefault(v, m.group(1))
    return addr


def volatile_set(addr):
    """taiko_volatile(), plus what this hardware showed."""
    byname = {n: a for a, n in addr.items()}

    def A(n, d):
        return byname.get(n, d)
    MBHC = A('TAIKO_A_CDC_MBHC_EN_CTL', 0x3C0)
    I1, I2 = A('TAIKO_A_CDC_IIR1_COEF_B1_CTL', 0x34A), A('TAIKO_A_CDC_IIR2_COEF_B2_CTL', 0x35B)
    A1, A1E = A('TAIKO_A_CDC_ANC1_IIR_B1_CTL', 0x202), A('TAIKO_A_CDC_ANC1_LPF_B2_CTL', 0x207)
    A2, A2E = A('TAIKO_A_CDC_ANC2_IIR_B1_CTL', 0x282), A('TAIKO_A_CDC_ANC2_LPF_B2_CTL', 0x287)
    gain = {a for a, n in addr.items()
            if re.match(r'TAIKO_A_CDC_(RX\d_VOL_CTL_B2_CTL|TX\d+_VOL_CTL_GAIN)$', n)}
    singles = {A('TAIKO_A_RX_HPH_L_STATUS', 0x1B3), A('TAIKO_A_RX_HPH_R_STATUS', 0x1B9),
               A('TAIKO_A_MBHC_INSERT_DET_STATUS', 0x14B),
               A('TAIKO_A_CDC_VBAT_GAIN_MON_VAL', 0x2FB)}
    singles |= {A(f'TAIKO_A_CDC_SPKR_CLIPDET_VAL{i}', 0x270 + i) for i in range(8)}

    vol = set()
    for r in range(MAX_REGISTER + 1):
        if (r < 0x100 or r >= MBHC or I1 <= r <= I2 or A1 <= r <= A1E
                or A2 <= r <= A2E or r in gain or r in singles):
            vol.add(r)
    vol |= HW_POPULATED
    vol |= SEMANTIC_VOLATILE
    return vol


def parse_blocks(path):
    out, cur, base, idx = {}, None, 0, 0
    for line in open(path, errors='replace'):
        m = re.match(r'=== (\S+)\s', line)
        if m:
            lbl = m.group(1)
            if lbl.startswith('low_'):
                cur, base, idx = out.setdefault(lbl, {}), LOW_FIRST, 0
            elif lbl.startswith('sentinel_'):
                cur, base, idx = out.setdefault(lbl, {}), CDC_FIRST, 0
            else:
                cur = None
            continue
        if cur is not None and re.fullmatch(r'[0-9a-f]{2,64}', line.strip()):
            row = line.strip()
            for i in range(0, len(row), 2):
                cur[base + idx] = int(row[i:i + 2], 16)
                idx += 1
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    addr = load_headers()
    if not addr:
        sys.exit(f'no headers in {CACHE}')
    vol = volatile_set(addr)
    b = parse_blocks(sys.argv[1])
    pre = b.get('low_before', {})
    rel = b.get('sentinel_after_bringup', {})
    if not pre or not rel:
        sys.exit('evidence lacks low_before / sentinel_after_bringup')

    readable = {r for r in addr if r not in WRITE_ONLY}

    defaults, skipped = [], {}
    for r in sorted(addr):
        if r not in readable:
            skipped.setdefault('unreadable (write-only)', []).append(r)
            continue
        if r in vol:
            skipped.setdefault('volatile', []).append(r)
            continue
        val = pre.get(r) if r < CDC_FIRST else rel.get(r)
        if val is None:
            skipped.setdefault('no measured reset value', []).append(r)
            continue
        defaults.append((r, val))

    holes = [r for r in range(MAX_REGISTER + 1) if r not in addr]

    # --- emit ---------------------------------------------------------------
    print('/*')
    print(' * Generated by tools/wcd9320-gen-cache-tables.py from')
    print(f' * {os.path.basename(sys.argv[1])}. Do not hand-edit.')
    print(' *')
    print(f' * readable : {len(readable)} of {MAX_REGISTER + 1}')
    print(f' *            {len(holes)} undocumented map holes rejected')
    print(f' *            {len(WRITE_ONLY)} write-only (INTR_CLEAR) rejected')
    print(f' * volatile : {len(vol)} (taiko_volatile + 0x1fd measured)')
    print(f' * defaults : {len(defaults)} -- every eligible cacheable register,')
    print(f' *            including the {sum(1 for _, v in defaults if v == 0)} whose')
    print(' *            reset value is zero, because reg_defaults takes part in')
    print(' *            sync decisions and an absent entry is not the same as a')
    print(' *            registered zero.')
    print(' */')
    print()

    print('static const u8 wcd9320_readable_bitmap[] = {')
    bm = bytearray((MAX_REGISTER + 8) // 8)
    for r in readable:
        bm[r // 8] |= 1 << (r % 8)
    for i in range(0, len(bm), 12):
        row = ', '.join(f'0x{x:02x}' for x in bm[i:i + 12])
        print(f'\t{row},')
    print('};')
    print()

    print('/*')
    print(' * Volatile, as a bitmap rather than transcribed range logic: a slip in')
    print(' * hand-written ranges would be silent and intermittent, and INTR_STATUS')
    print(' * being served from cache is the worst failure this driver has. The rules')
    print(' * it encodes, from taiko_volatile():')
    print(' *   reg < 0x100        top level; the whole interrupt block lives here')
    print(' *   reg >= 0x3c0       MBHC and MAD')
    print(' *   0x202-0x207,')
    print(' *   0x282-0x287        ANC filter coefficients')
    print(' *   0x34a-0x35b        IIR coefficients')
    print(' *   digital gain       RX1-7 volume, TX1-10 gain')
    print(' *   status/clipdet     HPH L/R, insert-detect, clip-detect, VBAT')
    print(' * plus, measured on this hardware and NOT in taiko_volatile():')
    print(' *   0x1fd              RC_OSC_TUNER, moved 14 -> 15 with no write')
    print(' * and status registers taiko_volatile() misses, on semantics:')
    print(' *   SAR_ERR, RX_LINE/EAR_STATUS, SPKR_DRV/PROT status, RC_OSC_STATUS,')
    print(' *   VBAT_GAIN_UPD_MON, and COMP0/1/2_SHUT_DOWN_STATUS -- the last three')
    print(' *   measurably moved 00 -> 03 across the core release.')
    print(' */')
    print('static const u8 wcd9320_volatile_bitmap[] = {')
    vbm = bytearray((MAX_REGISTER + 8) // 8)
    for r in vol:
        vbm[r // 8] |= 1 << (r % 8)
    for i in range(0, len(vbm), 12):
        row = ', '.join(f'0x{x:02x}' for x in vbm[i:i + 12])
        print(f'\t{row},')
    print('};')
    print()

    print('static const struct reg_default wcd9320_reg_defaults[] = {')
    for r, v in defaults:
        name = addr.get(r, '')
        print(f'\t{{ 0x{r:03x}, 0x{v:02x} }},\t/* {name} */')
    print('};')
    print()

    sys.stderr.write(f'readable  : {len(readable)}\n')
    sys.stderr.write(f'volatile  : {len(vol)}\n')
    sys.stderr.write(f'defaults  : {len(defaults)} '
                     f'({sum(1 for _, v in defaults if v == 0)} zero, '
                     f'{sum(1 for _, v in defaults if v)} non-zero)\n')
    for k, v in sorted(skipped.items()):
        sys.stderr.write(f'skipped {k:<28}: {len(v)}\n')
    sys.stderr.write(f'map holes (not readable)      : {len(holes)}\n')


if __name__ == '__main__':
    main()

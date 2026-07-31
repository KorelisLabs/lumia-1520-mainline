#!/usr/bin/env python3
"""Derive the WCD9320 register map and check it against silicon.

Two independent sources:

  header  -- every ``#define TAIKO_A_*`` / ``WCD9XXX_A_*`` address and its
             matching ``__POR`` reset value, from the downstream headers.
             Fetched on demand, never checked in.
  silicon -- a dump of ``/sys/kernel/debug/regmap/217:a0:1:0/registers``
             taken from the device with the read-only wcd9320 module loaded.

The point is the comparison. Neither source is trusted on its own: the
header could be for a different revision, and the silicon cannot say which
addresses are documented. Agreement between them is the evidence.

Usage:
    wcd9320-regmap-derive.py --fetch
    wcd9320-regmap-derive.py --compare DUMP [--compare-2nd DUMP2]

``--compare-2nd`` takes a second dump of the same function so that registers
which change with no write in between are reported directly rather than
inferred. See docs/audio/wcd9320-register-map.md.
"""

import argparse
import collections
import os
import re
import sys
import urllib.request

BASE = ('https://raw.githubusercontent.com/LineageOS/'
        'android_kernel_lge_hammerhead/cm-11.0/include/linux/mfd/wcd9xxx')
HEADERS = ('wcd9320_registers.h', 'wcd9xxx_registers.h')
CACHE = os.path.expanduser('~/.cache/wcd9320-hdr')

# The codec register map ends at 0x3ff; the headers also define bit-field
# shifts and masks with the same prefix, so anything above that is not an
# address and is dropped.
MAX_REGISTER = 0x3ff

DEFINE = re.compile(
    r'^#define\s+((?:TAIKO|WCD9XXX)_A_\w+?)(__POR)?\s+\(?(0[xX][0-9a-fA-F]+|\d+)')
DUMPLINE = re.compile(r'^([0-9a-f]+):\s*(\S+)\s*$')

# Address regions, from the block boundaries the silicon dump revealed. The
# register *names* do not follow these boundaries -- TAIKO_A_CDC_TX_1_GAIN is
# at 0x153 and TAIKO_A_CDC_MBHC_* is at 0x3c2 -- so grouping by name prefix
# gives a wrong answer. Group by address.
REGIONS = (
    (0x000, 0x1ff, 'top level + analog'),
    (0x200, 0x3bf, 'digital core'),
    (0x3c0, 0x3ff, 'MBHC'),
)


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    for h in HEADERS:
        dst = os.path.join(CACHE, h)
        with urllib.request.urlopen('%s/%s' % (BASE, h)) as r:
            data = r.read()
        with open(dst, 'wb') as f:
            f.write(data)
        print('  %-24s %6d bytes' % (h, len(data)))


def parse_headers():
    """-> {addr: (sorted names, por or None)}"""
    addr, por = {}, {}
    for h in HEADERS:
        p = os.path.join(CACHE, h)
        if not os.path.exists(p):
            sys.exit('missing %s -- run with --fetch first' % p)
        for line in open(p, errors='replace'):
            m = DEFINE.match(line.strip())
            if not m:
                continue
            name, is_por, val = m.group(1), m.group(2), int(m.group(3), 0)
            (por if is_por else addr)[name] = val

    regs = collections.defaultdict(list)
    for name, a in addr.items():
        if a <= MAX_REGISTER:
            regs[a].append(name)
    return {a: (sorted(ns), next((por[n] for n in sorted(ns) if n in por), None))
            for a, ns in regs.items()}


def load_dump(path):
    d = {}
    for line in open(path, errors='replace'):
        m = DUMPLINE.match(line.strip())
        if m:
            d[int(m.group(1), 16)] = m.group(2)
    if not d:
        sys.exit('%s: no "addr: val" lines found' % path)
    return d


def region_of(a):
    for lo, hi, name in REGIONS:
        if lo <= a <= hi:
            return name
    return '?'


def compare(hdr, dump, dump2):
    documented = set(hdr)
    answered = {a for a, v in dump.items() if v.lower() != 'xx'}

    print('== map ==')
    print('  addresses in dump        : %d' % len(dump))
    print('  answered (not XX)        : %d' % len(answered))
    print('  documented in header     : %d' % len(documented))
    print('  documented and answered  : %d' % len(documented & answered))
    print('  documented but XX        : %d' % len(documented - answered))
    undoc_nz = sorted(a for a in answered - documented if dump[a] != '00')
    print('  undocumented, non-zero   : %d' % len(undoc_nz))
    for a in undoc_nz[:20]:
        print('      0x%03x = %s' % (a, dump[a]))
    if not undoc_nz and documented <= answered:
        print('  -> header map and silicon agree in both directions')

    print()
    print('== reset defaults, by address region ==')
    print('  %-22s %6s %10s %10s' % ('region', 'regs', 'POR!=0', 'read 00'))
    for lo, hi, name in REGIONS:
        a = [x for x in documented if lo <= x <= hi and x in answered]
        pn = [x for x in a if hdr[x][1]]
        pz = [x for x in pn if dump[x] == '00']
        pct = (' (%.0f%%)' % (100.0 * len(pz) / len(pn))) if pn else ''
        print('  %-22s %6d %10d %10d%s' % (name, len(a), len(pn), len(pz), pct))
    print('  a region at 100% is not reading its reset defaults at all --')
    print('  the expected signature of an unclocked or held-in-reset block')

    print()
    print('== registers differing from __POR ==')
    diff = [x for x in sorted(documented & answered)
            if hdr[x][1] is not None and int(dump[x], 16) != hdr[x][1]]
    print('  %d of %d' % (len(diff), len(documented & answered)))
    for a in diff:
        print('    0x%03x  POR=%02x now=%s  [%s]  %s'
              % (a, hdr[a][1], dump[a], region_of(a), ', '.join(hdr[a][0])))

    if dump2:
        print()
        print('== changed between two reads, no write in between ==')
        vol = sorted(a for a in dump if a in dump2 and dump[a] != dump2[a])
        print('  %d registers' % len(vol))
        for a in vol:
            names = ', '.join(hdr[a][0]) if a in hdr else '(undocumented)'
            print('    0x%03x  %s -> %s  %s' % (a, dump[a], dump2[a], names))
        if not vol:
            print('  none. This is a weak negative: with the core dark, every')
            print('  interrupt masked and no audio path configured, there is')
            print('  little that could have changed. Not a volatile-set result.')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--fetch', action='store_true',
                    help='download the downstream headers into %s' % CACHE)
    ap.add_argument('--compare', metavar='DUMP',
                    help='regmap debugfs dump from the device')
    ap.add_argument('--compare-2nd', metavar='DUMP2',
                    help='a second dump of the same function, for volatility')
    args = ap.parse_args()

    if args.fetch:
        fetch()
    if not args.compare:
        if not args.fetch:
            ap.print_help()
        return

    hdr = parse_headers()
    print('== header ==')
    print('  distinct addresses <= 0x%03x : %d' % (MAX_REGISTER, len(hdr)))
    print('  with a __POR value           : %d'
          % sum(1 for v in hdr.values() if v[1] is not None))
    print('  defined under two names      : %d'
          % sum(1 for v in hdr.values() if len(v[0]) > 1))
    print()
    compare(hdr, load_dump(args.compare),
            load_dump(args.compare_2nd) if args.compare_2nd else None)


if __name__ == '__main__':
    main()

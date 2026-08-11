#!/usr/bin/env python3
"""Attribute every CDC register to the stage that set it.

Three snapshots from one fresh-path boot:
  before   as found, core still in reset
  bringup  after the 4-write core release
  after    after the 15-step RCO clock sequence

The question that gates reg_defaults: the 16 registers that differ from their
documented __POR -- were they already odd after the core release (so revision
defaults, or something the release itself sets), or did the clock sequence
write them (so not defaults at all)?
"""
import json, os, re, sys

S = ('/mnt/c/Users/Admin/AppData/Local/Temp/claude/'
     'C--Users-Admin-Documents-RegenX-AE/e0d5063a-4a08-4a42-a358-24549f0f7325/scratchpad')
HDR = {int(k, 16): v for k, v in
       json.load(open(os.path.expanduser('~/ds-hdr/wcd9320-regmap.json'))).items()}
FIRST, LAST = 0x200, 0x3bf
N = LAST - FIRST + 1

def load(p):
    t = ''.join(l.strip() for l in open(p) if re.fullmatch(r'[0-9a-f]+', l.strip()))
    if len(t) != N * 2:
        sys.exit('%s: %d hex chars, expected %d' % (p, len(t), N * 2))
    return [int(t[i*2:i*2+2], 16) for i in range(N)]

b = load(f'{S}/sentinel_before.txt')
g = load(f'{S}/sentinel_after_bringup.txt')
a = load(f'{S}/sentinel_after.txt')

print('=== stage totals ===')
for nm, v in (('before', b), ('after bring-up', g), ('after RCO', a)):
    print('  %-16s %3d non-zero of %d' % (nm, sum(1 for x in v if x), N))

# what the clock sequence changed at all
clk = [FIRST + i for i in range(N) if g[i] != a[i]]
print()
print('=== registers the RCO sequence changed (bringup -> after) ===')
print('  %d of %d' % (len(clk), N))
for x in clk:
    nm = HDR[x]['names'][0] if x in HDR else '(undocumented)'
    por = ('%02x' % HDR[x]['por']) if x in HDR and HDR[x]['por'] is not None else '--'
    print('    0x%03x  %02x -> %02x   POR=%s   %s'
          % (x, g[x-FIRST], a[x-FIRST], por, nm))

# the 16
tgt = [x for x in sorted(HDR) if FIRST <= x <= LAST and HDR[x]['por']]
odd = [x for x in tgt if a[x-FIRST] != HDR[x]['por']]
print()
print('=== the %d registers differing from __POR at stage 3 ===' % len(odd))
set_by_release, set_by_clock, other = [], [], []
for x in odd:
    bv, gv, av = b[x-FIRST], g[x-FIRST], a[x-FIRST]
    if gv == av:
        set_by_release.append(x)
    else:
        set_by_clock.append(x)
print('  already at their final value after the core release : %d' % len(set_by_release))
print('  changed by the RCO clock sequence                   : %d' % len(set_by_clock))
print()
for x in odd:
    nm = HDR[x]['names'][0]
    tag = 'RELEASE' if x in set_by_release else 'CLOCK'
    print('    0x%03x  before=%02x bringup=%02x after=%02x  POR=%02x  [%-7s] %s'
          % (x, b[x-FIRST], g[x-FIRST], a[x-FIRST], HDR[x]['por'], tag, nm))

print()
print('=== verdict ===')
if not set_by_clock:
    print('  None of the %d were touched by the clock sequence.' % len(odd))
    print('  They hold their values from the moment the core leaves reset,')
    print('  so they are reset-state values for this die -- consistent with')
    print('  revision-dependent defaults -- and NOT side effects of clocking.')
else:
    print('  %d were changed by the clock sequence and cannot be treated as' % len(set_by_clock))
    print('  defaults. The rest are reset-state values.')

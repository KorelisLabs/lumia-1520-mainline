# `reg_defaults`: the derivation, and what is left before a cache

The full-map fresh capture closes the ambiguity that kept this open. This
records the method, the classification of all 1024 registers, the proposed
defaults table, and the short list of things that still need doing.

Evidence: `wcd9320-fullmap-20260815T154307Z.txt`, 16/16, fresh path,
`adopted=0`, `nonzero_before=0`. Derived by `wcd9320-defaults-derive.py`.

## What was missing, and what fixed it

The sentinel covered `0x200`–`0x3bf`. That was enough to attribute the CDC
region and nothing else, so 28 cacheable registers in `0x100`–`0x1ff` read
something other than their documented `__POR` with no way to tell a
revision-dependent reset value from something written after reset — and the
ADSP is running and owns the NGD, so that was not hypothetical.

`fullmap-rc7` adds `low_before` / `low_after_bringup` / `low_after` for
`0x000`–`0x1ff`, captured at the same three moments as the sentinel. The
complete map at each stage gives the discriminator directly:

| stage | source |
|---|---|
| fresh pre-init | `low_before` + `sentinel_before` |
| after core release | `low_after_bringup` + `sentinel_after_bringup` |
| after RCO | `low_after` + `sentinel_after` |
| final, live | regmap debugfs |

**The CDC half of pre-init reads all-zero — measured, 0 of 448 non-zero.** The
digital core is held in reset and its register file returns zero rather than
its defaults. That is the finding this port started from, so for `0x200`–`0x3bf`
the reset state is taken from the after-release stage, which the three-stage
work already established (the RCO sequence changes exactly one register in
448). The table records which source each default came from.

## Classification of all 1024 registers

| class | count | meaning |
|---|---|---|
| `matches-por` | 424 | measured reset value equals documented `__POR` |
| `volatile` | 379 | `taiko_volatile()`, or measured volatile here |
| `unresolved` | 163 | undocumented map holes — see below |
| `reset-default` | 50 | stable reset value differing from `__POR` |
| `driver-write` | 7 | this driver writes it during core init |
| `hw-side-effect` | 1 | moved with no write from us |

### The 27 analog reset-defaults are now attributable

Every one reads identically at pre-init, after core release and after RCO —
stable from reset, never touched by us, differing from the documented `__POR`.
That is a revision-dependent default for this die, not something written after
reset.

```
0x153 TX_1_2_EN        __POR 00 -> 02      0x1a5 RX_HPH_CHOP_CTL   b4 -> a4
0x155 TX_1_2_ADC_CH1   __POR 44 -> 02      0x1a6 RX_HPH_BIAS_PA    aa -> 7a
0x15d TX_3_4_EN        __POR 00 -> 02      0x1aa RX_HPH_OCP_CTL    68 -> 69
0x15f TX_3_4_ADC_CH3   __POR 44 -> 02      0x1ac RX_HPH_CNP_WG_CTL de -> da
0x167 TX_5_6_EN        __POR 11 -> 02      0x1ad RX_HPH_CNP_WG_TIME 2a -> 15
0x169 TX_5_6_ADC_CH5   __POR 44 -> 02      0x1ba RX_EAR_BIAS_PA    a6 -> 76
0x183 BUCK_MODE_3      __POR cc -> ce      0x1be RX_EAR_CMBUFF     04 -> 05
0x186 BUCK_CTRL_VCL_1  __POR 48 -> 08      0x1c2 RX_EAR_CNP        f2 -> c0
0x189 BUCK_CTRL_CCL_1  __POR ab -> 5b      0x1c6 RX_LINE_BIAS_PA   a8 -> 78
0x18c BUCK_CTRL_CCL_4  __POR 58 -> 51      0x1ce/d2/d6/da LINE_x_TEST 00 -> 02
0x198 NCP_DTEST        __POR 00 -> 10      0x1e2 SPKR_DRV_OCP_CTL  98 -> 97
                                           0x1e3 SPKR_DRV_CLIP_DET 48 -> 01
                                           0x1e4 SPKR_DRV_IEC      20 -> 00
```

The CDC-region 23 behave the same way from the after-release stage: all ten
`TX_MUX_CTL` `08 → 48`, all seven `RX_B4_CTL` `00 → 08`, all three `COMP`
pairs `3c → 37` and `1f → 7f`.

### `0x1fd RC_OSC_TUNER` — resolved, and not as predicted

```
__POR 00   pre-init 14   after release 14   after RCO 15
```

It was **already `0x14` at reset**, so the RCO sequence did not populate it
from nothing, which was the hypothesis. But it moved `14 → 15` between the core
release and the final state with no write from us. That is a hardware side
effect — consistent with an oscillator trim the hardware adjusts — and it
disqualifies the register as a default **and** as a cacheable value.

It should join `volatile_reg`. Downstream does not mark it, which makes it the
one place where this hardware contradicts `taiko_volatile()`.

### The 7 driver-write registers have known reset values

```
0x101 BIAS_CENTRAL_BG_CTL  __POR 50  pre 50  -> fin 55
0x105 BIAS_OSC_BG_CTL      __POR 16  pre 16  -> fin 17
0x108 CLK_BUFF_EN1         __POR 04  pre 04  -> fin 0d
0x109 CLK_BUFF_EN2         __POR 02  pre 02  -> fin 04
0x1fa RC_OSC_FREQ          __POR 46  pre 46  -> fin c6
0x1fb RC_OSC_TEST          __POR 0a  pre 0a  -> fin 0a
0x311 CDC_CLK_MCLK_CTL     __POR 00  pre 00  -> fin 01
```

Every one reads its documented `__POR` at pre-init. Their reset values are
therefore *measured and known*; only our own writes change them. They are
eligible for `reg_defaults` at their pre-init value — a cache would start from
the true power-on state and then track our writes normally. Whether to include
them is a judgement call, not an evidence gap.

### The 163 unresolved are map holes

All undocumented — no name or `__POR` in the headers — in 35 runs between
documented blocks, and **every one reads zero at every stage**. Nothing needs a
default for them. The correct handling is a `readable_reg` limited to the 673
documented addresses, which is what downstream's `taiko_reg_readable[]` is for.
They are not a blocker.

## Proposed table

| set | count |
|---|---|
| cacheable (not volatile) | 645 |
| **eligible for `reg_defaults`** | **474** (424 `matches-por` + 50 `reset-default`) |
| of those, non-zero — worth an entry | **229** |
| zero-valued — regmap's default anyway | 245 |
| eligible if the 7 driver-write are included at their pre-init value | 481 |

Nothing hardware-populated, volatile, or unresolved is in that set.

## What still has to happen before `cache_type` changes

1. **Add `0x1fd` to `volatile_reg`.** Measured hardware-populated; downstream
   does not cover it.
2. **Add `readable_reg`** limited to documented addresses, so the 163 holes are
   never accessed.
3. **Build the 229-entry `reg_defaults`** from the measured reset state, with
   each entry sourced from pre-init (analog) or after-release (CDC).
4. **Decide whether the 7 driver-write registers get entries.**

None of these is an evidence gap. They are implementation.

## On enabling the cache

The argument for doing it *now* rather than after the ASoC component exists:
the interrupt path is proven end to end and exercises the most dangerous part
of the volatile predicate. `INTR_STATUS` and `INTR_CLEAR` are below `0x100` and
must never be cached; if that is got wrong, `wcd9320-irq-acceptance.sh` fails
visibly and immediately. Enabling while the test surface is small and every
milestone has a passing regression is the cheapest moment to find out.

The argument for waiting is that there is still no consumer, so the cache
optimises nothing today and the first real exercise happens later regardless.

Either way `REGCACHE_NONE` stays until that call is made deliberately.

# C2 design map: RX1 CHAIN → CLASS_H → HPHL DAC

**Status:** research only. Nothing built, nothing claimed on hardware.
Derived from the downstream Taiko driver and `wcd9xxx-common.c` /
`wcd9xxx-resmgr.c`, cached locally for analysis and not checked in.

Scope under consideration: everything between the proven RX1 CHAIN and the
HPHL DAC, **stopping before the PA** (`RX_HPH_CNP_EN` 0x1AB).

## 1. The compander → HPH gain handoff, resolved

The three registers deliberately excluded from the compander experiment:

| register | addr | written by | when |
|---|---|---|---|
| `RX_HPH_L_GAIN` | 0x1AE | `taiko_config_gain_compander()` | compander PRE_PMU / POST_PMD |
| `RX_HPH_R_GAIN` | 0x1B4 | same | same |
| `COMP1_B4_CTL` | 0x373 | `taiko_config_compander()` | compander PRE_PMU |

`taiko_config_gain_compander()` is called only from lines 1074 and 1110 —
both inside `taiko_config_compander()` itself. So these belong to the
**compander→HPH interface**, not to generic analog output: bit 5 of each HPH
gain register selects whether that channel's gain comes from the compander or
from the static register value.

**They belong to the compander milestone, not this one** — but they only have
an effect once an output stage exists. The honest placement is: enable them
when the compander is enabled *and* an output path is being brought up. Leaving
them out of the compander-only experiment was correct; leaving them out of a
DAC milestone that feeds a PA later would not be.

## 2. What "enable the HPHL DAC" actually requires

Three separate things, not one:

| # | what | register / call |
|---|---|---|
| 1 | the DAPM widget bit | `RX_HPH_L_DAC_CTL` **0x1B1** bit 7 |
| 2 | the RDAC clock | `CDC_CLK_RDAC_CLK_EN_CTL` **0x30D** bit 1 |
| 3 | the class-H state machine | `wcd9xxx_clsh_fsm(HPHL, ENABLE, PRE_DAC)` |

Plus, upstream of it:

| | |
|---|---|
| `CLASS_H_DSM MUX` POST_PMU | reads `CDC_CONN_CLSH_CTL` **0x3B0** bits 0x30, writes bits 0x0C |
| `RX_BIAS` supply | `RX_COM_BIAS` bit 7, refcounted in the resource manager |

## 3. The class-H step is much larger than it looks

`wcd9xxx_clsh_state_hph_l(enable)` calls nine helpers, which between them write:

```
buck        BUCK_CTRL_CCL_1/3/4, BUCK_MODE_1/3/4/5
charge pump CDC_CLK_OTHR_CTL
NCP         NCP_EN, NCP_STATIC            <- negative charge pump
class-H     CDC_CLSH_B1_CTL, B2_CTL, B3_CTL, BUCK_NCP_VARS,
            FCLKONLY_HPH_THSD, IDLE_HPH_THSD,
            I_PA_FACT_HPH_L/U, K_ADDR, K_DATA,
            V_PA_HD_HPH, V_PA_MIN_HPH
```

That is roughly twenty registers, and it powers the **buck converter and the
negative charge pump** — real analog rails, not a digital enable. Calling this
step "the DAC" understates it considerably.

## 4. The problem: there is no DAC-only teardown

This is the finding that should shape the milestone.

`wcd9xxx_clsh_state_hph_l()` with `is_enable = false` handles only the HPHR
case; for HPHL it logs *"stub fallback to hph_l"* and does nothing. The real
teardown is `wcd9xxx_clsh_turnoff_postpa()` — which reverses `BUCK_MODE_1`,
`CDC_CLSH_B1_CTL`, `NCP_EN`, the charge pump and the class-H block — and it is
called **only from the POST_PA event**, at all three of its call sites.

So in the downstream model, class-H is torn down when the **power amplifier**
goes away, not when the DAC does. A milestone that enables class-H and never
enables a PA therefore has **no inverse sequence to copy**. It would leave the
buck and NCP configured with no defined way back, which breaks the discipline
every milestone here has followed: establish teardown before enabling anything.

Three ways out, in my order of preference:

1. **Derive the teardown from `turnoff_postpa()` directly** and prove it
   restores the analog baseline, treating "enable then cleanly disable" as the
   milestone rather than "enable". This keeps the PA out and keeps the
   discipline.
2. **Split again**: a milestone for the DSM mux and RDAC clock only (0x3B0,
   0x30D, 0x1B1) with class-H left alone — but it is unclear the DAC does
   anything meaningful without class-H, so this may prove very little.
3. Accept a one-way transition, which I would not do.

## 5. No pre-PA observable is documented

`RX_HPH_L_STATUS` (0x1B3) and `RX_HPH_R_STATUS` (0x1B9) appear exactly **once**
in the downstream driver — in the volatile-register callback, marking them
uncacheable. Nothing ever reads them for logic, so their bit semantics are
undocumented there.

And they are not simply "off at rest": our own live baseline reads
**`0x1b3 = 0x04`** while the register header gives POR `0x00`. So a non-zero
reading already exists with nothing powered, and "non-zero means the DAC is
doing something" would be wrong on its face.

Determining whether either can distinguish *DAC active* from *DAC merely
powered* is therefore an empirical question with no documentation to lean on —
and given `0x376` and `hw_ptr` both turned out to be state flags rather than
activity indicators, I would not assume a third candidate behaves differently.

## 6. Safety constraints to freeze into the experiment

Carried from the branch plan, to be enforced by the gate rather than by memory:

- deterministic low-amplitude test waveform, not the full-scale ramp
- minimum sensible digital and analog gain
- **PA disabled for the entire DAC milestone** (`RX_HPH_CNP_EN` 0x1AB guarded)
- `TRIGGER_POST` ordering stays as frozen
- teardown sequence established **before** anything is enabled
- a contaminated analog baseline is an INVALID run, not a failure
- right-channel and speaker registers guarded against movement
- "registers enabled" is never reported as "audio exists"

## Open questions before any code

1. **Teardown.** Can `turnoff_postpa()`'s sequence be used as a DAC-only
   inverse, and does it demonstrably restore the analog baseline? This gates
   the whole milestone.
2. **Is class-H separable?** Does the HPHL DAC do anything observable with the
   DSM mux and RDAC clock alone, class-H untouched?
3. **`0x1B3` semantics.** What does `0x04` mean at rest, and does anything in
   the mapped chain change it?
4. **Buck voltage.** `taiko_codec_get_buck_mv()` reads platform data we do not
   have; `wcd9xxx_enable_buck_mode(BUCK_VREF_2V)` picks a specific rail. What
   this board's buck actually supplies needs establishing before it is driven.

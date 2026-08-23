# Branch C design map: the WCD9320 RX audio path

**Status:** research only. Nothing built, nothing claimed on hardware.
Derived by reading the downstream Taiko driver
(`LineageOS/android_kernel_lge_hammerhead`, cm-11.0,
`sound/soc/codecs/wcd9320.c`) — fetched to a local cache for analysis, **not**
checked in, the same rule `wcd9320-regmap-derive.py` follows for the register
headers.

Branch B ends with the QDSP6 consuming periods and the SLIMbus endpoint active,
but with **no measurement joining them**. This branch is about building the
receiver that could.

## 1. Which chain is RX1?

Slave port 16 / channel 144 is **SLIM RX1**, and it feeds the HPHL (left
headphone) interpolator chain. Every element, with the register that controls
it:

| # | widget | register | bit | what it is |
|---|---|---|---|---|
| 1 | `SLIM RX1` | — (`NOPM`) | — | the port endpoint; **already proven** |
| 2 | `RX1 MIX1 INP1` | `CDC_CONN_RX1_B1_CTL` **0x380** | 0..3 | input mux; select `RX1` |
| 3 | `RX1 MIX1` | — (`NOPM`) | — | first mixer stage |
| 4 | `RX1 MIX2` | `CDC_CLK_RX_B1_CTL` **0x30F** | 0 | **the interpolator** |
| 4a | reset pulse | `CDC_CLK_RX_RESET_CTL` **0x301** | 0 | toggled 1 then 0 on PRE_PMU |
| 4b | digital gain | `CDC_RX1_VOL_CTL_B2_CTL` **0x2B7** | — | re-written on POST_PMU |
| 5 | `RX1 CHAIN` | `CDC_RX1_B6_CTL` **0x2B5** | 5 | interpolator output enable |
| 6 | `CLASS_H_DSM MUX` | — (`NOPM`) | — | select `DSM_HPHL_RX1` |
| 7 | `HPHL DAC` | `RX_HPH_L_DAC_CTL` **0x1B1** | 7 | **the first DAC** |
| 8 | `HPHL` (PA) | `RX_HPH_CNP_EN` **0x1AB** | 5 | output driver — **out of scope** |
| — | `RX_BIAS` | — (`NOPM`) | — | analog bias supply widget |

The alternative first DAC is the earpiece: `DAC1` at `RX_EAR_EN` **0x1BC** bit
6, also fed from `CLASS_H_DSM MUX`. `RX2 CHAIN` feeds `HPHR DAC` for the right
channel; we have one channel, so RX1/HPHL is the whole story for now.

Note the chain is derived from **Taiko**, not inferred from WCD9335. The two
differ: WCD9335 has no `RX1 CHAIN` stage and numbers its interpolators
differently.

## 2. What mainline lacks

**Everything.** Mainline has no WCD9320 codec driver at all — only WCD9335.
Our driver registers a component declaring `.name` and `.endianness` and one
DAI, with zero DAPM widgets, zero routes and zero controls.

The delta for a digital RX path is items 2–5 above, plus:

- the DAPM widgets and the routes joining them
- interpolator clock enable and the reset pulse
- digital gain (`0x2B7`)
- compander configuration, if used as the observable (see §3)
- sample-rate configuration for the interpolator
- `snd_soc_component_driver` gaining `.dapm_widgets`, `.dapm_routes`,
  `.controls`

Items 6–8 and `RX_BIAS` are the analog milestone and deliberately excluded.

## 3. Where byte arrival can finally be observed

This is the question that decides whether a digital-only milestone is worth
anything, and there **is** a candidate.

| register | addr | volatile in our regmap? | notes |
|---|---|---|---|
| `CDC_COMP1_SHUT_DOWN_STATUS` | **0x376** | **yes**, readable | compander 1 serves RX1/RX2 |
| `CDC_COMP0_SHUT_DOWN_STATUS` | 0x36E | yes | compander 0 (EAR) |
| `CDC_SPKR_CLIPDET_VAL0..7` | 0x270–0x277 | yes | speaker path (RX7), not RX1 |
| `CDC_VBAT_GAIN_MON_VAL` | 0x2FB | yes | VBAT monitor |
| `RX_HPH_L_STATUS` | 0x1B3 | yes | **analog**, needs the PA |

The compander is a **digital** block sitting on the interpolator output. Its
shutdown status is signal-dependent, and — verified against our generated
tables, not assumed — 0x376 is classified **volatile and readable**, so a read
reaches the chip rather than the cache. A cached status register would have
been useless here, and it was worth checking before building a milestone on it.

**This is a hypothesis, not a result.** That 0x376 is signal-dependent is read
from the block's purpose, not measured. The experiment is precisely to find out
whether it moves when the DSP is streaming and stays put when it is not — and
the B2 negative control gives us exactly the "streaming with nothing connected"
condition to compare against.

If it does move, Branch B's gap closes without any analog output. If it does
not, no receiver-side digital observable exists on this part and byte arrival
cannot be proven until sound comes out.

## 4. The minimum digital-only milestone

```
QDSP6 data loop (proven)
        +
active SLIMbus stream (proven)
        ↓
RX1 MIX1 INP1 mux -> RX1 MIX1 -> RX1 MIX2 (interpolator) -> RX1 CHAIN
        ↓
compander 1 enabled
        ↓
0x376 observed to change while streaming, and not while idle
```

It stops **before** `HPHL DAC` (0x1B1). No DAC, no class-H, no PA, no bias, no
speaker. Nothing can make a sound, which is the point: the failure class here is
register sequencing, and mixing it with analog power sequencing would confound
both.

## 5. The clock question, which may gate everything

Downstream takes `WCD9XXX_CLK_RCO` for most blocks but has a separate
`taiko_mclk_enable()` that demands `WCD9XXX_CLK_MCLK`.

This board has **no external MCLK** — established earlier and recorded in
`wcd9320-mclk-investigation.md` and the RCO wake work, which is why the CDC core
is brought up on the internal RC oscillator.

An RC oscillator is not frequency-accurate and is not locked to the ADSP's
sample clock. A digital interpolator consuming a SLIMbus stream needs a clock
related to the data rate, or it drifts. Whether Taiko derives its audio clock
from the SLIMbus clock in a no-MCLK configuration is **not yet established**,
and it is the single largest risk to this branch.

Worth noting it is a *different* question from Branch B's unexplained 1.45%
pacing offset: that one is unchanged with SLIMbus removed, so it lives on the
ASM/host/DSP side, not here.

I would answer this by reading the resource manager's clock selection before
writing any RX code, because if the interpolator cannot be clocked correctly
then the digital milestone's shape changes.

## The ladder from here

```
DONE   msm8974-q6-data-plane-proven      DSP consumes PCM buffers
DONE   msm8974-slim-rx-stream-proven     WCD9320 transport endpoint active

NEXT   wcd9320-rx-digital-path-proven    RX digital/interpolator chain operates,
                                         ideally with receiver-side evidence
THEN   wcd9320-playback-routing-proven   DAC + analog routing established
THEN   lumia1520-audible-playback-proven physically verified sound
```

`TRIGGER_POST` stays frozen going into this. Once an output exists, that
ordering stops being an invisible correctness detail and starts preventing the
start/stop click it was found by predicting.

## Open questions before any code

1. **The clock.** Can the RX interpolator be correctly clocked with no MCLK?
   Read the resource manager's selection logic first.
2. **Is 0x376 actually signal-dependent?** The whole digital milestone rests on
   it. If not, name the fallback before starting.
3. **Sample-rate configuration.** The interpolator and compander both take a
   rate; 48 kHz is our only case, but the register writes must be identified.
4. **Does the compander need the analog buck voltage?** `taiko_config_compander`
   reads `taiko_codec_get_buck_mv()` and branches on it, which may drag analog
   state into a nominally digital milestone.

# The RX clock question, resolved

**Status:** resolved by measurement and source, 2026-08-23. No code written.
Prerequisite for Branch C, raised in `wcd9320-rx-path-mapping.md` as the single
largest risk to the branch.

## The question

Downstream exposes `taiko_mclk_enable()` demanding `WCD9XXX_CLK_MCLK`, and this
board has no external MCLK — the CDC core runs on the internal RC oscillator.
If the RX interpolator required MCLK, the digital-only milestone would be
blocked before it started.

## Answer: it does not. The digital path needs no clock switch.

Three independent findings, two from source and one from the running hardware.

### 1. Nothing calls `taiko_mclk_enable()`

Searching the whole downstream Taiko driver returns exactly **one** occurrence:
its own definition. It is an exported entry point for a machine driver, not
something the codec's own paths invoke. The reference MSM8974 machine driver's
MCLK event is a no-op.

### 2. The RX clock dependency is I2S-only

The routes

```
{"SLIM RX1", NULL, "RX_I2S_CLK"}
```

live in `audio_i2s_map[]`, the **I2S-only** route table — not the SLIMbus one.
On a SLIMbus part, `SLIM RX1` carries no clock-supply dependency at all. Reading
that route without checking which array it belongs to would have produced the
opposite conclusion.

### 3. The interpolator acquires no clock

Neither `taiko_codec_enable_interpolator()` nor `taiko_codec_enable_slimrx()`
contains a single `resmgr_get_clk_block`, `WCD9XXX_CLK_MCLK` or
`WCD9XXX_CLK_RCO` reference. The interpolator event does three things: pulse the
reset bit, enable the clock **gate** already assigned to it, and re-apply
digital gain.

## What the hardware is actually doing right now

Read live from the codec's regmap debugfs on r160, with nothing streaming:

| register | addr | value | meaning |
|---|---|---|---|
| `CLK_BUFF_EN1` | 0x108 | **0x0d** | bit 3 = RCO selected as buffer source, bit 0 = buffer enabled |
| `CLK_BUFF_EN2` | 0x109 | 0x04 | clock on |
| `RC_OSC_FREQ` | 0x1fa | 0xc6 | bit 7 = RC oscillator enabled |
| `RC_OSC_STATUS` | 0x1fc | 0x18 | volatile, live read |
| `CDC_CLK_MCLK_CTL` | 0x311 | **0x01** | the CDC clock gate is **already open** |

**The register named `CDC_CLK_MCLK_CTL` is a gate, not a source selector.** The
source lives in `CLK_BUFF_EN1` bit 3, which reads RCO. So a register with "MCLK"
in its name is already enabled on a board that has no MCLK, and reading the name
alone would give exactly the wrong answer. This is the second time on this part
that a name has been misleading — `port_rx_cfg_reg_base` was the first.

The RX path itself is idle and clean, as it should be before any of this work:

| register | addr | value |
|---|---|---|
| `CDC_CLK_RX_B1_CTL` (interpolator) | 0x30F | 0x00 |
| `CDC_CLK_RX_B2_CTL` (compander clk) | 0x310 | 0x00 |
| `CDC_CONN_RX1_B1_CTL` (input mux) | 0x380 | 0x00 |
| `CDC_RX1_B6_CTL` (RX1 CHAIN, bit 5) | 0x2B5 | 0x80 — bit 5 clear |
| `CDC_COMP1_B1_CTL` | 0x370 | 0x30 = POR |
| `CDC_COMP1_SHUT_DOWN_STATUS` | 0x376 | **0x03 = POR** |

## The fork, resolved

```
Current RCO
   ↓
enable RX1 digital clock/interpolator
   ↓
clock source remains RCO, no switch requested   <-- THIS BRANCH
   ↓
digital-only milestone survives
```

The alternative — the RX path demanding MCLK and the clock architecture needing
solving first — is not what the source or the hardware shows.

**Caveat kept deliberately:** this establishes the path does not *request* a
different clock. It does not establish that an RC oscillator can clock an
interpolator *correctly* against a SLIMbus-paced stream. Whether the data rate
and the codec's clock stay related is a question only the experiment answers,
and a drifting interpolator would most likely show as compander behaviour that
never settles, or as nothing changing at all.

## Consequences for the first milestone

**Stop at `RX1 CHAIN`.** No `CLASS_H_DSM MUX`, no `HPHL DAC`, no PA, no bias.
The registers in scope are exactly five:

| step | register | addr |
|---|---|---|
| input mux -> RX1 | `CDC_CONN_RX1_B1_CTL` | 0x380 |
| interpolator reset pulse | `CDC_CLK_RX_RESET_CTL` | 0x301 |
| interpolator clock enable | `CDC_CLK_RX_B1_CTL` | 0x30F |
| digital gain re-apply | `CDC_RX1_VOL_CTL_B2_CTL` | 0x2B7 |
| chain output enable | `CDC_RX1_B6_CTL` | 0x2B5 |

Plus the compander, only if it is used as the observable.

## `0x376` is not yet an activity indicator

That it is volatile and readable makes it a **valid observation point**. It does
not make it a sample-arrival indicator, and the milestone must not be named as
though it were.

The experiment needs its own control, structurally identical to Branch B's:

```
same QDSP6 RUN, same SLIMbus stream, RX1 digital chain OFF   -> 0x376 baseline
same QDSP6 RUN, same SLIMbus stream, RX1 digital chain ON    -> 0x376 observed
```

A reproducible difference establishes something real about that block's state.
Only if it is further shown to track signal presence — rather than merely
"the compander is powered" — can it close Branch B's byte-arrival gap.

So the gate has two possible outcomes and both are worth having:

- **strong:** RX digital path enabled *and* receiver-side activity observed
- **weaker, still valuable:** RX1 mixer, interpolator and chain successfully
  clocked and configured on hardware, with no claim of byte arrival

The milestone is therefore not pre-named `wcd9320-rx-digital-path-proven`. It
gets its name after the evidence says which of those two it is.

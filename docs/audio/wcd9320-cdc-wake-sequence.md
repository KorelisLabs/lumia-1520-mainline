# WCD9320 CDC-core wake sequence — traced from downstream

Source work only. No register has been written; nothing here has been built
or booted. The purpose is to establish the exact sequence before issuing any
write, per the plan in `wcd9320-asoc-survey.md`.

Sources: `sound/soc/codecs/wcd9xxx-resmgr.c`, `wcd9320.c`, `wcd9320-tables.c`
and `include/linux/mfd/wcd9xxx/wcd9320_registers.h` from
`LineageOS/android_kernel_lge_hammerhead` (`cm-11.0`).

## 1. The headline: `0x311` is written in exactly one place

`TAIKO_A_CDC_CLK_MCLK_CTL` (`0x311`) — one of the four registers this trace
was asked to cover — appears exactly once in the entire downstream tree
outside the register tables:

```
wcd9xxx-resmgr.c:437:  snd_soc_update_bits(codec, WCD9XXX_A_CDC_CLK_MCLK_CTL, 0x01, 0x01);
```

It is the **last step** of `wcd9xxx_enable_clock_block()`, after the clock is
already running. That single fact settles the distinction this trace was
supposed to draw.

## 2. The distinction: who supplies the clock, who merely ungates the block

**Registers that configure and enable the clock itself** — all in
`0x100`–`0x1ff`, the region that is **readable right now** on this device:

| addr | register | role |
|---|---|---|
| `0x101` | `BIAS_CENTRAL_BG_CTL` | bandgap, prerequisite for any clock |
| `0x105` | `BIAS_OSC_BG_CTL` | bandgap mode for the RC oscillator |
| `0x108` | `CLK_BUFF_EN1` | clock **source select** and buffer enable |
| `0x109` | `CLK_BUFF_EN2` | clock on/off |
| `0x1fa` | `RC_OSC_FREQ` | internal RC oscillator enable |
| `0x1fb` | `RC_OSC_TEST` | RC oscillator start pulse |

**Register that merely ungates the CDC digital block** — the only one inside
the dark region:

| addr | register | role |
|---|---|---|
| `0x311` | `CDC_CLK_MCLK_CTL` bit 0 | gate the already-running clock into the CDC block |

So `0x311` does not create a clock and cannot. It is the final valve. The
clock is produced and selected entirely by registers this port can already
read and verify.

The other three registers in the original list turn out **not** to be part of
the wake path at all:

- `0x308` `CDC_CLK_OTHR_RESET_B1_CTL` — appears once, as `0x00` in a
  register-init table (`wcd9320.c:6008`). Not touched by the clock path.
- `0x309` `CDC_CLK_OTHR_RESET_B2_CTL` — four `update_bits()` calls
  (`wcd9320.c:1067,1070,1099,1102`), all in per-path widget context, not in
  core enablement.
- `0x314` `CDC_CLK_POWER_CTL` — appears once, as `0x03` in
  `taiko_reg_defaults[]` (`wcd9320.c:5967`), applied as a blind write at codec
  probe. It is **not** referenced by `enable_clock_block()`.

## 3. There is an internal clock source — no external MCLK required

`wcd9xxx_enable_clock_block(resmgr, config_mode)` takes a mode argument, and
`wcd9xxx_resmgr_get_clk_block()` selects it:

```c
case WCD9XXX_CLK_RCO:   wcd9xxx_enable_clock_block(resmgr, 1);  /* RC oscillator */
case WCD9XXX_CLK_MCLK:  wcd9xxx_enable_clock_block(resmgr, 0);  /* external MCLK */
```

**`WCD9XXX_CLK_RCO` runs the codec from an on-die RC oscillator.** It needs no
external reference at all. The two modes are interchangeable enough that
downstream switches between them at runtime, disabling one clock block and
re-enabling the other.

This matters enormously here, because `wcd9320-mclk-investigation.md` left the
external route unknown and could not resolve it. The RCO path sidesteps that
question entirely for the purpose of the accessibility experiment.

Supporting evidence already in hand, from the silicon dump: the RC oscillator
block is alive and reading sensible values right now —
`RC_OSC_FREQ` (`0x1fa`) = `0x46` (`__POR` `0x46`),
`RC_OSC_TEST` (`0x1fb`) = `0x0a` (`__POR` `0x0a`),
`RC_OSC_STATUS` (`0x1fc`) = `0x18` (`__POR` `0x18`).
All three are outside the dark region and match their documented defaults.

It is also consistent with why MBHC works without MCLK: headset detection runs
off this same oscillator.

## 4. The RCO sequence, step by step

Assembled from `wcd9xxx_resmgr_enable_config_mode(codec, 1)` followed by
`wcd9xxx_enable_clock_block(resmgr, config_mode=1)`. Every write is on the
**PGD** (control function); none touch the IFD.

Prerequisite: bandgap in audio mode. `taiko_mclk_enable()` calls
`wcd9xxx_resmgr_get_bandgap(WCD9XXX_BANDGAP_AUDIO_MODE)` **before**
`get_clk_block()`, which routes to `wcd9xxx_enable_bg()` and touches
`BIAS_CENTRAL_BG_CTL` (`0x101`).

| # | register | mask | value | delay after | notes |
|---|---|---|---|---|---|
| 1 | `0x1fa` `RC_OSC_FREQ` | `0x10` | `0x00` | — | |
| 2 | `0x105` `BIAS_OSC_BG_CTL` | (write) | `0x17` | 5 µs | "bandgap mode to fast" |
| 3 | `0x1fa` `RC_OSC_FREQ` | `0x80` | `0x80` | — | enable RCO |
| 4 | `0x1fb` `RC_OSC_TEST` | `0x80` | `0x80` | 10 µs | start pulse, rising |
| 5 | `0x1fb` `RC_OSC_TEST` | `0x80` | `0x00` | **10 ms** | start pulse, falling |
| 6 | `0x108` `CLK_BUFF_EN1` | `0x08` | `0x08` | — | select RCO as buffer source |
| 7 | `0x109` `CLK_BUFF_EN2` | (write) | `0x02` | 1 ms | |
| 8 | `0x108` `CLK_BUFF_EN1` | `0x01` | `0x01` | **1–1.2 ms** | enable clock buffer — comment says the delay is "required by codec hardware" |
| 9 | `0x109` `CLK_BUFF_EN2` | `0x02` | `0x00` | — | |
| 10 | `0x109` `CLK_BUFF_EN2` | `0x04` | `0x04` | — | clock on |
| 11 | `0x311` `CDC_CLK_MCLK_CTL` | `0x01` | `0x01` | 50 µs | **gate into the CDC block** |

Steps 1–10 are all in the readable region, so **each one can be verified by
readback before proceeding**. Only step 11 writes blind, and it is the step
the sentinel is designed to detect.

For reference, the external-MCLK variant (`config_mode = 0`) differs only in
steps 1–6: it clears `CLK_BUFF_EN1` bit 3 instead of setting it, switches off
RCO if running, and sets `CLK_BUFF_EN1` `0x0C` to `0x04` — "clk source to ext
clk and clk buff ref to VBG". Steps 7–11 are identical. That is the cleanest
statement of the difference: **the same block, fed from a different source.**

## 5. The inverse

`wcd9xxx_disable_clock_block()`:

| # | register | mask | value | delay after |
|---|---|---|---|---|
| 1 | `0x109` `CLK_BUFF_EN2` | `0x04` | `0x00` | 50 µs |
| 2 | `0x109` `CLK_BUFF_EN2` | `0x02` | `0x02` | — |
| 3 | `0x108` `CLK_BUFF_EN1` | `0x05` | `0x00` | 50 µs |

Then `enable_config_mode(codec, 0)` clears `BIAS_OSC_BG_CTL` bit 0 and
`RC_OSC_FREQ` bit 7.

**Note what the inverse does *not* do: it never clears `0x311`.** The CDC
clock gate is left set. So downstream does not power the CDC register block
back down as part of clock teardown, which bears directly on step 6 of the
planned experiment — the block may well stay accessible after the clock is
removed, and if so that is a finding rather than a failure.

There is also a hardware ordering constraint worth respecting, asserted twice
in downstream via `WARN_ON`: switching to RCO requires MCLK off, checked as
`CLK_BUFF_EN2 & (1 << 2)`.

## 6. Revision variance

None found for this path. `taiko_reg_defaults[]` has per-revision entries
elsewhere, but every register in §4 is written unconditionally by
`wcd9xxx-resmgr.c`, which is shared across WCD9xxx parts and keys off
`WCD9XXX_A_*` names rather than Taiko-specific ones. No `TAIKO_IS_1_0` /
`1_1` guard appears anywhere in the clock path.

## 7. Consequence for the first wake experiment

The experiment can be built as specified, and the RCO route makes it
materially stronger than an MCLK-dependent one would have been:

- it needs **no external clock**, so it does not depend on the unresolved
  question in `wcd9320-mclk-investigation.md`
- ten of the eleven steps are verifiable by readback as they are applied, so a
  failure localises to a specific step rather than to the sequence as a whole
- if the sentinel region transitions, that proves the CDC block became
  accessible via a **fully documented, source-grounded sequence**

The sentinel keeps its name and its limits. A transition would prove the
prerequisite sequence worked; it would still not isolate any single cause, and
on the RCO path it would specifically **not** say anything about external
MCLK.

### Open, and deliberately not guessed at

- **Bit semantics.** The masks above are transcribed from downstream, not
  understood. No datasheet has been consulted; `0x17` in step 2 is a magic
  value.
- **`0x314`.** Still unexplained. It is not in the clock path, so the earlier
  worry about writing it is now moot for this experiment — it simply is not
  needed.
- **Whether the RCO frequency is usable for audio.** Irrelevant to
  accessibility, but it will matter later; RCO is a low-accuracy oscillator
  and downstream uses it for MBHC and idle, switching to MCLK for streams.
- **Whether bandgap audio mode is strictly required** before the clock, or
  merely how downstream happens to order it.

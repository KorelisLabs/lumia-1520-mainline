# r168 mapping: the codec-side RCO -> MCLK source switch

**Status:** research only, 2026-08-27. **No code written, no register poked.**
Prerequisite: the r167 PMIC configuration (DIV_CTL1 = 2, gpio15 func1) is now
frozen and is not revisited here. No PMIC changes in r168.

## Why this is the next single uncertainty

r167 returned **M2**: the external MCLK path was established as far as the PMIC
pad -- `/2` written and chip-verified, gpio15 on func1, the RPM vote held, and
all of it surviving the vote transition -- and `0x314` and `0x30d[1]` still
refused while the codec remained RCO-selected. So the remaining variable is
whether the codec has to be *running from* that clock.

Everything below is transcribed from downstream `wcd9xxx-resmgr.c` and
`wcd9320.c`, cached externally and never checked in.

## 1. THE SWITCH IS NOT A HOT SWAP

This is the single most important structural fact, and it changes the risk
model completely. `wcd9xxx_resmgr_get_clk_block(MCLK)` from an RCO state does:

```c
} else if (resmgr->clk_mclk_users == 1 &&
           resmgr->clk_type == WCD9XXX_CLK_RCO) {
        WARN_ON(!(snd_soc_read(codec, WCD9XXX_A_RC_OSC_FREQ) & 0x80));
        wcd9xxx_disable_clock_block(resmgr);   /* ALL clock off first */
        wcd9xxx_enable_clock_block(resmgr, 0); /* then bring up on MCLK */
        resmgr->clk_type = WCD9XXX_CLK_MCLK;
}
```

The codec passes through a state with **no clock at all**. There is no
glitchless mux, and the `WARN_ON` at the top of `enable_clock_block` --
`snd_soc_read(CLK_BUFF_EN2) & (1 << 2)` -- exists precisely to assert the block
really was turned off first.

## 2. The exact RCO -> MCLK sequence

### Preconditions

| requirement | where it comes from | our status |
|---|---|---|
| central bandgap on | `wcd9xxx_resmgr_get_bandgap(AUDIO_MODE)` before the clock, and `BIAS_CENTRAL_BG_CTL` 0x101 must be on or the OSC bandgap enable will not set | **already satisfied** -- our `core_init` stage 2 implements it, and this project measured the failure mode when it is omitted |
| RCO currently running | `WARN_ON(!(RC_OSC_FREQ & 0x80))` | satisfied: `0x1fa = c6`, bit 7 set |
| clock block off before enable | `WARN_ON(CLK_BUFF_EN2 & 0x04)` | must be produced by step A |
| MCLK rate declared | `CHIP_CTL[2:1]`, see section 4 | **NOT satisfied** -- reads `0x00` = 12.288 MHz |

### Step A -- `wcd9xxx_disable_clock_block()`

```
notify PRE_MCLK_OFF (or PRE_RCO_OFF, by current clk_type)
CLK_BUFF_EN2  0x109  mask 0x04 <- 0x00        clock off
usleep 50
CLK_BUFF_EN2  0x109  mask 0x02 <- 0x02
CLK_BUFF_EN1  0x108  mask 0x05 <- 0x00        bits 0 and 2 clear
usleep 50
notify POST_MCLK_OFF (or POST_RCO_OFF)
```

### Step B -- `wcd9xxx_enable_clock_block(resmgr, config_mode = 0)`

```
WARN_ON(read(CLK_BUFF_EN2) & 0x04)            assert step A happened
notify PRE_MCLK_ON

CLK_BUFF_EN1  0x108  mask 0x08 <- 0x00        stop selecting RCO

if (read(RC_OSC_FREQ 0x1fa) & 0x80) {         RCO still enabled?
        write(CLK_BUFF_EN2 0x109, 0x02)       full write, not masked
        wcd9xxx_resmgr_enable_config_mode(codec, 0):
                BIAS_OSC_BG_CTL 0x105  mask 0x01 <- 0
                RC_OSC_FREQ     0x1fa  mask 0x80 <- 0     RC oscillator OFF
}

CLK_BUFF_EN1  0x108  mask 0x0C <- 0x04        source = external, ref = VBG
CLK_BUFF_EN1  0x108  mask 0x01 <- 0x01        buffer enable
usleep 1000..1200                             "sleep required by codec hardware
                                               to enable clock buffer"
CLK_BUFF_EN2  0x109  mask 0x02 <- 0x00
CLK_BUFF_EN2  0x109  mask 0x04 <- 0x04        clock on
CDC_CLK_MCLK_CTL 0x311 mask 0x01 <- 0x01      the CDC gate
usleep 50
notify POST_MCLK_ON
```

**Note the asymmetry that matters for recovery:** switching to MCLK *disables
the RC oscillator* (`RC_OSC_FREQ` bit 7 cleared). After the switch there is no
warm RCO to fall back to -- it must be restarted, which costs ~10 ms.

## 3. The exact inverse, MCLK -> RCO

`wcd9xxx_resmgr_put_clk_block(MCLK)` with RCO users still held does
`disable_clock_block()` then `enable_clock_block(resmgr, 1)`. Step A above is
identical. Step B becomes:

```
notify PRE_RCO_ON
wcd9xxx_resmgr_enable_config_mode(codec, 1):
        RC_OSC_FREQ     0x1fa  mask 0x10 <- 0
        BIAS_OSC_BG_CTL 0x105  <- 0x17            FULL WRITE
        usleep 5
        RC_OSC_FREQ     0x1fa  mask 0x80 <- 0x80  RC oscillator on
        RC_OSC_TEST     0x1fb  mask 0x80 <- 0x80
        usleep 10
        RC_OSC_TEST     0x1fb  mask 0x80 <- 0
        usleep 10000                              <-- the 10 ms RCO settle
        CLK_BUFF_EN1    0x108  mask 0x08 <- 0x08  select RCO
write(CLK_BUFF_EN2 0x109, 0x02)
usleep 1000

  ... then the SHARED TAIL, identical to the MCLK path:
CLK_BUFF_EN1  0x108  mask 0x01 <- 0x01
usleep 1000..1200
CLK_BUFF_EN2  0x109  mask 0x02 <- 0x00
CLK_BUFF_EN2  0x109  mask 0x04 <- 0x04
CDC_CLK_MCLK_CTL 0x311 mask 0x01 <- 0x01
usleep 50
notify POST_RCO_ON
```

`BIAS_OSC_BG_CTL <- 0x17` is a full write our own `core_init` already carries,
annotated there as "inherited magic: bandgap mode to fast".

## 4. CHIP_CTL is a RATE DECLARATION, not part of the switch

```c
/* taiko_codec_probe(), after taiko_update_reg_defaults(),
   before taiko_codec_init_reg() */
if (wcd9xxx->mclk_rate == TAIKO_MCLK_CLK_12P288MHZ)
        snd_soc_update_bits(codec, TAIKO_A_CHIP_CTL, 0x06, 0x0);
else if (wcd9xxx->mclk_rate == TAIKO_MCLK_CLK_9P6MHZ)
        snd_soc_update_bits(codec, TAIKO_A_CHIP_CTL, 0x06, 0x2);
```

It is written **once at probe**, from board data, and never touched by the
clock switch. But it is not optional for us:

- our external MCLK is **9.6 MHz** (r167 set DIV_CTL1 = 2 from a 19.2 MHz XO)
- our `CHIP_CTL` reads **`0x00`**, which declares **12.288 MHz**

So a switch to MCLK with `CHIP_CTL` untouched would run the codec's internal
dividers against a rate the hardware is not receiving. Any honest r168 must
either set `CHIP_CTL[2:1] = 0x2` as an explicit, separately-verified step, or
state plainly that it is testing a deliberately mismatched configuration.

The earlier "do not write CHIP_CTL" rule was an r167 boundary, and r167 kept
it: the artefact gate proves the driver has zero write sites for `0x001`.

## 5. Failure and recovery model

### Downstream has NO failure handling whatsoever

`wcd9xxx_enable_clock_block()` returns `void`. There is no status register, no
polling, no timeout, no readback of success anywhere in the clock path -- the
only checks are three `WARN_ON`s that log and continue. `RC_OSC_STATUS`
(0x1fc) exists and is volatile and readable in our regmap, but downstream never
consults it.

So downstream's model is: the board is known good, the sequence is applied
open-loop, and nothing verifies the clock arrived.

### Register access does NOT depend on the CDC clock

This is the recovery guarantee, and it is established from downstream's own
ordering rather than by argument:

- `get_clk_block` calls `disable_clock_block()` and *then*
  `enable_clock_block()`
- `enable_clock_block()`'s **first statement is a register read**
  (`snd_soc_read(CLK_BUFF_EN2)`), and it performs a second read of
  `RC_OSC_FREQ` partway through
- it also issues eight register writes while the block is off

If codec register access required the CDC clock, that code could not function
on any board. Register access is carried by the SLIMbus interface function,
clocked from the ADSP-mastered bus, which is why this project gave the IFD its
own regmap in the first place.

**Therefore: software can always write the codec back to RCO. Recovery does not
require a module reload, reboot or power cycle.**

### The residual ambiguity that r168 must design around

A CDC-block register that reads `00` is ambiguous between:

1. the write was refused, and
2. the CDC block has no clock and reads as zero

These are indistinguishable from `0x30d`/`0x314` alone -- and if r168 switches
to an MCLK that is not physically arriving, outcome 2 is exactly what happens.
Reporting that as "MCLK still insufficient" would be a false negative of the
worst kind, because it would look like a clean result.

**r168 therefore needs a positive control**: CDC-block registers with known
non-zero contents, re-read after the switch.

| register | known value | why it works as a control |
|---|---|---|
| `0x2b4` CDC_RX1_B5_CTL | `78` | rate field, non-zero at POR, CDC digital block |
| `0x373` COMP1_B4_CTL | `37` | non-zero at POR, CDC digital block |
| `0x370` COMP1_B1_CTL | `30` | non-zero at POR, CDC digital block |

If those still read their known values after the switch, the CDC block is
responding and a refusal of `0x314`/`0x30d` is a real refusal. If they read
`00`, the core is unclocked and the run says nothing about the RDAC question.

### Which registers are safe to verify, and which are not

| register | bypassed read meaningful? |
|---|---|
| `0x101` `0x105` `0x108` `0x109` `0x1fa` `0x1fb` `0x311` | **yes** -- ordinary registers over SLIMbus, independent of the CDC clock |
| `0x1fc` RC_OSC_STATUS | yes, volatile; but only meaningful while the RC oscillator is enabled |
| `0x2b4` `0x370` `0x373` | **the positive control** -- meaningful precisely because their value is known |
| `0x314` `0x30d` | the registers under test; a `00` read is ambiguous without the control above |

## 6. Reference counting and sharing

Downstream refcounts, and the clock is genuinely shared:

- `clk_rco_users` and `clk_mclk_users`, distinct counters
- `bg_audio_users` and `bg_mbhc_users` for the bandgap
- everything under `WCD9XXX_BG_CLK_LOCK(&resmgr)`
- **MBHC shares it**: `mbhc_cfg.mclk_cb_fn` is the machine driver's
  `msm_snd_enable_codec_ext_clk`, and the machine driver keeps its own
  `clk_users` count under `cdc_mclk_mutex`
- the bandgap can only change mode with the clock off, so `get_bandgap` does
  `save_clock -> disable_bg -> enable_bg_audio -> restore_clock`

Our port has no resmgr, no notifier chain and no bandgap manager -- `core_init`
implements the bandgap and RCO bring-up as a fixed sequence. So r168 would be
writing a **bare, single-user** version of this, and must say so rather than
pretending to the shared model.

## 7. The smallest safe r168 experiment

One variable: the codec's clock source. The PMIC configuration from r167 is a
frozen prerequisite, re-established but not re-investigated.

```
0. establish the r167 path      DIV_CTL1 = 2, gpio15 func1, RPM vote
                                (re-verified, not re-derived)
1. record the positive control  0x2b4, 0x370, 0x373 -- known non-zero
2. declare the rate             CHIP_CTL[2:1] <- 0x2  (9.6 MHz), chip-verified
3. disable the clock block      step A
4. enable on MCLK               step B
5. RE-READ THE POSITIVE CONTROL is the CDC block alive at all?
6. only if alive, retry         0x314 <- 03, 0x30d[1] <- 1
7. restore                      step A, then enable_clock_block(1) = RCO
8. re-read the positive control and confirm the codec survived
```

Everything in steps 2 to 7 is a codec register write over SLIMbus, so every
step is reversible by software.

### Guaranteed recovery, in order of escalation

1. **Normal**: step 7 restores RCO. ~12 ms of sleeps, all register writes.
2. **If the gate aborts mid-sequence**: the restore path must run from a
   teardown that executes unconditionally, not only on success.
3. **If the codec is unresponsive to the restore**: it will not be, by section
   5 -- but if reads themselves fail, `core_reinit` already exists in this
   driver and re-runs the whole bring-up including the RCO block.
4. **Last resort**: power cycle. No filesystem or eMMC involvement anywhere in
   this experiment, unlike r166.

## 8. Explicit stop conditions

**Stop and report, do not continue to C2b:**

- the positive control reads `00` after the switch -- the CDC core is
  unclocked, the run says nothing about the RDAC registers, and the conclusion
  is that no clock is arriving at the pin
- `0x314` or `0x30d[1]` still refuse *with* the positive control intact -- that
  is a real negative and the next question is the physical route, which needs
  measurement rather than more register work
- the restore to RCO does not read back correctly -- report and stop; do not
  attempt further configuration on a codec in an unknown clock state
- any PA guard trip, at any point

**Do not, in r168:**

- change anything on the PMIC side; r167's configuration is frozen
- enable the DAC or the PA
- treat `clk_get_rate()` as evidence of anything
- report "MCLK insufficient" without the positive control having passed

## 9. What is still not measurable

That 9.6 MHz physically reaches the codec's MCLK pin. r168 can only produce
*corroboration*: if the CDC core keeps running after the source switch, a clock
is arriving. If it stops, one is not. That is a much stronger instrument than
anything available before -- the codec becomes its own clock detector -- but it
is still inference from behaviour, not a waveform.

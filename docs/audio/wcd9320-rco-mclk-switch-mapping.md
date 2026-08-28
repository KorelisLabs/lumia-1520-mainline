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
it: the driver had zero write sites for `0x001` of any kind. (The artefact gate
was cited for that at the time. It could not actually have seen a
`wcd9320_c2b_write()` to `0x001` -- see section 10. The fact was true; the
check was weaker than the claim made for it.)

### RESOLVED, and what it costs

**Decision: `CHIP_CTL[2:1] <- 0x2` is written inside the switch, as step 2 of
the sequence, chip-verified, with no probe between it and the source change.**

So r168 moves **two** things in one run: the rate declaration and the clock
source. That is stated here rather than hidden, because it determines what a
positive result can be claimed to mean:

- if `0x314`/`0x30d` **still refuse**, the run is unaffected. Both changes are
  in the direction that should help, and neither helped.
- if they **latch**, r168 cannot say which of the two did it. Separating them
  is a further build — and one worth doing at that point, because there would
  finally be something to separate.

The alternative that was rejected was to leave `CHIP_CTL` at `0x00` and test a
knowingly mismatched configuration. It preserves the never-written property and
one-variable discipline, but it makes the *negative* case weak: a refusal could
be blamed on the deliberate rate mismatch, and that objection could not be
answered without a second build either. Given that the negative is the outcome
r167 makes likely, the mismatch is the worse thing to spend the run on.

The restore puts `CHIP_CTL` back to the value **measured** before the write,
while the codec is running from the RC oscillator again — the same clock state
it was written under.

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

## 9. What is still not measurable (ANSWERED at r169, see 10a)

That 9.6 MHz physically reaches the codec's MCLK pin. r168 can only produce
*corroboration*: if the CDC core keeps running after the source switch, a clock
is arriving. If it stops, one is not. That is a much stronger instrument than
anything available before -- the codec becomes its own clock detector -- but it
is still inference from behaviour, not a waveform.

## 10. r168 RAN, AND WAS BLOCKED BY A THIRD REFUSED REGISTER

**Result: S -- no MCLK conclusion. `CHIP_CTL` (0x001) refuses writes.**
Evidence: [wcd9320-clk-source-20260826T101629Z.txt](wcd9320-clk-source-20260826T101629Z.txt).
Artefact verified 75/0 before the run.

The switch aborted at step 2, before the clock block was touched:

```
c2b: 0x001 mask 06 want 02 -> chip 00  [CHIP_CTL[2:1] = 0x2, MCLK rate 9.6 MHz]
c2b: 0x001 did not take on the chip
```

So r168's design was self-blocking: it made the source switch conditional on a
write the part will not accept. Nothing else moved -- PA untouched at `80`, DAC
never powered, `0x314` and `0x30d` back at POR, divider restored, mclk
released, positive control `78/30/37` throughout, zero new kernel warnings. The
frozen r167 path re-established exactly: factor 2, gpio15 function 2, dir 2,
enabled 1.

### The finding, which is worth more than the run that was blocked

**`0x001` is the third MCLK-domain register to refuse**, after `0x314`
CDC_CLK_POWER_CTL and `0x30d[1]` the HPHL RDAC clock enable. Downstream
corroborates the grouping from the other direction --
`taiko_reg_defaults[]` **opens** with these two entries, adjacent, under one
comment:

```c
/* set MCLk to 9.6 */
TAIKO_REG_VAL(TAIKO_A_CHIP_CTL, 0x02),
TAIKO_REG_VAL(TAIKO_A_CDC_CLK_POWER_CTL, 0x03),
```

applied by `taiko_update_reg_defaults()` at probe -- on a board where the
machine driver has the codec's external MCLK running by then.

So the three registers this branch has been fighting share exactly one
property, and it is not their function: `0x001` is a rate selector in the
chip-ID page, `0x314` is CDC clock power, `0x30d` is a reconstruction-clock
gate. What they have in common is that all three are **MCLK-domain on a codec
that has never had an MCLK**. Every register that accepts writes is either
analog-page or RCO-domain.

That replaces three separate puzzles with one hypothesis.

**Two things this does not establish.** It cannot separate "needs a live MCLK"
from "read-only on this part or revision" -- both predict the refusal seen. And
**the restore path is still unexercised**: the abort happened before the clock
block was touched, so the recovery guarantee remains untested on hardware.

### A gate defect the run exposed

The retry of `0x314`/`0x30d` was gated on `cdc_alive` alone. The switch aborted
without touching the clock block, so the codec was still on RCO -- and because
`cdc_alive` is computed live from three registers that were therefore
untouched, it read 1 and **the retry ran anyway**, reproducing the ordinary RCO
baseline. The evidence file filed that under "the retry, run only against a
responding CDC block", which is exactly the label that would later be misread
as an MCLK result.

It now requires that the switch actually completed as well. A retry on RCO is
the baseline, not the experiment.

## 10a. r169 RESULT: THE CLOCK ARRIVES. THE REGISTERS STILL REFUSE.

**M2', 25/0, VERDICT PASS.** pkgrel 169, `clksrc-rc2`, artefact verified 75/0.
Evidence: [wcd9320-clk-source-20260826T210612Z.txt](wcd9320-clk-source-20260826T210612Z.txt).

### 1. A CLOCK PHYSICALLY REACHES THE CODEC'S MCLK PIN

This is the finding, and it closes a question open since r166.

```
clk-src rco-shutdown step 3/3: reg 0x1fa old=c6 mask=80 want=00 -> read=46  OK
   [RC_OSC_FREQ: RC oscillator OFF -- no warm fallback past this row]
clk-src mclk-tail step 1/5: reg 0x108 old=00 mask=0c want=04 -> read=04  OK
   [CLK_BUFF_EN1: source = external, reference = VBG]
clk-src: positive control 0x2b4 = 78, 0x370 = 30, 0x373 = 37  after the switch
clk-src: SWITCHED to MCLK, CDC block RESPONDING (a clock is arriving)
```

The RC oscillator was **disabled and chip-verified off** -- `0x1fa` read back
`46`, bit 7 clear -- and `CLK_BUFF_EN1` bit 3 was clear with the external source
selected. The CDC digital block then kept answering with its POR contents.

A digital core cannot run without a clock. There was no RC oscillator. So the
external MCLK is real, and **PM8941 gpio15 does reach the WCD9320 MCLK pad on
RM-940**. That was the one thing no amount of PMIC-side verification could
establish, and the codec has now established it by acting as its own clock
detector.

It is still not a waveform. Nothing here measures 9.6 MHz, only that *a* usable
clock arrives.

### 2. THE MCLK-DOMAIN HYPOTHESIS IS REFUTED

r168 proposed that `0x001`, `0x314` and `0x30d[1]` refuse because all three are
MCLK-domain registers on a codec with no MCLK. **That is now disproven by
measurement.** With the codec running from the external clock, with the RC
oscillator off and the CDC block demonstrably alive:

| register | on RCO | on MCLK |
|---|---|---|
| `0x314` CDC_CLK_POWER_CTL | refused | **refused** |
| `0x30d[1]` RDAC clock enable | refused | **refused** |
| `0x001` CHIP_CTL rate bits | refused | **refused** |

```
clk-src: 0x001 mask 06 want 02 : 00 -> 00  REFUSED  [rate 9.6 MHz, retried ON MCLK]
```

Being on MCLK is not the unlock for any of the three. The clock hypothesis for
these registers is exhausted, and the next question is not about the clock.

One constraint that survives and narrows it: **this is not a page-level lock.**
`0x311` CDC_CLK_MCLK_CTL sits in the same neighbourhood as `0x30d` and `0x314`
and accepts writes throughout -- it reads `01` in every run.

### 3. THE RESTORE IS PROVEN ON HARDWARE

r168 never reached it. r169 exercised it three times, identically:

```
clk-src block-off (restore): all 3 steps applied cleanly
clk-src rco-restore: all 11 steps applied cleanly
clk-src: RESTORED to RCO, CDC block RESPONDING
```

The RCO restart, the 10 ms settle, the shared tail -- the slice of
`wcd9320_rco_wake[]` -- all behave exactly as the table does at boot. The codec
survives losing its clock entirely and being brought back, with the positive
control intact either side. Nothing else moved: PA at `80` throughout, DAC
never powered, `0x314`/`0x30d` back at POR, divider restored, mclk released,
zero new kernel warnings.

### 4. TWO CHECKER FAULTS, BOTH FOUND BEFORE THEY WERE BELIEVED

The hardware behaved identically in all three invocations on that boot. Only
the checking differed, and both faults were verified by hand against dmesg
before anything was changed.

**The gate script on the phone was stale.** The r169 driver ran against the
**r168** evidence script, because the script was edited in the repo and never
redeployed. It reported a spurious FAIL on a check that no longer exists
(`rate declared 9.6 MHz`) and never displayed the CHIP_CTL probe result at all.
The deploy step now checksums the phone's copy against the repo's and refuses
on a mismatch.

**`check_sequence_complete()` double-counts across runs.** dmesg is cumulative,
so the second run on one boot counted 6 block-off step lines against a summary
claiming 3, 10 mclk-tail against 5, and 22 rco-restore against 11 -- three
failures on sequences that had all applied perfectly. The shared lib already
has `DMESG_MARKER` for exactly this; this gate simply never set one. It now
uses the driver's `clk-src: CHIP_CTL measured` line, logged once per switch
immediately before the first sequence, so the assertions see one run.

Both are the pattern this branch has hit repeatedly: **when a checker reports
failures, verify one by hand before acting on the batch.**

## 10b. r169 AS DESIGNED

pkgrel 169, `clksrc-rc2`.

One change from r168, and it inverts the ordering:

| | r168 | r169 |
|---|---|---|
| CHIP_CTL before the switch | **written**, fatal on refusal | measured only |
| the switch | gated on that write | unconditional |
| CHIP_CTL after the switch | never reached | **probed**, non-fatal |
| CHIP_CTL restore | after returning to RCO | **before** leaving MCLK |

`wcd9320_chip_ctl_probe()` is a measurement in the same sense as
`wcd9320_rdac_probe()`: it always succeeds as an operation and records whether
the bits stuck, because "the experiment ran and the answer was no" must stay
distinguishable from "the experiment failed to run". It drops the register from
the cache on a refusal, which `rdac_probe` gets away with not doing only
because it always writes its bit back.

**The restore order is the finding applied to itself.** If `0x001` is writable
only while an MCLK is present, a restore attempted after switching back to RCO
would be refused and would leave the codec declaring a rate it is not
receiving. So it goes back in the same clock state it was changed in, and
non-fatally -- getting the codec onto a working clock matters more than a rate
field, and a teardown must not be blockable.

This means the switch now runs with `CHIP_CTL` declaring 12.288 MHz against a
9.6 MHz input. That is no longer a choice between two options: the part will
not let the rate be declared beforehand, so it is the only configuration the
hardware permits.

Three outcomes, all informative:

- **CHIP_CTL latches on MCLK** -- the MCLK-domain hypothesis is confirmed, a
  clock is arriving, and the rate can then be declared properly.
- **CHIP_CTL still refuses, positive control intact** -- the clock arrived
  (the core kept running with the RC oscillator off) but these registers are
  locked for some other reason. `0x001` is then not in the same class as the
  other two after all.
- **positive control goes dark** -- no clock at the pin. The M5 answer, which
  is what r168 set out to get.

### Gate expectations that moved

| | r168 | r169 | why |
|---|---|---|---|
| `0x001` direct write sites | 2 | **1** | one site in `chip_ctl_probe()`, reached for both the attempt and the restore |
| `read_bypassed_calls` | 54 | **56** | +2 for `chip_ctl_probe` reading 0x001 either side of its write |

The source-to-artefact offset noted at r168 is now **corroborated at exactly
2** in both builds: r167 had 34 source call sites against 32 counted, r168 had
49 against 47, and 54 passed on the artefact. So the rule is
`expectation = (source call sites in core.c) - 2 + 7`, and r168 also settled
the question it left open -- `wcd9320_clk_read_control` did **not** inline.

## 10c. r168 AS BUILT (superseded, kept for the record)

pkgrel 168, `clksrc-rc1`.

### The driver

`wcd9320_clk_source_switch(wcd, to_mclk)` in `wcd9320-core.c`, driven from two
new sysfs files on the control function:

```
echo mclk > clk_source_test      steps 2-5
echo rco  > clk_source_test      steps 7-8
cat clk_source_state             the positive control and every clock register
```

Every register transition goes through `wcd9320_run_sequence()` as a
`wcd9320_wake_step` table, which is the machinery `core_init` has always used:
bypassed read, write, delay, bypassed readback, abort on the first mismatch,
and a parent-IRQ check between steps. Four tables:

| table | rows | what |
|---|---|---|
| `wcd9320_clk_block_off[]` | 3 | step A, **both** directions |
| `wcd9320_clk_mclk_desel[]` | 1 | stop selecting RCO |
| `wcd9320_clk_rco_shutdown[]` | 3 | `enable_config_mode(0)`, taken conditionally |
| `wcd9320_clk_mclk_tail[]` | 5 | external source, buffer, CDC gate |

Two of those are not new work, and that is deliberate:

- `wcd9320_clk_block_off[]` is the first three rows of `wcd9320_rco_sleep[]`
  verbatim.
- **the MCLK -> RCO restore is not a table at all.** Phase B of
  `wcd9320_rco_wake[]` *is* `enable_clock_block(1)` -- `enable_config_mode(1)`
  plus the shared tail -- so the restore runs a slice of that proven table,
  `&wcd9320_rco_wake[4]` onwards, rather than a hand-written copy. There is no
  second place for the two to drift apart, and the slice's start is checked at
  runtime against `RC_OSC_FREQ` so index drift cannot silently repoint it.

The `if (RC_OSC_FREQ & 0x80)` branch is a read-then-branch in C around the
tables, because a step table cannot express one and inventing an unconditional
version would be reversing the enable path by hand.

**The teardown runs from a failure label, not from the success path.** Any
abort after the first sequence write re-enters the function in the restore
direction. Two corrections were needed to make that real:

- the PA guard was originally a hard precondition on **both** directions. A
  tripped guard would then have refused the restore and stranded the codec
  without a clock. It refuses outbound and only observes inbound: recovery must
  not be blockable by a safety check.
- the driver's own `clk_src_mclk` flag is forced true before the restore is
  entered from an abort, because the clock block is part-way through a
  transition whatever the driver believes.

### The gate

`tools/wcd9320-clk-source-evidence.sh`. Exit codes carry the finding:

| exit | finding | meaning |
|---|---|---|
| 0 | **M4** | switched, control intact, `0x314`/`0x30d` accepted |
| 1 | **M2'** | switched, control intact, still refused -- a real negative |
| 2 | **M5** | control read `00`: the CDC block went dark, no clock arriving |
| 3 | **S** | setup, path, or switch failure -- no conclusion |

Step 6 is **conditional on step 5**: the retry does not run against a dark CDC
block, because two `00` reads that mean nothing would otherwise be reported as
a result. The positive control must also hold its POR values *before* the
switch or the run aborts as INVALID -- that is the instrument's calibration,
and an uncalibrated instrument makes the run void rather than inconclusive.

The compander and the RX1 chain are deliberately **not** brought up, unlike the
r167 harness. Both move registers in the control set, and r165 established by
measurement that neither affects whether these two registers latch.

### A DEFECT FOUND IN THE ARTEFACT GATE, AND A CLAIM IT WEAKENS

`wcd9320-verify-artifact.py` asserted that `0x1ab`, `0x001` and `0x108` had
zero write sites by looking for `update_bits` or `regmap_write` on the same
line as the symbol. That misses **both** mechanisms this driver actually uses:

- `wcd9320_c2b_write()`, the chip-verified helper through which every C2b write
  is made. **A `c2b_write` to the PA would have passed the guard silently.**
- a `wcd9320_wake_step` table row, `{ REG, mask, val, delay, ... }`, through
  which every clock-sequence write is made.

So the r166/r167 statement that *"the artefact gate proves the driver has zero
write sites for `0x108`"* -- in the r167 evidence script's own header, and
repeated in `wcd9320-mclk-mapping.md` -- was true only of direct calls and
vacuous about the tables. `wcd9320_rco_wake[]` and `wcd9320_rco_sleep[]` were
writing `0x108` throughout.

**This does not disturb r167's M2 result.** What mattered there was that the
codec remained RCO-selected, and that was *measured* on the chip after the vote
transition (`source=RCO`), not inferred from the gate. The overclaim is in how
the guarantee was described, not in the finding.

The check now counts both forms, separately, and pins numbers rather than
asserting absence:

| register | direct | table rows | why |
|---|---|---|---|
| `0x1ab` PA | 0 | 0 | the milestone is defined by it staying off |
| `0x001` CHIP_CTL | **2** | 0 | set and restored, both inside the switch |
| `0x108` CLK_BUFF_EN1 | 0 | **7** | 3 pre-existing, 4 for the switch; never a direct write |

### One expectation that may need a second look after the build

`read_bypassed_calls` goes 39 -> 54: +15 source call sites (1 in
`wcd9320_clk_read_control`, 3 in the switch, 11 in `clk_source_state_show`).
That assumes `clk_read_control` survives as a real function, giving one
relocation for its three callers; if the compiler inlines it the count is 56.
A reported 56 is that compiler decision and **not** a defect.

Separately, the existing comment's arithmetic was already carrying an
unexplained offset: it enumerates 32 call sites in `wcd9320-core.c` where the
file has 34 (it omits one in `rx1_digital_state_show` and one in
`hphl_dac_test_store`), yet 39 was confirmed against the r167 artefact. So the
artefact carries two fewer relocations than the source has call sites and why
is not established. Recorded so the next delta is not computed from the source
alone and found to be two out.

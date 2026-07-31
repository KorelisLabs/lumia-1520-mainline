# WCD9320 interrupt topology — desk port

Deliverable for the `wcd9320-irq-parent-mapped` milestone. Desk work plus
read-only device state; no interrupt has been requested and no register
written.

Sources: `drivers/mfd/wcd9xxx-irq.c`, `drivers/mfd/wcd9xxx-core.c`,
`include/linux/mfd/wcd9xxx/core.h` and `sound/soc/codecs/wcd9320.c` from
`LineageOS/android_kernel_lge_hammerhead` (`cm-11.0`); the Lumia's own DSDT;
and the silicon dump in `wcd9320-register-map.md`.

## 1. Register block

Four bytes per function, `WCD9XXX_A_INTR_*`, all outside the dark CDC region
and all confirmed at their documented reset values on this device:

| addr | register | `__POR` | this device |
|---|---|---|---|
| `0x090` | `INTR_MODE` | `00` | `00` |
| `0x094`–`0x097` | `INTR_MASK0-3` | `ff ff 3f 3f` | `ff ff 3f 3f` |
| `0x098`–`0x09b` | `INTR_STATUS0-3` | `00` | `00` |
| `0x09c`–`0x09f` | `INTR_CLEAR0-3` | `00` | `00` |
| `0x0a0`–`0x0a2` | `INTR_LEVEL0-2` | `01 00 00` | `01 00 00` |

`0x091`–`0x093` are undocumented and read `0x00`.

Bit addressing is `BIT_BYTE(n) = n / 8`, `BYTE_BIT_MASK(n) = 1 << (n % 8)` —
IRQ *n* is bit *n mod 8* of register *n div 8*.

## 2. Polarity and clear semantics

**Mask: 1 = masked, 0 = enabled.** From `wcd9xxx-irq.c`:

```c
/* unmask */ wcd9xxx->irq_masks_cur[BIT_BYTE(irq)] &= ~(BYTE_BIT_MASK(irq));
/* mask   */ wcd9xxx->irq_masks_cur[BIT_BYTE(irq)] |=   BYTE_BIT_MASK(irq);
```

Worth stating explicitly because it inverts the intuitive reading of the
register name, and because it makes the reset value dangerous — see §3.

**Acknowledgement is a write of a 1 to `INTR_CLEAR`, per bit:**

```c
wcd9xxx_reg_write(wcd9xxx, WCD9XXX_A_INTR_CLEAR0 + BIT_BYTE(irqbit),
                  BYTE_BIT_MASK(irqbit));
```

and at the end of the thread, a bulk write of `0xff` to all four:

```c
memset(status, 0xff, num_irq_regs);
wcd9xxx_bulk_write(wcd9xxx, WCD9XXX_A_INTR_CLEAR0, num_irq_regs, status);
```

So **reading `INTR_STATUS` has no side effect** — `precious_reg` is empty for
this block — and `INTR_CLEAR0-3` are write-only, which
`taiko_reg_readable[]` independently confirms by excluding exactly those four
addresses (`wcd9320-register-map.md` §2a).

**Status is read as a bulk read** of `INTR_STATUS0` for `num_irq_regs` bytes,
then masked in software against `irq_masks_cur` before dispatch. The hardware
status register is not pre-masked.

**`INTR_LEVEL` is per-source level-vs-edge.** Downstream sets
`irq_level_high[0] = true` with the comment that all other sources are edge
triggered, then writes the packed array to `INTR_LEVEL0-2`. That yields
`INTR_LEVEL0 = 0x01`, which is exactly what this device reads. So source 0
(`SLIMBUS`) is level-high and the other 30 are edge.

## 3. The reset state does not mask everything

`MASK2` and `MASK3` reset to `0x3f`, not `0xff`. With 1 = masked, bits 6 and 7
of both registers are **unmasked at reset**. Mapping them to §4:

| register | bit | IRQ | source | at reset |
|---|---|---|---|---|
| `MASK2` | 6 | 22 | `WCD9XXX_IRQ_RESERVED_0` | unmasked |
| `MASK2` | 7 | 23 | `WCD9XXX_IRQ_RESERVED_1` | unmasked |
| `MASK3` | 6 | 30 | `WCD9XXX_IRQ_VBAT_MONITOR_RELEASE` | **unmasked** |
| `MASK3` | 7 | 31 | — (beyond `TAIKO_NUM_IRQS`) | unmasked |

The two reserved sources are presumably inert. `VBAT_MONITOR_RELEASE` is a
real source. **The first hardware image must therefore write the mask
registers explicitly rather than rely on the reset state**, which is the one
concrete safety consequence of this whole document.

Downstream does exactly that, and its loop is worth copying precisely.
`wcd9xxx_irq_init()` iterates `i` over `0 .. num_irqs-1` setting every bit,
then writes the four bytes. With `TAIKO_NUM_IRQS = 31` the loop covers bits
0–30, producing:

```
MASK0 = 0xff   MASK1 = 0xff   MASK2 = 0xff   MASK3 = 0x7f
```

Note `MASK3 = 0x7f`, not `0xff`: bit 7 is IRQ 31, which does not exist, so the
loop never sets it. Copying `0xff` there would be masking a non-existent
source — harmless, but it would be a divergence from downstream introduced by
carelessness rather than by decision, so `0x7f` it is.

## 4. Child sources — 31 of them

From the `core.h` enum, with `TAIKO_NUM_IRQS = WCD9XXX_NUM_IRQS = 31`. The
"needs CDC" column is the one that matters for sequencing: those sources
cannot be exercised while `0x200`–`0x3bf` is unreachable.

| IRQ | reg.bit | source | domain | needs CDC |
|---|---|---|---|---|
| 0 | 0.0 | `SLIMBUS` | bus | no |
| 1 | 0.1 | `MBHC_REMOVAL` | MBHC | no |
| 2 | 0.2 | `MBHC_SHORT_TERM` | MBHC | no |
| 3 | 0.3 | `MBHC_PRESS` | MBHC | no |
| 4 | 0.4 | `MBHC_RELEASE` | MBHC | no |
| 5 | 0.5 | `MBHC_POTENTIAL` | MBHC | no |
| 6 | 0.6 | `MBHC_INSERTION` | MBHC | no |
| 7 | 0.7 | `BG_PRECHARGE` | analog bias | no |
| 8–12 | 1.0–1.4 | `PA1..PA5_STARTUP` | analog PA | no |
| 13–15 | 1.5–1.7 | `MICBIAS1..3_PRECHARGE` | analog | no |
| 16 | 2.0 | `HPH_PA_OCPL_FAULT` | analog OCP | no |
| 17 | 2.1 | `HPH_PA_OCPR_FAULT` | analog OCP | no |
| 18 | 2.2 | `EAR_PA_OCPL_FAULT` | analog OCP | no |
| 19 | 2.3 | `HPH_L_PA_STARTUP` | analog PA | no |
| 20 | 2.4 | `HPH_R_PA_STARTUP` | analog PA | no |
| 21 | 2.5 | `WCD9320_IRQ_EAR_PA_STARTUP` | analog PA | no |
| 22 | 2.6 | `RESERVED_0` | — | — |
| 23 | 2.7 | `RESERVED_1` | — | — |
| 24 | 3.0 | `MAD_AUDIO` | CDC MAD | **yes** |
| 25 | 3.1 | `MAD_BEACON` | CDC MAD | **yes** |
| 26 | 3.2 | `MAD_ULTRASOUND` | CDC MAD | **yes** |
| 27 | 3.3 | `SPEAKER_CLIPPING` | CDC clip det | **yes** |
| 28 | 3.4 | `WCD9320_IRQ_MBHC_JACK_SWITCH` | MBHC | no |
| 29 | 3.5 | `VBAT_MONITOR_ATTACK` | CDC VBAT | **yes** |
| 30 | 3.6 | `VBAT_MONITOR_RELEASE` | CDC VBAT | **yes** |

The "needs CDC" assignments follow the register blocks each source is
configured through, all of which fall inside `0x200`–`0x3bf`: MAD at
`0x3e0`–`0x3eb`, speaker clip detect at `TAIKO_A_CDC_SPKR_CLIPDET_VAL0-7`, and
VBAT at `0x2e8`–`0x2f8`. Every one of those read `0x00` in the dump.

MBHC is the useful observation in the other direction: sources 1–6 and 28 are
configured through `0x3c0`–`0x3ff`, which reads its documented defaults and
sits outside the dark region. **The MBHC block is reachable now.** That makes
an MBHC source the natural candidate for the eventual single-source test,
without needing the digital core first.

Note the enum aliases `WCD9306_IRQ_MBHC_JACK_SWITCH = WCD9320_IRQ_EAR_PA_STARTUP`
(both 21) — different parts, same bit. Taiko uses bit 21 as `EAR_PA_STARTUP`
and has its own jack switch at 28. Copying the wrong one would silently wire a
jack detect to a PA startup bit.

## 5. Where this belongs in the driver

`wcd9xxx-core.c` settles it. In `wcd9xxx_device_init()`:

```
line 480:  ret = wcd9xxx_irq_init(wcd9xxx);
line 487:  ret = mfd_add_devices(wcd9xxx->dev, -1, found->dev, found->size, ...);
```

The interrupt controller is brought up **before** the codec children are
created. So IRQ handling belongs in the permanent codec core — our
`drivers/slimbus/wcd9320-core.c` — and not in the future ASoC component. This
matches how the children then request nested IRQs from a controller that
already exists.

## 6. TLMM 72 — a candidate parent, not a proven one

The Lumia's DSDT declares exactly one audio-related GPIO interrupt:

```
Device (MBHC)            /* \_SB.ADSP.SLM1.ADCM.AUDD.MBHC */
    GpioInt (Edge, ActiveHigh, Exclusive, PullDown, 0x0000, "\\_SB.GIO0", ...)
        { 0x0048 }       /* pin 72 */
```

**Measured trigger type: edge, active high, pull-down, exclusive.** In DT
terms `IRQ_TYPE_EDGE_RISING` with `bias-pull-down`.

Two things about this deserve to be flagged rather than smoothed over.

**It disagrees with downstream.** `wcd9xxx_irq_init()` requests the parent
line as:

```c
request_threaded_irq(wcd9xxx->irq, NULL, wcd9xxx_irq_thread,
                     IRQF_TRIGGER_HIGH | IRQF_ONESHOT, "wcd9xxx", wcd9xxx);
```

`IRQF_TRIGGER_HIGH` is level, the Lumia's DSDT says edge. Both can be
correct for their own board, because the codec's aggregated output behaviour
depends on how `INTR_MODE` and `INTR_LEVEL0-2` are programmed, and hammerhead
and the Lumia need not have programmed them the same way. The instruction for
the first image is to use *the measured DSDT type*, so edge/active-high is
what goes in DT — but the disagreement is real and should be watched: an edge
request against a level-asserting source is a classic way to produce either a
missed interrupt or a storm, which is precisely what the first image is
designed to detect.

**"MBHC" in the DSDT does not settle shared-versus-narrow.** The label and the
`Exclusive` flag both point at the narrow reading. Against that: pin 72 is the
*only* audio-related `GpioInt` anywhere in the tables. `AUDD`, the codec device
proper, has a `_CRS` with no `GpioInt` at all. Every other `GpioInt` in the
DSDT belongs to something unrelated (`TSC1` 61, `SDC2` 62, `DISP` 12, `PMPB`
216–218, `BTN0`, `PWIO`, `UAR2` 5). So if the codec's aggregated interrupt
output is wired to the AP at all, this is the only pin it can be on.

That is an argument from absence of alternatives, not proof. It is consistent
with the shared reading and does not establish it. The Lumia still has to prove
it, and the first image is what does that.

## 7. First hardware image — scope

Read-only in every respect that matters. No CDC-core write, no MCLK write, no
source unmasked.

1. Describe TLMM 72 in DT as an input with the measured type
   (`IRQ_TYPE_EDGE_RISING`, `bias-pull-down`).
2. Request it in the core driver as a threaded IRQ.
3. Explicitly write `MASK0-3 = ff ff ff 7f` — do not trust the reset state
   (§3).
4. On each parent assertion, read and log `INTR_STATUS0-3`, `INTR_MASK0-3`
   and `INTR_MODE`. Acknowledge by writing `INTR_CLEAR0-3`.
5. Confirm: no storm; no unexpected pending bits; suspend/resume stable;
   ADSP, NGD, PGD and IFD all healthy afterwards; no write outside the
   interrupt block.

Step 4 is the only place this image writes anything, and it writes only
`INTR_MASK0-3` and `INTR_CLEAR0-3` — both outside the dark region, both with
semantics established in §2, and neither touching a clock, a reset, or an
analog path.

The expected result is *silence*: with everything masked, the parent line
should never assert. An assertion would itself be informative — it would mean
either that the line is shared with something else, or that a source asserts
despite being masked.

Checkpoint on success: **`wcd9320-irq-parent-mapped`**. That names what it
proves — parent-line plumbing and idle behaviour.

**Not** `wcd9320-irq-proven`. That waits until one controlled physical source
is safely unmasked and produces the expected status bit, parent IRQ, nested
dispatch and clear sequence. On the evidence in §4, that source should come
from the MBHC block, which is reachable now, rather than from anything behind
the CDC sentinel.

## 8. `volatile_reg`, from `taiko_volatile()`

Recorded here because it is the same desk pass. `wcd9320.c` supplies a real
callback, and these are its rules verbatim in effect:

| rule | addresses |
|---|---|
| all top-level registers | `reg < 0x100` |
| everything from `CDC_MBHC_EN_CTL` up | `reg >= 0x3c0` |
| IIR coefficient registers | `0x34a`–`0x35b` |
| ANC1 filter registers | `0x202`–`0x207` |
| ANC2 filter registers | `0x282`–`0x287` |
| digital gain registers | `RX1-7_VOL_CTL_B2_CTL`, `TX1-10_VOL_CTL_GAIN` |
| headphone status | `0x1b3`, `0x1b9` |
| jack insert status | `0x14b` |
| speaker clip detect values | `SPKR_CLIPDET_VAL0-7` |
| VBAT gain monitor value | `CDC_VBAT_GAIN_MON_VAL` |
| anything in `audio_reg_cfg[]` | runtime MAD configuration |

Three of these are directly corroborated by the dump: `0x14b`, `0x1b3` and
`0x1b9` are the three status registers outside the dark block that read
something other than their `__POR` (`0e`, `04`, `04`).

The `reg < 0x100` rule is the broadest and its stated reason is that top-level
registers "can be written by the Taiko core driver" behind the ASoC layer's
back — a cache-coherence concern, not a hardware volatility claim. It is
adopted anyway: for a mainline driver with `REGCACHE_NONE` it changes nothing
today, and it is the safe direction when caching is eventually enabled.

The last rule cannot be evaluated statically, since `audio_reg_cfg[]` is
populated at runtime from MAD configuration. It is noted as an open item and
does not block the IRQ work.

# WCD9320 MCLK path on the Lumia 1520 — investigation

> **Read this first (added 2026-08-01).** Everything below remains factually
> correct, but its *significance* has shrunk considerably.
>
> This investigation was motivated by the `0x200`–`0x3bf` region reading
> all-zero, on the assumption that a missing clock was the likely cause. That
> assumption was wrong. The block was held in reset because this port had
> never run `wcd9xxx_bring_up()`, the codec's digital-core release. Once that
> ran, the block became fully accessible on the codec's **on-die RC
> oscillator**, with no external clock of any kind — 87 of 87 registers, 71
> at their documented defaults.
>
> So: the external MCLK route is still unresolved, and this document is still
> the record of that. But it is **not** a blocker for register access, and it
> was never the reason the digital core was unreachable. The PM8941 pad
> sweeps in sections 6 and 7 were sound work aimed at a question that turned
> out not to be the one blocking progress.
>
> MCLK becomes relevant again only when an actual audio path needs an
> accurate reference; RCO is a low-accuracy oscillator that downstream uses
> for MBHC and idle, switching to MCLK for streams.
> See `wcd9320-cdc-rco-wake-2026-08-01.log`.

Deliverable for the `wcd9320-mclk-path-mapped` milestone. No codec writes.
The question: where does the codec's 9.6 MHz reference clock come from on
*this* device, and does Linux control it?

## 1. The Lumia's own ACPI tables do not describe a codec MCLK

Searched `mmcblk0p24:/ACPI/dsdt.aml` (decompiled) for every plausible name:

| Term | Hits |
|---|---|
| `CDC_MCLK` | 0 |
| `MCLK` | 4 — **all camera** (`camss_mclk0_clk`, `camss_mclk2_clk`) |
| `9600000` | 0 |
| `CLKDIV`, `OSR_CLK`, `osr_clk`, `0xCE0028` | 0 |

The ADSP ACPI subtree contains no clock resource at all. So Windows does not
route a codec MCLK through an AP-visible ACPI clock description.

This is a **negative result, not a gap in the search**: the camera MCLKs *are*
described, with explicit `"CLOCK"` packages naming `camss_mclk0_clk` and a
rate of `0x00927C00` (9.6 MHz, as it happens — for the camera). If Nokia had
described a codec MCLK the same way, it would have been found by the same
grep. It is not there.

The reasonable reading is that the codec MCLK is arranged by the ADSP, which
already owns the SLIMbus manager and the LPASS clock tree on this SoC. That
is consistent with everything else established about this device, but it is
an inference and is not yet proven.

## 2. What the DSDT *does* name

RPM resource identifiers are present, including the divider clocks:

```
PPP_RESOURCE_ID_CXO_BUFFERS_DIVCLK1_A
PPP_RESOURCE_ID_DIV_CLK_1_A
PPP_RESOURCE_ID_DIV_CLK_2_A
PPP_RESOURCE_ID_DIV_CLK_3_A
```

So the RPM divider-clock resources exist on this platform. Nothing ties one
of them to the codec.

## 3. Live Linux clock state

From `/sys/kernel/debug/clk/clk_summary` on the running device, with both
codec SLIMbus functions bound:

| Clock | Rate | Enabled | Consumers |
|---|---|---|---|
| `xo_board` | 19 200 000 | Y | 6 (remoteproc, both mmc) |
| `div_clk1_a` | 19 200 000 | Y | **0**, `deviceless` |
| `div_clk2`, `div_clk2_a` | 19 200 000 | Y | **0**, `deviceless` |
| `camss_mclk0..3_clk` | 19 200 000 | N | 0 |

**Nothing in the entire clock tree runs at 9 600 000 Hz.** The RPM divider
clocks exist and are enabled, but sit at the XO rate with no consumers and no
connection id — they are present because the RPM clock driver models them,
not because anything requested them.

PM8941 GPIO 15 exists in pinctrl (`pin 14 (gpio15)` under
`pm8941@0:gpio@c000`) but its `pinconf-pins` entry is empty: **the pin is not
claimed or configured by Linux**, and nothing indicates whether Windows left
it as a clock output.

## 4. The finding that matters most

**The codec is fully responsive over SLIMbus with no 9.6 MHz MCLK present.**
Immediately after all of the above, both functions still read correctly:

```
217:a0:1:0  major 0x0102 minor 0x0001 version 0x00 laddr 0xcb
217:a0:0:0  interface function: no chip id, laddr 0xca
```

That is expected once stated plainly: SLIMbus register access is clocked by
the bus itself, not by the codec's MCLK. MCLK feeds the codec's internal
audio clock block — which is exactly what `taiko_mclk_enable()` switches on,
and why that function cannot create the reference signal.

So MCLK is **not** a prerequisite for register access, identity, enumeration
or any milestone proven so far. It becomes a prerequisite the moment audio
paths are configured.

## 5. Where this leaves the milestone

`wcd9320-mclk-path-mapped` is **not** achievable from the evidence gathered
here, and should not be claimed. What is established:

- the Lumia's ACPI tables do not describe a codec MCLK
- the RPM divider clocks exist but are unrequested and at XO rate
- no 9.6 MHz exists anywhere in Linux's view of this hardware
- PM8941 GPIO 15 is unclaimed and unconfigured
- register access does not need MCLK, so nothing already proven is at risk

What is **not** established:

- whether the Lumia even routes MCLK through PM8941 GPIO 15. The
  reference-design match for reset (TLMM 63) and MBHC (TLMM 72) does not
  license assuming this third pin.
- whether the ADSP supplies the codec MCLK autonomously, which would mean the
  AP should not drive it at all
- whether `div_clk1` can be programmed to 9.6 MHz through the mainline
  `rpmcc` driver on msm8974

The cheapest next evidence is probably not more source reading. Reading
PM8941 GPIO 15's actual register configuration over SPMI while Windows'
firmware state is still resident would show whether that pin is set up as a
clock output on this board — a direct answer to the question the reference
design cannot settle.

Until then, no MCLK code should be written, and `TAIKO_A_CHIP_CTL` stays
unwritten.

---

## 6. PM8941 GPIO 15–18: no DIV_CLK routing in the inherited state

On PM8941, alternate function 1 on GPIOs 15–18 is `DIV_CLK` and function 2 is
the sleep clock. Reference boards commonly use GPIO 15 for codec MCLK, so all
four capable pins were read rather than only the reference one.

Read-only, via the `pmic-spmi` regmap at `/sys/kernel/debug/regmap/0-00`
(sid 0 = pm8941). Note `dd` seeking does not work on that debugfs file and
unimplemented addresses print as `XX`; the block below was obtained by a
single sequential pass and matched on address string, and `0x0100`–`0x0107`
returning real revision values confirms reads succeed generally.

| Pin | base | `+0x04` type | `+0x05` subtype | `+0x40` mode | `+0x42` pull | `+0x45` out | `+0x46` en |
|---|---|---|---|---|---|---|---|
| GPIO 15 | `0xce00` | `10` | `05` | `00` | `04` | `01` | `80` |
| GPIO 16 | `0xcf00` | `10` | `05` | `00` | `04` | `01` | `80` |
| GPIO 17 | `0xd000` | `10` | `05` | `00` | `04` | `01` | `80` |
| GPIO 18 | `0xd100` | `10` | `05` | `00` | `04` | `01` | `80` |

Mode `0x00` decodes as direction = input, function select = 0 = normal GPIO.
**Not** function 1 (`DIV_CLK`), **not** function 2 (sleep clock). The
`type = 0x10, subtype = 0x05` fields confirm these are GPIO peripheral blocks,
so the reads landed on the intended registers.

Linux's pinctrl reports no configuration for any of them
(`pinconf-pins` entries are empty), consistent with nothing in the device tree
claiming them.

### What this does and does not establish

**Establishes:** the PM8941 reference route for codec MCLK is not active on
this device in its current state. The assumption that Nokia followed the
reference design for this pin — reasonable given reset (TLMM 63) and MBHC
(TLMM 72) both matched — is not supported for GPIO 15, nor for any of the
other three DIV_CLK-capable pins.

**Does not establish:** that the route is absent from the board. This is the
*current inherited* PMIC state, not pristine Windows state. Two readings
remain open:

- Nokia routed MCLK somewhere else entirely, or the ADSP supplies it
- the route exists on one of these pins but is demuxed while idle, since no
  audio session is running and Windows is not booted

Distinguishing those requires observing the pin state across an actual audio
clock request, which cannot be done until something can make that request.
That is circular for now, and worth naming as such rather than papering over.

### Consequence

`wcd9320-mclk-path-mapped` is not achieved and is not claimed. The
reference-design assumption is removed, which is the useful outcome: no MCLK
code should be written against GPIO 15 on the strength of hammerhead.

Nothing already proven depends on this. Register access, identity,
enumeration and both bus functions all work with no MCLK present, because
SLIMbus messaging is clocked by the bus rather than by the codec's reference
clock.

---

## 7. Full PM8941 pad sweep — one bounded pass, no clock-function pin

Section 6 covered only the four DIV_CLK-capable pins. Since a negative there
does not exclude a route elsewhere, every PM8941 GPIO and MPP was swept once,
read-only, from a single sequential capture of the SPMI regmap.

Scope: GPIOs 1–36 (`0xc000` + n·`0x100`) and MPPs 1–8 (`0xa000` + n·`0x100`).
Per pad: type (`+0x04`), subtype (`+0x05`), mode/function select (`+0x40`),
output-source select (`+0x44`), output config (`+0x45`), enable (`+0x46`).
The goal was not to decode every pad's purpose — only to find a positive
clock candidate.

### GPIOs

All 36 blocks read `type = 0x10`, so every read landed on a real GPIO
peripheral. **Function select is 0 (normal GPIO) on all 36 pins.** No pin is
in function 1 (`DIV_CLK`) or function 2 (sleep clock).

Thirty-one pads are idle inputs (`mode = 0x00`). Five are configured as
outputs:

| Pin | base | `+0x40` mode | direction | func sel | `+0x44` out-src | `+0x45` out cfg |
|---|---|---|---|---|---|---|
| GPIO 8 | `0xc700` | `10` | out | 0 | `00` | `03` |
| GPIO 19 | `0xd200` | `11` | out | 0 | `00` | `02` |
| GPIO 21 | `0xd400` | `21` | in/out | 0 | `00` | `01` |
| GPIO 23 | `0xd600` | `11` | out | 0 | `00` | `03` |
| GPIO 24 | `0xd700` | `11` | out | 0 | `00` | `03` |

The output-source select is `0x00` on all five — and on all 36 pins. That
field is what selects an alternate driver for the pad; a clock output would
show up either there or as a non-zero function select. Both are zero
everywhere, so these five are ordinary data-register-driven outputs.

### MPPs

All eight blocks read `type = 0x11`, confirming real MPP peripherals.

| MPP | base | subtype | `+0x40` mode | `+0x46` en |
|---|---|---|---|---|
| MPP 1 | `0xa000` | `05` | `51` | `80` |
| MPP 2–8 | `0xa100`–`0xa700` | `03`/`05` | `00` | `00` |

Only MPP 1 is enabled; mode `0x51` decodes to direction field 5 = current
sink, which is an LED or haptic drive, not a clock. MPPs 2–8 are disabled
outright. The PM8941 MPP block has no clock alternate function in any case.

### Result

**No active PM8941 GPIO or MPP clock output was observed in the current idle
inherited state.**

Stated as narrowly as the evidence allows. This does **not** establish that
MCLK is absent from the board, and it does **not** establish that the ADSP
generates it. It closes one search: the PMIC pad complement, in this state,
is not sourcing a codec reference clock, so no further PMIC pin hunting is
warranted without new information.

MCLK is therefore deferred rather than resolved. It is not a prerequisite for
register classification, IRQ mapping, or ASoC component structure, all of
which proceed without it.

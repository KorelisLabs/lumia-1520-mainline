# Why `0x30d[1]` and `0x314` refuse: a source-generation and mechanism audit

**Status:** sections 0–8 are the audit, 2026-08-28, research only — no register
was written and the driver was left untouched at the time, so the deployed r169
artefact and the staged patch stayed in agreement. **Section 9 is r170**, which
acts on it: the address is fixed, and the build is staged at pkgrel 170.

Prerequisite: [wcd9320-rco-mclk-switch-mapping.md](wcd9320-rco-mclk-switch-mapping.md)
section 10a. **The MCLK branch is closed** and nothing here reopens it.

---

## 0. THE HEADLINE, BEFORE ANYTHING ELSE

**`WCD9320_A_CHIP_CTL` is defined as `0x001` in our driver. The real CHIP_CTL
is `0x000`. `0x001` is `CHIP_STATUS`.**

r168 and r169 were therefore writing a *status* register and reporting its
refusal as a silicon finding. Two consequences:

1. **There are two refusing registers, not three.** `0x001` never belonged in
   the set. The "three MCLK-domain registers" grouping that r168 proposed was
   built partly on this error.
2. **The 9.6 MHz rate declaration has never actually been attempted**, in any
   build. Every claim that "CHIP_CTL refuses" is void.

This does **not** disturb the r169 MCLK result. `0x30d` and `0x314` were
correctly addressed throughout, and the finding that a clock physically reaches
the codec rests on the RC oscillator being off and the CDC block still
answering — neither of which involves `0x001`.

### The evidence, three ways

**Downstream, across three independent source generations:**

| tree | `WCD9XXX_A_CHIP_CTL` | `WCD9XXX_A_CHIP_STATUS` |
|---|---|---|
| hammerhead `cm-11.0` | `0x00` | `0x01` |
| hammerhead `cm-12.1` | `0x00` | `0x01` |
| sony msm8974 `cm-14.1` | `0x00` | `0x01` |

The address never changed. This is **not** a generational difference; it is a
transcription error on our side. `wcd9320_registers.h` only aliases
`TAIKO_A_CHIP_CTL` to `WCD9XXX_A_CHIP_CTL`, so the number lives in the common
header alone, which is where the two got separated.

**Our own silicon**, live low dump, `0x000`–`0x01f`:

```
08 00 00 00 01 00 02 01 20 00 00 00 77 66 55 00 ...
^0x000                  ^0x008
```

- `0x004`–`0x007` = `01 00 02 01` → id_minor `0x0001`, id_major `0x0102`, which
  matches the identity the driver reports independently.
- `0x008` = `0x20` = `WCD9XXX_A_CHIP_VERSION__POR` exactly.
- `0x00c`–`0x00e` = `77 66 55` = the three SLAVE_ID registers.

The block decodes correctly **only** with CHIP_CTL at `0x000`. And `0x000` reads
`0x08`, not `0x00`.

**Scope of the defect.** It is one hand-written constant. The generated regmap
tables are unaffected: `wcd9320-regmap-derive.py` parses the numeric
`WCD9XXX_A_*` defines, so `readable`/`volatile`/`defaults` all carry `0x000`
correctly. Our regmap already treats `0x000` as readable and volatile, matching
downstream's "everything below `0x100` is volatile" rule, so nothing in the
regmap obstructs writing it.

**What `0x000` currently holds.** `0x08`, against a POR of `0x00`. Bits `[2:1]`
= `0b00`, which declares **12.288 MHz**. Bit 3 is set by something and is not
explained by the header; that matters for how the write is made — see 7.1.

---

## 1. The live silicon revision, established from the chip

Asked for first because it was the obvious suspect. It is a dead end, and the
elimination is clean.

`wcd9xxx_check_codec_type()` reads `CHIP_ID_BYTE_0..3` and matches
`wcd9xxx_codecs[]`. Our part reports **id_major `0x0102` = `TAIKO_MAJOR`,
id_minor `0x0001`**, which selects:

```c
{ TAIKO_MAJOR, cpu_to_le16(0x1), taiko_devs,
  ARRAY_SIZE(taiko_devs), TAIKO_NUM_IRQS, 2,   /* .version = 2 */
  WCD9XXX_SLIM_SLAVE_ADDR_TYPE_TAIKO, 0x01 },
```

`.version = 2`, and the version comes from the **table**, not the chip: the
core only falls back to `CHIP_VERSION & 0x1F` when `d->version == -1`, which is
not our row. With `TAIKO_VERSION_1_0 = 1`, `TAIKO_IS_1_0(2)` is **false**.

> **The part is Taiko 2.0.** Downstream would apply `taiko_2_0_reg_defaults[]`.

This corrects a loose end in
[taiko-revision-2026-07-30.log](taiko-revision-2026-07-30.log), which recorded
`CHIP_VERSION` reading `0x00` at r116 where the r142 full map and today's live
dump both read `0x20`. `CHIP_VERSION` takes no part in Taiko identification
either way, so the identification stands; the r116 read was taken before the
core was fully up.

**Why the revision does not explain the refusals.** Neither register is
revision-conditional anywhere:

- `TAIKO_A_CDC_CLK_POWER_CTL` has **exactly one** reference in the whole codec
  driver — the common `taiko_reg_defaults[]` entry. It is in neither the 1.0
  nor the 2.0 table.
- `TAIKO_A_CDC_CLK_RDAC_CLK_EN_CTL` appears only in `taiko_hphl_dac_event()`
  and `taiko_hphr_dac_event()`, unconditionally in both.

The `taiko_2_0_reg_defaults[]` comment — *"Don't update TAIKO_A_CHIP_CTL,
TAIKO_A_BUCK_CTRL_CCL_1 and TAIKO_A_RX_EAR_CMBUFF as those are updated in
taiko_reg_defaults"* — confirms CHIP_CTL is deliberately in the **common**
table, applied to both revisions.

---

## 2. Downstream is structurally blind to this failure mode

This is the most important derived fact after section 0, because it removes an
argument that has been implicitly load-bearing: *"downstream works on
hammerhead, so these registers must be writable."*

```c
static int taiko_volatile(struct snd_soc_codec *ssc, unsigned int reg)
{
	if ((reg >= TAIKO_A_CDC_MBHC_EN_CTL) || (reg < 0x100))
		return 1;
	...
```

`0x30d` and `0x314` are in neither range, so both are **non-volatile**, and:

```c
static unsigned int taiko_read(struct snd_soc_codec *codec, unsigned int reg)
{
	if (!taiko_volatile(codec, reg) && taiko_readable(codec, reg) && ...) {
		ret = snd_soc_cache_read(codec, reg, &val);
		if (ret >= 0)
			return val;          /* the CACHE, never the chip */
	}
	...
```

So every `snd_soc_update_bits()` on these two registers is a **cache**
read-modify-write followed by an unconditional chip write. **Downstream never
reads either register back from silicon, on any board.** It cannot tell a write
that landed from one that was ignored.

> Downstream working elsewhere is therefore not evidence that `0x30d` or
> `0x314` read back anywhere. Our port sees this only because every write is
> verified with `regmap_read_bypassed()`.

Against that, downstream's own `taiko_reg_readable[]` marks both as
**readable = 1**. Only four registers in the entire 0x400 map are marked
write-only: `TAIKO_A_INTR_CLEAR0..3` (`0x09c`–`0x09f`). So downstream *intends*
these to be readable — it just never checks.

---

## 3. The probe path before the first write, and what we already match

Traced through `drivers/mfd/wcd9xxx-core.c` and `wcd9320.c`:

| # | step | our port |
|---|---|---|
| 1 | regulators, `wcd9xxx_reset()` — 20 ms low, 20 ms settle | **matches** |
| 2 | `wcd9xxx_bring_up()` | **matches byte for byte** |
| 3 | `wcd9xxx_check_codec_type()` — chip id read | matches |
| 4 | SLIMbus PGD + interface function, logical address | matches; IFD has its own regmap |
| 5 | IRQ init | matches |
| 6 | `taiko_codec_probe()` → resmgr init, MBHC init | partial: no resmgr, fixed sequence instead |
| 7 | `taiko_update_reg_defaults()` — **first write to `0x000` and `0x314`** | **never done** |
| 8 | `CHIP_CTL[2:1]` by MCLK rate | **never done, wrong address** |
| 9 | `taiko_codec_init_reg()` | not done |

Step 2 is worth stating precisely because it is the only reset-domain candidate
and it is **eliminated by measurement**:

```c
wcd9xxx_reg_write(wcd9xxx, WCD9XXX_A_LEAKAGE_CTL, 0x4);
wcd9xxx_reg_write(wcd9xxx, WCD9XXX_A_CDC_CTL, 0);
usleep_range(5000, 5000);
wcd9xxx_reg_write(wcd9xxx, WCD9XXX_A_CDC_CTL, 3);
wcd9xxx_reg_write(wcd9xxx, WCD9XXX_A_LEAKAGE_CTL, 3);
```

Our `wcd9320_bring_up_seq[]` is identical, and the **live chip confirms it
landed**: `0x080` (CDC_CTL) reads `03` and `0x088` (LEAKAGE_CTL) reads `03`,
against PORs of `0x00` and `0x04`. The digital core is out of reset.

---

## 4. Mechanisms searched for, and not found

| mechanism | result |
|---|---|
| write-protect / unlock / lock register | **none exists** anywhere in `0x000`–`0x3ff` in any generation |
| secure / test / config mode gate | none; the only `*_TEST_*` registers are per-block analog test enables |
| QFUSE dependency | downstream **never touches** `QFUSE_CTL`/`QFUSE_STATUS`; ours read `00`/`00` |
| reset-held domain | eliminated: `CDC_CTL = 3` measured on the chip |
| shadow / aliased register | no alias for `0x30d` or `0x314` in any generation |
| revision-dependent address or POR | addresses and PORs identical across all three generations |
| alternate SLIMbus function ownership | the IFD register map ends at `0x1b0`; neither register is in it |
| power-domain dependency | no downstream regulator or power call is ordered against either write |

`0x30d`, `0x314` and `0x311` all carry POR `0x00` in
`taiko_reset_reg_defaults[]`, matching our regmap and our silicon.

---

## 5. The structural grouping, sharpened

Measured on our part, all within one 21-register block:

| register | | result |
|---|---|---|
| `0x309` CLK_OTHR_RESET_B2_CTL | | accepts, reads back |
| `0x30d` CLK_RDAC_CLK_EN_CTL | | **REFUSES** |
| `0x30f` CLK_RX_B1_CTL | | accepts, reads back |
| `0x310` CLK_RX_B2_CTL | | accepts, reads back |
| `0x311` CLK_MCLK_CTL | | accepts, reads back `01` |
| `0x314` CLK_POWER_CTL | | **REFUSES** |

Eliminated as groupings: same page (`0x311` accepts), clock domain (r169),
silicon revision (section 1), reset domain (section 3), write-protect
(section 4).

**What the two refusing registers uniquely share, from the source:**

- Downstream writes `CHIP_CTL = 0x02` and `CDC_CLK_POWER_CTL = 0x03` as the
  **first two entries of `taiko_reg_defaults[]`, adjacent, under one comment**:

  ```c
  static const struct wcd9xxx_reg_mask_val taiko_reg_defaults[] = {
  	/* set MCLk to 9.6 */
  	TAIKO_REG_VAL(TAIKO_A_CHIP_CTL, 0x02),
  	TAIKO_REG_VAL(TAIKO_A_CDC_CLK_POWER_CTL, 0x03),
  ```

  applied by `taiko_update_reg_defaults()` with `snd_soc_write()` — **full-byte
  writes**, not masked ones. Nothing else in the driver writes either register.

- `0x30d` is the RDAC — reconstruction DAC — clock enable, the only register in
  the block that gates a clock into the **analog** output path rather than
  within the digital core. `0x311`, which accepts, gates the MCLK into the CDC
  block and is written by the resmgr, never by the codec driver.

So the sharpest available grouping is not positional. It is: **the two
registers that carry the codec's MCLK-rate-dependent clock configuration, whose
declared rate we have never set.**

---

## 6. Ranked candidate mechanisms

### H1 — `CDC_CLK_POWER_CTL` depends on the rate declaration in the real `CHIP_CTL`
**Support: direct, from downstream source. Strongest by a distance.**

They are paired in the source, adjacent, in that order, under one comment,
written nowhere else, with `CHIP_CTL` first. We have never written the real
`CHIP_CTL` — section 0 — so this precondition has never been satisfied in any
build, and every previous run that concluded otherwise was writing
`CHIP_STATUS`. It also costs nothing to test: no MCLK, no PMIC, no DAC, no PA.

### H2 — `0x30d[1]` is interlocked with the analog RDAC/DAC power state
**Support: moderate, circumstantial.**

`0x30d` is the only register in the block gating a clock into the analog path,
and C2b sets it at DAPM `PRE_PMU` — *before* `0x1b1` powers the DAC. Downstream
does the same, but per section 2 never reads it back, so downstream's ordering
is evidence for neither side. Would explain `0x30d` and not `0x314`.

### H3 — both are write-only / read-as-zero on this silicon
**Support: weak, but not dismissible.**

Section 2 shows downstream could not have noticed if they were. Against it:
`taiko_reg_readable[]` marks both readable, and only `INTR_CLEAR0..3` are
write-only. If true, C2b has been stopping on a verification artefact rather
than a hardware failure — which is why it stays on the list despite the weak
support.

### H4 — silicon revision
**Support: none. Eliminated in section 1.**

### H5 — write-protect, secure mode, QFUSE, reset domain, aliasing
**Support: none. Eliminated in sections 3 and 4.**

---

## 7. The smallest falsifiable experiment, for H1

Two register writes on the RC oscillator, both reversible, nothing else
touched.

```
0. fix the constant:  WCD9320_A_CHIP_CTL  0x001 -> 0x000
1. read   0x000                    expect 08 (not 00 -- bit 3 is set)
2. write  0x000 [2:1] <- 0x2       the 9.6 MHz declaration, chip-verified
3. retry  0x314 <- 0x03            the register under test
4. retry  0x30d[1] <- 1            the second register under test
5. restore 0x314, 0x30d, then 0x000 to its measured value
```

**Falsifies H1** if `0x314` still refuses with `0x000[2:1]` verified at `0x2` on
the chip.
**Confirms H1** if `0x314` latches.
**Partially confirms** if `0x314` latches and `0x30d[1]` does not, which would
promote H2 for `0x30d` alone.

### 7.1 The one design decision it carries

Downstream writes `CHIP_CTL` as a **full byte** (`snd_soc_write(reg, 0x02)`),
which would clear the bit 3 our part currently has set. Our port's convention
is masked writes, which would preserve it.

Do the masked write first — `0x06 <- 0x02` — and record whether `0x314` then
latches. Only if it does not, and only as a separate step, try the full `0x02`
downstream actually issues. Bit 3 of `CHIP_CTL` is not described in any header
we hold, so clearing it is an unknown and should not be bundled into the same
measurement.

### 7.2 Guards

`0x000` is readable and volatile in our regmap, so `regmap_update_bits()` does
a chip read-modify-write with no cache involvement and no obstruction. The PA
guard and the positive control (`0x2b4`/`0x370`/`0x373`) apply unchanged. No
PMIC access, no clock-source switch, no DAC, no PA.

---

## 8. What was deliberately NOT done DURING THE AUDIT

The driver source was not modified while sections 0-8 were written, so the
deployed r169 artefact and the staged r169 patch kept corresponding -- this
project's build discipline treats that correspondence as what makes a run
interpretable. No register was written, no build was made, and no PMIC or MCLK
change was considered.

The fix moved to r170, which is section 9.

---

## 9. r170 AS BUILT

**Status: STAGED, NOT YET BUILT.** pkgrel 170, `chipctl-rc1`. **RCO only** — no
PMIC, no gpio15, no MCLK selection, no DAC, no PA.

### The fix, made permanent

```c
#define WCD9320_A_CHIP_CTL      0x000   /* the rate declaration */
#define WCD9320_A_CHIP_STATUS   0x001   /* READ ONLY, never written */
```

The artefact gate now **asserts both addresses in source**, so the
transcription cannot recur silently, and pins the write sites:

| register | direct | table | meaning |
|---|---|---|---|
| `0x000` CHIP_CTL | **1** | 0 | one site, `wcd9320_chip_ctl_probe()`, used to set and to restore |
| `0x001` CHIP_STATUS | **0** | 0 | a status register; read in the state readers, never written |
| `0x1ab` PA | 0 | 0 | unchanged |
| `0x108` clock source | 0 | 7 | unchanged |

### The chain the run tests

Downstream's own order, reproduced for the first time:

```
1. read    0x000                baseline, must have rate bits clear
2. write   0x000 mask 06 <- 02  the 9.6 MHz declaration, chip-verified
3. write   0x314 <- 03          immediately, as taiko_reg_defaults[] does
4. write   0x30d[1]             under the FULL C2b prerequisite state
5. teardown in dependency order: 0x30d, then 0x314, then 0x000 last
```

**The prediction is `0x0a`, not `0x02`.** This part reads `0x08` at CHIP_CTL
against a POR of `0x00`, so bit 3 is set by something no header we hold
describes. The write is **masked** (`0x06 <- 0x02`) and preserves it;
downstream's full-byte `snd_soc_write(0x02)` would clear it, and changing an
unexplained bit in the same act as the rate field would make a positive `0x314`
result unattributable. If the masked write proves insufficient, the full byte
is a separate build.

The expectation is **derived from the measured baseline** in both the driver
and the gate — `(baseline & ~0x06) | 0x02` — and the two are cross-checked
against each other, rather than either hardcoding `0x0a`. A part presenting a
different bit 3 is then still verified correctly instead of failing a constant.

### Why step 4 is not a naked probe

r164's negative on `0x30d[1]` was obtained with RX1, the compander, the DSM
mux, RX bias and class-H all established. A refusal measured in any other state
would not be comparable with it. So r170 re-establishes that state and retries
there — using a new `prereq-on` verb that runs C2b stages 3 to 6 and **stops**,
leaving `0x1b1` untouched. The DAC is a separate milestone.

Step 4 runs only if `0x314` latched: the C2b path already refuses up front when
`0x314` does not read `0x03`, which is the correct behaviour and makes the
dependency explicit rather than implicit.

### Four outcomes, and the exit code for each

| exit | finding | meaning |
|---|---|---|
| 4 | **R1** | CHIP_CTL refuses at the correct address — a real result about the top-level control register, and the first one this project has had. Stop. |
| 1 | **R2** | CHIP_CTL latches, `0x314` still refuses — downstream's adjacency is not sufficient; `0x314` has another prerequisite, and it is neither the clock (r169) nor the rate (r170). Candidate 1 refuted, candidate 3 promoted. |
| 2 | **R3** | Both latch, `0x30d` still refuses under the full C2b state — the general clock-configuration problem is solved and the RDAC has its own condition. Candidate 2 is then the one to test. |
| 0 | **R4** | All three latch — the blocker that stopped C2b at stage 6 of 7 is very probably gone, and its cause was a single incorrect register constant. |

### What r170 does NOT do

Power `0x1b1`. Touch the PA. Touch the PMIC. Select MCLK. Reopen anything the
r169 freeze closed.

---

## 10. r170 RESULT: CHIP_CTL WRITES. `0x314` STILL REFUSES.

**R2, 15/0, VERDICT PASS.** Artefact verified 79/0 first. Evidence:
[wcd9320-chip-ctl-20260826T215943Z.txt](wcd9320-chip-ctl-20260826T215943Z.txt).

```
chip-ctl: 0x000 measured 08 before any write (rate field 00)
chip-ctl: 0x000 mask 06 want 02 : 08 -> 0a (predicted 0a)  LATCHED
c2b:      0x314 mask 03 want 03 -> chip 00
c2b:      0x314 did not take on the chip
chip-ctl: 0x000 mask 06 want 00 : 0a -> 08 (predicted 08)  LATCHED  [restored]
```

### 1. The top-level control register is writable

`0x000` went `08 -> 0a` and back, chip-verified both ways, with the unexplained
bit 3 preserved exactly as the masked write was designed to. The driver and the
gate derived the prediction `0a` independently and agreed.

So **there is no access problem at CHIP_CTL**, and the 9.6 MHz rate can be
declared. That outcome — R1, "CHIP_CTL refuses at the correct address" — is
eliminated, and with it the possibility that the top-level register was itself
gated. Five builds of "CHIP_CTL refuses" were entirely an artefact of writing
`0x001`.

### 2. And it changes nothing for `0x314`

`0x314 <- 03` read back `00` immediately after the declaration, exactly as it
did immediately before it in the same run. The register was retried under
identical conditions either side of the only variable, which is as clean as
this harness gets.

Because `0x314` never latched, step 3 did not run: the C2b path refuses when
`0x314` does not read `0x03`, so `0x30d` was not retried and **r170 says
nothing new about the RDAC clock**.

### 3. What is refuted, stated more precisely than the gate did

The gate's finding text says "candidate 1 is refuted". That is right as far as
it goes, but the precise claim is narrower and the difference matters:

> **Refuted:** the rate declaration *alone*, with the codec on its RC
> oscillator, unlocks `0x314`.

Downstream's adjacency and ordering are therefore not a sufficient explanation.
The two registers sit together in `taiko_reg_defaults[]` because they belong to
one initialisation step, not because the first unlocks the second.

### 4. THE GAP THIS OPENS, which is the honest headline

| run | MCLK present | MCLK selected | rate declared | `0x314` |
|---|---|---|---|---|
| r165 | no | no | no | refused |
| r167 | yes, at the pad | no | no | refused |
| r169 | yes | **yes** | no | refused |
| r170 | no | no | **yes** | refused |
| — | yes | **yes** | **yes** | **NEVER TESTED** |

Every run so far has moved one of the two halves. **The conjunction is
untested, and it is exactly the state downstream is in**: MCLK running at
9.6 MHz *and* `CHIP_CTL` declaring 9.6 MHz, before `taiko_reg_defaults[]`
writes `0x314`.

There is a physical reading that makes the conjunction more than bookkeeping.
Declaring 9.6 MHz while the codec runs from its RC oscillator is an
*inconsistent* configuration — the RCO is not that clock. A register that
powers a clock tree may reasonably refuse when the declared rate and the actual
source disagree. r169 supplied the source without the declaration; r170 the
declaration without the source.

This is **not** grounds to reopen the MCLK investigation. The MCLK questions
are answered and stay answered. It is a proposal to *use* the MCLK switch —
built, proven, and reversible three times over — as a precondition for a
different question.

### 5. Candidate 3 is now the strongest single-register hypothesis

That `0x314` and `0x30d` are write-only or read-as-zero on this silicon, and
downstream cannot tell because `taiko_read()` returns the ASoC cache for both
(section 2). If true, C2b has been stopping on a verification artefact rather
than a hardware failure.

It needs an **observable**, not a readback. One cheap discriminator has not
been tried: every write this project has made to these two registers used a
narrow mask — `0x03` for `0x314`, bit 1 for `0x30d`. Nobody has established
whether *any* bit of either register is writable. A bit-walk would separate
"the register does not accept writes at all" from "these specific bits are
gated", which are very different findings and currently indistinguishable.

### 6. Nothing else moved

PA `80` throughout, guard never tripped, DAC never powered (`0x1b1 = 00`),
`0x30d` at POR, `0x314` at POR, `CHIP_CTL` restored to `08`, no new kernel
warnings, 15 checks passed and 0 failed.

---

## 11. THE WRITE-SITE MAPPING FOR `0x314` AND `0x30d`

Recorded before r171 was designed, so the experiment tests documented bits and
nothing else. Enumerated across **every cached downstream file and three
independent source generations** — hammerhead `cm-11.0`, hammerhead `cm-12.1`,
sony msm8974 `cm-14.1`. The three agree exactly; nothing about either register
changed between generations.

Files searched and found to contain **no** write site for either register:
`wcd9xxx-common.c` (class-H), `wcd9xxx-resmgr.c`, `drivers/mfd/wcd9xxx-core.c`,
`sound/soc/msm/msm8974.c`, the clock drivers. Both registers are written from
the codec driver and nowhere else.

### `0x314` CDC_CLK_POWER_CTL — exactly ONE write site

```c
static const struct wcd9xxx_reg_mask_val taiko_reg_defaults[] = {
	/* set MCLk to 9.6 */
	TAIKO_REG_VAL(TAIKO_A_CHIP_CTL, 0x02),
	TAIKO_REG_VAL(TAIKO_A_CDC_CLK_POWER_CTL, 0x03),
```

```c
#define TAIKO_REG_VAL(reg, val)   {reg, 0, val}     /* mask field is 0 */

static void taiko_update_reg_defaults(struct snd_soc_codec *codec)
{
	for (i = 0; i < ARRAY_SIZE(taiko_reg_defaults); i++)
		snd_soc_write(codec, taiko_reg_defaults[i].reg,
			      taiko_reg_defaults[i].val);
```

| | |
|---|---|
| sites | **1**, in all three generations |
| mechanism | `snd_soc_write()` — a **full-byte** write, not a masked update |
| value | `0x03`, only ever this value |
| bits exercised | **0 and 1**, and only ever together |
| bits never written | 2–7. Undefined to us. |
| when | once at probe, inside `taiko_update_reg_defaults()` |

The `mask` field of the table entry is `0` and is **not used on this path** —
`taiko_update_reg_defaults()` calls `snd_soc_write()`, which ignores it. So
downstream never performs a masked update of `0x314` at all.

**A simplification that follows, and it matters for r171.** Our baseline for
`0x314` is `0x00`. A masked `0x03 <- 0x03` therefore computes
`(0x00 & ~0x03) | 0x03 = 0x03` and puts **the identical byte on the wire** as
downstream's full write of `0x03`. The two are indistinguishable at this
baseline, so r171 needs no separate full-byte step, and the combined case is a
faithful reproduction of the only write downstream ever makes.

### `0x30d` CDC_CLK_RDAC_CLK_EN_CTL — exactly FOUR write sites

All four are in the two DAC events, unconditional in both, identical across all
three generations:

```c
taiko_hphl_dac_event()   PRE_PMU  : update_bits(0x30d, 0x02, 0x02)
                         POST_PMD : update_bits(0x30d, 0x02, 0x00)
taiko_hphr_dac_event()   PRE_PMU  : update_bits(0x30d, 0x04, 0x04)
                         POST_PMD : update_bits(0x30d, 0x04, 0x00)
```

| bit | mask | meaning | our history |
|---|---|---|---|
| 1 | `0x02` | **HPHL** RDAC clock enable | written many times, always refused |
| 2 | `0x04` | **HPHR** RDAC clock enable | **never written by this project** |
| 0, 3–7 | — | never written by downstream | undefined to us |

| | |
|---|---|
| mechanism | `snd_soc_update_bits()` — masked, always |
| granularity | one bit at a time; downstream never writes both together |

**Bit 2 is the interesting one.** It is the exact structural twin of bit 1 —
same register, same mechanism, same event shape, different channel — and this
project has never touched it. If bit 2 latches where bit 1 does not, that is a
per-path result and a very sharp one. Writing both together is diagnostic only
and is labelled as such: downstream never does it.

### What r171 may therefore test

| register | mask | rationale |
|---|---|---|
| `0x314` | `0x01` | bit 0, documented, tested alone as a diagnostic |
| `0x314` | `0x02` | bit 1, documented, tested alone as a diagnostic |
| `0x314` | `0x03` | the production value, byte-identical to downstream's full write |
| `0x30d` | `0x02` | bit 1, HPHL — downstream's own mask |
| `0x30d` | `0x04` | bit 2, HPHR — downstream's own mask, never tried here |
| `0x30d` | `0x06` | both, diagnostic only |

**Nothing else.** Bits 2–7 of `0x314` and bits 0 and 3–7 of `0x30d` are not
written by downstream in any generation, are undefined to us, and are not
touched. No blind bit-walk.

---

## 12. r171 AS BUILT

**Status: STAGED, NOT YET BUILT.** pkgrel 171, `writability-rc1`.
**Diagnostic, not the C2b production sequence.**

RCO only: no PMIC divider, no gpio15, no source switch, no DAC power, no PA.
`CHIP_CTL` stays at its baseline — this run is about writability, not rate
configuration.

### The six steps

Each is a masked write, a bypassed chip readback, and an immediate restore, so
no two steps compound. Only bits from the section 11 mapping are touched.

| # | reg | mask | kind |
|---|---|---|---|
| 0 | `0x314` | `0x01` | bit 0 alone — diagnostic |
| 1 | `0x314` | `0x02` | bit 1 alone — diagnostic |
| 2 | `0x314` | `0x03` | **production**, byte-identical to downstream's full write |
| 3 | `0x30d` | `0x02` | **production**, HPHL RDAC clock |
| 4 | `0x30d` | `0x04` | **production**, HPHR RDAC clock — never tried here before |
| 5 | `0x30d` | `0x06` | both — diagnostic, downstream never does this |

`wcd9320_probe_bits()` generalises the CHIP_CTL probe: attempt, bypassed
readback, record, **drop the poisoned regcache entry on a refusal**, and always
return the measurement rather than an error. A refusal is the result here, so
an `-EIO` would destroy what the run exists to report.

**The two registers are independent.** Nothing aborts early — a refusal on
`0x314` cannot prevent the `0x30d` characterisation. The PA guard is sampled
after every step.

### Why bit 2 of `0x30d` is the one to watch

It is the exact structural twin of bit 1 — same register, same mechanism, same
event shape, different channel — and this project has never written it. If bit
2 latches where bit 1 does not, the condition is **per-path**, not
per-register, and that is the sharpest result the run can produce.

### Classification, with precedence

| exit | | condition |
|---|---|---|
| 1 | **W0** | nothing latches — a register or domain-level condition, not a functional gate on any particular bit |
| 0 | **W4** | `0x314 <- 03` and `0x30d` bit 1 both latch — writability is fine and the earlier refusals depend on surrounding sequence or state |
| 4 | **W3** | individual bits latch, the combined value does not — a combination or in-register sequencing interaction |
| 2 | **W1/W2** | some documented bits latch and others do not — per-bit, or for `0x30d` per-path, gating |
| 3 | **S** | setup failure, or any failed check |

### Deliberately not tested

The **MCLK-selected + rate-declared conjunction**. It is preserved as the next
experiment if this result leaves it relevant, and r170's conclusion stays
narrow: the rate declaration *alone*, on RCO, does not unlock `0x314`. That is
not generalised to the conjunction by this run or by any other.

---

## 13. r171 RESULT: W0 — NOTHING LATCHES, IN EITHER REGISTER

**W0, 12/0, VERDICT PASS.** Artefact verified 79/0 first. Evidence:
[wcd9320-writability-20260826T231758Z.txt](wcd9320-writability-20260826T231758Z.txt).

```
baseline  0x314 = 00   0x30d = 00     CHIP_CTL 0x000 = 08 (untouched)

  0x314 bit 0   mask 01  -> read 00   REFUSED   diagnostic
  0x314 bit 1   mask 02  -> read 00   REFUSED   diagnostic
  0x314 bits01  mask 03  -> read 00   REFUSED   PRODUCTION
  0x30d bit 1   mask 02  -> read 00   REFUSED   PRODUCTION (HPHL)
  0x30d bit 2   mask 04  -> read 00   REFUSED   PRODUCTION (HPHR)
  0x30d bits12  mask 06  -> read 00   REFUSED   diagnostic
```

Six independent attempts, every one a bit downstream actually writes, and not
one held.

### What this eliminates

| | |
|---|---|
| **per-bit gating** | eliminated — `0x314` bits 0 and 1 behave identically |
| **per-path gating** | eliminated — `0x30d` bit 2 (HPHR), never written by this project before, refuses **identically** to bit 1 (HPHL) |
| **combination effects** | eliminated — the combined values behave exactly as the individual ones |

Whatever refuses does not distinguish between the clock-power bits and the RDAC
clock bits, or between the left and right channels. It is a **whole-register**
condition on both registers, and both are in the same condition.

That kills W1, W2 and W3 outright, and it kills the reading that `0x30d` had
"its own remaining condition" separate from `0x314` — audit candidate 2 as
originally framed. The two registers behave as one phenomenon.

### What it does NOT settle

**Write-only versus refused.** Both produce exactly this pattern. r171 was
always going to be blind to that distinction, and it is: telling them apart
needs an **observable**, not a readback.

### It is also not an address-block condition

Within the same 21-register block, `0x309`, `0x30f`, `0x310` and `0x311` all
accept writes and read back. So "the CDC clock block refuses" is false. It is
these two registers specifically, entirely, regardless of which documented bits
are attempted.

### A candidate observable, found while reading around the result

`TAIKO_A_RX_HPH_L_STATUS` (**`0x1b3`**) and `TAIKO_A_RX_HPH_R_STATUS`
(**`0x1b9`**) are status registers for the two headphone paths, and downstream
marks **both volatile** — `taiko_volatile()` names them explicitly at line
4106 — so downstream reads them from the chip rather than from its cache.

On our part both currently read **`0x04`** against a POR of `0x00`. Something
is already asserted in them.

That makes them a candidate discriminator for the write-only hypothesis, and a
cheap one: `0x30d` bit 1 is the **HPHL** RDAC clock and bit 2 is **HPHR**, so
the two are independently addressable against two independent status registers.
If `0x1b3` moves when bit 1 is written while `0x30d` itself still reads `00`,
the write is landing and the register is write-only. No DAC, no PA, no MCLK.

**Stated as a candidate, not a conclusion.** Bit 2 of those status registers is
not described in any header we hold, and it may reflect something unrelated to
the RDAC clock — an OCP or comparator state, for instance. The asymmetry is
what makes it worth trying: a *left*-channel write moving only the *left*
status register would be hard to explain any other way.

### Where this leaves the hypothesis space

1. **The conjunction** — MCLK selected *and* rate declared. W0 makes this more
   attractive rather than less: a whole-register condition affecting two
   clock-related registers identically is what a clock-domain prerequisite
   would look like. Still untested, still the only cell of the matrix left.
2. **Write-only / read-as-zero** — undiminished by r171, and now with a
   candidate observable that needs neither the DAC nor the PA.

Both are live. Nothing else is.

---

## 14. WHAT THE HPH STATUS REGISTERS ACTUALLY MEAN

Searched before r172 was designed, across every cached file and every
generation: `wcd9320.c` (cm-11.0), `gen2-wcd9320.c` (cm-12.1),
`gen3-wcd9320.c` (sony cm-14.1), `wcd9320-tables.c`, `wcd9xxx-mbhc.c`,
`wcd9xxx-common.c`, `wcd9xxx-resmgr.c`, `wcd9xxx-slimslave.c`, the MFD core,
the machine driver, and all four register headers.

### Addresses and PORs, identical everywhere

| register | address | POR | ours reads |
|---|---|---|---|
| `RX_HPH_L_STATUS` | `0x1b3` | `0x00` | `0x04` |
| `RX_HPH_R_STATUS` | `0x1b9` | `0x00` | `0x04` |

### Every reference, and what it is

1. **`taiko_volatile()`**, in all three codec generations, identically:

   ```c
   /* HPH status registers */
   if (reg == TAIKO_A_RX_HPH_L_STATUS || reg == TAIKO_A_RX_HPH_R_STATUS)
   	return 1;
   ```

   A cache-policy statement only. It establishes that downstream reads them
   from the chip, and nothing about what the bits mean.

2. **`taiko_reg_readable[]` and `taiko_reset_reg_defaults[]`** — table entries,
   readable = 1, POR = `0x00`. No semantics.

3. **`wcd9xxx_hphl_status()` in `wcd9xxx-mbhc.c` — the ONLY functional read
   anywhere**, and it is not what we hoped:

   ```c
   hph = snd_soc_read(codec, WCD9XXX_A_MBHC_HPH);
   snd_soc_update_bits(codec, WCD9XXX_A_MBHC_HPH, 0x12, 0x02);   /* stimulus */
   usleep_range(WCD9XXX_HPHL_STATUS_READY_WAIT_US, ... );         /* 1 ms     */
   status = snd_soc_read(codec, WCD9XXX_A_RX_HPH_L_STATUS);
   snd_soc_write(codec, WCD9XXX_A_MBHC_HPH, hph);
   ```

   It is called from `wcd9xxx_find_plug_type()`. **`L_STATUS` is an MBHC
   plug-detection comparator output**, meaningful only while `MBHC_HPH`
   (`0x1fe`) bit 1 is asserted, and read 1 ms after that stimulus.

### The conclusion, recorded as required

> **No semantic interpretation of these bits as an RDAC-clock acknowledgement
> exists in any generation.** Downstream never uses them that way, and the one
> use it does have points somewhere else entirely — jack detection.

This **weakens the observable** relative to the hope that prompted it, and it
should be said plainly before the run rather than after: **S0 is now the
expected outcome, not a surprise.** The evidence boundary already set for r172
therefore holds with room to spare —

- a reproducible **channel-specific** response is strong positive evidence;
- **no response is not evidence** that the `0x30d` write failed;
- and the existing `0x04` baseline is **not** to be interpreted.

### One detail carried into the design

Downstream waits **1 ms** (`WCD9XXX_HPHL_STATUS_READY_WAIT_US = 1000`) between
the stimulus and the status read. r172 carries that settle, derived from the
source rather than guessed, so a real but slow response is not missed.

r172 deliberately does **not** apply the `MBHC_HPH` stimulus. Doing so would
make the register meaningful in its *own* documented sense, which is a
different experiment, and it would touch the MBHC path this run has no reason
to disturb.

---

## 15. r172 AS BUILT

**Status: STAGED, NOT YET BUILT.** pkgrel 172, `hphstatus-rc1`. RCO only: no
MCLK, no DAC, no PA. **`0x314` takes no part in this run.**

### The sequence, per channel and per cycle

```
sample   0x30d, 0x1b3 L_STATUS, 0x1b9 R_STATUS      before
write    0x30d bit 1 (HPHL)  -- or bit 2 (HPHR)
settle   1 ms                                        downstream's own
sample   all three again      <-- BEFORE RESTORING, inside the driver
record   whether the bit latched; drop the poisoned cache entry if not
restore  the bit
settle   1 ms
sample   all three again                             after
```

Both channels, then **the whole thing again as a second cycle**. A response
that is not reproducible is not a response, and one cycle cannot tell the
difference.

**The middle sample is the experiment**, and it is taken inside the driver
between the write and the restore. A shell-side read after the restore would
be looking at a codec already put back, which is exactly how an observable
like this gets missed.

### The 1 ms settle is derived, not invented

`WCD9XXX_HPHL_STATUS_READY_WAIT_US` is `1000`, and `wcd9xxx_hphl_status()`
waits that long between its stimulus and its read. A real but slow response
would otherwise be missed. `MBHC_HPH` is deliberately **not** asserted -- see
section 14.

### Classification

| exit | | condition |
|---|---|---|
| 0 | **S1** | the stimulus moves its **own** status register in **both** cycles and never the other channel's, while `0x30d` still reads `00` |
| 1 | **S0** | neither status responds -- **INCONCLUSIVE, not a refusal** |
| 2 | **SX** | movement is coupled, cross-channel, or differs between cycles -- observable rejected |
| 3 | **S** | setup failure or a failed check |

### What each outcome does next

- **S1 -> STOP.** Do not proceed to the conjunction. The assumption
  underpinning this entire branch -- that a bypassed readback is a valid
  success criterion for `0x30d` -- would be in question, and with it every
  "refused" verdict recorded against these registers, including the C2b stage 6
  blocker itself. Reassess before building anything.
- **S0 or SX -> preserve as inconclusive** and move to the still-untested
  **MCLK-selected + `CHIP_CTL` = 9.6 MHz conjunction**, the last cell of the
  matrix.

S0 is the expected outcome, for the reasons in section 14. That is stated
before the run, not after it.

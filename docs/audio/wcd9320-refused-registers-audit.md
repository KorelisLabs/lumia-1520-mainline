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

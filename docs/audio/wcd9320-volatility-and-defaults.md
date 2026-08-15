# Volatility and `reg_defaults`: findings, and why the cache stays off

`REGCACHE_NONE` has had exactly one remaining justification since the
core-release finding: volatility was unmeasured, and downstream's
`taiko_volatile()` had never been checked against this part. This measures what
can be measured, and reports what still cannot.

**Recommendation: do not enable a cache yet.** The reasons are below, and they
are not "it might be risky" — they are two specific unknowns with a concrete
experiment that would settle each.

## 1. What was measured

`wcd9320-volatility-evidence.sh`, six full 1024-register snapshots from
regmap's debugfs: idle, idle again, insert detection enabled, physical
insertion, physical removal, detection disabled. Exactly four register writes,
all to `0x14a`, all logged by the driver and asserted by the run. No interrupt
source armed at any point.

### Positively volatile: one register

| register | evidence |
|---|---|
| `0x14b` `MBHC_INSERT_DET_STATUS` | `0e → 04` when `0x14a` was written; `04 → 0b` on a physical insertion; `0b → 04` on removal |

`0x14b` moved twice without ever being written. The first movement is a
**cross-register side effect** — writing `0x14a` changes `0x14b` — which a
cache cannot model even in principle. Downstream marks it volatile; no
conflict.

### Nothing contradicted downstream

No register moved that `taiko_volatile()` fails to cover. That is the outcome
that would have forced the question, and it did not happen.

### A hardware finding: masked sources do not latch

`INTR_STATUS` (`0x098`–`0x09b`) read `00 00 00 00` in **all six** snapshots,
across a real insertion and removal, with all 29 sources masked.

So on this part masking gates the status latch itself, not merely the interrupt
output. That is worth recording independently of caching — it explains why the
first IRQ acceptance attempt saw `INTR_STATUS` flat while `0x14b` moved.

It also means **this test did not exercise `INTR_STATUS` at all**. Those
registers stay volatile on two other grounds — downstream's blanket
`reg < 0x100`, and the fact that regmap-irq demonstrably dispatched during the
acceptance runs, which requires reading a set status bit — but *not* on
anything measured here.

## 2. What `taiko_volatile()` covers

Reimplemented in `wcd9320-volatility-analyse.py` from `wcd9320.c`, with
addresses resolved from the headers rather than transcribed:

| rule | registers |
|---|---|
| `reg < 0x100` | top level, core-driver written — **includes the whole INTR block** |
| `reg >= 0x3c0` | MBHC + MAD |
| IIR coefficients, ANC filters | `0x34a`–`0x35b`, `0x202`–`0x207`, `0x282`–`0x287` |
| digital gain (17 registers) | RX1–7 volume, TX1–10 gain |
| 12 singles | HPH status, insert-detect status, clip-detect, VBAT |

**379 of 1024 registers volatile (37%); 645 cacheable.**

### Three-way classification, as measured

| bucket | count |
|---|---|
| observed volatile, downstream agrees | **1** (`0x14b`) |
| observed volatile, downstream does **not** mark it | **0** |
| downstream marks volatile, this test never exercised | **378** |

That third number is the honest headline. A measured volatile list of one
register cannot be the basis for a cache; the predicate would rest almost
entirely on downstream's authority, unverified on this die.

## 3. Candidate `reg_defaults`, and the hole in them

Of the 645 cacheable registers, 237 read non-zero, and **57 differ from the
documented `__POR`**. Six of those are this driver's own doing:

```
0x101 BIAS_CENTRAL_BG_CTL   __POR 50  measured 55   rco-wake
0x105 BIAS_OSC_BG_CTL       __POR 16  measured 17   rco-wake
0x108 CLK_BUFF_EN1          __POR 04  measured 0d   rco-wake
0x109 CLK_BUFF_EN2          __POR 02  measured 04   rco-wake
0x1fa RC_OSC_FREQ           __POR 46  measured c6   rco-wake
0x311 CDC_CLK_MCLK_CTL      __POR 00  measured 01   rco-wake
```

Core init runs before any dump can be taken, so these are not reset values and
must never become defaults. The remaining **51** have no write from us.

### The 23 in the CDC region are well supported

They fall into uniform families, which is what revision-dependent reset
defaults look like and is not what deliberate configuration looks like:

| family | registers | `__POR` → measured |
|---|---|---|
| `TX1`–`TX10_MUX_CTL` | 10 | `08` → `48`, every one |
| `RX1`–`RX7_B4_CTL` | 7 | `00` → `08`, every one |
| `COMP0/1/2_B4/B5_CTL` | 6 | `3c` → `37` and `1f` → `7f`, every one |

All are inside `0x200`–`0x3bf`, where the three-stage snapshots already
established that the values present after the core release are this die's reset
state — the RCO sequence changed exactly one register in 448. So these are
defensible as defaults.

### The 28 in the analog region are NOT

`0x153`–`0x169` (TX enable/ADC), `0x183`–`0x18c` (buck), `0x198`, `0x1a5`–`0x1ad`
(HPH), `0x1ba`–`0x1c6` (EAR/LINE bias), `0x1ce`–`0x1da` (LINE test),
`0x1e2`–`0x1e4` (speaker driver), `0x1fd`.

**There is no snapshot of this region taken after reset release and before core
init.** The sentinel covers `0x200`–`0x3bf` only. So for these 28 we cannot
distinguish

- revision-dependent reset values for this die, from
- values something wrote after reset — the ADSP is running and owns the
  SLIMbus NGD, and is a plausible writer.

One is actively suspicious: **`0x1fd RC_OSC_TUNER`, `__POR 00` → measured `15`**,
sitting immediately beside the `RC_OSC_FREQ`/`RC_OSC_TEST` registers the RCO
sequence drives. A tuner value populated *by hardware* as a consequence of
oscillator enable would look exactly like this — and would make `0x1fd` a
hardware-updated register, so neither a default nor cacheable.

## 4. Why the cache stays off

1. **The volatile predicate is unverified on this die.** One register measured;
   378 taken on trust. Getting volatility wrong yields stale reads that are
   silent and intermittent — the worst failure mode this port has, and the one
   it has already been bitten by twice.
2. **28 candidate defaults are unattributed**, with at least one likely
   hardware-written.
3. **The benefit is currently near zero.** There is no ASoC component, no DAI,
   no mixer traffic. A cache would optimise a register access pattern that does
   not yet exist, while adding a failure mode to a stack whose interrupt path
   depends on uncached reads below `0x100`.

## 5. What would settle it

**A full-map snapshot between reset release and core init.** The driver already
asserts reset and captures `sentinel_before` at exactly that moment; extending
that capture from 448 registers to all 1024 would give a true post-reset dump
of the whole map. That single change would:

- attribute all 28 analog-region differences as reset values or not;
- show whether `0x1fd` is populated by the RCO sequence, by diffing before
  against after;
- give a defensible `reg_defaults` for the entire cacheable set rather than
  half of it.

**A provoked run per volatile family.** The measurement exercised the MBHC
path. Nothing exercised the digital-gain registers, clip-detect, VBAT, or the
IIR/ANC coefficient windows. Each needs a stimulus before its volatility is
measured rather than assumed.

Until then `REGCACHE_NONE` stays, and the reason in the driver comment should
be updated from "volatility is unmeasured" to what is now true: volatility is
*measured only for the MBHC path*, and the analog reset state is unattributed.

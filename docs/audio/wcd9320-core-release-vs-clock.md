# Three-stage snapshot: the core release does the work, not the clock

Recorded 2026-08-01 from the `core-init-rc2`/`rc3` cold-boot runs.

## The measurement

`wcd9320_core_init()` snapshots the CDC register file at three points:
as found, after `wcd9xxx_bring_up()`, after the RCO clock sequence. On a
genuinely dark cold start the counts are:

| stage | non-zero of 448 |
|---|---|
| as found | **0** |
| after core release (4 writes) | **94** |
| after RCO clock sequence (15 writes) | **95** |

**The four-write core release accounts for 94 of the 95 registers. The entire
fifteen-step clock sequence adds one.**

## Why this matters

`wcd9320-cdc-rco-wake-proven` established that the block becomes accessible
after running bring-up followed by the RCO sequence, and its wording was
careful — "through the downstream RCO clock sequence" — because at the time
the two could not be separated. The stage split now separates them, and the
answer is unambiguous: **register accessibility comes from taking the digital
core out of reset, not from clocking it.**

This is the third correction in a row pointing the same direction. The block
was never dark for want of a clock:

1. `wcd9320-mclk-investigation.md` looked for an external MCLK, on the
   assumption a missing clock was the cause. It was not.
2. `wcd9320-register-map.md` correctly identified the block boundary and
   correctly declined to name a cause, leaning slightly toward "unclocked".
   The true cause was "held in reset".
3. This measurement removes the remaining ambiguity: even the *internal*
   clock is nearly irrelevant to accessibility.

## What it does not say

The RCO sequence is not useless — it is what supplies the codec's audio clock
domain, and no audio path can run without a clock. What is now established is
narrower and worth stating exactly: **the clock is not what makes the register
file readable.** One register does depend on it, and identifying which is
cheap follow-up work from the two snapshots already captured.

Nor does it say anything about external MCLK, which remains unresolved and
becomes relevant only when a stream needs a frequency-accurate reference.

## Consequence

The `0x200`–`0x3bf` sentinel should keep its name — CDC-core accessibility
sentinel — and its interpretation is now sharper. A transition proves the
core came out of reset. It does not, on its own, prove anything about clocking.

The 16 registers that differ from their documented defaults are still
unattributed. The three-stage snapshots exist to settle that, and the
`after bring_up` snapshot is now the place to look: if those 16 already carry
their odd values at stage 2, they are revision defaults rather than anything
the clock sequence did. `REGCACHE_NONE` stays until that is answered.

# The core release does the work, not the clock

Measured 2026-08-01 from a single fresh-path boot under `core-init-rc4`,
which exposes all three stage snapshots.

## Method

`wcd9320_core_init()` dumps the whole CDC block (`0x200`–`0x3bf`, 448
registers) at three points, and rc4 makes all three readable:

| stage | when | non-zero |
|---|---|---|
| `sentinel_before` | as found, core in reset | **0** |
| `sentinel_after_bringup` | after `wcd9xxx_bring_up()`, 4 writes | **94** |
| `sentinel_after` | after the RCO sequence, 15 writes | **95** |

## Result 1 — the clock sequence has no side effects at all

Comparing stage 2 against stage 3, **exactly one register in 448 differs**:

```
0x311  00 -> 01   POR=00   TAIKO_A_CDC_CLK_MCLK_CTL
```

That is the gate bit the sequence deliberately writes as its own final step.
Nothing else in the block moves.

So the earlier "94 of 95" framing understated it. It is not that the core
release does most of the work — **the core release produces the entire
register-file state, and the clock sequence contributes nothing beyond the
single bit it sets on purpose.**

Register accessibility comes from taking the digital core out of reset. The
clock is not involved in it, internal or otherwise.

## Result 2 — the 16 non-default registers are reset-state values

The 16 registers that read something other than their documented `__POR` are
**all** already at their final values immediately after the core release:

| addresses | register | `__POR` | reads |
|---|---|---|---|
| `0x223`,`0x22b`,`0x233`,`0x23b`,`0x243`,`0x24b`,`0x253`,`0x25b`,`0x263`,`0x26b` | `CDC_TX1..TX10_MUX_CTL` | `08` | `48` |
| `0x36b`,`0x373`,`0x37b` | `CDC_COMP0..2_B4_CTL` | `3c` | `37` |
| `0x36c`,`0x374`,`0x37c` | `CDC_COMP0..2_B5_CTL` | `1f` | `7f` |

Every one goes `00 → final` at stage 2 and does not move at stage 3.
Attribution: **RELEASE, 16 of 16. CLOCK, 0 of 16.**

They are therefore the reset state of this die, not a side effect of anything
this driver does. Identical deltas within each family reinforce that: all ten
TX MUX registers differ from the header by the same bit, and the COMP pairs
likewise.

### What that does and does not license

It **rules out** the possibilities that mattered: these are not produced by
the RCO sequence, and not produced by anything between reset release and the
first read.

It is **consistent with** revision-dependent defaults for this part
(minor `0x0001`), which was the leading hypothesis. It does not prove that
specifically — the alternative that the downstream header is simply wrong for
this die is not distinguished, and from a driver's point of view the two are
the same thing.

That is enough for the purpose it was blocking. A `reg_defaults` table can be
built from the **measured** stage-2 dump, which is authoritative for this
silicon, rather than from the header's `__POR` values, which disagree in 16
places.

## Consequence for caching

`REGCACHE_NONE` still stays, but the reason has narrowed to one item.

- reset defaults — **settled**. Use the measured stage-2 snapshot.
- volatility — **still unmeasured**. Nothing has yet exercised a register
  that changes without a write, and `taiko_volatile()` gives the semantic
  set but has never been checked against this part.

Volatility is now the only thing between here and a working cache.

## Consequence for the sentinel

The `0x200`–`0x3bf` sentinel keeps its name, with the sharpest reading yet: a
transition proves **the core came out of reset**, and says nothing whatever
about clocking. Any future use of it as clock evidence would be wrong.

# `CDC_CLSH_B1_CTL` bit 3 and `COND_HPH`, resolved

**Status:** resolved from source, 2026-08-23. Prerequisite for C2a.

## The question

`wcd9xxx_clsh_comp_req(HPH_L, true)` does not write bit 3 directly. It calls
`wcd9xxx_resmgr_add_cond_update_bits(COND_HPH, CDC_CLSH_B1_CTL, shift 3,
invert false)`. Is the write immediate, or deferred until some headphone
condition is satisfied?

## Answer: always immediate. Only the *value* is conditional.

`add_cond_update_bits()` appends an entry to a list and then **immediately**
calls `wcd9xxx_resmgr_cond_trigger_cond()`, which does:

```c
set = !!test_bit(cond, &resmgr->cond_flags);
list_for_each(...)
    if (e->cond == cond)
        snd_soc_update_bits(codec, e->reg, 1 << e->shift,
                            (set ? !e->invert : e->invert) << e->shift);
```

With `invert = false`, the register is written on every call:

| `COND_HPH` flag | bit 3 written |
|---|---|
| set | **1** |
| clear | **0** |

There is no pending state and no deferral. `cond_update_cond()` merely re-runs
the same write when the flag later changes.

`rm_cond_update_bits()` writes `e->invert << e->shift` — with `invert = false`
that is **0** — and then removes the entry. So teardown unconditionally clears
bit 3, which confirms it participates in cleanup semantics as suspected.

## The part that actually matters for this port

**We have no resource manager.** `cond_flags` is a bitmask inside downstream's
`struct wcd9xxx_resmgr`, which this driver does not implement and will not. The
conditional mechanism is software bookkeeping, not a hardware handshake — so
there is nothing on the device to measure and no pre-C2a hardware experiment to
run.

What the mechanism reduces to, for a faithful port:

```
enable:   write CDC_CLSH_B1_CTL bit 3 = (COND_HPH set ? 1 : 0)
teardown: write CDC_CLSH_B1_CTL bit 3 = 0
```

And `COND_HPH` has **no setter in any fetched source**. Searching the codec
driver, `wcd9xxx-common.c` and `wcd9xxx-resmgr.c` finds only the two
`clsh_comp_req` call sites that *consume* it; the two `cond_update_cond()` uses
in the codec driver are for `COND_HPH_MIC`, a different condition. The likely
setter is the MBHC jack-detection path in `wcd9xxx-mbhc.c`, which was not
fetched — and which this port does not run.

So on this device, with no MBHC and no jack handling: **bit 3 is written 0 on
enable and 0 on teardown.** It is included in the C2a assertions with that
expected value, rather than omitted.

## Consequences for the C2a predictions

This lets both states be predicted exactly, not just the post-teardown one.

`CDC_CLSH_B1_CTL`, POR `0xE4` = `1110 0100`:

| step | write | value |
|---|---|---|
| POR | | `0xE4` |
| `cfg_clsh_param_common` | bit 5 ← 1 (already), bit 1 ← 1 | `0xE6` |
| `cfg_clsh_param_hph` | bit 6 ← 0 | `0xA6` |
| `enable_clsh_block(true)` | bit 0 ← 1 | `0xA7` |
| `enable_anc_delay(true)` | bit 1 ← 1 (already) | `0xA7` |
| `clsh_comp_req(HPH_L, true)` | bit 3 ← 0 (`COND_HPH` clear) | **`0xA7`** |
| — teardown — | | |
| `clsh_comp_req(HPH_L, false)` | bit 3 ← 0 | `0xA7` |
| `turnoff_postpa` | bit 4 ← 0 (already) | `0xA7` |
| `enable_clsh_block(false)` | bit 0 ← 0 | **`0xA6`** |

**Enabled: `0xA7`. After teardown: `0xA6`.**

That also gives a free diagnostic: if the enabled state reads `0xAF` instead of
`0xA7`, bit 3 came up set, which would mean something *is* asserting `COND_HPH`
— and the whole conditional analysis would need revisiting.

## What would change this

If jack detection or MBHC is ever wired up, `COND_HPH` becomes meaningful and
bit 3 will be 1 whenever a headphone is present. The C2a expectation is
therefore conditional on "no MBHC running", and that assumption is recorded here
so a future run that fails on bit 3 is diagnosed in seconds rather than
rediscovered.

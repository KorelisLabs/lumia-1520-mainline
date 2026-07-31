# WCD9320 register map, validated against silicon

Deliverable for register classification: the readable set, the reset-default
table, and the volatile/precious question. Entirely read-only — no register
was written at any point.

The `wcd9320-asoc-survey.md` section 5 listed "reset defaults as a table" and
"register classification" as the largest remaining unknowns, and noted that
downstream provides no `readable`/`volatile`/`precious` callbacks to copy.
They are derived here and then checked against the actual part.

## 1. Method

Two independent sources, compared:

**Header-derived.** `include/linux/mfd/wcd9xxx/wcd9320_registers.h` and
`wcd9xxx_registers.h` from `LineageOS/android_kernel_lge_hammerhead`
(`cm-11.0`) parsed for every `#define TAIKO_A_*` / `WCD9XXX_A_*` address and
its matching `__POR` reset value.

| | count |
|---|---|
| address `#define`s parsed | 805 |
| `__POR` `#define`s parsed | 798 |
| distinct addresses ≤ `0x3ff` | **673** |
| addresses with a `__POR` value | 673 / 673 |
| addresses defined under two names | 132 |
| address range | `0x000` – `0x3fc` |

The 132 aliases are the `TAIKO_A_*` / `WCD9XXX_A_*` pairs for registers common
to the whole WCD9xxx family (`INTR_MODE`, `PIN_CTL_OE0`, …), not distinct
registers.

**Silicon-derived.** The full 1024-address map read from both SLIMbus
functions through the existing read-only regmap, twice each, two seconds
apart, with no write in between. 4096 reads total.

## 2. The header's map matches this silicon exactly

Every address answered — SLIMbus reads never fail, so an undocumented address
returns `0x00` rather than an error. That makes the comparison sharper, not
weaker:

| | count |
|---|---|
| addresses answered | 1024 |
| addresses failing (`XX`) | 0 |
| documented (673), read out | **673** |
| documented, read as `XX` | 0 |
| **undocumented (351), non-zero** | **0** |

**All 351 addresses absent from the header read `0x00`, and all 673 present
read out.** Neither direction has a single exception. The header's
implemented set is the silicon's implemented set on this part.

Note the consequence for driver config: because unimplemented reads silently
return `0x00` rather than erroring, a regmap without a `readable_reg`
callback presents 351 fabricated zero registers to userspace and to any
future cache. The callback is not cosmetic.

## 3. The `__POR` table is accurate — in the region that is awake

Comparing the first pass against the header's reset values, split by address:

| region | regs | with `__POR` ≠ 0 | of those, read `0x00` |
|---|---|---|---|
| `0x000`–`0x1ff` (top level + analog) | 289 | 154 | **2** (1%) |
| `0x200`–`0x3bf` (digital core) | 323 | 87 | **87** (100%) |
| `0x3c0`–`0x3ff` (MBHC) | 61 | 15 | 1 (7%) |
| total | 673 | 256 | 90 |

In `0x000`–`0x1ff` the header's reset values are confirmed against silicon
almost perfectly. The two exceptions are `WCD9XXX_A_SB_VERSION` (`0x009`,
`__POR = 0x10`, reads `0x00`) and `TAIKO_A_SPKR_DRV_IEC` (`0x1e4`,
`__POR = 0x20`, reads `0x00`).

Per-page detail, counting registers with a non-zero documented reset value
that nevertheless read back zero:

```
0x000-0x03f    8 documented non-zero,  1 zeroed
0x040-0x07f    2                       0
0x080-0x0bf    6                       0
0x100-0x13f   40                       0
0x140-0x17f   29                       0
0x180-0x1bf   41                       0
0x1c0-0x1ff   28                       1
0x200-0x23f    8                       8   <-- boundary
0x240-0x27f   12                      12
0x280-0x2bf    6                       6
0x2c0-0x2ff   24                      24
0x300-0x33f   12                      12
0x340-0x37f   23                      23
0x380-0x3bf    2                       2
0x3c0-0x3ff   15                       1   <-- boundary
```

## 4. The digital core is dark

`0x200`–`0x3bf` reads as all-zero regardless of documented reset value, at
87 of 87, with a clean boundary at each end. That is a block-level condition,
not 87 unrelated facts.

The first attempt to characterise this grouped registers by the `_A_CDC_`
name prefix, which gave a muddled 79%. The prefix is a bad proxy:
`TAIKO_A_CDC_TX_1_GAIN` sits at `0x153` in the analog front-end and
`TAIKO_A_CDC_MBHC_*` sits at `0x3c2`+, and both read their `__POR` correctly.
Bucketing by address instead gives 100% with no exceptions. The split is a
hardware block boundary, and the register names do not follow it.

**The best-supported reading is that the digital core is unclocked or held in
reset, so its register file returns zero rather than its reset defaults.**
Supporting it:

- the `__POR` table is demonstrably accurate elsewhere in the same map, so
  this is not a stale-header or wrong-revision artefact
- a revision difference would not zero exactly 87 of 87 while matching
  152 of 154 immediately below
- zero is what an unclocked register file returns

Two sub-cases are **not** distinguished by this evidence: no clock reaching
the block, versus the block being held in reset by a control bit. They are
different, and the block's own clock and reset controls
(`TAIKO_A_CDC_CLK_OTHR_RESET_B1/B2_CTL` at `0x308`/`0x309`,
`TAIKO_A_CDC_CLK_MCLK_CTL` at `0x311`, `TAIKO_A_CDC_CLK_POWER_CTL` at
`0x314`) all live *inside* the dark region and read `0x00` themselves. The
block's state cannot be read from inside the block.

MBHC at `0x3c0`–`0x3ff` reading correctly is consistent rather than
surprising: `TAIKO_A_RC_OSC_STATUS` (`0x1fc`) reads `0x18`, so the RC
oscillator is alive, and headset detection is designed to run off it without
the main clock.

### This connects to the MCLK question from the other side

`wcd9320-mclk-investigation.md` looked for MCLK by inspecting the SoC and PMIC
and found nothing. This is the same question seen from inside the codec, and
it agrees: the part is fully responsive over SLIMbus while its digital core is
dark.

It also supplies a far better MCLK test than probing PMIC pads. If a clock is
ever supplied and the core enabled, `0x200`–`0x3bf` should stop reading zero
and snap to the documented reset values. That is an unambiguous, read-only,
87-register signal — a much stronger detector than any pin-state guess, and it
needs no assumption about where the clock comes from.

### And it constrains the first-writes milestone further

The survey already deferred `TAIKO_A_CHIP_CTL = 0x02` and
`TAIKO_A_CDC_CLK_POWER_CTL = 0x03`. This adds a concrete reason for the
second one: `0x314` is inside the dark block. Writing it means writing to a
register file that currently cannot even report its own contents, and the
readback verification step that every other write milestone has relied on is
unavailable there. `TAIKO_A_CHIP_CTL` (`0x000`) is outside the dark region and
does read back — it currently reads `0x08` against a `__POR` of `0x00`.

## 5. Volatility: no register changed, and that is a weak result

Across both functions, two passes, 2048 address pairs: **zero differences**.

This is honestly reported as a weak negative rather than a classification:

- the codec is idle, no audio path is configured and no clock is running
- every interrupt is masked, so no status bit could have been set
- 87 of the registers most likely to be volatile are in the dark block and
  read zero unconditionally

So empirical volatility testing is blocked until the core is clocked. The
volatile set has to be derived from register semantics for now, and marked
as provisional.

## 6. Interrupt block, as read

| addr | register | `__POR` | read | reread |
|---|---|---|---|---|
| `0x090` | `INTR_MODE` | `00` | `00` | `00` |
| `0x094` | `INTR_MASK0` | `ff` | `ff` | `ff` |
| `0x095` | `INTR_MASK1` | `ff` | `ff` | `ff` |
| `0x096` | `INTR_MASK2` | `3f` | `3f` | `3f` |
| `0x097` | `INTR_MASK3` | `3f` | `3f` | `3f` |
| `0x098`–`0x09b` | `INTR_STATUS0-3` | `00` | `00` | `00` |
| `0x09c`–`0x09f` | `INTR_CLEAR0-3` | `00` | `00` | `00` |
| `0x0a0` | `INTR_LEVEL0` | `01` | `01` | `01` |
| `0x0a1`–`0x0a2` | `INTR_LEVEL1-2` | `00` | `00` | `00` |

The whole block is at its documented reset state: every interrupt masked,
nothing pending, nothing latched. `0x091`–`0x093` are undocumented and read
`0x00`, consistent with section 2.

Because acknowledgement is a write to `INTR_CLEAR0-3` and not a read of
`INTR_STATUS0-3`, **reading status has no side effect**. That answers the
precious question for this block: `precious_reg` is empty here. It is the
`CLEAR` registers that need care, and they need it on write.

Other status registers outside the dark block that are *not* at their reset
value, and so reflect real analog state:

| addr | register | `__POR` | read |
|---|---|---|---|
| `0x14b` | `MBHC_INSERT_DET_STATUS` | `00` | `0e` |
| `0x1b3` | `RX_HPH_L_STATUS` | `00` | `04` |
| `0x1b9` | `RX_HPH_R_STATUS` | `00` | `04` |

## 7. The interface function

The IFD's 1024 addresses were dumped on the same terms. Four are non-zero:

| addr | value |
|---|---|
| `0x001` | `21` |
| `0x002` | `01` |
| `0x020` | `4d` |
| `0x021` | `47` |

Everything else, including `TAIKO_SLIM_PGD_PORT_INT_EN0` at `0x030`, reads
`0x00` — correct for a codec whose ports have never been configured. The four
non-zero values confirm the reads reach real storage rather than a hole, so
"blank" here is a real observation and not a failed access. No interpretation
of those four is offered; nothing in the fetched headers names them.

This also re-confirms the `0x800` offset applies to the interface function, as
`wcd9320-asoc-survey.md` section 7 argued from source.

## 8. What this settles for `regmap_config`

| field | decision | basis |
|---|---|---|
| `readable_reg` | the 673 documented addresses | §2, both directions exact |
| `writeable_reg` | not established | no write has been attempted |
| `volatile_reg` | provisional, semantics-derived | §5, empirical test blocked |
| `precious_reg` | empty for the interrupt block | §6, ack is a write |
| `cache_type` | **must stay `REGCACHE_NONE`** | §4 |
| `reg_defaults` | do **not** populate from `__POR` yet | §4 |

The last two are the load-bearing ones. A cache initialised now would capture
the dark block's zeros and then never re-read them, so the first time the core
is clocked the cache would be silently wrong for 347 registers with no error
anywhere. `reg_defaults` has the same problem in reverse: the documented reset
values are correct for the part but are not what the part currently returns,
so seeding them would make the cache disagree with hardware from the first
access.

Both become safe once the core is clocked and `0x200`–`0x3bf` reads its
defaults. Until then, `REGCACHE_NONE` is not a placeholder — it is the correct
setting.

## 9. What this does not establish

- **Writability of anything.** No write was attempted. The
  readable/writable distinction is still entirely unmeasured.
- **Why the digital core is dark** — no clock versus held in reset. §4.
- **The real volatile set.** §5.
- **Whether `__POR` is right inside the dark block.** It is confirmed only
  where the block is awake; the 87 zeroed registers are untested against
  their documented defaults, and confirming them is exactly the test in §4.
- **The meaning of the four non-zero IFD registers.** §7.
- **Whether the analog trims that differ from `__POR` come from the QFUSE.**
  `TAIKO_A_QFUSE_DATA_OUT1-7` (`0x04b`–`0x051`) read
  `02 43 22 c5 7e 2c 48` against a documented reset of all zero, and a cluster
  of BUCK/HPH/EAR/LINE/SPKR trims in `0x180`–`0x1e4` also differ. Fuse-loaded
  trim is the obvious explanation and it is not evidence. Noted as a
  hypothesis, not a finding.

## 10. Reproducing this

The header parse is scripted and fetches its own inputs, so nothing derived
from downstream sources is checked in — only the measurement taken from this
device:

- `tools/wcd9320-regmap-derive.py` — fetch headers, emit the address/`__POR`
  table, compare against a silicon dump
- `docs/audio/wcd9320-register-dump-2026-07-31.log` — the raw dumps from this
  device, both functions, both passes

The device dumps come from `/sys/kernel/debug/regmap/217:a0:1:0/registers` and
`.../217:a0:0:0/registers` with the read-only `wcd9320` module loaded. Bus
health after all 4096 reads: zero SLIMbus errors, zero timeouts, ADSP running,
both functions still reporting `major 0x0102 minor 0x0001`.

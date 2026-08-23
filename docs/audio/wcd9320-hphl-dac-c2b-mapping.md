# C2b design map: RX1 CHAIN → HPHL DAC

**Status:** research only. No DAC writes yet.
Builds on `wcd9320-clsh-reversibility.md` (C2a), which proved the class-H
lifecycle this milestone inherits.

## The question

Can the proven RX1 digital chain be routed through the compander/HPH interface
and class-H support into the HPHL DAC, then returned cleanly to the pre-DAC
state, with the PA physically disabled throughout?

## 1. Exact ordering

DAPM powers supplies first, then source → sink. From the widget definitions and
routes:

| # | stage | what happens | register |
|---|---|---|---|
| 1 | `COMP1_CLK` supply **PRE_PMU** | compander config **and** the HPH gain handoff | `0x1AE`/`0x1B4` bit 5 ← 0 |
| 2 | RX1 chain | already proven | 0x380 / 0x301 / 0x30F / 0x2B7 / 0x2B5 |
| 3 | `CLASS_H_DSM MUX` **kcontrol** | select `DSM_HPHL_RX1` | `0x3B0` bits[5:4] ← 1 |
| 4 | `CLASS_H_DSM MUX` **POST_PMU** | reads `0x3B0 & 0x30`, sees `0x10`, sets zoh | `0x3B0` mask 0x0C ← 0x04 |
| 5 | `RX_BIAS` supply **PRE_PMU** | refcounted bias enable | `RX_COM_BIAS` **0x1A2** bit 7 |
| 6 | `HPHL DAC` **PRE_PMU** | RDAC clock, then class-H `PRE_DAC` | `0x30D` bit 1, then the C2a enable |
| 7 | `HPHL DAC` widget + switch | DAC power **and** its input switch | `0x1B1` bit 7 **and bit 6** |
| — | `HPHL` PA | **NOT DONE** | `0x1AB` bit 5 stays 0 |

### The thing I would have got wrong

`0x1B1` needs **two** bits, not one. The widget is
`SND_SOC_DAPM_MIXER_E("HPHL DAC", 0x1B1, shift 7)` — that is the DAC power bit —
but its input comes through `hphl_switch`, which is
`SOC_DAPM_SINGLE("Switch", 0x1B1, shift 6)`, the kcontrol on the route
`{"HPHL DAC", "Switch", "CLASS_H_DSM MUX"}`.

Setting only bit 7 gives a **powered DAC with nothing connected to it** — which
would look like a successful run and prove nothing. Enabled value is `0xC0`.

Similarly the DSM mux is two writes, not one: the enum selects the source
(`bits[5:4]`) and the event then derives the ZOH mux from it (`mask 0x0C`).
`0x3B0` should read **`0x14`** enabled, from a POR of `0x00`.

## 2. Exact inverse

Downstream's power-down events, sink → source, with the class-H teardown placed
where our port needs it rather than where downstream triggers it:

| # | stage | register |
|---|---|---|
| 1 | DAC power + switch off | `0x1B1` bits 7 and 6 ← 0 |
| 2 | `HPHL DAC` POST_PMD — RDAC clock off | `0x30D` bit 1 ← 0 |
| 3 | class-H teardown (**C2a, proven**) | `state_idle(HPHL)` + `turnoff_postpa` |
| 4 | `CLASS_H_DSM MUX` POST_PMD — clear zoh | `0x3B0` mask 0x0C ← 0 |
| 5 | mux deselect | `0x3B0` bits[5:4] ← 0 |
| 6 | `RX_BIAS` POST_PMD — release | `0x1A2` bit 7 (refcount) |
| 7 | `COMP1_CLK` **PRE_PMD** — gain handoff restored | `0x1AE`/`0x1B4` bit 5 ← 1 |

Note step 7: the compander widget uses **PRE_PMD**, not POST_PMD, so downstream
restores the gain source *before* the block powers down.

Class-H teardown sits at step 3 because downstream triggers it from the PA's
disappearance, which never happens here. C2a proved that transition standalone.

## 3. RX bias ownership

`wcd9xxx_resmgr_enable_rx_bias()` refcounts `resmgr->rx_bias_count` and only
touches `RX_COM_BIAS` (**0x1A2**) bit 7 on the 0↔1 edge.

It is **genuinely shared**: `taiko_codec_enable_aux_pga()` takes the same
reference. In this port only the DAC path takes it, so the count is trivially
1 — but the implementation must be refcounted rather than a raw write, so adding
HPHR, EAR or AUX later cannot break it by releasing a bias another path still
needs.

## 4. PA hard guard

`0x1AB` reads `0x80` at baseline; the PA enables are bits 5 (HPHL) and 4 (HPHR),
both clear. The guard is **mask `0x30` must remain `0x00`**, sampled immediately
before and after every DAC-affecting stage rather than only at the ends — so the
run cannot become a PA run unnoticed between snapshots.

For completeness, what we are declining to do: the PA's POST_PMU sleeps a
settle time and then calls `clsh_fsm(POST_PA, ENABLE)`. Downstream's class-H
bring-up is therefore **two-stage** — `PRE_DAC` at the DAC, `POST_PA` at the PA —
and C2b uses only the first stage. C2a established that stage is reversible on
its own.

## Predicted transitions

Baseline-relative, per the C2a lesson. Whole-register predictions only where the
register is not fuse-loaded:

| register | addr | baseline | enabled | after |
|---|---|---|---|---|
| `CDC_CONN_CLSH_CTL` | 0x3B0 | 00 | **14** | 00 |
| `RX_HPH_L_DAC_CTL` | 0x1B1 | 00 | **c0** | 00 |
| `CDC_CLK_RDAC_CLK_EN_CTL` | 0x30D | measure | bit 1 set | bit 1 clear |
| `RX_COM_BIAS` | 0x1A2 | measure | bit 7 set | bit 7 clear |
| `RX_HPH_L_GAIN` | 0x1AE | measure | bit 5 **clear** | bit 5 **set** |
| `RX_HPH_R_GAIN` | 0x1B4 | measure | bit 5 clear | bit 5 set |
| `RX_HPH_CNP_EN` (PA) | 0x1AB | 80 | **80** | **80** |

`0x1AE`, `0x1B4` and `0x1AB` are inside the fuse-loaded 0x180–0x1e4 range, so
only their bits are predicted, not their whole values.

## Open question before implementation

**`COMP1_B4_CTL` (0x373) bit 7** is chosen by
`taiko_codec_get_buck_mv()`, which reads the buck regulator's `min_uV` from
platform data we do not have: set if the buck is 1.8 V, clear otherwise. This
board's buck voltage is not established.

Options: leave `0x373` untouched (it is a static gain offset, and the compander
milestone already ran without it), or determine the buck voltage first. I would
leave it untouched for C2b and record it, since gain offset cannot affect
whether the DAC powers — but it must be resolved before anything is expected to
sound correct.

## Acceptance shape

Pristine analog baseline; RX1 chain and class-H prerequisites still pass; the
seven enable stages reach their mapped values; PA guarded at every stage; no
HPHR/EAR/speaker movement beyond genuinely shared resources; QDSP6 loop and
SLIMbus stream healthy underneath; the real inverse executes; shared refcounts
return; power-state **bits** restore; configuration matches its mapped steady
state; and the DAC cycle repeats identically.

**No audible-output claim.** Without the PA this is a conversion and routing
result only.

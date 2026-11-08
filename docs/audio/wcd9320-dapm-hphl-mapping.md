# DAPM for the HPHL path: ordinary playback powers the chain (r184 map)

**Status:** built as r184 `dapm-hphl-rc1` (section 4a), not yet run on
hardware. Mapped 2026-11-07, after r183.

**The goal.** `aplay` on the Q6 card, with nothing else, produces sound on
the left earcup. Today the same sound needs the C3a runner, which writes six
sysfs research attributes around the PCM stream. DAPM has to do what the
runner does, in the same order, through the same proven functions.

## 1. What exists

**The card is already real.**
- `lumia1520-q6.c` (compatible `nokia,lumia1520-q6-sndcard`) links
  MultiMedia1 (q6asm) to SLIMBUS_0_RX (q6afe), with q6routing as the platform
  and the codec's one RX DAI ("WCD9320 SLIM RX1 Playback").
- PCM streams already run through ASoC, and the codec DAI's
  `startup`/`hw_params`/`trigger`/`shutdown` program SLIMbus port 16 (proven
  r156 to r160).

**The codec component has no DAPM.** `wcd9320_soc_component` declares no
widgets and no routes, so DAPM powers nothing on the codec side. Everything
analog is switched by hand.

**The runner's per-cycle order** (`wcd9320-hphl-pa-evidence.sh`, `c3_cycle`),
proven heard on r177 and r181 to r183:

| step | runner write | driver function |
|---|---|---|
| 0 | `clk_source_test mclk` (once per run) | `wcd9320_mclk_get` |
| 1 | `hphl_pa_test prep` | `wcd9320_pa_prep(on)`: NCP, buck, class-H |
| 2 | `cdc_clk_prereq on` | `wcd9320_cdc_clk_prereq(on)`: forced 0x314 |
| 3 | `rx1_digital_test rx1-on` | `wcd9320_rx1_digital_path(on)` |
| 4 | `hphl_dac_test dac-on-reggain` | `wcd9320_hphl_dac_path(on, reggain)` (takes RX_BIAS itself) |
| 5 | `hphl_pa_test pa-on` | `wcd9320_hphl_pa_path(on)`: the only 0x1ab write sites |
| — | the PCM tone plays | ASoC: DAI hw_params / trigger |
| 5' | `pa-off` | `wcd9320_hphl_pa_path(off)` |
| 4' | `dac-off-reggain` | `wcd9320_hphl_dac_path(off)` |
| 2' | `cdc_clk_prereq off` | forced 0x314 inverse |
| 3' | `rx1-off` | `wcd9320_rx1_digital_path(off)` |
| 1' | `unprep` | `wcd9320_pa_prep(off)` |
| 0' | `clk_source_test rco` (once per run) | `wcd9320_mclk_put` |

## 2. Downstream's graph for the same path

From `taiko.c` (`hh-wcd9320.c`) plus the msm8974 machine driver:

```
AIF1 PB -> SLIM RX1 MUX -> SLIM RX1 -> RX1 MIX1 INP1 -> RX1 MIX1 -> RX1 MIX2
        -> RX1 CHAIN -> CLASS_H_DSM MUX -> HPHL DAC -> HPHL_PA_MIXER -> HPHL
        -> HEADPHONE
supplies: HPHL DAC <- RX_BIAS;  RX1 MIX1 <- COMP1_CLK;  RX_BIAS <- MCLK (machine)
```

**Widget types downstream:**
- `HPHL` is `PGA_E` on `RX_HPH_CNP_EN` bit 5.
- `HPHL DAC` is `MIXER_E` on `RX_HPH_L_DAC_CTL` bit 7.
- `RX1 MIX2` is `MIXER_E` on `CDC_CLK_RX_B1_CTL` bit 0.
- `RX1 CHAIN` is `MIXER` on `CDC_RX1_B6_CTL` bit 5.
- `RX_BIAS` and `CLASS_H_DSM MUX` are NOPM with events.
- `MCLK` is a machine-driver `SUPPLY` (`msm8974_mclk_event`).

**The mux and mixer chain** (SLIM RX1 MUX, RX1 MIX1 INP1, ANC1 MUX) is
routing that our port fixes in the proven `rx1_digital_path` sequence: port
16 into RX1, no ANC. **This build does not reproduce downstream's selectable
routing.** One fixed path is the honest scope.

## 3. The design (r184, `dapm-hphl-rc1`)

### 3a. Every widget is NOPM and calls a proven function

Downstream lets DAPM write `0x1ab` bit 5 and `0x1b1` bit 7 itself. **Here
that would break the PA fence.** The fence counts exactly four `0x1ab` write
sites (two in `hphl_pa_path`, two in the zdet static PA), all masked to HPHL.
A register-backed PGA would add a fifth, DAPM-generated one.

So every codec widget is `SND_SOC_NOPM`, and its event calls the function the
runner calls today. **No new register write site, no new sequence.** The
fences stay exactly as they are, plus a new one: widget events may call only
the proven functions.

| widget (codec) | type | PRE_PMU / POST_PMD event |
|---|---|---|
| `AIF1 PB` | `AIF_IN`, stream "WCD9320 SLIM RX1 Playback" | none (the DAI ops already program the port) |
| `MCLK` | `SUPPLY_S`, subseq 0 | `wcd9320_mclk_get` / `_put` |
| `CLASS_H PREP` | `SUPPLY_S`, subseq 1 | `wcd9320_pa_prep(on/off)` |
| `CDC PREREQ` | `SUPPLY_S`, subseq 2 | `wcd9320_cdc_clk_prereq(on/off)`: the forced 0x314 pair |
| `RX1 CHAIN` | `MIXER_E` | `wcd9320_rx1_digital_path(on/off)` |
| `HPHL DAC` | `DAC_E` | `wcd9320_hphl_dac_path(on/off, reggain)` |
| `HPHL` | `PGA_E` | `wcd9320_hphl_pa_path(on/off)` |
| `HEADPHONE` | `OUTPUT` | none |

**Routes:**

```
AIF1 PB -> RX1 CHAIN -> HPHL DAC -> HPHL -> HEADPHONE
RX1 CHAIN <- MCLK, CDC PREREQ;   HPHL DAC <- CLASS_H PREP
```

**Order.** DAPM powers supplies before mixers, mixers before DACs, and DACs
before PGAs. `SUPPLY_S` subsequences fix the order among the supplies. Power
up is therefore MCLK, prep, prereq, RX1, DAC, PA, which is the runner's order
with MCLK first. Power down is the exact reverse: PA, DAC, RX1, prereq, prep,
MCLK.
- **One difference from the runner:** it clears prereq *before* RX1 on the
  way down, while DAPM clears it after. Both orders keep the forced inverse
  pair intact, and neither touches the PA (already off). Recorded, not
  engineered around.

### 3b. Serialisation

- Each event takes `c3_lock`, the lock every research hook already holds.
  The functions set the same state flags (`pa_prep_on`, `clk_prereq_on`,
  `rx1_digital_on`, `hphl_dac_on`, `hphl_pa_on`), so the existing idle checks
  in the voltmeter, the zdet and the runner preflight automatically refuse
  while a DAPM path is up.
- **Lock order:** DAPM mutex, then `c3_lock`. No research hook calls into
  DAPM, so the reverse order never occurs.
- **The other direction.** A research hook that finds a DAPM path up refuses
  (it sees the flags), and DAPM events tolerate an `already off` state left
  by `wcd9320_c3_abort` (they log it and return 0) so a stream stop after an
  abort cannot error out.

### 3c. THE SAFETY MODEL CHANGES, and how it is bounded

Today every PA enable passes three things: the runner's gates, the
Volume Down abort proven at arm time, and a fail-safe timer. With DAPM, the
PA comes on whenever a stream plays into a connected headphone path. That is
what a phone does, and it is the point of this work. But it removes the
runner's gate.

**Bounded by:**
1. **A pin switch, default OFF.** The card adds
   `SND_SOC_DAPM_HP("Headphones")`, routes `Headphones <- HEADPHONE`, adds the
   standard `SOC_DAPM_PIN_SWITCH("Headphones")` control, and disables the pin
   at card init. With the pin off the path is incomplete and **DAPM powers
   nothing**, not even MCLK. The operator turns it on explicitly:
   `amixer cset name='Headphones Switch' on`. This is mainline's mechanism,
   not custom safety code.
2. **Gain starts at the minimum.** The DAC path uses `pa_gain_field`, whose
   probe default is `0x14` (minimum). No ALSA volume control is added in
   r184; the C3a gain attribute stays the only way to raise it.
3. **The DC contract is measured and within** (`wcd9320-hphl-electrical-proven`),
   which is what made a PA enable outside the runner defensible at all.
4. **HPHL only.** No HPHR widget exists, so DAPM cannot enable the right PA.

**Abort, for the first acoustic DAPM test.** A small runner holds the
Volume Down abort and a fail-safe timer, like C3a. On either it does two
things: kill the player, and switch the pin off. Both make DAPM run the
reverse sequence. After that test, the product behaviour (no runner) is the
operator's call.

### 3d. Not in r184

- **No HPHR, no stereo,** and no selectable RX routing (ANC, IIR, other RX
  ports).
- **No volume control,** no jack-detect-driven pin (MBHC plug events driving
  `Headphones` come later), and no comp1 / class-H mode controls. The proven
  register-gain mode stays fixed.
- **No change to any research hook.** C3a, the voltmeter, the zdet and the
  trace keep working, and they refuse while DAPM holds the path.

## 4. Gates

**Fence** (new section 5i):
- the component declares widgets and routes;
- every codec widget is `SND_SOC_NOPM`;
- each event body calls only its listed proven function, under `c3_lock`;
- no new `0x1ab`, `0x1b1` or forced-write site (the existing counts are
  unchanged);
- no HPHR widget;
- the card disables `Headphones` at init.

**Digital gate** `wcd9320-dapm-evidence.sh`. The PA stays off because the pin
is left OFF throughout:
1. `aplay` of silence with the pin OFF: no widget powers, `mclk_users` 0, PA
   `80`, nothing in the forced journal.
2. The DAPM widget states from debugfs (`/sys/kernel/debug/asoc/.../dapm/`):
   every codec widget off.
3. `cache_check` 0 at the end.

**Acoustic gate** `wcd9320-dapm-listen.sh` (C3a-style abort and fail-safe):
- operator approval in chat;
- gain set through the existing attribute;
- pin ON, then the 1 kHz tone/silence pattern played with the plain PCM
  tool;
- telemetry while it plays: DAPM states, `mclk_users=1`, `0x1ab=a0`,
  `1b3=08`, OCP 0;
- after the stream ends: everything down, pin OFF, `mclk_users` 0,
  `cache_check` 0;
- analysed by `c3a-capture.py` as before.

**Forced budget.** One played stream costs 4 entries (the prereq pair and the
DAC-path pair), the same as one C3a cycle.

## 4a. As built (r184, `dapm-hphl-rc1`, pkgrel 184)

Three deviations from section 3, each found while building:

1. **RX1 and the DAC are supplies, not a MIXER and a DAC.** Mainline's
   `dapm_up_seq[]` powers `dac` (7) *before* `mixer` (8), so the table in 3a
   would have run the DAC event before RX1, and the DAC path refuses without
   RX1. All five pre-PA stages are therefore `SUPPLY_S` with subsequences
   0 to 4 (MCLK, prep, prereq, RX1, DAC), all feeding the `HPHL` PGA.
   Supplies always power before PGAs, subsequences ascend on the way up and
   descend on the way down (`dapm_seq_compare()`), so the order is fixed by
   the widget types alone. The route graph is `AIF1 PB -> HPHL -> HEADPHONE`
   with the five supplies on `HPHL`.
2. **Ownership chain.** `dapm_seq_check_event()` logs a failed event and
   carries on powering the next widget, so the events cannot trust the
   graph. `dapm_held` records what DAPM itself powered:
   - a stage powers only if DAPM holds exactly every stage below it;
   - MCLK powers only on an idle codec (`wcd9320_dapm_idle()`: no MCLK user,
     no prep, prereq, RX1, DAC, PA, compander, class-H or RX bias), so DAPM
     never shares the path with the runner, the voltmeter or the zdet;
   - any failure runs `wcd9320_c3_abort()` and drops what it took down from
     `dapm_held`, so every later stage refuses;
   - power-down undoes only stages DAPM holds.
3. **One event function.** The stage number is the widget's `.shift`, which
   nothing reads on an `SND_SOC_NOPM` widget, and one dispatcher holds the
   six calls. So the lock, the chain and the abort exist once.

**Also added:**
- a `dapm_state` attribute: `held`, `ups`, `downs`, `refusals`, `failures`;
- the C3a runner's preflight refuses while the Headphones pin is on.

**Gates:**
- fence 5i: 42 checks, 11 of 11 mutations caught;
- `tools/wcd9320-dapm-selftest.sh`: 38/38 offline, covering the expectations
  and the DAPM teardown against fakes;
- `tools/wcd9320-dapm-evidence.sh`: the digital gate;
- `tools/wcd9320-dapm-listen.sh`: the acoustic gate. It runs as the
  `wcd9320-c3a` unit, so `tools/c3a-approve.sh dapm-c1` works unchanged.

**The emergency path** is `tools/wcd9320-dapm-teardown.sh`: pin off, kill the
player, then the C3 abort unconditionally.

## 5. Order of work

Fences first, then driver and card, then selftests, then the gates.
**Hardware:**
1. the digital gate (pin off);
2. the regression set: mclk-own, vm, zdet;
3. one acoustic DAPM run of 2 streams, on one fresh boot.

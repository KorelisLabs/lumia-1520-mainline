# r187: the loudspeaker and the earpiece, as safe probes (design map)

**Status:** MAPPED 2026-11-08, nothing written. This is Phase 1 of
`phase0-remaining-audio-map.md`.

**Operator decision:** find the speaker wiring with safe probes, not by
reverse-engineering the Windows driver.

**Sources:**
- `~/ds-hdr/src/hh-wcd9320.c`:
  - `taiko_codec_enable_spk_pa`
  - `taiko_codec_enable_vdd_spkr`
  - `taiko_spk_dac_event`
  - `taiko_codec_enable_ear_pa`
  - `taiko_codec_ear_dac_event`
  - `taiko_config_compander`
  - the routes at lines 3620-3720
  - `taiko_reg_defaults`
- `~/.cache/wcd9320-downstream/wcd9xxx-common.c`: `state_ear` and
  `cfg_clsh_param_ear`.

**Live values** (r186 boot, codec 2.0):
- `SPKR_DRV_EN 0x1df = 6f`, `GAIN 0x1e0 = 00`, `DBG_PWRSTG 0x1e7 = 00`;
- `OCP_CTL 0x1e2 = 97`, `CLIP_DET 0x1e3 = 01`, `IEC 0x1e4 = 00`, already
  downstream's 2.0 defaults;
- `RX_EAR_EN 0x1bc = 00`, `RX_EAR_GAIN 0x1bd = 02`;
- RX7: `0x2e4 = 78` (48 kHz), `0x2e5 = 80`.

## 1. The loudspeaker: the codec's class-D driver (`SPK_OUT`)

**Hypothesis** (phase 0, section 1): no separate amplifier exists in ACPI,
so the speaker hangs off `SPK_OUT`. The first hardware step tests exactly
this, at the minimum gain.

**Downstream's graph:**

```
SLIM RX1 -> RX7 MIX1 INP1 -> RX7 MIX1 (COMP0_CLK) -> RX7 MIX2 (interpolator, 0x30f bit 6)
        -> SPK DAC (NOPM, no event; supplies RX_BIAS and VDD_SPKDRV) -> SPK PA -> SPK_OUT
```

- **No class-H and no DSM mux.** The class-D runs from the speaker supply,
  not the buck or NCP. The DSM mux feeds only DAC1 and the HPHL DAC.
- **No "RX7 CHAIN" widget.** `SPK DAC` takes RX7 MIX2 directly, so RX7's
  `B6` chain bit is not written.
- **`COMP0_CLK` (`taiko_config_compander`)** does nothing with compander 0
  off, the same choice r184 made for compander 1. Its gain-source bit is
  `SPKR_DRV_GAIN` bit 2, which is 1 = register gain while the compander is
  off.
- **`VDD_SPKDRV`** is an optional regulator. It is not in downstream's 8974
  DT, and not in this board's ACPI either. Then there is the `spkr_drv_wrnd`
  workaround:
  - downstream sets `SPKR_DRV_EN` bit 7 at probe;
  - the supply's PRE_PMU clears it, and the PA's PRE_PMU sets it;
  - PMD reverses both, so bit 7 is set again while idle.

  This port has never set bit 7 at probe, so the PRE_PMU clear is a no-op the
  first time. After the first stream, bit 7 is idle-set, as on downstream.
  Recorded, and kept faithful.
- **`DBG_PWRSTG = 24`** is in downstream's reg-defaults table ("close leakage
  on the spkdrv"). It is changed again only on Taiko 1.0, so on our 2.0 part
  the speaker always runs with `24`. **The speaker path writes it once,
  before the first PA enable, and leaves it** (programmed state, like
  POST_PA).
- **The PA is one bit:** `SPKR_DRV_EN` bit 7, set at PRE_PMU and cleared at
  POST_PMD.
- **Gain:** `SPKR_DRV_GAIN [6:3]`, inverted, 0..8 on 2.x ("SPK DRV Volume").
  The live value `00` is the **maximum**, so the prep writes bit 2 (register
  source) and field 8 (minimum) before the PA, and restores the baseline
  after. This is the HPH prep pattern.
- **Over-current:** the driver protects itself (`OCP_CTL 97`, auto). There is
  no OCP interrupt on this codec, only `SPEAKER_CLIPPING`, which is read as
  evidence.

**Which channel feeds RX7: a choice.** Downstream's mixer paths feed the
speaker from SLIM RX1 alone and leave the downmix to the DSP. Our back end
is always stereo, so RX1 alone would drop the right channel's content. RX7
MIX1 has two inputs:
- **r187 sets `INP1 = RX1` and `INP2 = RX2`** (an L+R sum);
- RX7's digital volume is `-6 dB` by default, so the sum cannot clip.

This is a one-line change if the probe says otherwise.

**The stage table** (DAPM, all NOPM supplies, the r184/r185 ownership
model):

| subseq | stage | function |
|---|---|---|
| 0 | `MCLK` | `wcd9320_mclk_get` / `_put` (shared, refcounted) |
| 1 | `SPK PREP` | `DBG_PWRSTG 24` once, `SPKR_DRV_GAIN` source + field, baseline restore |
| 2 | `CDC PREREQ` | the forced 0x314 pair (refcounted with HPH; see section 3) |
| 3 | `RX7 CHAIN` | `wcd9320_rx_digital_path(2)`: a third table row with no chain write |
| 4 | `SPK DAC` | `rx_bias(on)`, then the `VDD_SPKDRV` workaround |
| 5 | `SPK PA` | `SPKR_DRV_EN` bit 7 |

These feed a NOPM PGA `SPK` -> OUTPUT `SPK_OUT`. The card adds a
`Speaker` pin, OFF at boot, with no jack linkage. UCM will choose between
speaker and headphones in Phase 4.

## 2. The earpiece (EAR)

**Downstream:**

```
RX1 CHAIN -> CLASS_H_DSM MUX (DSM_HPHL_RX1) -> DAC1 [0x1bc bit 6, switch bit 5; supply RX_BIAS]
          -> EAR_PA_MIXER -> EAR PA [0x1bc bit 4] -> EAR
DAC1 PRE_PMU: clsh_fsm(EAR, ENABLE, PRE_DAC)
EAR PA POST_PMU: clsh_fsm(EAR, ENABLE, POST_PA), 5 ms;  POST_PMD: clsh_fsm(EAR, DISABLE, POST_PA), 5 ms
```

- **The earpiece shares RX1 and the DSM mux with HPHL,** and class-H has no
  EAR+HPH state (`state_err`). **So the earpiece and the headphones are
  mutually exclusive,** enforced by the idle check: either path refuses while
  the other holds class-H.
- **Class-H in EAR mode** (`state_ear`):
  1. `cfg_clsh_buck`, `param_common`;
  2. **`param_ear`**: B1 bit 7, `V_PA_HD_EAR 0d`, `V_PA_MIN_EAR 3a`,
     thresholds `26` / `2c`, `I_PA_FACT 07a9`, and a K-table write of 6 data
     bytes through `K_ADDR` / `K_DATA` (volatile since r181);
  3. block on, charge pump, ANC delay;
  4. `comp_req(EAR)` (B1 bit 4);
  5. buck 2 V, NCP fclk 8.

  The teardown is `idle(disable, EAR)`, which is `turnoff_postpa` only.
- **Gain:** `RX_EAR_GAIN [7:5]`, an enum. The prep writes the most negative
  step before the PA, and restores the baseline after.

**Stages:**

| subseq | stage | function |
|---|---|---|
| 0 | `MCLK` | |
| 1 | `EAR PREP` | gain at the minimum |
| 2 | `CDC PREREQ` | |
| 3 | `RX1 CHAIN` | shared with HPH, refcounted |
| 4 | `EAR DAC` | DSM mux, rx_bias, DAC1 switch and power, class-H EAR PRE_DAC |
| 5 | `EAR PA` | bit 4, class-H POST_PA, 5 ms |

The card adds an `Earpiece` pin, OFF at boot.

## 3. Sharing between paths

r184-r186 assumed one path, and `wcd9320_dapm_idle()` refuses to start while
anything is up. That rule holds for HPH and the earpiece, which are mutually
exclusive.
- **Speaker beside headphones** (ringtone with a headset in) needs shared,
  refcounted MCLK, prereq, RX bias and RX1. That is the r182 MCLK pattern
  extended.
- **r187 keeps it simple:** every output path requires the others to be
  idle, one output at a time. Simultaneous output is a Phase 4 item, if UCM
  needs it.

## 4. The probes (hardware, one fresh boot)

**Before any probe:**
- the digital gate with every pin OFF;
- the regressions;
- the HPH listen, two streams, to show nothing regressed.

**Probe S (speaker):**
- the phone flat on a table, the USB mic at a marked spot about 5 cm above
  the speaker grille (the operator's fixed rig);
- `Speaker` pin on, gain at the minimum, a -40 dBFS tone, one approved
  stream;
- recorded and analysed.

| result | meaning | next |
|---|---|---|
| heard | `SPK_OUT` drives the loudspeaker | step the gain under approval, and measure the step size with the fixed rig |
| silent, and the chip shows the PA live | `SPK_OUT` is not connected, or its supply is off | the line outputs, next build |

**Probe E (earpiece):** the same, with the mic at the earpiece slot, the
gain at the minimum.

**Safety, as before:**
- the Volume Down abort is proven at arm time;
- the fail-safe timer is armed;
- one chat approval per stream;
- the minimum gain first;
- the pins start OFF;
- a hard abort on a clip interrupt or an unexpected PA state.

## 5. As built (r187 `outputs-rc1`, card `q6-card-rc6`, pkgrel 187), staged 2026-11-08

**Compile:** both modules compile clean at `W=1`.

**Deviations, found while building:**

1. **`spkr_drv_wrnd` is not ported.** Downstream leaves `SPKR_DRV_EN` bit 7
   (the PA enable) set while idle. Here bit 7 is set only by the PA stage,
   so no PA bit is ever set outside a stream. Fenced in 5k.
2. **The DSM mux is one helper, `wcd9320_dsm_route()`.** It moved unchanged
   out of the HPHL DAC path, and the earpiece DAC calls it too.
3. **Class-H is one body, `wcd9320_clsh_mode(ear)`.** The HPH table was split
   unchanged into `clsh_cfg` (buck and common) plus `clsh_param_hph`, and
   `clsh_param_ear` was added. `wcd9320_clsh_hphl()` keeps its meaning.
4. **The DAPM stage widgets for the new paths are one macro,
   `WCD9320_DAPM_STAGE`**, with `(path << 4) | stage` in `.shift`. Each path
   has its own ownership mask (`held`, `spk_held`, `ear_held`).
5. **The C3 abort takes every output down:** the speaker, earpiece and HPH
   PAs first, then the DACs, the prereq and the preps. The DAPM emergency
   teardown switches every pin off.

**Fences:**
- 5i covers the three graphs, seven controls and the per-path ownership;
  5j covers RX7.
- 5k is new: 40+ checks covering bits, single write sites, gains booting at
  the minimum, earpiece exclusivity, the `param_ear` values, the single DSM
  copy, the abort order and the stage table.
- **Results:** 514 source checks PASS. Mutation test 18/18.
- The read-bypassed expectation is 129.

**Tools:**
- `OUTPUT=hph|spk|ear` in the listen runner. The speaker and earpiece default
  to one stream at the minimum gain, `B:0:84`.
- The digital gate covers all three graphs with every pin off.
- The teardown turns off every pin.
- Selftest 91/0.

**Build** (operator):

```
tools/build-wcd9320-kernel.sh --pkgrel 187 --version outputs-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r187 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

`pcm-tone` is unchanged from r186, so there is no helper rebuild.

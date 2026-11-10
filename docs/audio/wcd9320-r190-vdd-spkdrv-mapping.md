# r190: the speaker driver's own supply, VDD_SPKDRV (design map)

**Status:** mapping, 2026-11-10.

## 0. Why

- **r187** drove the WCD9320's class-D speaker driver (`SPK_OUT`) live on
  the chip to -20 dBFS at full gain. It stayed silent.
- **r187's map** recorded `VDD_SPKDRV` as "optional, not in downstream's
  8974 DT, not in this board's ACPI". So no regulator was ever enabled for
  it. The ACPI half of that was wrong:
  - the vote is not in the codec node's `_CRS`;
  - it is in the power framework's entry for the audio device.
- **r189** read that entry's component list (`\_SB.PEP0` APCC) but not
  `AUDD.PPNF`, the endpoint → component map. PPNF switches **component 1**
  (PM8941 SMPS4, 5,000,000 µV, 1,500,000 µA) together with **component 0**
  (the codec), for endpoints `0x45` and `0x43`. It never switches it with
  the Secondary MI2S pins:

  | endpoints | components | what they are |
  |---|---|---|
  | `0x46`, `0x51` | 4 | TLMM 79, 80, 82 |
  | `0x4A` | 5 | TLMM 81 |

  r189 then proved Secondary MI2S silent on both data lines, with the rail
  up.

**Sources:**
- **[DS]:** `cm11-wcd9320.c` (`taiko_codec_enable_vdd_spkr`, the
  `VDD_SPKDRV` widget, `spkr_drv_wrnd`, `taiko_update_reg_defaults`,
  `taiko_2_0_reg_defaults`), `cm11-wcd9xxx-core.c` (on-demand supplies),
  `pdata.h` (`WCD9XXX_VDD_SPKDRV_NAME "cdc-vdd-spkdrv"`).
- **[PEP]:** this phone's DSDT (analysis only).
- **[KSRC]:** `pm8941.dtsi` (`pm8941_5v: s4`).

## 1. Downstream [DS]

**The widget and its route:**
```
SND_SOC_DAPM_SUPPLY("VDD_SPKDRV", SND_SOC_NOPM, 0, 0,
		    taiko_codec_enable_vdd_spkr, PRE_PMU | POST_PMD)
{"SPK DAC", NULL, "VDD_SPKDRV"}
```
It is a supply of `SPK DAC`, beside `RX_BIAS`. It is up before the DAC and
before the PA, and down after both.

**`taiko_codec_enable_vdd_spkr`:**
- **PRE_PMU:** `regulator_enable(spkdrv_reg)`. Then, only if
  `spkr_drv_wrnd > 0`, `SPKR_DRV_EN` bit 7 is cleared. Then, only on Taiko
  1.0, `DBG_PWRSTG &= ~0x24`.
- **POST_PMD:** the reverse. 1.0 only: `PWRSTG |= 0x24`; if wrnd: bit 7 is
  set; then `regulator_disable`.

**`spkr_drv_wrnd` on this part:**
- It defaults to 1.
- `taiko_update_reg_defaults()` sets it to **-1 on Taiko 2.0**, and our part
  is 2.0 (r187).
- Every wrnd branch, and the bandgap vote it takes at probe, is therefore
  off.
- On 2.0 the event is exactly: regulator on before the DAC, and off after.

**The regulator:**
- `taiko_codec_find_regulator(codec, "cdc-vdd-spkdrv")`, from the core's
  supplies.
- Boards that have it list it in `qcom,cdc-on-demand-supplies`. The core sets
  its voltage and load at init but does not enable it; only the event does.

**2.0 register defaults on the speaker block:** `SPKR_DRV_OCP_CTL = 0x97`,
`CLIP_DET = 0x01`, `IEC = 0x00`.
- These are also the chip's reset values (this driver's regmap
  `reg_defaults`), so they change nothing.
- The live values are read in the r190 run.

## 2. This board [PEP] [KSRC]

- **The supply:** `VDD_SPKDRV` = PM8941 SMPS4, the 5 V boost
  (`pm8941_5v`), voted 5.0 V / 1.5 A with the codec.
- **The regulator:**
  - Linux has it as `regulator.N name=s4 5000000 uV`.
  - Its only other consumer is the r189 I2S diagnostic component.
  - Reference counting makes the two independent.
  - 5vs1/5vs2 (USB, HDMI) sit behind it and stay disabled.

## 3. What r190 builds

**DT:** `codec@1,0` gets `vdd-spkdrv-supply = <&pm8941_5v>;`.

**Driver** (`spkdrv-rc1`):
- **Getting the regulator:** `devm_regulator_get_optional(dev,
  "vdd-spkdrv")`. `-ENODEV` means no supply, which is r187's behaviour, so
  a board without it is unchanged. Any other error fails probe.
- **`wcd9320_spk_dac(on)`:**
  1. `rx_bias(on)`;
  2. then `regulator_enable(spkdrv)`;
  3. a failure unwinds the bias and returns the error.
- **`wcd9320_spk_dac(off)`:** `regulator_disable(spkdrv)`, then
  `rx_bias(off)`.

  So the PA, which refuses without the DAC, is only ever enabled with the
  rail up. The C3 abort's existing `spk_pa(false)` → `spk_dac(false)` takes
  the rail down.
- **`out_state`** gains `spkdrv_present`, `spkdrv_on` and
  `spkdrv_enables/disables`.
- **Unchanged:** the stage mask (`3f`) and `spkr_drv_wrnd` (off on 2.0, as
  downstream).

**Fences:**
- the optional get;
- enable after the bias, before `spk_dac_on`;
- disable before the bias release;
- the unwind;
- one enable site and one disable site;
- the DT property;
- the version.

**Runner, `OUTPUT=spk`:**
- live: `spkdrv_on=1`, and the regulator class `s4` enabled;
- after: `spkdrv_on=0` and `s4` disabled;
- per run: spkdrv enables == disables == streams.

## 4. Probes (one fresh boot, headset unplugged)

**Gates:**
- the digital gate (every pin OFF: the rail must stay off);
- mclk-own and vm;
- one HPH listen.

**Probe S2:**
- mic at the grille, the operator at the grille and the earpiece slot;
- **Speaker Volume 0 (the minimum, field 8)**: -50 dBFS first, then -40;
- then Volume 4 and 8 at -40;
- -30/-20 only with "declared".

| result | meaning | next |
|---|---|---|
| heard | VDD_SPKDRV was the missing piece | the level per step; then EAR with the same eyes (does the earpiece need anything?) |
| silent to Volume 8 at -40, with the rail on | the speaker is not on SPK_OUT even powered | LINEOUT with the rail on (the other 5 V-with-codec reading) |

## 5. As built (r190 `spkdrv-rc1`, card unchanged `q6-card-rc8`, pkgrel 190), staged 2026-11-10

**What changed:**
- **The codec:**
  - an optional `vdd-spkdrv` regulator;
  - inside `wcd9320_spk_dac()`, up is RX bias → rail → DAC on, and a
    refused rail releases the bias;
  - down is rail → bias;
  - `out_state` adds `spkdrv_present`, `spkdrv` and `spkdrv_enables/disables`.

  No new register access, so the read-bypassed call sites stay at 139.
- **DT:** `codec@1,0` gets `vdd-spkdrv-supply = <&pm8941_5v>`.

**Checks:**
- W=1 clean.
- Verifier 5n: 10 checks.
- Pre-build, against r189's module: 618 pass and 1 expected failure, the
  version.
- Mutation: 6/6 caught.

**Runners:**
- **`OUTPUT=spk`:**
  - live: `spkdrv=1` and the regulator class `s4` enabled;
  - after: `spkdrv=0` and `s4` disabled;
  - per run: the spkdrv enable/disable deltas equal the speaker streams,
    and are 0 for every other output.
- **The digital gate:** the 5 V rail must stay disabled during the SLIMbus
  tone, with every pin OFF.
- **Selftest:** 105/0.

**Build:**
```
tools/build-wcd9320-kernel.sh --pkgrel 190 --version spkdrv-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r190 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

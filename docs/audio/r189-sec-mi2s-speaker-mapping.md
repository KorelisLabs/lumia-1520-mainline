# r189: the loudspeaker on Secondary MI2S (design map)

**Status:** mapping, 2026-11-09. Nothing is built yet.

## 0. Why

- **The codec is ruled out.** r187 probed the WCD9320's `SPK_OUT` and `EAR`,
  and r188 its four `LINEOUT`s. Every one was live on the chip up to
  -20 dBFS at full gain, and none sounded. Only HPH sounds.
- **What phase 0 missed.** It searched the stock ACPI tables for an amplifier
  device (an I2C peripheral, or a GPIO in the audio node's `_CRS`) and found
  none, so it concluded the speaker must sit on the codec. It never read
  the **power framework's** entry for the audio device (`\_SB.PEP0`, the
  `APCC` package for `\_SB.ADSP.SLM1.ADCM.AUDD`). On Qualcomm Windows phones
  that entry lists every rail, clock and pin mux the PEP switches for the
  device. That is where the speaker is.

**Sources:**
- **[PEP]:** this phone's own `dsdt.aml` (`mmcblk0p24:/ACPI`, decompiled
  with `iasl -d`). Analysis only; it is not redistributed, and only the
  facts below are recorded.
- **[DS]:** LineageOS `android_kernel_lge_hammerhead` `cm-11.0`:
  `board-8974-gpiomux.c`, `msm8974-regulator.dtsi`, `apr_audio-v2.h`,
  `q6afe-v2.h`, `msm-dai-q6-v2.c`.
- **[KSRC]:** mainline 6.16.12: `q6afe.c`, `q6afe-dai.c`, `q6routing.c`,
  `apq8016_sbc.c`, `pinctrl-msm8x74.c`, `pm8941.dtsi`.
- **[LIVE]:** the running phone (r188 boot), read-only.

## 1. What Windows switches for the audio device [PEP]

The audio device has 15 power components (0 to 14). Each has an "on" state
(F0) and an "off" state (F1). These are the ones that do something:

| component | F0 (on) | F1 (off) | meaning |
|---|---|---|---|
| 0 | PM8941 GPIO 15 as a digital output; DIV_CLK_1 on; SMPS2 2.15 V; SMPS3 1.8 V | clock off, votes dropped | the codec: the MCLK pin and divider (owned by our driver since r182), and its supplies |
| **1** | **PM8941 SMPS4 at 5,000,000 µV, 1,500,000 µA** | vote dropped | **a 5 V / 1.5 A load: a power amplifier's supply** |
| **4** | **TLMM 82, 79, 80 to function 1** | back to function 0 | **`sec_mi2s`: DATA1, SCK and WS** (roles by convention, section 2) |
| **5** | **TLMM 81 to function 1** | back to function 0 | **`sec_mi2s`: DATA0, switched on its own** |
| 2, 3, 6 to 14 | empty | empty | placeholders |

- **Pin 78** (`sec_mi2s` MCLK) is never muxed: the device behind the port
  takes no master clock.
- **No amplifier on a control bus:** the whole DSDT still declares no I2C
  audio device, and the audio node's only GPIO is the codec reset (TLMM 63).
- **The reading:** the loudspeaker is fed by a **control-less I2S class-D
  amplifier** on the SoC's Secondary MI2S port. It runs from BCLK/WS/DATA
  and powers up from its 5 V supply. That supply is the PM8941 boost, which
  Windows votes on only while the speaker component is active.
- **DATA0 is switched separately.** It may carry a second transducer (the
  earpiece?), or it may be a feedback or capture line. [UNKNOWN]

## 2. Confirmation

### The pins [KSRC] [DS] [LIVE]

- **Mainline function 1:** `pinctrl-msm8x74.c` gives TLMM 78 to 82 as
  function 1 = `sec_mi2s`.
  - It names the function only, not each pin's role.
  - The roles used in this document (78 MCLK, 79 SCK, 80 WS, 81 DATA0,
    82 DATA1) are the MSM8974 convention, and are **not verified** here.
  - Windows' grouping fits them: 81 alone, 82 with 79 and 80.
  - If DATA0 and DATA1 were the other way round, the two `sd-lines` images
    of section 2 still cover both lines.
- **Downstream:** `msm8974_sec_auxpcm_configs` muxes 79 to 82 to function
  1:
  - active: 8 mA, no pull;
  - suspended: function 1, 2 mA, pull-down.
- **Live, today:** all five pins are unclaimed plain GPIOs:
  - 78, 81 and 82 out-low;
  - 79 and 80 in, with pull-down.

  Linux has never driven this port.

### The 5 V rail [KSRC] [DS] [LIVE]

- **In the device tree:** `pm8941.dtsi` declares `pm8941_5v: s4` (the SPMI
  boost at `0xa000`, 5.0 V, 500 µs ramp) under `qcom,pm8941-regulators`, as
  `vin_5vs` for the 5vs1/5vs2 switches.
- **Live:** it is `regulator.5 name=s4 5000000 µV`, **disabled, 0 users**.
- **Downstream:** it is `pm8941_boost`, with the same voltage and enable
  time.
- **USB:** the boost does not put 5 V on USB by itself.
  - On downstream, the OTG switch (`mvs1`) hangs off the charger's own OTG
    supply.
  - On mainline, the switches `5vs1`/`5vs2` sit behind it and stay
    disabled (0 users, live).
  - Enabling S4 alone changes nothing on the port this work runs over.

### The DSP side [KSRC] [DS]

- **The port and its parameters:** `AFE_PORT_ID_SECONDARY_MI2S_RX` is
  `0x1002` (DT id `SECONDARY_MI2S_RX` = 18). The I2S config parameter is
  `0x1020D`, and the line codes are `SD0` = 1 and `SD1` = 2. Downstream and
  mainline agree on all of these.
- **The bit clock:** for MSM8974's DSP generation it is set per port with
  `AFE_PARAM_ID_LPAIF_CLK_CONFIG` (`0x10238`, `struct afe_clk_cfg`).
  - Mainline sends exactly that for `snd_soc_dai_set_sysclk(cpu_dai,
    LPAIF_BIT_CLK, ...)`.
  - It is not the newer `AFE_PARAM_ID_CLOCK_SET` that sdm845 uses.
- **The template:** mainline's `msm8916_qdsp6_*` in `apq8016_sbc.c`, the
  same DSP generation:
  - `set_fmt(BP_FP)` at link init;
  - `LPAIF_BIT_CLK` at 1.536 MHz in BE `.startup`, reference-counted;
  - 0 in `.shutdown`;
  - a BE fixup to 48 kHz, 2 channels, S16.
- **Routing:** `q6routing` has `SEC_MI2S_RX Audio Mixer` with a
  `MultiMedia1` switch.
- **Windows' speaker profile** [PEP, `QCRT.DEVI`]: ACDB device 15 at
  48 kHz, 16-bit.

### One data line per boot [KSRC]

- `qcom,sd-lines` is read once, at q6afe-dai probe.
- With two lines (`QUAD01`) and a 1- or 2-channel stream,
  `q6afe_i2s_port_prepare()` silently falls back to **`SD0` only**. One
  stereo stream cannot drive both lines.
- **So r189 selects one line per boot:** `<1>` (DATA1, pin 82, switched with
  the clocks in component 4) first. `<0>` is a DT-only variant image if
  DATA1 is silent.

## 3. What r189 builds

**Device tree** (`qcom-msm8974-microsoft-rm940.dts`):
- **`&tlmm` states:**
  - `sec_mi2s_active`: pins 79 to 82, function `sec_mi2s`, 8 mA, no pull;
  - `sec_mi2s_sleep`: function `sec_mi2s`, 2 mA, pull-down, as downstream.
  - Pin 78 is left alone, as Windows leaves it.
- **The q6afe DAI:** `dai@18 { reg = <SECONDARY_MI2S_RX>; qcom,sd-lines =
  <1>; }`.
- **The amplifier node:** `compatible = "nokia,lumia1520-i2s-spk"`,
  `vdd-supply = <&pm8941_5v>`, `#sound-dai-cells = <0>`, and the
  `sec_mi2s` pinctrl states, which are applied only while the amp is
  powered.
- **The sound node:** a third link, `sec-mi2s-dai-link`, with:
  - cpu `<&q6afedai SECONDARY_MI2S_RX>`;
  - platform `<&q6routing>`;
  - codec `<&i2s_spk>`.

**Card module** (`snd-soc-lumia1520-q6`, card version `q6-card-rc8`):
- **A minimal component, "unknown I2S amplifier".** It claims no part
  number, because the part is unknown.
  - One playback DAI: S16_LE, 48 kHz, 2 channels, I2S.
  - A DAPM `REGULATOR_SUPPLY` for `vdd`, so the 5 V rail is on only while
    DAPM powers the path.
  - Pinctrl `default` = sleep, and `active` while the supply is up.
  - Output `I2S_SPK_OUT`.
- **The MI2S back end gets its own ops**, chosen by `link->id ==
  SECONDARY_MI2S_RX`; the SLIM BE keeps its ops unchanged.
  - init: `set_fmt(BP_FP | I2S)`;
  - startup: the bit clock at 1.536 MHz;
  - shutdown: the bit clock to 0.
- **The pin and route:** a card pin `Loudspeaker` (`SND_SOC_DAPM_SPK`) from
  `I2S_SPK_OUT`.
  - It is added to `pins_off`, so it boots off like every other pin.
  - The r187 `Speaker`/`Earpiece`/`Lineout` pins stay as they are, as
    diagnostic paths.

**Tools:**
- The verifier's fences.
- The selftest.
- The listen runner gets `OUTPUT=i2s`:
  - the pin is `Loudspeaker Switch`;
  - the mixer is `SEC_MI2S_RX Audio Mixer MultiMedia1`, with the SLIM
    mixer off;
  - the live checks read the regulator's state, the pins' mux, and the
    AFE port start in dmesg.

## 4. Probes (one fresh boot, headset unplugged)

**Before any probe:**
- the zdet regression owed from r188, headset in;
- the digital gate, with the I2S graph added and every pin off;
- mclk-own and vm;
- one HPH listen.

**Probe I (DATA1):**
- the mic at the grille, the operator listening at the grille and the
  earpiece;
- the `Loudspeaker` pin on;
- the first stream at **-60 dBFS**.

  An I2S amp has no analog gain to start low on, so the tone level is the
  only control. -60 dBFS is 20 dB under r187's first stream. Then it steps
  to -50 and -40. -30/-20 need the operator's "declared", as before.

| result | meaning | next |
|---|---|---|
| heard | DATA1 feeds the loudspeaker | its level per step, then left/right (is the amp mono? which slot?) |
| silent to -40, with the AFE port started and the rail on | DATA1 is not the speaker, or the format is wrong | the DATA0 image; then the format (I2S vs left-justified, 32 vs 64 fs) |
| AFE start fails | the DSP refused the port or clock | stop and read the APR error; no escalation |

**Safety:**
- the Volume Down abort is proven at arm time;
- the fail-safe timer;
- one chat approval per stream;
- the pins boot OFF;
- the 5 V rail is under DAPM: on only while the pin and a stream are both
  up, and checked off after every stream.

## 5. Unknown, and how each is settled

- **Which data line:** settled by probe I, then the DATA0 image.
- **The amp's channel use** (mono L, mono R, or (L+R)/2): settled by side
  L/R streams once it sounds.
- **The earpiece:** DATA0? The codec EAR was silent in r187. It is listened
  for on every DATA1/DATA0 stream.
- **The amp's gain, and so the safe ceiling:** settled by measurement at
  -60/-50/-40 dBFS before any declared escalation.

## 6. As built (r189 `spk-i2s-rc1`, card `q6-card-rc8`, pkgrel 189), staged 2026-11-09

**What changed:**
- **The codec:** only its version string changed (no code). Its
  read-bypassed call sites stay at 139.
- **DT** (`qcom-msm8974-microsoft-rm940.dts`, identical in both pmaports
  trees):
  - `sec_mi2s_active`: TLMM 79-82, `sec_mi2s`, 8 mA, no pull.
  - `sec_mi2s_sleep`: `gpio`, 2 mA, pull-down, `output-disable`.
  - Pin 78 is untouched.
  - `q6afedai` `dai@18` (`SECONDARY_MI2S_RX`, `qcom,sd-lines = <1>`).
  - `i2s_spk: audio-amplifier` (`nokia,lumia1520-i2s-spk`, `vdd-supply =
    <&pm8941_5v>`, pinctrl default = sleep, active = active).
  - The third link `sec-mi2s-dai-link`.
  - The compiled DT resolves `vdd-supply` to the PM8941 `s4` node at
    5,000,000 µV.
- **Card** (`snd-soc-lumia1520-q6`, `q6-card-rc8`): the "unknown I2S
  amplifier" component.
  - `SPK 5V` is a DAPM supply on `I2S_SPK_OUT`. Up: regulator, then pins.
    Down: pins, then regulator. A refused pin mux unwinds the rail.
  - Its DAI is 48 kHz, 2 channels, S16_LE.
  - `i2s_spk_state` in sysfs.
  - The MI2S back-end ops: `BP_FP|I2S|NB_NF`, `LPAIF_BIT_CLK` at 1.536 MHz
    at startup and 0 at shutdown.
  - The `Loudspeaker` pin, OFF at init.
  - Two platform drivers, the amplifier's registered first.

**Fences, verifier 5m:**
- 31 checks on the card patch and the DT, plus 2 on the built card module.
- Pre-build: 606 pass. The 3 expected failures are the codec version and the
  two built-card checks, run against r188's modules.
- Mutation: 16/16 caught.

**Tools:**
- **The listen runner, `OUTPUT=i2s`:**
  - the spec is `B:0:84` only, and DBFS may be -60, -50 or -40;
  - the SEC_MI2S mixer is on, with the SLIMbus mixer off (and the reverse
    for codec outputs);
  - it waits on `i2s_spk_state`;
  - live checks: the amplifier `1 1 1`, the regulator class `enabled`, the
    pinmux `sec_mi2s` x4, the codec holding nothing, no SLIMbus stream, no
    MCLK user;
  - after: everything back, and the amplifier's accounting per run.
- **The digital gate** has a second tone through the MI2S back end alone,
  with the Loudspeaker pin OFF. The bit clock must run while the amplifier
  stays unpowered, the rail off and the pins GPIO.
- **The teardown** turns the Loudspeaker pin off too.
- **The selftest:** 105/0.

**Build:**
```
tools/build-wcd9320-kernel.sh --pkgrel 189 --version spk-i2s-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r189 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

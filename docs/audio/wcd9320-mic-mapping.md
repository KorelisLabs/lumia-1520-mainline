# The microphones, mapped from Windows (in progress)

**Status:** map only. Nothing is built or probed.

**Sources:**
- the phone's DSDT (`AUDD.PPNF`, `AUDD.QCRT.DEVI`, `QCRT.LSTN`);
- the ACDB files `Handset_cal_8974.acdb` and `Speaker_cal_8974.acdb` (device properties `0x113b7`/`0x113b8`);
- `Codec_cal_8974.acdb` (the codec-path element lists);
- `qcauddev8974.sys` (register writes through the helper `0x41bf4c(0, reg, mask, shift, value)`, with the value taken from the stack);
- downstream `wcd9320.c` and `wcd9320_registers.h` for register names.

Only derived facts are recorded here.

## 1. The built-in mics are digital: DMIC 1–4 on the WCD9320

Every microphone device in the two ACDB files uses a **DMIC** codec path.
None uses an ADC path.

| ACDB device | name | codec path | AFE port | ch |
|---|---|---|---|---|
| 4 | `HANDSET_MIC` | `DMIC_1` (0x21100) | 0x4001 SLIMBUS_0_TX | 1 |
| 5 | `HANDSET_MIC_BROADSIDE` | `DMIC_1_2_STEREO` (0x21204) | SLIMBUS_0_TX | 2 |
| 6 | `HANDSET_MIC_ENDFIRE` | `DMIC_2_4_STEREO` (0x21203) | SLIMBUS_0_TX | 2 |
| 11 | `SPKR_PHONE_MIC` | `DMIC_4` (0x21103) | SLIMBUS_0_TX | 1 |
| 13, 34, 62 | speakerphone / stereo / fluence dual | `DMIC_2_4_STEREO` | SLIMBUS_0_TX | 2 |
| 12 | `SPKR_PHONE_MIC_BROADSIDE` | `DMIC_1_2_STEREO` | 0x4003 SLIMBUS_1_TX | 2 |
| 19, 101, 102 | speakerphone quad / multi-mic / rear camera | `DMIC_1_2_3_4_QUAD` (0x21400) | 0x4005 SLIMBUS_2_TX | 4 |
| 40 | `NOKIA_CAMERA_MIC` | `DMIC_1_2_3_4_QUAD` | 0x4007 SLIMBUS_3_TX | 4 |
| 41 | quad mic portrait | `DMIC_1_2_3_4_QUAD` | 0x4009 SLIMBUS_4_TX | 4 |
| 63 | fluence quad | `DMIC_1_2_1_3_QUAD` (0x21401) | SLIMBUS_0_TX | 4 |
| 82 | `HANDSET_MIC_HIGH_POWER_LISTEN` | `DMIC_1`, 8 kHz-class | 0x4007 | 1 |

So the four "Rich Recording" microphones are **DMIC1–DMIC4**. The call
microphone is DMIC1. The speakerphone microphone is DMIC4.

## 2. What Windows pairs, and at what format (`QCRT.DEVI`)

Each entry is (RX device, TX device, RX rate, TX rate, RX bits, TX bits).
The entries that matter for capture:

| RX ↔ TX | use | TX format |
|---|---|---|
| 0x07 ↔ **0x04** | handset call: DMIC1 | 48 kHz, **24-bit** |
| 0x46 ↔ **0x0B** | loudspeaker: DMIC4 | 48 kHz, 24-bit |
| 0x23 ↔ 0x04 | EAR+SPK HAC: DMIC1 | 48 kHz, 24-bit |
| 0x07 ↔ 0x28 / 0x13; 0x46 ↔ 0x65 / 0x66 | camera, quad, multi-mic, rear camera | 48 kHz, 24-bit |
| 0x07 ↔ 0x05 / 0x06 / 0x0C / 0x0D / 0x27 | broadside, endfire and variants | 48 kHz, 16-bit |
| 0x0A, 0x09 ↔ **0x08** | headset: the headset mic | 48 kHz, 16-bit |
| 0x25 ↔ 0x24 / 0x40 | Bluetooth SCO | 8 / 16 kHz |

`QCRT.LSTN` names device 0x54 (`HANDSET_MIC_LOW_POWER_LISTEN`) for voice
wake.

**Device 0x08, the headset mic, is not in the two ACDB files we copied.**
Its codec path is still unmapped; it belongs to the headset batch.

## 3. Power: nothing outside the codec (`AUDD.PPNF`)

None of the mic devices (4, 5, 6, 11, 19, 40, 0x65, 0x66) has a PPNF
entry. They get only the default, component 0, the codec MCLK, which is the
same as the earpiece. There is no SoC GPIO, regulator or I2S pin. The DMIC
clock and the microphones' supply come from the codec itself: its DMIC clock
pins and a mic bias.

## 4. Which mic bias feeds which DMIC (ACDB `Codec_cal`)

The codec-path record lists carry element **0x100d**, the mic bias. Its
first action's value is the mic bias number:

| path | 0x100d action 1 | action 2 | action 5 |
|---|---|---|---|
| DMIC_1, DMIC_2 | **1** (MICBIAS1) | 1 | 28 |
| DMIC_3, DMIC_4 | **3** (MICBIAS3) | 1 | 28 |
| DMIC_5, DMIC_6 | 4 | 1 | 28 |
| ADC_1 | 1 | 1 | 40 |
| ADC_2 | **2** (MICBIAS2) | 2 | 42 |
| ADC_3, ADC_4 | 2 | 2 | 40 |
| ADC_5 / ADC_6 | 3 / 4 | 3 | 40 |

**What this gives:**
- **The built-in mics:** DMIC1/2 sit on MICBIAS1, and DMIC3/4 on MICBIAS3.
- **The headset mic:** on Qualcomm reference designs it is ADC2 on MICBIAS2, the MBHC bias. That has to be confirmed in the headset batch.
- **Not yet decoded:** action 2 (possibly the CFILT) and action 5 (28 for DMIC, 40/42 for ADC; possibly a voltage code). Both come from the element handler.

Element **0x1008** is the DMIC element (`3:1008=2`, then `1:1008`), which
likely sets the DMIC clock divider and then enables it. Element 0x1005 is
the TX/decimator element (with gain `6:1005=…`), and element 0x1007 appears
only in the ADC paths.

## 5. The Windows register side (first pass)

The TX side of `qcauddev8974.sys` mirrors downstream's mux controls:
- **Decimator input selects:** `CDC_CONN_TX_B1..B4` (0x393–0x396), per decimator, with DMIC or ADC choices.
- **Decimator DMIC/ADC select:** `CDC_TXn_MUX_CTL` bit 0 (0x223 + 8·(n−1)).
- **SLIMbus TX port muxes:** `CDC_CONN_TX_SB_B1..B10` (0x3a3–0x3ac).

**An init routine** (0x43f27c) sets:
- `LDO_H_MODE_1` (0x110) [3:2] = 3;
- `MICB_CFILT_2_VAL` (0x12f) [7:2] = 0x18;
- bit 0 of `MICB_1_CTL` (0x12b), `MICB_3_CTL` (0x137) and `MICB_4_CTL` (0x13d).

That fits MICBIAS1/3/4 being the ones this board uses.

**No constant-address writes to the DMIC clock registers**
`CDC_CLK_DMIC_B1/B2` (0x304/0x305) were found. They are probably written
through a computed address, which needs the element 0x1008 handler.

## 6. The board values, decoded (second pass)

Downstream takes the mic bias and DMIC values from board data
(`taiko_handle_pdata`). Windows has to set the same registers, so its
values give the Lumia's.

**LDO_H.** Windows' init writes `LDO_H_MODE_1` [3:2] = 3, which is
`WCD9XXX_LDOH_3P0_V`. With that LDO, the CFILT range is 260–2875 mV.

**CFILT voltage.** Downstream's `wcd9xxx_resmgr_get_k_val` gives
mV = 2875 × (k + 4) / 44. Windows writes `MICB_CFILT_2_VAL` = 0x60, so
k = 24 and **1.8 V**.

**ACDB element 0x100d is the mic bias, decoded:**
- action 1 is the mic bias number;
- action 2 is the CFILT number;
- action 5 is the CFILT index (k + 4).

| paths | mic bias | CFILT | index | voltage |
|---|---|---|---|---|
| DMIC_1, DMIC_2 | MICBIAS1 | CFILT1 | 28 | **1.8 V** |
| DMIC_3, DMIC_4 | MICBIAS3 | CFILT1 | 28 | **1.8 V** |
| ADC_1 | MICBIAS1 | CFILT1 | 40 | 2.6 V |
| ADC_2 (presumably the headset mic) | MICBIAS2 | CFILT2 | 42 | 2.7 V |

So the DMICs run on a 1.8 V mic bias, the usual DMIC supply.

**DMIC clock (likely).** The DMIC element's `3:1008=2` matches downstream's
`TAIKO_DMIC_SAMPLE_RATE_DIV_4` = 2. With the 9.6 MHz MCLK that is a
**2.4 MHz DMIC clock**. Downstream programs that code into
`CDC_TXn_DMIC_CTL` [2:0] for every decimator and into the
`CDC_CLK_DMIC_B1/B2` divider fields. The DMIC clock enables are B1 bit 0
(DMIC1/2), B1 bit 4 (DMIC3/4) and B2 bit 0 (DMIC5/6), each refcounted
(`taiko_codec_enable_dmic`).

**Open:**
- Windows' init also sets bit 0 of `MICB_1/3/4_CTL`, which downstream never writes.
- Windows' functions 0x442e58 and 0x443c10 set `MICB_1/2/4_INT_RBIAS` bits; downstream's "Internal" bias variants do the same for ECMs.
- Function 0x421a74 runs a per-bias sequence on `MICB_n_CTL` bit 0 and `0x12d + 6(n−1)` bits 7 and 4, with a delay. It looks MBHC-related.

None of these is needed for an external-bias DMIC. They are recorded for
the headset batch.

## 7. The capture chain, from downstream

For one microphone (DMIC1, the call mic), in DAPM order:
1. **The mic bias:** `MICB_1_CTL` bit 7 (the "External" widget), after `cfilt_get`. Then a **20 ms settle**.
2. **The DMIC clock:** `CDC_CLK_DMIC_B1_CTL` bit 0, refcounted with DMIC2.
3. **The decimator input:** `CDC_CONN_TX_B1` [1:0] = 1 selects DMIC1 for decimator 1 (choices ZERO, DMIC1, ADC6). Then `CDC_TX1_MUX_CTL` bit 0 = 1 selects DMIC rather than ADC.
4. **The decimator** (`taiko_codec_enable_dec`):
   - PRE_PMU: TX digital mute on (`TX1_VOL_CTL_CFG` bit 0), a reset pulse on `CDC_CLK_TX_RESET_B1` bit n, the HPF cut-off forced to 150 Hz (`TX1_MUX_CTL` [5:4] = 1) and the HPF enabled (bit 3 = 0);
   - the TX clock, `CDC_CLK_TX_CLK_EN_B1` bit n;
   - POST_PMU: mute off, the HPF cut-off restored after 300 ms, and the digital gain (`TXn_VOL_CTL_GAIN`) rewritten.
5. **The SLIMbus TX port:** `CDC_CONN_TX_SB_B1` = 8 routes DEC1 to SLIM TX1. Windows writes the same mux values 1–8 and 1–0x11.
6. **The capture interface:** AIF1 CAP, on codec TX ports 0–15. `taiko_tx_chs` maps TX port n to channel n; the RX ports start at 16.

## 8. The SLIMbus TX side (mapped from mainline WCD9335)

Mainline's `wcd9335.c` and `wcd9335.h` drive the same SLIMbus "PGD"
interface-device layout our RX code already uses. That code programs
`PORT_CFG(16)` at 0x40 and the multi-channel register at 0x180, which is
0x140 + 4·16.

| | RX (ours, proven) | TX (to build) |
|---|---|---|
| port config | `0x30 + port` (port 16 → 0x40) | **`0x50 + port`** (TX port 0 → 0x50) |
| channel bitmap | `0x140 + 4·port` | **`0x100 + 4·port`**, plus `0x101 + 4·port` for TX ports 8 and 9 |
| SLIMbus channel | 144 + n (we use 144/145) | **128 + n**: DMIC1 on TX port 0 → channel 128 |
| slim stream | direction PLAYBACK, port mask BIT(16) | direction **CAPTURE**, port mask BIT(0) |
| port interrupts | `PORT_INT_*_RX_0/1` | `PORT_INT_*_TX_0/1`, already counted in our IFD snapshot |

The codec answers `get_channel_map` with `tx_slot[] = { 128 }` for its
capture DAI. The card hands that to q6afe's `set_channel_map`, as it already
does for RX.

## 9. The DSP side

- **q6afe** already supports `SLIMBUS_0_TX`: the q6slim ops, the DAPM route `SLIMBUS_0_TX` ← "Slimbus Capture", and `set_channel_map` for TX slots. Our DT declares only `dai@2 = SLIMBUS_0_RX`, so it needs a `SLIMBUS_0_TX` child.
- **q6asm** declares only `MULTIMEDIA1` with `direction = Q6ASM_DAI_RX`. Capture needs a second front end, for example `MULTIMEDIA2` with `direction = Q6ASM_DAI_TX`.
- **q6routing** connects them with the UL mixer, "MultiMedia2 Mixer" / `SLIMBUS_0_TX`, the capture twin of "SLIMBUS_0_RX Audio Mixer MultiMedia1".
- **The codec** has a single DAI today, with `#sound-dai-cells = <0>`. Capture adds AIF1 CAP as a second DAI, so it becomes `<1>`: the playback link names `<&wcd9320 0>` and capture `<&wcd9320 1>`. The artefact gate's `--expect-dais` goes from 1 to 2.

## 10. Build plan (not started)

**C1 (codec, `wcd9320-core.c`):**
- **The capture DAI:** AIF1 CAP, "WCD9320 SLIM TX1 Capture". Its `hw_params` programs TX port 0 (`0x50`, `0x100` bit 0), and the slim stream runs CAPTURE on channel 128. `get_channel_map` returns TX slot 128.
- **DAPM stages,** the same verified-write and refusal discipline as the outputs:
  - the mic bias (LDO_H 3.0 V, CFILT1 1.8 V, `MICB_1_CTL` bit 7, 20 ms settle);
  - the DMIC1 clock (DIV_4, 2.4 MHz);
  - DEC1 (fixed to DMIC1, with the downstream enable sequence);
  - SLIM TX1 = DEC1;
  - AIF1 CAP.
- **Evidence:** `capture_state` in sysfs.

**C2 (DT and card):**
- the `SLIMBUS_0_TX` AFE DAI and the `MULTIMEDIA2` TX front end;
- the "MultiMedia2 Capture" and "SLIM Capture" links;
- the card's back-end `hw_params` hands the TX slots to q6afe, and the capture fixup starts mono S16 at 48 kHz, with 24-bit after;
- the routing control.

**Test:**
- **A capture tool on the phone,** the capture twin of `pcm-tone`, which writes a WAV.
- **The silent floor first,** the phone face up and the room quiet.
- **Then the tone:** the PC plays a 1 kHz tone at a fixed level (`c3a-capture.py play`), and the existing analyser checks it on the PC.
- **Approval:** nothing on the phone drives a transducer, so the gate is one go per run, rather than the per-stream amplifier gates.

## 11. Still to map

1. Whether 24-bit capture needs anything on the codec side. The SLIMbus word length is set by the stream config. The DSP side is 24-bit capable.
2. The TX digital gain default (`TXn_VOL_CTL_GAIN`), and a sensible starting level.
3. The headset mic, device 0x08, in the headset batch.

## 12. r197 (`capdmic-rc1`, card `q6-card-rc12`, pkgrel 197): staged 2026-11-13

**Codec (C1):**
- **A capture path of its own.** It has six DAPM supply stages:
  1. cap MCLK, the proven `mclk_get` / `mclk_put`;
  2. cap prereq, the proven `cdc_clk_prereq`;
  3. MIC BIAS1, which turns LDO_H on at 3.0 V, then a 1 ms settle, then CFILT1 at k = 24 (1.8 V), the bias on CFILT1 and the bias on, then a 20 ms settle;
  4. the DMIC1/2 clock at DIV_4 (2.4 MHz), with DEC1's DMIC rate set to DIV_4;
  5. DEC1: CDC_CONN, the input set to DMIC1, the DMIC select, mute, a reset pulse, the HPF at 150 Hz and on, the TX clock, unmute, and the gain rewritten;
  6. SLIM TX1 = DEC1.

  Every field is measured first and restored masked in reverse at teardown. The reset pulse sits outside the tables.
- **The event.** Capture has its own held mask and event function. Its stage 0 requires an idle codec. While capture holds MCLK and the prereq, every output's stage 0 refuses. That keeps the rule of one path at a time, with capture included, and leaves the proven output code untouched. A failed stage unwinds capture.
- **The TX DAI.** AIF1 CAP, "WCD9320 SLIM TX1 Capture", is mono:
  - `hw_params` programs TX port 0 in the interface device: the bitmap 0x100 = 01, then the config 0x50. The reverse happens at `hw_free`.
  - The SLIMbus runtime is its own, CAPTURE on channel 128.
  - `get_channel_map` reports TX slot 128.
- **Evidence:** `capture_state` (the stages, the TX port and stream, and 13 registers live from the chip).

**DT and card (C2):**
- the AFE `SLIMBUS_0_TX` DAI (id 3) and the `MULTIMEDIA2` TX front end;
- the codec's `#sound-dai-cells` is now `<1>`, with playback as `<&wcd9320 0>` and capture as `<&wcd9320 1>`;
- the links "MultiMedia2 Capture" and "SLIM Capture";
- the card fixes the capture back end at mono, 48 kHz, S16, and relays the TX slots to q6afe;
- a **"Handset Mic"** pin on DMIC1 is OFF at init, like every output pin.

**The route to record:**
- "MultiMedia2 Mixer SLIMBUS_0_TX" = 1;
- "Handset Mic Switch" = 1;
- open the capture PCM (`/dev/snd/pcmC0D*c`).

**Tools:**
- **`pcm-capture.c`:** raw ioctls, a static musl build, a WAV out, and the stats printed.
- **`build-pcm-capture.sh`:** builds it in the armv7 buildroot.
- **`wcd9320-capture.sh`:**
  - preflight: the versions, every output idle, capture idle, and the pin and mixer off;
  - the run: the mixer and pin on, record, the pin and mixer off;
  - 41 checks: every mapped field live, and every register back as found after.
- **The card version** in the runners is now rc12.

**Verification:**
- **Compile:** `W=1` is clean for the codec and the card, and the DT compiles through cpp and dtc.
- **Pin:** `read_bypassed_calls` is 146, from +2 measured in the compile-check tree (138 → 140).
- **Fence 5u** has 30 checks. The widget, route, NOPM and pins-off fences and the capture-stream check were updated.
- **Results:** 726 checks pass. The only 3 failures are against the old r196 build: its version, its pin and its card version.
- **Mutation test:** 21/21.
- **Selftest:** 131/0.

**Build:** both commands, `--expect-dais 2` now:
```
tools/build-wcd9320-kernel.sh --pkgrel 197 --version capdmic-rc1 \
    --expect-asoc --expect-dais 2 --stage ~/r197 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
tools/build-pcm-capture.sh --stage ~/r197
```

**Test plan, after the gates:**
1. **A silent capture, 5 s:** the noise floor and the path proof.
2. **A 1 kHz tone from the PC speaker** (`c3a-capture.py play`) at a fixed distance, 5 s, analysed on the PC.

Each run needs one chat go. Nothing on the phone drives a transducer.

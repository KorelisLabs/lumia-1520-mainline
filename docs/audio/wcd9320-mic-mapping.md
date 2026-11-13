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

## 6. Still to map

1. **The element handlers 0x100d (mic bias), 0x1008 (DMIC) and 0x1005 (decimator):** the exact register writes and values, including the DMIC clock divider and the mic bias voltage.
2. **Downstream:** `taiko_codec_enable_dmic`, the mic bias and CFILT sequencing, the decimator enable and its "TX path HPF/volume" settle, the TX SLIMbus ports and the codec's capture DAI (AIF1 CAP).
3. **Our SLIMbus side:** TX ports and channels. Our stream code covers RX only.
4. **QDSP6:** the AFE `SLIMBUS_0_TX` port and ASM capture, and the card's capture link.
5. **The headset mic,** device 0x08, in the headset batch.

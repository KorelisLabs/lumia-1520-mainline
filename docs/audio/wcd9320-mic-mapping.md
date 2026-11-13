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

## 8. Still to map

1. **Our SLIMbus side:** TX ports and channels. The stream code covers RX only; TX port 0 to the ADSP's SLIMBUS_0_TX is the first target.
2. **QDSP6:** the AFE `SLIMBUS_0_TX` port, ASM capture, and the card's capture link and routing.
3. **The decimator details still worth checking:** the `TXn_VOL_CTL_GAIN` default, the TX path HPF settle, and whether 24-bit needs anything codec-side (the SLIMbus word length).
4. **The headset mic,** device 0x08, in the headset batch.

## 9. Proposed build order (not started)

- **C1 (codec):** MICBIAS1 at 1.8 V, the DMIC1 clock at 2.4 MHz, decimator 1 from DMIC1, and SLIM TX1 from DEC1. These go in as DAPM stages under the same verified-write discipline as the outputs, with a `capture_state` sysfs attribute.
- **C2 (SLIMbus):** TX port 0 on the slave and its channel, mirroring the RX stream code.
- **C3 (card and Q6):** a capture DAI link (SLIMBUS_0_TX to AIF1 CAP), with the MultiMedia1 capture route.
- **Test:** the PC plays a 1 kHz tone at a fixed level near the phone while it records 48 kHz audio; the analyser checks the tone's level and the noise floor. A silent capture first gives the floor. Approval gates as for playback; capture itself drives nothing audible.

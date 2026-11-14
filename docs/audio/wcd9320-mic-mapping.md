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
   - PRE_PMU: TX digital mute on (`TX1_VOL_CTL_CFG` bit 0), a reset pulse on `CDC_CLK_TX_RESET_B1` bit n, the HPF cut-off forced to 150 Hz (`TX1_MUX_CTL` [5:4] = **2**; downstream's own comment says 0x1, but `CF_MIN_3DB_150HZ` is 2 and 1 is 75 Hz — corrected in r200) and the HPF enabled (bit 3 = 0);
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
  5. DEC1: CDC_CONN, the input set to DMIC1, the DMIC select, mute, a reset pulse, the HPF at 150 Hz and on (in fact 75 Hz, kept for the whole stream; see section 15), the TX clock, unmute, and the gain rewritten;
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

## 13. r197 result, and r198 (`capsel-rc1`, pkgrel 198): staged 2026-11-13

**r197 on the phone.** The gates were green: dapm 83/0, mclk-own 90/0 and vm 57/0. The card registered 5 links, and the capture PCM is `pcmC0D3c`. Three DMIC1 recordings followed:

| run | runner | peak | RMS | reading |
|---|---|---|---|---|
| silent, 5 s | 39/4 (a runner timing bug and a chip-owned bit) | 5 | −86 dBFS | idle; nearly all the power is DC and < 100 Hz |
| PC tone, 1 kHz at −20 dBFS, heard in the room | 43/0 | 5 | −86 dBFS | **no tone** (1 kHz at −118 dBFS) |
| blowing and tapping on the bottom edge | 43/0 | **69** | −80 dBFS | rhythmic bursts, 53% of the power in 100–1000 Hz |

**What the runs establish:**
- The whole capture chain works end to end: the stages, the TX port and the SLIMbus stream on channel 128, the DSP, the PCM and the WAV.
- Every mapped register reads as intended while live, and is restored after.
- **But DMIC1 delivers about 50 dB too little.** That is what reading the wrong slot of a shared DMIC data line would look like: DMIC1 and DMIC2 share a pin and are told apart by the clock edge. The other possibility is that the call mic sits on the DMIC3/4 pair.

**Runner fixes:**
- It polls for `cap_held=3f` and `tx_up=1` rather than sampling at a fixed 1 s.
- The volume config register (0x222 for DEC1) is compared on bit 0 only. The chip sets bit 3 itself during a stream.

**r198, `cap_dmic` (1–4, DMIC1 by default):**
- DMIC *n* goes through decimator *n* (`CONN_TX_B1` field *n* = 1), then SLIM TX*n* (`0x3a3 + n−1` = 8, which is DEC*n* on every one of TX1–TX4 in downstream), then TX port *n*−1 on channel 128 + *n*−1. The port's channel bitmap carries the port's own shift.
- **The pair** sets the clock (B1 bit 0 and [3:1] for DMIC1/2, bit 4 and [7:5] for DMIC3/4) and the bias (MICBIAS1 or MICBIAS3). Both biases sit on CFILT1 at 1.8 V, because the ACDB gives every DMIC path CFILT1, index 28.
- **The tables** are built by `wcd9320_cap_build()` at capture stage 0 and kept until the next build. The switch is refused while capture, the TX port or a TX stream runtime is up.
- **`capture_state`** reports the shared registers plus the selected decimator's (`micb`, `gain`, `volcfg`, `mux`, `txdmic`, `sbtx`), and `cap_dmic` / `tx_port`.
- **The runner** takes `CAP_DMIC=1..4`, with the live checks computed for *n*.
- **Verification:**
  - **Compile:** `W=1` is clean.
  - **Pin:** unchanged at 146 (140 in the compile-check tree).
  - **Fence 5u:** the table checks were rewritten for the builder, and new checks cover `cap_dmic` and the pair logic.
  - **Results:** 726 checks pass. The only failure is the old r197 build's version.
  - **Mutation test:** 9/9.
  - **Selftest:** 131/0.
- **Unchanged:** the card and `pcm-capture`.

**Build:**
```
tools/build-wcd9320-kernel.sh --pkgrel 198 --version capsel-rc1 \
    --expect-asoc --expect-dais 2 --stage ~/r198 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

**Test:** four tap-and-blow recordings, `CAP_DMIC=1`, 2, 3, 4, with one go for the set. Whichever line reaches near full scale carries the mic nearest the bottom edge, and the others show where the remaining mics answer.

## 14. r198 result, and r199 (`capgain-rc1`, pkgrel 199): staged 2026-11-14

**r198 on the phone.** The gates were green. Four tap-and-blow recordings ran, one per DMIC line (`CAP_DMIC=1..4`), and every run passed 45/45:

| line | RMS while blowing and tapping | peak | strongest band |
|---|---|---|---|
| DMIC1 | **−69.5 dBFS** | 93 | 85% below 300 Hz (blowing) |
| DMIC2 | −79.0 dBFS | 131 | 45% at 300 Hz–3 kHz |
| DMIC3 | −82.7 dBFS | 86 | 46% at 3–8 kHz |
| DMIC4 | −76.0 dBFS | 63 | 91% below 300 Hz |

The idle floor is −86 dBFS on every line, with the same DC offset of −0.48.

**What the runs establish:**
- **All four lines respond to acoustic input.** DMIC1 carries the most blowing energy, so it is likely the mic nearest the bottom edge.
- **Every line is about 40–50 dB too quiet,** so the shared-line theory is out.
- The cause is common to the path. The candidates are a missing digital gain (the ACDB's decimator element carries **30** for DMIC_1, against 5 for the analog paths), or DMICs running outside their normal mode.

**r199, "Capture Digital Volume":**
- **The control:** 0..124 = −84..+40 dB, in 1 dB steps (downstream's DECn Volume range). The default is 84 = 0 dB, the level r197 and r198 used.
- **How it is written:** the value is the decimator post-table's last write, so it is measured first and restored at teardown. It also moves the chip live while the decimator is up. This replaces r197's read-and-rewrite of the gain register.
- **The runner:** `CAP_GAIN=0..124`. A live check confirms the gain register equals the control, and the control ends as found.
- **Verification:**
  - **Compile:** `W=1` is clean.
  - **Pin:** unchanged at 146.
  - **Fences:** the controls list and fence 5u's builder rows are updated, plus a new control check.
  - **Results:** 727 checks pass. The only failure is the old r198 build's version.
  - **Mutation test:** 4/4.
- **Unchanged:** the card and `pcm-capture`.

**Test:** DMIC1 at `CAP_GAIN=114` (+30 dB), with tap-and-blow and then the PC tone.
- **If the gain is what was missing:** both scale up cleanly, and the tone appears.
- **If they do not:** the mics are not in their normal mode, and the DMIC clock pin or pad mode is next.

## 15. r199 result, and r200 (`hpfsettle-rc1`, pkgrel 200): staged 2026-11-14

**r199 on the phone.**
- **Gates:** digital 83/0, MCLK ownership 90/0, vm 57/0, cache 0 mismatches. "Capture Digital Volume" is present and reads 84 (0 dB).
- **Recordings:** five, each at `CAP_GAIN=114` (+30 dB) and 6 s, and every run passed 47/47.

| run | line | result |
|---|---|---|
| tap and blow | DMIC1 | Floor −88 → −56.6 dBFS, the same +30 dB. Blowing reaches −20 dBFS RMS (22 samples touch full scale). Taps arrive about 190 ms apart, each decaying over roughly 100 ms. |
| PC tone, twice | DMIC1 | Not detectable, either before or after the phone was moved back to its usual spot. The 1 kHz bin stays within ±10 dB of its neighbours. |
| claps, ~15 cm, no contact | DMIC1 | Clear: peaks of −26 to −34 dBFS against −55 to −58, with 60% of the energy at 300 Hz–3 kHz and 33% at 3–8 kHz. |
| counting, normal voice, ~15 cm | DMIC1 | Median −40 dBFS, peak −31.5, 15–25 dB above the floor. |
| counting, normal voice, ~15 cm | DMIC4 | Median −44.7 dBFS, peak −36, about 4 dB below DMIC1 and weighted more to low frequencies. |

The user listened to the normalised voice and clap recordings and reported they "sound great".

**What the runs establish:**
- **The DMICs work.** r198's 40–50 dB shortfall was the decimator gain.
- **Windows likely runs at +30 dB.** The ACDB decimator element (0x1005) carries 30 for DMIC_1, which fits a +30 dB setting.
- **The PC speakers can't serve as a mic test source.** They are far too quiet at the phone; use voice or claps.
- **Not yet decided:** the default gain belongs to the UCM, not the driver.

**A bug the recordings exposed: the HPF cut-off.**
- `TXn_MUX_CTL` [5:4] is the decimator's high-pass corner: 0 = 4 Hz, 1 = 75 Hz, 2 = 150 Hz (downstream `CF_MIN_3DB_*`).
- r197–r199 wrote 1 under the label "150 Hz", taken from downstream's comment ("CF_MIN_3DB_150HZ (0x1)"). That gave 75 Hz, kept for the whole stream.
- Downstream does something different in `taiko_codec_enable_dec`. It forces 150 Hz only while the decimator settles; 300 ms after POST_PMU, `tx_hpf_work` restores the cut-off it found. The reset default is 0, which is 4 Hz.

**r200, "the HPF settle":**
- **The value:** the post table's first row writes a true 150 Hz (`WCD9320_CAP_HPF_150HZ` = 0x20). It is still measured first and restored at teardown.
- **Arming:** after the post table, the decimator stage arms a 300 ms delayed work. If the measured cut-off was already 150 Hz, there is nothing to restore and it doesn't arm.
- **The work:** under `c3_lock`, it writes the measured cut-off back, only while still armed and while the decimator is held. A leftover run from an earlier stream sees the new deadline and reschedules, so it cannot cut a new settle short.
- **Disarm:** at decimator teardown, a non-waiting cancel. The work takes `c3_lock`, which teardown already holds, so a waiting cancel could deadlock.
- **Unbind:** a devm action cancels synchronously, unwinding after the component and before power and the regmap.
- **Observable:** `capture_state` adds `hpf_armed`, `hpf_found`, `hpf_settles` and `hpf_errors`.
- **The runner** waits out the settle, then checks:
  - the HPF is on;
  - the cut-off came back as found;
  - the settle ran once, with no errors.
- **The verifier:**
  - the builder row is updated;
  - two new HPF fences cover the value, the arm/disarm order and the work;
  - a third covers the cancel discipline and the devm order.
- **Copies corrected:** the 150 Hz statements in sections 7 and 12.
- **Unchanged:** the card, `pcm-capture`, the DT and the pin (146). No new baseline reads.

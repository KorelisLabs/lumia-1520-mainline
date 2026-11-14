# WCD9320 full duplex (calls): first mapping pass

Status: mapping, 2026-11-14. Nothing is built yet. This follows the mic work
(`wcd9320-mic-mapping.md`, r197–r200), where both call mics record cleanly.

## 1. What "calls" needs, in three tracks

A call plays and records at the same time. That splits into three tracks:

| track | what | owner | state |
|---|---|---|---|
| **A** | Codec full duplex: an output and capture up together | our WCD9320 driver | mapped below |
| **B** | The DSP voice stack: MVM/CVS/CVP route modem audio to the AFE ports | `q6voice` (not in mainline) | not mapped |
| **C** | The cellular modem (MSS/Q6V5), rmtfs, QMI, ModemManager | separate project | README: untested |

Track A is needed for every kind of call, VoIP included, and for any app that
plays and records at once.

Tracks B and C apply only to cellular calls. The ADSP does advertise the voice
services: MVM 0x9, CVS 0xA and CVP 0xB (`msm8974-q6-control-plane-mapping.md`).

**The earpiece is out.** Its load is open (`wcd9320-r194-earpiece-mapping.md`),
so a handset call has to use headphones, a headset or the loudspeaker
(speakerphone).

## 2. Today: capture is exclusive with every codec output

- **Capture's first stage** refuses unless `wcd9320_dapm_idle()` holds: no MCLK user, no prereq, no output flag.
- **Every output's first stage** refuses on the same check, and capture holds MCLK and the prereq.
- **The outputs** are also exclusive with each other: one codec output at a time (r187).

## 3. What capture and the codec outputs share

Every register in capture's tables, checked against every other writer in the driver:

| shared item | capture | outputs | research paths | verdict |
|---|---|---|---|---|
| MCLK (RPM vote + RCO→MCLK switch) | stage 0 | stage 0 | runner | **already refcounted** (`mclk_users`, r182) |
| `CDC_CLK_POWER_CTL` 0x314 = 03 (the prereq) | stage 1 | stage 2 | runner | **a bool; a second enable returns -EBUSY** |
| `CDC_CLK_OTHR_CTL` 0x30c | bit 2 (CDC_CONN) | bit 0 (class-H CP clock) | — | separate bits, masked writes: no conflict |
| LDO_H 0x110, CFILT1 0x128/0x129 | the mic bias | — | the voltmeter (`wcd9320_vm_regs`) | research only, see section 5 |
| MICB1/3, DMIC clock, decimator, TX clock, CONN_TX, SB mux | capture only | — | — | no conflict |
| SLIMbus | TX port n-1, channel 128+n, its own stream runtime | RX ports 16/17, channels 144+, own runtime | — | separate PGD registers and runtimes |
| Q6 | MultiMedia2 → SLIMBUS_0_TX | MultiMedia1 → SLIMBUS_0_RX / SEC_MI2S_RX | — | separate ASM sessions and AFE ports |

**Downstream** (`wcd9320.c`) treats these as follows:
- **0x314:** it writes 0x03 once, in the init register table (`TAIKO_REG_VAL(TAIKO_A_CDC_CLK_POWER_CTL, 0x03)`), and never clears it. A shared, refcounted prereq is at least as faithful as our per-path enable.
- **CDC_CONN** (0x30c bit 2): a DAPM supply used only by the DEC muxes, I2S RX and ANC.
- **LDO_H, mic bias and CFILT:** refcounted (`ldo_h_users`, `micb_2_users`, `wcd9xxx_resmgr_cfilt_get/put`) because MBHC shares them. Our jack detection is the mechanical switch on 0x14a only, so nothing else uses them in normal operation.

## 4. The abort path takes the prereq unconditionally

`wcd9320_c3_abort()` runs on any output stage failure. It calls `wcd9320_cdc_clk_prereq(wcd, false)` whoever holds it. During a call, an output failure would drop capture's prereq too.

## 5. Two research paths ignore capture today (a hole since r197)

- **`wcd9320_hphl_vm`** requires only that the codec is on MCLK. Capture puts it on MCLK, so the voltmeter could run mid-recording. It writes LDO_H and CFILT1, which would move the mic bias.
- **`wcd9320_hphl_zdet`** checks the HPH analog flags, not capture.

Both should refuse while `dapm_held_cap` is non-zero.

## 6. The loudspeaker does not touch the codec at all

"Loudspeaker" is the card's own I2S output (`I2S_SPK_OUT`: SEC_MI2S → TAS2552). It holds no codec MCLK and no prereq, and nothing in the codec's idle check sees it. So **loudspeaker + mic should already run together on r200**, which is the speakerphone case (Windows' speakerphone mic is DMIC4).

That gives a no-build first test of duplex at the DSP level: two ASM sessions, SLIMBUS_0_TX alongside SEC_MI2S_RX. It is also the first acoustic loop with a known source, which the PC tone could not provide.

## 7. Proposed order

1. **Duplex probe 0 (no kernel build, tools only):** a runner that records DMIC4 (then DMIC1) at +30 dB while the loudspeaker plays the 1 kHz stimulus at −40 dBFS or below.
   - It checks both streams ran without xruns, the tone in the recording, and both paths torn down as found.
   - Above −40 dBFS needs the user's "declared".
2. **r201, codec duplex.**
   - **The prereq gets owners** (a bitmask: output DAPM, capture, research). Enable and disable are per owner; the hardware write happens on the first owner and the restore on the last.
   - **`wcd9320_c3_abort()`** drops every owner except capture.
   - **The idle checks split.** An output's first stage tolerates exactly capture's MCLK reference and prereq ownership. Capture's first stage tolerates exactly one DAPM-owned output (its masks account for its MCLK reference). Research paths stay exclusive with both.
   - **The voltmeter and zdet** refuse while capture holds anything.
   - **Test:** headphones playing while DMIC1 records.
3. **Track B/C mapping:** the modem bring-up (PAS like the ADSP, plus rmtfs and QMI), then `q6voice`. postmarketOS carries an out-of-tree `q6voice` for MSM8916; whether it fits MSM8974's ADSP is the first question.

## 8. Probe 0 result (r200, 2026-11-14): speakerphone duplex works with no build

One run of `tools/wcd9320-duplex-probe.sh`:
- **Setup:** DMIC4 (the speakerphone mic) at +30 dB for 8 s, while the loudspeaker played the 1 kHz stimulus twice at −40 dBFS (Loudspeaker Volume 22, +15 dB).
- **Checks:** the capture runner passed 49/49 and the probe 15/15.
- **Live, mid-stimulus:** the I2S path was up (rail, pins, BCLK) and capture held all six stages. The codec held no output and one MCLK user (capture).
- **After:** everything was down, and every control was back as found.

The recording:
- **Both plays are there:** at about 1.3 s and 3.45 s, each with its tone/silence/tone shape.
- **The 1 kHz bin** sits about 48 dB above its neighbours, at −47.6 dBFS. On quiet stretches the pattern score is 0.2 dB. This is the first acoustic loop with a source we control.

**A floor finding, from r200.** The floor between sounds is −45 dBFS broadband, against −56 in r199's quiet runs. The excess is entirely infrasonic:

| band | r199 floor (75 Hz HPF) | r200 floor (4 Hz after the settle) |
|---|---|---|
| < 20 Hz | −58.5 | **−46.1** |
| 20–75 Hz | −59.8 | **−51.6** |
| 75–150 Hz | −70.9 | −69.2 |
| 300 Hz–3 kHz | −73.0 | −77.1 |

- **What it is:** the r200 settle restores the reset cut-off (4 Hz), as downstream does, so room and handling rumble below 75 Hz now passes. The audible band is unchanged.
- **How downstream handles it:** the restored value is whatever its "TX HPF cut off" control holds, so the use-case configuration picks the corner.
- **Proposed for r201:** a "Capture HPF Cut-off" control (4 / 75 / 150 Hz) that the settle restores to. The driver default stays at the measured value, and the UCM picks 75 or 150 Hz for voice.

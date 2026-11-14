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

## 9. r201 (`duplex-rc1`, pkgrel 201): staged 2026-11-14

**The prereq has owners.**
- `WCD9320_PRQ_OUT` (a DAPM output), `_CAP` (capture) and `_RES` (the research attribute and runners).
- The first owner measures 0x314 and writes 03. A later owner only joins the mask, and an owner leaving while others remain only leaves it. The last owner restores the measured value.
- A second enable by the same owner still returns -EBUSY.
- Every caller names itself: outputs 4, capture 1, research 2. The signature change made the compiler find every call site.
- `wcd9320_c3_abort()` releases `OUT` and `RES` and never `CAP`, so an output failure mid-call leaves capture running.

**The idle checks split.**
- **`wcd9320_out_flags_idle()`:** every output flag off. `wcd9320_dapm_idle()` is that plus no MCLK user and no prereq, unchanged in meaning.
- **An output's first stage** uses `wcd9320_idle_but_capture()`: MCLK users equal capture's own reference (0 or 1), the prereq owners are a subset of `CAP`, and every output flag is off. Outputs stay exclusive with each other.
- **Capture's first stage** uses `wcd9320_idle_but_outputs()`. Every MCLK reference must be an output path's own first stage, and the prereq the outputs' alone, so a research path's MCLK or prereq refuses capture. With no output up it is `dapm_idle()`.
- **Counters** in `capture_state`: `out_beside_cap` and `cap_beside_out` count each kind of duplex start. `prereq_owners` shows the mask.

**The research guard.** `wcd9320_research_refuse()` refuses while DAPM holds any output or capture. It applies to every hook that writes outside the ownership model:
- the voltmeter and zdet, which run under `c3_lock`;
- `rdac_probe`, `writability_test` and `chip_ctl_test`, which take the lock for the check alone.

The gate runners all run those hooks with DAPM idle, so they are unaffected.

**Capture HPF Cut-off.**
- An enum control (4 / 75 / 150 Hz) that the r200 settle ends at, as downstream's `tx_hpf_work` ends at its "TX HPF cut off" control.
- The default at probe is 4 Hz, the reset value. While a settle is armed, a change is picked up by the work; after the settle, the chip moves at once.
- Teardown still restores the measured value.

**Runners.**
- **`wcd9320-capture.sh`:**
  - `CAP_HPF` sets the control for the run, and the settle check now expects the control's value.
  - `DUPLEX=1` relaxes the preflight and the live checks to exactly one output beside capture: MCLK 1–2, prereq owners 2–3.
  - Not in duplex mode, it checks that capture alone owns the prereq.
- **`wcd9320-duplex-probe.sh`:**
  - `OUTPUT=hph|i2s` and `ORDER=cap-first|out-first`.
  - For the headphones it checks, live: the nine stages, both PAs, `mclk_users=2` and `prereq_owners=3`.
  - It also checks the duplex counter for the order, no refusals, everything down after and every control as found.

**Verification.**

| check | result |
|---|---|
| Compile | `W=1` clean; no new baseline reads (pin stays 146) |
| Verifier | 738 checks pass; the only failure is the old r200 module's version |
| Fences | moved to the new call forms, plus nine new r201 fences |
| Mutation | 19/19: r199's 4, r200's 6 and r201's 9 |
| Selftest | 131/0 |

**Test plan:**
1. The gates.
2. The capture runner alone (`DUPLEX=0`) at `CAP_HPF=1` (75 Hz).
3. `OUTPUT=hph ORDER=cap-first` on DMIC1, with the user wearing the headphones and counting aloud.
4. `ORDER=out-first`.

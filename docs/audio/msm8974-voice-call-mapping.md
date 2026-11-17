# Call audio (M6): mapping

**Status:** map only. Nothing is built or probed. No SIM, so no real call can be placed; see section 6 for what can be proven without one.

**Sources:**
- **[DS]** downstream msm8974: `sound/soc/msm/qdsp6v2/q6voice.c`, `q6voice.h`, `msm-pcm-voice-v2.c`, `msm-pcm-routing-v2.c` (LineageOS `android_kernel_oneplus_msm8974` cm-14.1).
- **[OOT]** postmarketOS / msm8916-mainline out-of-tree driver: `sound/soc/qcom/qdsp6/q6voice*.c`, `q6mvm.c`, `q6cvp.c`, `q6cvs.c` (branch `wip/msm8916/7.0`, Stephan Gerhold, "ASoC: qdsp6: Add Q6 Voice DAI driver (v2.1)"). Mainline has no voice driver at all.
- **[WP]** the phone's Windows Phone install (MainOS, mounted read-only):
  - `qcaud8974.sys` strings;
  - all eight ACDB files (`*_cal_8974.acdb`), decoded with throwaway parsers.

  Analysis only; the blobs live in WSL `~/winaudio` and are never committed.

## 1. What a call needs on the DSP side

The voice services live on the **ADSP**, beside the audio services we already use:
- MVM 0x9, CVS 0xA, CVP 0xB are on the same APR (`apr_audio_svc`) edge.
- The inventory probe saw all three (`msm8974-q6-control-plane-mapping.md`).
- [DS] addresses every VSS command to the ADSP. The "MODEM" APR registrations are only for restart notifications.

For a cellular (CS) call, the modem owns the vocoder and the ADSP owns the device-side processing. The apps processor only sets up the ADSP side and names the two AFE ports.

**[DS] sequence for a CS call:**

| # | Command | ID | Notes |
|---|---|---|---|
| 1 | MVM `CREATE_PASSIVE_CONTROL_SESSION` | 0x110FF | name "default modem voice" |
| 2 | CVS `CREATE_PASSIVE_CONTROL_SESSION` | 0x11140 | same name; [OOT] skips CVS |
| 3 | `VSS_IMEMORY_CMD_MAP_PHYSICAL` | 0x11334 | calibration memory; "continue without calibration" on failure |
| 4 | MVM `SET_POLICY_DUAL_CONTROL` | 0x11327 | enable = 1 |
| 5 | CVP `CREATE_FULL_CONTROL_SESSION_V2` | 0x112BF | see below |
| 6 | calibration registration | 0x11369 / 0x11371 / 0x11373 / 0x11374 | each skipped when there is no calibration |
| 7 | CVP `ENABLE` | 0x100C6 | |
| 8 | MVM `ATTACH_VOCPROC` | 0x1123E | CVP handle |
| 9 | volume and mute | 0x112C2 / 0x1138B | |
| 10 | MVM `START_VOICE` | 0x11190 | |

**CVP create payload** (step 5): direction 2 (RX+TX), tx_port, tx_topology, rx_port, rx_topology, profile `NETWORK_ID_NONE` (0x1135E), vocproc_mode `EC_INT_MIXING` (0x10F7C), ec_ref_port `NONE` (0xFFFF).

**Teardown:** `STOP_VOICE` 0x11192, `DETACH_VOCPROC` 0x1123F, deregister calibration, `DESTROY_SESSION` 0x1003C on CVP. [DS] keeps the passive MVM and CVS sessions across calls.

**[OOT]** is the same minus CVS and calibration:
- MVM passive "default modem voice", dual control, CVP V2 with 0x10F71/0x10F77, enable, attach, start.
- Teardown: stop, detach, disable, destroy.
- Exposed as a `CS-VOICE` DAI (8 kHz mono) whose RX/TX mixers pick the AFE ports. Sessions start only when both directions are open.
- DT: `qcom,q6mvm` service 9 (with a `qcom,q6voice-dais` child), `qcom,q6cvs` 0xA, `qcom,q6cvp` 0xB.
- Known on MSM8916 phones, where the same services live on the modem DSP. Never tried on MSM8974.
- One defect to fix in the port: `q6cvp_session_create()` sends an uninitialised `name[20]` stack buffer.

## 2. What Windows uses on this phone [WP]

Windows' audio driver names the same sessions: "default modem voice", "default volte voice", and a "VOIP call" mode.

**Voice topologies per device** (ACDB device property 0x113AF). Every call device uses two **Nokia custom topologies**:
- **TX 0x10003202:** the handset mic, the speakerphone mic, the headset mic, BT SCO mic.
- **RX 0x10003201:** the earpiece, the loudspeaker, the headset, BT SCO speaker.
- **0x10003204:** the multi-mic devices.

The stock IDs appear only on generic and test devices (0x10F70 none, 0x10F71 single-mic ECNS, 0x10F74/0x10F75 Fluence, 0x10F77 RX default). Global property 0x12E47 lists custom topology IDs (0x10003000-0x10003209, including 0x10003202 and 0x10003204) with a module each, so the custom topologies are Nokia's.

**Whether this ADSP accepts 0x10003201/0x10003202 without the host registering them first is not knowable from the files.** The CVP create reply answers it (section 6).

**The call device pairs** that carry voice calibration (`VCGI` tables, device rate 48 kHz on both sides, networks CDMA/GSM/WCDMA/LTE/TD 0x1135F-0x11363):

| Call | TX device | RX device | Windows AFE ports | Our hardware |
|---|---|---|---|---|
| Handset | 0x04 `HANDSET_MIC`, DMIC1 | 0x07 `HANDSET_SPKR`, codec EAR | 0x4001 / 0x4000 | the earpiece is an open load, so not usable |
| Speakerphone | 0x0B `SPKR_PHONE_MIC`, DMIC4 | **0x46 `SEC_MI2S_RX`** (topology 0x10003201) | 0x4001 / SEC_MI2S | **the TAS2552 loudspeaker on SEC_MI2S, as brought up in r191-r193** |
| Headset | 0x08 `HEADSET_MIC`, ADC2 (0x20101) | 0x09 / 0x0A `HEADSET_SPKR` mono / stereo | 0x4003 / 0x4002 (SLIMBUS_1) | headphones work on our SLIMBUS_0_RX; the headset mic is not brought up yet |
| BT SCO | 0x24 | 0x25 | | 8/16 kHz; later |

Our card already has the back ends a call needs: SLIMBUS_0_RX (headphones), SLIMBUS_0_TX (DMIC1/DMIC4), SECONDARY_MI2S_RX (loudspeaker). Windows' choice of SLIMBUS_1 for the headset is a codec channel layout, not a requirement; CVP takes any AFE port.

**Calibration** exists and is substantial: `VCGI`/`VCGD`/`VCD2` vocproc tables, `VSTM` stream tables, `VVP3`, keyed by device pair, network and vocoder rate. Using it means mapping memory to the ADSP and registering the blocks (steps 3 and 6). Calls work without it in [OOT], with the topology's built-in defaults. **Calibration is a quality step after a working path, not a prerequisite.**

## 3. What our tree has

- APR on the ADSP edge with q6core, q6afe (SLIMBUS_0_RX/TX, SECONDARY_MI2S_RX), q6asm, q6adm and q6routing.
- No voice services in the DT, and no voice driver.
- `dt-bindings/soc/qcom,apr.h` already defines `APR_SVC_ADSP_MVM/CVS/CVP` (9/0xA/0xB).

## 4. The modem side

The modem's voice service answers on QMI ("Voice 2.1", section 21 of the modem doc). In a real call the modem attaches its vocoder to the ADSP's passive "default modem voice" session by itself. No SIM means no call, so the modem side of call audio cannot be exercised here.

## 5. Risks

- **An ADSP crash** from a malformed VSS command would take all audio down until the ADSP restarts. The ADSP is a remoteproc like the modem; recovery is untested for it.
- **Custom topology refused:** fall back to the stock pair 0x10F71/0x10F77, which every 8974 ADSP has.
- **The 48 kHz device rate:** Windows runs vocproc on 48 kHz AFE ports. Our back ends already run at 48 kHz.
- **Levels:** the acoustic rules apply to any audible test (start at or below −40 dBFS, escalation needs the user's "declared", ask about heaters and quiet first).

## 6. What can be proven without a SIM

1. **Session probe (no sound):** create MVM passive + CVP on our ports, then enable, attach, start, stop, destroy.
   - Every step must be ACKed, and the AFE ports must run.
   - Done twice: with Nokia's 0x10003202/0x10003201, then with the stock 0x10F71/0x10F77.
   - This answers the custom-topology question and proves the DSP side of a call, minus the modem.
2. **Loopback (audible):** a full-control MVM + CVS session in loopback direction (3, "TX and RX loopback", [DS] header). Speech into DMIC1 or DMIC4 returns through CVP to the headphones or loudspeaker.
   - That is the whole call path (mic, echo cancel / noise suppression, vocoder, speaker) with no modem.
   - Not in [OOT]; needs CVS full control and a loopback toggle.
   - The ADSP's support for it is unverified.
3. **The real call:** needs a SIM. ModemManager + the CS-VOICE DAI, with the passive session the modem attaches to.

## 7. Plan

1. **Patch 0011:** port [OOT] q6voice (common, MVM, CVP, CVS, DAI) onto 6.16, with these changes:
   - zero the CVP name;
   - make the topology a module parameter, so the probe can try both pairs without a rebuild;
   - add CVS passive create, as [DS] does.

   DT: services 9/0xA/0xB, plus a `CS-Voice` front end link in the card. Mixers route it to SLIMBUS_0_RX/TX and SECONDARY_MI2S_RX.
2. **Session probe** (6.1), silent, at the user's go.
3. **Loopback** (6.2), if the ADSP supports it: CVS full control in a separate, test-only path. Acoustic rules apply.
4. **Calibration** (ACDB voice blocks for the speakerphone and headset pairs) after a working path.
5. **The real call** when a SIM is available.

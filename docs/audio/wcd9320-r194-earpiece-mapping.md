# r194: the earpiece, mapped from Windows

**Status:** map only. Nothing is built or probed yet.

**The question.** Where is the earpiece, and why was it silent in r187?

**Sources.** Every fact below was derived from the Windows image. That
image is the MainOS partition, mounted read-only:
- the DSDT;
- the three ACDB calibration files;
- `qcauddev8974.sys`, the ADIE codec driver.

Only derived facts are recorded here. No blob or table is reproduced.

## 0. Answer

**The earpiece is the WCD9320 EAR output, fed from SLIMbus RX0.** Every
Windows source agrees. r187's silence is therefore a defect in our EAR
bring-up, not a wiring dead end. That retracts the r187 verdict for the
earpiece only. The loudspeaker verdict stands, since it is the TAS2552 (r191).

Windows' EAR sequence matches downstream and ours **with one exception.**
When it powers DAC1, Windows clears **bit 0 of `RX_EAR_CMBUFF` (0x1be)**. On
this chip that bit is set at idle (0x05). Downstream and our driver leave it
set. That is the r194 hypothesis.

## 1. The handset device in the ACDB

| ACDB device | name | codec path | AFE port | ch |
|---|---|---|---|---|
| 7 | `HANDSET_SPKR` | `0x10102` `EAROUT_SPEAKER` | `0x4000` SLIMBUS_0_RX | 1 |
| 35 (0x23) | `AUDIO_DEVICE_EAROUT_HAC_SPEAKER_OUT_COMBO` | `0x15101` `EAROUT_HAC_SPEAKEROUT` | `0x4002` SLIMBUS_1_RX | 2 |
| 69 (0x45) | `AUDIO_DEVICE_SPEAKER_OUT` | `0x15100` codec SPK_OUT | `0x4004` | 1 |

**How the tables are read:**
- A device's properties come from `Handset_cal` / `Speaker_cal`.
  - Property `0x113b7` holds the codec path id and the AFE port.
  - Property `0x113b8` holds the name.
- A codec path is decoded through `Codec_cal`.
  - `CPROPLUT` gives the path's name.
  - `CDCLUT0` gives the header: the output `0x1000N`, where 1 = EAR, 2 = SPK_OUT, 3 = HPHL and 4 = HPHR, with LINEOUTs as `0x2000N`.
  - The record list holds the element enables and disables.
  - Element `0x1009` occurs only in the two paths that contain EAR.

The `Codec_cal` file is a generic Qualcomm sysdef. It also lists LINEOUT and
SPK_OUT speaker paths, and those are not this board's speaker. So the ACDB
alone is not proof. Sections 2 and 3 are what settle it.

## 2. What the DSDT routes

**`AUDD.QCRT.DEVI`** is the list of RX/TX device pairs Windows actually uses:
- **RX 7** (the handset) pairs with the handset mic and its variants: 4, 5, 6, 12, 13, 39, 40 and 19.
- **RX 0x23** (the EAR+SPK_OUT HAC combo) pairs with 4.
- **RX 0x46 and 0x51** are the I2S loudspeaker.
- **RX 0x0a** is the headset.

**`AUDD.PPNF`** maps a device to its PEP power components. Device ids match the
ACDB.
- **The loudspeaker:** 0x46 and 0x51 map to comp 4, which is the sec_mi2s SCK, WS and DATA1 pins.
- **The codec SPK_OUT:** 0x45 maps to comp 0 + 1, the codec MCLK plus SMPS4 5 V. This is the 5 V that r190 tested.
- **The handset:** 7 and 0x23 are not listed. They get only the default, comp 0, the codec MCLK. **So the earpiece needs no rail, GPIO or pin beyond the codec.**

**PEP comp 5** is TLMM 81 (sec_mi2s DATA0), on function 1, **configured as an
input**, and endpoint 0x4A uses it. That endpoint is the TAS2552's IV-sense
feedback capture. **DATA0 is not an earpiece path**, which closes the r193
open lead.

## 3. Windows' EAR register sequence (`qcauddev8974.sys`, ADIE)

The ADIE register helper takes `(reg, mask, shift, value)`. Decoded:

**DAC1 on:**
1. `0x1bc` bit 5 = 1 (DAC1 switch)
2. `0x1bc` bit 6 = 1 (DAC1 power)
3. **`0x1be` bit 0 = 0** (RX_EAR_CMBUFF)

**Class-H, EAR mode, from idle:**
1. `0x320` bit 4 = 1 (B1 compute EAR)
2. `0x185` bit 1 = 1
3. `0x184` = 0x3f
4. buck mode bits in `0x181` / `0x183`
5. `0x181` bit 7 = 1 (buck on), then 1 ms
6. `0x194` bit 4 = 0, `[3:0]` = 8 (NCP fclk 8), bit 5 = 1
7. `0x192` bit 0 = 1 (NCP on), then 1 ms

**PA on:**
1. `0x1bc` bit 4 = 1
2. then POST_PA: `0x185` bit 1 = 0, `0x194` bit 5 = 0, and the `0x183` bits

**Off:**
1. `0x1bc` bit 4 = 0
2. `0x320` bit 4 = 0
3. `0x1bc` bits 5 and 6 = 0

Windows **never sets `0x1be` bit 0 again.** No write in the driver sets it.

## 4. Against downstream and ours

| step | Windows | downstream / ours (r187) |
|---|---|---|
| class-H EAR, all parameters | as above | the same (`wcd9xxx_clsh_state_ear`, ported in r187) |
| DAC1 switch and power | `0x1bc` bits 5, 6 | the same |
| `RX_EAR_CMBUFF` | **bit 0 cleared** at DAC1 on | **left at 0x05** (`taiko_reg_defaults` writes 0x05) |
| PA | `0x1bc` bit 4, POST_PA | the same |
| order | DAC1, then class-H | class-H PRE_DAC, then DAC1 |

The header gives `0x1be`'s POR as 0x04, but this chip reads **0x05** at idle.
Both the 2026-08-15 full chip map (the source of the regmap defaults) and
today's regmap read show it. Windows treats bit 0
as something to clear. Downstream's 0x05 is a no-op on this silicon.

The r187 run itself was clean:
- DAC1, switch and PA were live (`0x1bc = 70`);
- class-H was in EAR mode;
- there was no OCP fault, at -20 dBFS and full gain;
- and still nothing was heard or recorded at the slot.

That pattern fits an analog stage that is held off, not a digital fault. The
same RX1 chain plays the headphones.

## 5. Plan for r194 (not started)

**Codec driver:**
- **The Windows write:** `ear_dac` clears `RX_EAR_CMBUFF` bit 0 after DAC1 power, chip-verified like every other write. It restores the measured baseline at teardown.
- **A/B switch:** a sysfs switch `ear_cmbuff` (`clear` by default, `keep` = r187) allows an A/B test in one boot.
- **Evidence:** `out_state` gains `ear_cmbuff` and a live `RX_EAR_STATUS` (0x1c4) sample.

**Verifier:** fence 5r covers:
- the clear sits after DAC1 power;
- it is read back;
- the baseline is restored on every exit;
- the `keep` path writes nothing.

**Runner:**
- `OUTPUT=ear EAR_CMBUFF=clear|keep`;
- the early snapshot samples 0x1be and 0x1c4 during the tone.

**Probe:**
- the mic at the earpiece slot;
- s1 = Windows parity (`clear`) at -40 dBFS and minimum gain;
- s2 = `keep`, as the control.

Escalation follows the r187 rules: -30 and -20 only with "declared".

**If `clear` is also silent:** the next candidate is ordering (DAC1 before
class-H, as Windows does it). After that, sample `RX_EAR_STATUS` and the
EAR PA startup interrupt during the stream.

## 6. r194 (`earcm-rc1`, pkgrel 194): staged 2026-11-13

**Codec driver** (`wcd9320_ear_dac`):
- **The clear:** after DAC1's switch and power, the driver measures the 0x1be baseline and sets the owed flag. Then it clears bit 0 through `c2b_write`, which reads the chip back.
- **The restore:** teardown writes the measured baseline back *before* DAC1 power goes off. The inverse is owed whatever the clear did.
- **Failure:** a failed baseline read or clear tears the stage down.
- **The mode switch:** sysfs `ear_cmbuff` (`clear` default = Windows, `keep` = r187, which writes nothing). It is refused under `c3_lock` while any earpiece stage is up or a restore is owed.
- **`out_state`** gains a line: `ear_cmbuff_mode`, `ear_cmbuff_cleared`, the clears and restores counters, `ear_cmbuff_base`, `cmbuff_0x1be` and `earstat_0x1c5`.

The card module is unchanged (`q6-card-rc11`), and so is the DT.

**Verifier 5r:**
- 13 checks;
- the mutation test catches 8 of 8.

The source fences pass; the only FAIL is the old build's version string.

**Runner:**
- **The variable:** `EAR_CMBUFF=clear|keep[,...]` sets one mode per earpiece stream, and the last value repeats. Each stream's mode is written and read back while the path is down.
- **Live checks** (an abort if wrong): `clear` needs bit 0 = 0 and the flag set. `keep` needs 0x1be as found and nothing owed. `EAR_STATUS` is journalled.
- **Report:** the mode live, then the restore after. Per run, clears = restores = the number of `clear` streams, and 0x1be, the flag and the mode end as they were found.

**Selftest:** 115/0, which adds 10 cases for the per-stream plan.

**Build:**
```
tools/build-wcd9320-kernel.sh --pkgrel 194 --version earcm-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r194 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

**Probe plan (after the gates):**
- `OUTPUT=ear EAR_CMBUFF=clear,keep SPECS=B:0:84,B:0:84 DBFS=-40`;
- the mic at the earpiece slot;
- one chat "go" per stream: s1 is Windows, s2 is the r187 control.

-30 and -20 dBFS only with "declared".

## 7. r194 result (2026-11-13): `clear` is not enough

Booted `earcm-rc1` / `q6-card-rc11`. The post-boot gates all passed: dapm
83/0, mclk-own 90/0 and hphl-vm 57/0. Two listen runs followed, each with
`EAR_CMBUFF=clear,keep`, the mic at the earpiece slot, and one chat go per
stream.

| run | spec | 0x1be live (clear / keep) | 0x1c5 live | ear_pa, OCP | heard | analyser |
|---|---|---|---|---|---|---|
| A | `B:0:84`, -40 dBFS | 04 / 05 | 88 / 88 | 1, none | nothing | 0 events; pattern score at the floor |
| B | `B:6:84`, -20 dBFS (declared) | 04 / 05 | 88 / 88 | 1, none | nothing | 0 events; pattern score at the floor |

Each runner passed 101/0. Each `clear` stream cleared bit 0 once,
read it back as 0x04, and restored the 0x05 baseline once. Each `keep`
stream left the register untouched.

**Verdict.** Clearing `RX_EAR_CMBUFF` bit 0 does not make the earpiece
audible. Run B repeats r187's silent case (-20 dBFS, full gain) with the
Windows write, and it is still silent. `RX_EAR_STATUS` reads 0x88 in both
modes, so the chip's own status does not change with the bit either. The
hypothesis in section 0 is rejected. The write stays as Windows parity.

**Next candidates, in order:**
1. **Ordering.** Windows powers DAC1 before class-H; we do it the other way round.
2. **A full live register snapshot** of the analog block and the RX1 path
   during an earpiece stream, diffed against a headphone stream. RX1 drives
   the headphones and they play.

## 8. r195 (`earord-rc1`, pkgrel 195): staged 2026-11-13

Two tools for the next earpiece probe, built so one boot answers both
questions. The card (`q6-card-rc11`) and the DT are unchanged.

**The order switch, `ear_order`** (`downstream`, the default, or `windows`):
- **`downstream`** keeps r187–r194's order: class-H EAR PRE_DAC, then DAC1's switch and power, then the CMBUFF clear.
- **`windows`** follows `qcauddev8974.sys`: DAC1's switch and power and the CMBUFF clear first, *then* class-H EAR, before `dac_on`. It has its own teardown exit and counts `windows_ups`.
- **Teardown is the same for both.** The PA stage already drops class-H before DAC1 goes off, which is Windows' off order.
- The switch is refused under `c3_lock` while any earpiece stage is up or a CMBUFF restore is owed.

**The live register snapshot, `reg_snap`** (`arm` / `disarm`):
- **When:** once armed, it is taken exactly once, from the chip (`regmap_read_bypassed`), right after the next successful EAR PA on or HPHR PA on (the last stage of each path). It runs inside the DAPM event under `c3_lock`, so it cannot race the 1 s tone.
- **What it covers:** 368 registers.
  - `0x100–0x11f` bias
  - `0x180–0x1ff` analog RX
  - `0x2b0–0x2ff` RX1..RX7 digital
  - `0x300–0x33f` clocks and class-H
  - `0x380–0x3bf` CDC_CONN muxes
- **It writes nothing.** When unarmed, the proven paths are unchanged. `wcd9320_snap_take` is `noinline`, so it is one call site whatever the inliner does.
- **The dispatcher still calls** `ear_pa(wcd, on)` and `hphr_pa_path(wcd, on)` verbatim; the snapshot wraps them.

**Verifier:**
- **Fence 5s** has 12 checks. 5r's exit count is now bounded to the CMBUFF block.
- **Pin:** `read_bypassed_calls` is 143, from +1 measured in the compile-check tree (136 → 137).
- **Results:** 686 checks pass. The only 2 failures are the old r194 .ko's version and pin.
- **Mutation test:** 15/15, 12 for 5s and 3 for 5r.

**Compile:** clean at `W=1` in the compile-check tree, with 0 warnings.

**Runner:**
- **`EAR_ORDER=downstream|windows[,...]`** sets the order per earpiece stream. Each stream's order is written and read back while the path is down. The driver's `windows_ups` counter must move +1 for a `windows` stream and +0 for a `downstream` one. The run ends with the order as it was found.
- **`SNAP=1`** (hph or ear) arms the snapshot before each stream. After the stream, it saves the snapshot to `/var/log/wcd9320-regsnap-<stamp>-s<n>.txt` and checks that exactly one was taken, at the right PA, then disarmed. Every snapshot is also dumped in the evidence.

**Selftest:** 121/0, adding 6 cases.

**Build:**
```
tools/build-wcd9320-kernel.sh --pkgrel 195 --version earord-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r195 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

**Probe plan, after the gates:**
1. **Earpiece:** `OUTPUT=ear EAR_ORDER=windows,downstream EAR_CMBUFF=clear SNAP=1 SPECS=B:6:84,B:6:84 DBFS=-20 ESCALATE=declared`. The mic is at the slot, with a chat go per stream.
   - s1 is full Windows parity.
   - s2 is the r194 control, with a snapshot of each.
2. **Headphones, for the diff:** `OUTPUT=hph SNAP=1 SPECS=B:0:84 DBFS=-40`, one stream at minimum gain. Nothing needs to be plugged in, because only its registers are wanted.
3. **The diff:** EAR (s1, s2) against HPH, over the same RX1. Anything set for HPH but not for EAR, outside the HPH- and EAR-only registers, is the next lead.

## 9. r195 result (2026-11-13): order is not it; the live diff is clean

Booted `earord-rc1`. The gates passed: dapm 83/0, mclk-own 90/0 and vm 57/0.

**Earpiece run** (107/0): `EAR_ORDER=windows,downstream EAR_CMBUFF=clear SNAP=1`,
`B:6:84` at -20 dBFS (declared), with the mic at the slot.
- **Result:** both streams were silent by ear and by the analyser. Two pattern hits were broadband handling noise, with the spectral peak wandering from 100 to 2600 Hz and 1 kHz no more than a few dB above its neighbours.
- **Live state:** the earpiece PA was on, with no OCP. 0x1be read 04 and EAR_STATUS 0x1c5 read 88.
- **The two orders' snapshots are identical,** 0 of 368 registers.

**Headphone run** (98/0): `OUTPUT=hph SNAP=1 B:0:84 -40 dBFS`, a snapshot only.

**EAR vs HPH, live at PA on.** 20 of 368 registers differ, and every one is accounted for:

| group | registers (EAR / HPH) | reading |
|---|---|---|
| HPH analog | 1a5 a4/24, 1a9 2a/1a, 1ab 80/b0, 1ac da/db, 1ad 15/58, 1ae 00/34, 1b1 00/c0, 1b3 04/08, 1b4 00/34, 1b7 00/c0, 1b9 04/08 | HPH PAs, DACs, gains, wavegen, status: on only for HPH |
| EAR analog | 1bc 70/00, 1be 04/05, 1c5 88/04 | EAR DAC1, switch and PA, CMBUFF, status: on only for EAR |
| RX2 | 2bd 80/a8, 30f 01/03, 383 00/06 | RX2 chain, clock and mixer: HPHR only |
| class-H | 320 37/23, 328 0f/04 | EAR mode vs HPH mode, as downstream sets them |
| RX7 volume | 2e7 00/fa | the speaker's digital volume, left at its boot value by the HPH run; not on this path |

**The shared path is identical:** RX1 digital (0x2b0–0x2b7), the RX1 mixer
(0x380 = 05), the CLASS_H_DSM mux (0x3b0 = 14, DSM_HPHL_RX1), the clocks,
the buck and NCP block, and the bias. **Within the 368 registers read, the
earpiece is programmed as downstream and Windows program it, on the same
live RX1 and DSM that play the headphones.**

**What the snapshot could not see:**
- 56 addresses that the regmap refuses, among them **0x1c4** inside the EAR block, and 0x180, 0x19d, 0x1a3, 0x1de and 0x1ff;
- 0x000–0x0ff, 0x120–0x17f, 0x340–0x37f and 0x3c0–0x3ff.

**EAR_STATUS 0x1c5** reads 0x88 live. Bit 3 matches the HPH status
registers' clocked bit (04 → 08). **Bit 7 has no HPH counterpart,** and its
meaning is unknown.

**Leads, offline first:**
1. Decode the ACDB EAR codec path's record list (0x10102; element 0x1009 occurs only in EAR paths) as register writes, in case Windows applies an EAR register profile from the ACDB that the driver code doesn't show.
2. Search `qcauddev8974.sys` for 0x1c4 and 0x1c5, and for any read of EAR_STATUS bit 7.
3. Check the board: does the earpiece really hang off EAR_P/EAR_M, or is there an external switch or amp the DSDT does not name?

## 10. Offline leads closed, and the PA flags (2026-11-13)

**The ACDB EAR path is not a register profile.** `EAROUT_SPEAKER` (0x10102)
is a list of (action, element) steps that `qcauddev8974.sys` executes.
- Element 0x1009 is the EAR element, and its handler is the section 3 sequence.
- Next to the headphone path, EAR also uses the NCP and buck elements, but not 0x1010, which the HPH and LO paths include.

**`qcauddev8974.sys` writes nothing more to the EAR block.** Of the 991
helper calls with constant addresses, the EAR block (0x1b8–0x1c7) receives
only:
- 0x1ba and 0x1c6, the PA bias, [7:4] = 7;
- 0x1bc bits 4–6;
- 0x1bd [7:5], the gain;
- 0x1be bit 0.

The same init block also writes buck fields 0x183, 0x186 and 0x189. Our
live snapshot already holds every one of those values.

The driver's only register table is an ascending list of valid addresses,
with no values. **0x1c4 is not in it,** so that register does not exist, which
is why the regmap refuses it. **0x1c5 is never accessed.** The 0x1c3–0x1c7
hits were WPP trace message numbers, not registers.

**The EAR PA's own flags.** `INTR_STATUS2` bit 2 is EAR_PA_OCPL_FAULT and
bit 5 is EAR_PA_STARTUP. Both are masked (`INTR_MASK2` = 3f), and no run had
ever sampled them. Runner 5aa155d now samples `irq_live` about every 25 ms,
80 times, through each hph or ear tone.
- **Earpiece** (`B:0:84`, -40 dBFS, 83/0): 80 of 80 samples read 00, so neither bit was ever seen. Nothing was heard.
- **Headphone control** (`B:0:84`, -40 dBFS, 96/0): 80 of 80 samples read 00. **Not even the HPH start-up bits** (3 and 4) appeared, on the path that plays.

So masked sources do not show in `INTR_STATUS2` on this chip. **This
sampling cannot see an EAR OCP trip,** and the result is no evidence either
way.

**Where this leaves the earpiece.** Every codec-side difference that
Windows, downstream or a working HPH stream could reveal has been tested or
shown equal. That covers CMBUFF, the order, the live registers on the shared
path, and the whole Windows EAR write set. The remaining possibilities are:
1. **The earpiece itself or its wiring.** This needs a hardware answer: does the earpiece work on this unit under Windows, does it measure as a receiver across EAR_P/EAR_M (about 32 Ω), and is there a part between the codec and the earpiece?
2. **An OCP trip that only an unmasked source can show.** A diagnostic build could unmask bits 2 and 5 for the duration of an earpiece stream, observation only, which would answer whether the PA starts up or faults.

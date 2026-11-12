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

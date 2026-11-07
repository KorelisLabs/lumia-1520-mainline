# HPHL DC on the codec's own voltmeter: design map

**Status:** MAPPED, nothing written. Research: `wcd9320-mbhc-voltmeter-research.md`.
Purpose: clear the final-build blocker. That is the §22 DC contract of
`wcd9320-hphl-pa-c3-mapping.md`, measured on-chip because no scope or meter
is available.

Sources, all cached under `~/.cache/wcd9320-downstream/`:

- `mbhc/nemo310-wcd9xxx-mbhc.c`: the engine
  - `wcd9xxx_mbhc_setup()`
  - `wcd9xxx_update_mbhc_clk_rate()`
  - `wcd9xxx_mbhc_cal()`
  - `__wcd9xxx_codec_sta_dce()`
  - `__wcd9xxx_codec_sta_dce_v()`
  - `wcd9xxx_detect_impedance()`
- `gen3-wcd9320.c`: Taiko's `taiko_setup_zdet()`. Taiko uses the engine's
  default callbacks for the mux bias block, CFILT fast mode, CFILT select and
  codec-specific calibration.
- `wcd9xxx-resmgr.c`: `wcd9xxx_resmgr_get_k_val()`.
- `hammerhead/sound_soc_msm_msm8974.c`: `def_taiko_mbhc_cal()`, the only
  calibration blob we hold for this codec.

## 1. What is measured, and what is not

**One quantity: the voltage on the HPHL node**, in raw counts from the MBHC
short-term average (STA). It is converted to mV by a two-point calibration
taken in the same call with identical engine settings.

It is downstream's impedance sample **L0**: `SCALING_MUX_2 = 0xF0`, "HPHL
without ical". It is passive. **Not used:** the five other zdet samples
(they inject the 37.5 uA ical), the PA ramp generator (`CDC_PA_RAMP_B1..B4`,
which drives the headphone), and `wcd9xxx_prepare/enable_static_pa()`.
Nothing in this design writes `0x1ab`.

## 2. Preconditions, refused rather than supplied

| condition | why |
|---|---|
| codec on MCLK (`clk_src_mclk`, `cdc_alive`) | downstream measures only with the external MCLK on (`wcd9xxx_onoff_ext_mclk` brackets zdet), every timing below is derived for 9.6 MHz, and the analog path is now known to want the real clock |
| `0x14a` insert detect OFF | the MBHC FSM must be idle, so nothing else is driving the engine; the proven insert-detect contract is not shared |
| `MICB_4_MBHC [1:0] == 01` (MICBIAS2) and `MICB_2_CTL [6:5] == 00` (CFILT1) | the reference is computed for this exact path; a different selection would make "1800 mV" a guess |
| `LDO_H_MODE_1 [3:2] == 01` and `MICB_CFILT_1_VAL == 0x80` | together these ARE the 1800 mV; checked, never assumed |
| interrupt masks as certified (`ff ff 3f 7f`) | no MBHC source may be unmasked. Measured 2026-08-15: masked sources do not latch, so the engine is **polled with fixed waits**, exactly as `__wcd9xxx_codec_sta_dce()` does with `dce_est_complete` disabled |
| `c3_lock` held | one sequence at a time; the C3a stores already serialise on it |

**The PA may be off or on.** The contract needs both, and the measurement
never touches the PA. The PA guard is sampled before and after, with the
expected state passed in by the caller (the C3a phase-dependent guard).

## 3. Engine settings (constants, from `def_taiko_mbhc_cal`, 9.6 MHz index 1)

| field | value | register write |
|---|---|---|
| FIR coefficients c[0..7] | 62, 124, 0 x6 | `FIR_B1_CFG` [2:0] = n, `FIR_B2_CFG` = c[n] |
| nc | 1 | `CDC_MBHC_B2_CTL` [2:0] |
| gain[1] | 9 | `CDC_MBHC_B2_CTL` [6:3] |
| nsa | 4 | `TIMER_B4` [6:4] |
| n_meas | 3 | `TIMER_B4` [3:0] |
| navg | 4 | `TIMER_B5` |
| nsc | 11 | `CDC_MBHC_B1_CTL` [6:3], plus bit 7 |
| n_ready[1] | 68 | `TIMER_B1` |
| n_cic[1] | 47 | `TIMER_B6` |

Derived waits (µs, `wcd9xxx_update_mbhc_clk_rate`):

```
t_sta     = 1000*128*(4+1)/9600 + 250        =   316
t_dce     = 1000*512*47*(3+1)/9600           = 10026
t_sta_dce = (1000*256/9600)*68 + 10          =  1778   (integer: 26*68+10)
```

**NAVG must not change between calibration and measurement.** Downstream's
zdet setup writes `TIMER_B5 = 0x10`, but it computes impedance from count
*ratios* taken under that one setting. Mixing navg=4 calibration with
navg=16 readings would be wrong if STA is a sum, not a mean. Unknown, so the
design forbids it: **one setting, navg = 4, for z, mb and L0 alike.**

## 4. The reference voltage: known by construction

- `LDO_H_MODE_1` (`0x110`) reads `65`: field [3:2] = 1, LDOH at **2.35 V**.
  Bit 7 (LDO_H enable) is **clear**.
- At LDOH 2.35 V, `wcd9xxx_resmgr_get_k_val()` gives min 200 / max 2200 mV,
  and `k = rc − 4`, where rc is the first rc with `2200*rc/44 >= mv`.
- For **1800 mV**: rc = 36, k = 32, `CFILT_VAL = k << 2 = 0x80`. **That is
  the POR value of all three CFILT_VAL registers, read live as `80`.** The
  reference is 1800 mV with no CFILT write, at the value hammerhead uses for
  CFILT1.
- **Which mic bias the engine uses** is selected by `MICB_4_MBHC` [1:0]
  (`wcd9xxx_mbhc_setup()` writes `MBHC_MICBIAS2` there). Live `0x13f = 01`,
  which is already MICBIAS2. So the bias registers are **micbias 2**:
  `MICB_2_CTL 0x131`, `MICB_2_MBHC 0x133`. Treated as a precondition, read
  and verified, never written.
- micbias 2's filter is `MICB_2_CTL` [6:5]. Live `0x131 = 16`, so [6:5] = 00,
  which is **CFILT1** (`0x128`/`0x129`), 1800 mV at POR. Downstream's
  hammerhead used CFILT2 at 2700 mV under a 3.0 V LDOH. The map uses
  **CFILT1 as found**, so there is no select write and no LDOH change.
- **Self-consistency point, the closest this design gets to an independent
  check:** CFILT1 reprogrammed to **1200 mV** (rc = 24, k = 20, `VAL = 0x50`)
  must give `(mb' − z) / (mb − z) = 1200/1800 = 0.667`. That is a
  characterisation step, not part of every measurement.

**The mic bias appears on the headset's mic contact (Sleeve) during the mb
point.** That is what every phone does with a headset in, a few mA at most
through the internal bias resistor. It is bounded to the 50 ms settle plus
one conversion.

## 5. The sequence (one sysfs operation, atomic under `c3_lock`)

```
S0  preconditions (section 2); PA guard sampled
S1  SNAPSHOT, bypassed, every register any step below writes (section 6)
S2  engine: section 3 table; TIMER_B1 = 68, TIMER_B6 = 47
    MICB_2_MBHC bit 2 <- 1               (wcd9xxx_mbhc_setup)
    CDC_MBHC_B1_CTL bit 1 (rel detection) CLEAR for the whole operation
S3  calibration, wcd9xxx_mbhc_cal() order, STA only:
      CFILT1_CTL bit 6 <- 0              fast mode
      MICB_2_CTL bit 0 <- 0
      LDO_H_MODE_1 |= 0x60, and bit 7    LDO_H on for the reference
      TX_7_MBHC_TEST_CTL = 0x78
      CDC_MBHC_B1_CTL bit 2 <- 1         override on
    z:  MICB_2_CTL bit 0 <- 1            pull the mic bias to ground
        MAD_ANA_CTRL bit 4 <- 0          override disconnected from micbias
        SCALING_MUX_1 = 0x02, |= 0x80    mux on micbias, bias block on
        wait 50 ms                       WCD9XXX_MUX_SWITCH_READY_WAIT_MS
        CLK_CTL 0x0A, 0x02               reset
        sta_z = STA (section 7)
        MICB_2_CTL, MAD_ANA_CTRL restored from S1
    mb: CLK_CTL 0x0A; EN_CTL 0x02; CLK_CTL 0x02
        SCALING_MUX_1 = 0x02, |= 0x80; wait 50 ms
        EN_CTL 0x02; wait t_sta; sta_mb = B3:B2_STATUS
S4  HPHL, wcd9xxx_detect_impedance() + taiko_setup_zdet() PRE_MEAS,
    minus the PA ramp:
      MAD_ANA_CTRL bit 4 <- 0            the override must not power micbias
      SCALING_MUX_1 = 0xC0               mux enabled, ADC7
      SCALING_MUX_2 = 0xF0               HPHL, NO ical
      TX_7_MBHC_TEST_CTL = 0x78; TX_7_MBHC_EN = 0x8C
      CLK_CTL 0x0A; EN_CTL 0x02; CLK_CTL 0x02
      MBHC_HPH mask 0xB3 <- 0x80         "Set HPH_MBHC for zdet"
      SCALING_MUX_1 |= 0x80; wait 25 us
      L[i] = STA, i = 0..N-1, back to back
S5  RESTORE every S1 register, in reverse order, each chip-verified
    (bypassed) against its S1 value; any mismatch is reported loudly
    and fails the operation
S6  PA guard sampled; result published
```

The z/mb/L0 order is downstream's. Calibrating **in the same call** as the
reading, not cached from probe, means drift between calibration and
measurement is milliseconds.

## 6. The write set, closed (for the fence)

With live values from this boot:

```
CDC_MBHC_FIR_B1_CFG  0x3c1 (00)    CDC_MBHC_FIR_B2_CFG  0x3c2 (06)
CDC_MBHC_TIMER_B1    0x3c3 (03)    CDC_MBHC_TIMER_B4    0x3c6 (45)
CDC_MBHC_TIMER_B5    0x3c7 (04)    CDC_MBHC_TIMER_B6    0x3c8 (78)
CDC_MBHC_B1_CTL      0x3ce (c0)    CDC_MBHC_B2_CTL      0x3cf (5d)
CDC_MBHC_EN_CTL      0x3c0 (00)    CDC_MBHC_CLK_CTL     0x3dc (00)
MBHC_SCALING_MUX_1   0x14e (00)    MBHC_SCALING_MUX_2   0x14f (80)
MAD_ANA_CTRL         0x150 (f1)    TX_7_MBHC_EN         0x171 (0c)
TX_7_MBHC_TEST_CTL   0x174 (38)    MBHC_HPH             0x1fe (44)
MICB_2_CTL           0x131 (16)    MICB_CFILT_1_CTL     0x128 (40)
MICB_2_MBHC          0x133 (02)    LDO_H_MODE_1         0x110 (65)
MICB_CFILT_1_VAL     0x129 (80)    characterisation only (the 1200 mV point)
```

- **Read-only:** `CDC_MBHC_B2..B5_STATUS` (`0x3ca`-`0x3cd`).
- **Never written by this feature:** `0x1ab`, `0x14a`, `INTR_MASK*`,
  `CDC_PA_RAMP_B1..B4`, `0x314`, `0x30d`.
- **Restore caveat, settled in the fence:** the FIR coefficient bank is
  written through an index register (`FIR_B1_CFG` [2:0]). Its eight slots
  cannot be snapshotted individually without the same indexed reads, so S1
  reads all eight through the index and S5 writes all eight back.

## 7. The conversion, polled

From `__wcd9xxx_codec_sta_dce(dce=0, override_bypass=true)`:

```
CLK_CTL bit 3 <- 1; EN_CTL = 0x02; CLK_CTL bit 3 <- 0
wait t_sta_dce (1778 us)
EN_CTL = 0x02
wait t_sta (316 us)
value = (s16)(B3_STATUS << 8 | B2_STATUS)
CLK_CTL bit 3 <- 1; EN_CTL = 0x00
```

## 8. Conversion to mV, and what makes a reading valid

```
mv = (L - sta_z) * 1800 / (sta_mb - sta_z)
```

Published with the raw counts, so the arithmetic can be redone offline.
Validity, all derived and none recorded from hardware:

| check | why |
|---|---|
| `sta_mb − sta_z` large and positive (at least 1/8 of the 16-bit range, to be settled at characterisation) | a dead or saturated engine gives a tiny or negative span |
| repeated `sta_z` within a few counts | the zero is a short to ground and must be stable |
| L samples within the drift budget | §22 needs drift ≤ 10 mV across 250 ms |
| **any L equal to `sta_z` exactly, repeatedly** | possible clipping at 0 V. A ground-referenced HPH output idles near 0 V and the ADC may not read below zero. **This is the largest open risk** and characterisation must settle it before any number is trusted |

## 9. Characterisation, before any contract run (r178 gate, PA never on)

1. **Repeatability:** the operation 10 times at idle; spread of z, mb, L.
2. **Restore proof:** every S1 register equal after each call; all 10 calls
   leave the full register map identical (a sentinel / full-map diff).
3. **Self-consistency:** CFILT1 at 1800 then 1200 mV; the span ratio must be
   0.667 within a stated tolerance.
4. **HPHL at idle,** PA off, DAC off: a plausible near-0 V. If L sits at
   `sta_z`, test whether it moves when the C3a DAC path is up (PA still off).
   A reading pinned at the zero while the analog state changes would mean
   clipping.
5. **MCLK and RCO.** On RCO the operation must refuse (precondition).

## 10. The contract run, after characterisation passes

The C3a runner on MCLK, no tone, instrument `dc` (new):

- Stage 1, PA off, full DAC path: `Voff`, 250 ms of samples.
  Precondition `|Voff| ≤ 100 mV`, or abort before the PA.
- Stage 2, PA on, after the mapped settle: `Von` the same way.
  `|Von − Voff| ≤ 50 mV`, drift ≤ 10 mV.
- `|V| ≥ 250 mV` at any sample: hard abort through the existing `c3_abort`.

A pass earns `wcd9320-hphl-electrical-proven`, **qualified as on-chip**: the
evidence states that the instrument is the codec's own ADC, calibrated
against its own mic bias, at the internal HPHL node.

## 11. Open, and settled only on hardware

- the ADC's input range, and the sign behaviour below 0 V (section 8)
- the exact meaning of `MBHC_HPH 0x80` and `TX_7_MBHC_EN 0x8C`. Both are
  copied from the only working sequence, restored after, and not interpreted
- whether STA scales with navg (avoided by design, not answered)
- whether LDO_H bit 7 is needed for the mb point, or whether the override
  path powers it. The map sets it: downstream's mbhc calibration runs with
  LDO_H already up from pdata handling

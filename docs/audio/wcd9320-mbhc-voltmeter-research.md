# HPHL DC with the codec's own voltmeter: research before mapping

**Status:** research only, 2026-11-07. No code. Prerequisite for clearing the
final-build blocker in §28 of `wcd9320-hphl-pa-c3-mapping.md`: the HPHL DC
contract of §22, measured on-chip because no scope or meter is available.

## What other projects have

| source | what it has | usable? |
|---|---|---|
| Qualcomm downstream `wcd9xxx-mbhc.c` (msm-3.10, cached as `mbhc/nemo310-wcd9xxx-mbhc.c`) | the whole MBHC measurement engine, calibration and impedance detection for the WCD93xx family, Taiko included | **yes, the template** |
| downstream `gen3-wcd9320.c` (Sony 2014, cached) | `taiko_setup_zdet()` and `taiko_compute_impedance()`, Taiko's own callbacks into that engine | **yes** |
| downstream vendor trees (SmartisanOS, OnePlus msm8974/8994, mako) | the same code, copied | adds nothing |
| `RobLymm/xperia-sirius-linux` (Xperia Z2, mainline, working audio) | WCD9320 driver; README says "no jack detection" | no MBHC |
| flto's msm8974 `wcd9320.c` (`0af04bc`, the Xperia driver's base) | jack-reporting plumbing, MBHC IRQ names; no ADC, no impedance | no |
| mainline `wcd934x.c` / `wcd-mbhc-v2.c` | impedance through a newer ramp engine (`ANA_MBHC_ZDET`, `RESULT_1/2`) | different hardware, does not transfer |

**No project outside Qualcomm's downstream has measured an HPH voltage on a
WCD9320.** This is new ground on mainline, with downstream as the only
reference.

## The finding that makes it feasible: downstream already reads HPHL DC

`wcd9xxx_detect_impedance()` takes six raw readings through the MBHC scaling
mux. The first is:

```
SCALING_MUX_2 (0x14f) = 0xF0    "Set MBHC_MUX for HPHL without ical"
SCALING_MUX_1 (0x14e) |= 0x80   enable the mux bias block
wait 25 us                      "required after mux change to settle down"
L0 = __wcd9xxx_codec_sta_dce(mbhc, 0 /* STA */, true, false)
```

"Without ical" means no test current is injected. L0 is the **passive voltage
on the HPHL node in raw ADC counts**, which is exactly what §22 asks for. The
other five readings (with ical, after the PA ramp) are for impedance and are
not needed here. Neither is the static-PA ramp that drives the headphone,
which would be the wrong thing to run under a DC safety check.

Taiko's PRE_MEAS setup routes HPH to the measurement path:

```
SCALING_MUX_1 = 0xC0      enable mux, mux current 37.5 uA, ADC7
SCALING_MUX_2 = 0xF0
TX_7_MBHC_TEST_CTL (0x174) = 0x78
TX_7_MBHC_EN       (0x171) = 0x8C
CDC_MBHC_TIMER_B4 |= 0x40, TIMER_B5 = 0x10      NSA / NAVG
CDC_MBHC_CLK_CTL = 0x0A, CDC_MBHC_EN_CTL = 0x02, CDC_MBHC_CLK_CTL = 0x02
MBHC_HPH (0x1fe) mask 0xB3 <- 0x80               "Set HPH_MBHC for zdet"
```

Every one of those is saved and restored by downstream
(`wcd9xxx_soc_update_bits_push` / `wcd9xxx_restore_registers`).

## Raw counts to millivolts: a two-point calibration

```
mv = (value - z) * micb_mv / (mb - z)                 (__wcd9xxx_codec_sta_dce_v)
```

- `z`: the reading at 0 V. The mux is pointed at the mic bias with the mic
  bias pulled to ground (`MICB_n_CTL` mask 0x81 <- 0x01, `MICB_n_MBHC` bit 7
  cleared, `MAD_ANA_CTRL` bit 4 moved).
- `mb`: the reading with the mux on the live mic bias (`SCALING_MUX_1 = 0x02`
  plus the bias block, after a 50 ms settle).
- `micb_mv`: the mic-bias CFILT voltage. Downstream takes it from DT
  (hammerhead uses 1800 / 2700 / 1800 mV). **This port can program the CFILT
  itself and so know it**, rather than trusting a board value the Lumia (a
  Windows Phone device, no DT) never published.
- **STA vs DCE.** STA is the fast short-term average, DCE the slower direct
  conversion. L0 uses STA, so the calibration for it is `sta_z` / `sta_mb`.
  Raw results are `CDC_MBHC_B3:B2_STATUS` for STA and `B5:B4` for DCE, 16-bit
  signed.

## Timing depends on the codec clock

```
t_sta     = 1000 * 128 * (navg + 1) / (rate / 1000) + 250    us
t_dce     = 1000 * 512 * ncic * (nmeas + 1) / (rate / 1000)  us
t_sta_dce = 1000 * 256 / (rate / 1000) * n_ready + 10        us
```

`rate` is the MCLK rate, and `wcd9xxx_detect_impedance()` brackets the whole
measurement with `wcd9xxx_onoff_ext_mclk(mbhc, true/false)`. **Downstream
measures only with the external MCLK running.** That matches today's result
(`wcd9320-rx-port-flow-mapping.md`, "SOUND"): the analog path wants the real
9.6 MHz clock, and the measurement should run on it too. `n_ready`, `n_cic`,
`nmeas` and `navg` come from the ACDB calibration blob. Defaults must be
chosen and justified when mapping.

## What this does not give us

- **No independent check.** The codec measures itself. The calibration makes
  the numbers millivolts, but nothing outside the chip confirms them. The
  `z` / `mb` points and a known third point (CFILT programmed to two
  different values) are the best available self-consistency test.
- **A different node from a scope.** The mux taps HPHL inside the codec, not
  at the jack contact. For DC, with no series element between them on a
  ground-referenced class-H output, they should agree. That is an
  assumption, and the result will say so.
- **ADC range and sign.** The ADC's input range and whether it reads below
  0 V are unknown. A ground-referenced HPH output idles near 0 V, so a
  negative offset could clip at `z`. This has to be characterised before any
  number is trusted.

## Open questions for the mapping

1. The minimum register set for an L0-only reading. The full zdet sequence
   also arms the PA ramp, which is not wanted here.
2. Whether `MBHC_HPH 0x80` is needed for a passive read, or only for the
   ramp.
3. CFILT programming: which filter and which `VAL` code for a known voltage.
   `wcd9xxx_resmgr_get_k_val()` and the cfilt code in `wcd9xxx-resmgr.c` are
   already cached.
4. MBHC clock and FSM state against the already-proven insert-detect setup
   (`0x14a`) and the masked MBHC interrupts: no new IRQ source may be armed.
5. Interaction with a live PA. Downstream runs zdet with PAs muted or static.
   Our Von is measured with the PA on and the DAC path up, idle, with no
   tone.

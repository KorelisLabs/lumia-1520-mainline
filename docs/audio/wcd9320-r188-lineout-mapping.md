# r188: the four line outputs, as safe probes (design map)

**Status:** MAPPED 2026-11-09, before any code. This is Phase 1's second step,
after r187 refuted `SPK_OUT` and `EAR`
(`wcd9320-r187-speaker-earpiece-mapping.md` section 6).

**Question:** do the loudspeaker and/or the earpiece hang off `LINEOUT1`..`4`,
most likely through an amplifier the hardware keeps on? ACPI declares no
amplifier enable and no amp on I2C (phase 0, section 1).

**Sources:**
- `~/ds-hdr/src/hh-wcd9320.c`:
  - `taiko_codec_enable_lineout` (the PA event)
  - `taiko_lineout_dac_event`
  - `taiko_codec_enable_interpolator`
  - `taiko_config_compander` (`COMPANDER_2`)
  - the widgets at 5252-5318 and the routes at 3669-3736
  - `taiko_reg_defaults` and `taiko_codec_reg_init_val`
- `~/.cache/wcd9320-downstream/wcd9xxx-common.c`: `wcd9xxx_clsh_state_lo`,
  plus `state_idle`'s LO disable and the FSM's `cdc_lo_count`.
- `~/.cache/wcd9320-downstream/hammerhead/sound_soc_msm_msm8974.c`: the
  LIQUID board's external speaker amp. It is fed from **all four** line outs
  (`LO_1..LO_4_SPK_AMP`) and is enabled only when all four are up.
- Register addresses: `~/ds-hdr/wcd9320_registers.h`.

**Live values** (r187 boot, idle, debugfs regmap):

| reg | name | live | note |
|---|---|---|---|
| `0x19c` | `RX_PA_AUX_IN_CONN` | `00` | no AUX into any line PA |
| `0x1c6` | `RX_LINE_BIAS_PA` | `78` | downstream's 70 % already |
| `0x1c9` | `RX_LINE_COM` | `80` | |
| `0x1ca` | `RX_LINE_CNP_EN` | `00` | the four PA enables, bits 0..3 |
| `0x1cb`/`0x1cc` | `CNP_WG_CTL` / `_TIME` | `00` / `04` | |
| `0x1cd 0x1d1 0x1d5 0x1d9` | `LINE_n_GAIN` | `00` | **bit 5 clear, field 0** -- see below |
| `0x1ce 0x1d2 0x1d6 0x1da` | `LINE_n_TEST` | `02` | downstream's default already |
| `0x1cf 0x1d3 0x1d7 0x1db` | `LINE_n_DAC_CTL` | `00` | bit 7 DAC power, bit 6 DAC "switch" |
| `0x2c0..0x2df` | `RX3..RX6` B1..B6, VOL | B4 `08`, B5 `78` (48 kHz), B6 `80`, VOL `00` | like RX7 |
| `0x386..0x38d` | `CONN_RX3..RX6_B1/B2` | `00` | MIX1 inputs ZERO |
| `0x3b1` | `CONN_MISC` | `01` | RDAC5 (bit 2) = DEM4, RDAC7 (bit 1) = DEM6 |
| `0x378..0x37f` | `COMP2` | `30 b5 28 37 7f 00 03 03` | compander 2 off |
| `0x301`, `0x30f` | `CLK_RX_RESET`, `CLK_RX_B1` | `00`, `00` | |
| `0x181 0x184 0x185 0x192 0x194` | `BUCK_MODE_1/4/5`, `NCP_EN`, `NCP_STATIC` | `25 ff 00 fe 08` | class-H LO touches these. `NCP_STATIC` = `08`, the HPH path's fclk 8 left programmed. |

## 1. The graph (downstream)

```
SLIM RXn -> RX3 MIX1 (INP1/INP2, 0x386) -> [0x30f bit 2] -> LINEOUT1 DAC (0x1cf) -> LINEOUT1 PA (0x1ca bit 0) -> LINEOUT1
                                          \-> RDAC5 MUX "DEM3_INV" -> LINEOUT3 DAC (0x1d7) -> LINEOUT3 PA (bit 2) -> LINEOUT3
SLIM RXn -> RX4 MIX1 (0x388)            -> [0x30f bit 3] -> RDAC5 MUX "DEM4"     -> LINEOUT3 DAC
SLIM RXn -> RX5 MIX1 (0x38a) -> [0x30f bit 4] -> LINEOUT2 DAC (0x1d3) -> LINEOUT2 PA (bit 1) -> LINEOUT2
                                          \-> RDAC7 MUX "DEM5_INV" -> LINEOUT4 DAC (0x1db) -> LINEOUT4 PA (bit 3) -> LINEOUT4
SLIM RXn -> RX6 MIX1 (0x38c)            -> [0x30f bit 5] -> RDAC7 MUX "DEM6"     -> LINEOUT4 DAC
every LINEOUTn DAC <- RX_BIAS;  RX3 MIX1 and RX5 MIX1 <- COMP2_CLK
```

- **The interpolators** (RX3..RX6) are exactly RX1's and RX7's: a reset
  pulse in `0x301`, the clock in `0x30f`, and the gain latched after.
  - No chain bit: the B6 reg default is `80`, as on RX7.
  - `COMP2_CLK` does nothing with compander 2 off.
  - The compander's gain-source bit is `LINE_n_GAIN` bit 5: 1 = register
    gain while the compander is off.
- **The DAC** (`taiko_lineout_dac_event`):
  - PRE_PMU: `clsh_fsm(LO, ENABLE, PRE_DAC)`, then `DAC_CTL |= 0x40`, then
    DAPM sets bit 7;
  - POST_PMD: `DAC_CTL &= ~0x40`, and DAPM clears bit 7.
  - The "LINEOUT3/4 DAC GROUND" switches are the same bit 6. They are not a
    separate thing to drive.
- **The PA** (`taiko_codec_enable_lineout`):
  - PRE_PMU: `GAIN |= 0x40`, then DAPM sets `CNP_EN` bit n;
  - POST_PMU: `clsh_fsm(LO, ENABLE, POST_PA)`, which is a no-op for LO, then
    sleep 3 ms;
  - POST_PMD: `clsh_fsm(LO, DISABLE, POST_PA)`, then `GAIN &= ~0x40`.
- **The gain:** `LINE_n_GAIN [4:0]`, inverted, 0..20 ("LINEOUTn Volume",
  invert = 1). **0 is the loudest and 20 (`0x14`) is the quietest,** exactly
  as HPH. Bit 5 = gain source (1 = register).
  - `taiko_codec_reg_init_val` sets bit 5 on all four at probe. **This port
    never did, so the live value `00` is the maximum gain, on a source we
    don't set.**
  - The prep therefore writes bit 5 and the field before anything powers,
    and restores the measured baseline afterwards. This is the r187 speaker
    pattern.

## 2. Class-H in LO mode (`wcd9xxx_clsh_state_lo`), on a 2.15 V buck

This board's buck is pm8941 s2 at 2.15 V (`wcd9320-buck-voltage.md`), so
`buck_mv != 1P8`.

**Enable** (refcounted downstream by `cdc_lo_count`; one LO user here):
1. `enable_buck_mode(BUCK_VREF_1P8V = e6)`:
   - `BUCK_MODE_5` 02 <- 03;
   - `BUCK_MODE_4` ff <- e6;
   - `BUCK_MODE_1` 04 <- 04 and 08 <- 00;
   - `BUCK_MODE_3` 04 <- 00 and 08 <- 00;
   - `BUCK_MODE_1` 80 <- 80;
   - 50 us.
2. `set_fclk_enable_ncp(NCP_FCLK_LEVEL_5)`:
   - `NCP_STATIC` 10 <- 00, then 0f <- 05, then 20 <- 20;
   - `NCP_EN` 01 <- 01;
   - 50 us.
3. The 2.15 V branch:
   - `NCP_EN` 40 <- 00;
   - `enable_ncp(true)` (`NCP_EN` 01 <- 01);
   - 50 us;
   - `BUCK_MODE_5` 01 <- 01, then fb <- 08.
4. `BUCK_MODE_1` 04 <- 00.

No class-H block, no K table, no charge-pump clock request, and no
`comp_req`. **LO mode never touches `CLSH_B1_CTL`.**

**Disable** (`state_idle(disable, LO)`): `enable_ncp(false)` and
`enable_buck(false)`, and nothing else.

**DELIBERATE DEVIATION, NO TRACE:** downstream leaves the following changed
after a line-out stream:
- `BUCK_MODE_4` = `e6`;
- `BUCK_MODE_5` bits;
- `NCP_EN` bit 6 clear;
- `NCP_STATIC` fclk 5.

The proven HPH path rewrites `BUCK_MODE_4` and `NCP_STATIC` itself, but not
`NCP_EN` bit 6 or all of `BUCK_MODE_5`. So after the downstream disable, r188
**restores the five registers' measured pre-enable values**:
- `0x181`, `0x184`, `0x185`, `0x192` and `0x194`;
- the buck and NCP are already off;
- the restore is read back, and fenced.

**Why:** the headphone path must see the state it was proven on, whatever ran
before it. A HPH regression listen *after* the line-out streams checks this
on hardware.

Exclusivity: LO shares the buck and NCP with HPH and EAR, so the existing
rule holds. **One output at a time:** stage 0 requires the whole codec idle,
`clsh_on` included, and the LO class-H has its own `clsh_lo_on` flag in the
idle check.

## 3. What r188 builds: one output, `LO_OUT`, all four line outs in LIQUID's configuration

**Routing:**
- `RX3 MIX1 INP1 = RX1` (L), so L goes to `LINEOUT1`;
- `RDAC5 = DEM3_INV`, so `LINEOUT3 = -LINEOUT1` (a differential pair);
- `RX5 MIX1 INP1 = RX2` (R), so R goes to `LINEOUT2`;
- `RDAC7 = DEM5_INV`, so `LINEOUT4 = -LINEOUT2`.

RX4 and RX6 are not used.

**Why this one configuration finds the wiring:**
- every line out carries the tone, so any **single-ended** connection hears
  it;
- the two **differential** pairs LIQUID uses get the full level;
- downstream's own 8974 machine driver drives exactly this for its external
  speaker amp.

**Bisection:** `Lineout Select` is a 4-bit mask, boot `0xf`, read by the DAC
and PA stages. A heard result is followed by single-bit streams to name the
pin, or pins. RX4 and RX6 (independent `LINEOUT3/4` content) wait until a
pin needs them.

**The stage table** (the r187 ownership model, path 3, six NOPM supplies):

| subseq | stage | function |
|---|---|---|
| 0 | `LO MCLK` | `wcd9320_mclk_get` / `_put` |
| 1 | `LO PREP` | baselines of the 4 gains and `CONN_MISC`; gains = bit 5 + the set field; `CONN_MISC` = DEM3_INV + DEM5_INV; restored after |
| 2 | `LO PREREQ` | the forced 0x314 pair |
| 3 | `RX3+RX5 CHAIN` | `wcd9320_rx_digital_path(3)` then `(4)`: two new table rows, no chain bit |
| 4 | `LO DAC` | `rx_bias(on)`, class-H LO enable, then for each selected n: `DAC_CTL` bit 6, then bit 7 |
| 5 | `LO PA` | for each selected n: `GAIN` bit 6, then `CNP_EN` bit n; then 3 ms |

These feed a NOPM PGA `LO` -> OUTPUT `LO_OUT`.
- **The card:** a `Lineout` line widget (pin `Lineout`), routed from
  `LO_OUT`, OFF at boot, in `lumia_q6_pins_off[]`. The teardown and the
  digital gate switch it off with the others.
- **The PA teardown, in downstream's order:**
  1. `CNP_EN` bits clear;
  2. class-H LO disable;
  3. the gain bit 6s clear.
- **The DAC teardown:** bit 7 then bit 6, the five-register class-H restore,
  then the RX bias.

**Controls:**
- `Lineout Volume`: 0..20, field = 20 - v, boot 0 = **minimum** (`0x14`).
- `Lineout Select`: 0..15, boot 15.
- `RX3 Digital Volume` and `RX5 Digital Volume`: 0..84, boot 84 (0 dB). There
  is no L+R sum here, so no -6 dB is needed.

**The C3 abort** gains `lo_pa(false)` with the PAs and `lo_dac(false)` with
the DACs, so every PA is still first. `lo_prep(false)` goes with the preps.

**Housekeeping (fix every copy):** `wcd9320_dig_vol_put` labels RX7's
writes "RX2 Digital Volume". It now names the channel from the table.

## 4. Probes (hardware, one fresh boot)

**Before any probe:**
- the digital gate with every pin OFF (four graphs);
- the regressions;
- the HPH listen, one stream.

**Probe L (line outs, all four):**
- mic at the speaker grille, phone flat;
- `Lineout` on, `Lineout Volume 0` (minimum), -40 dBFS, one approved stream;
- then with the mic at the earpiece slot.

| result | meaning | next |
|---|---|---|
| heard | a line out feeds a transducer | bisect with `Lineout Select` (1, 2, 4, 8), then the gain step size |
| silent at minimum | not yet meaningful | Lineout Volume up, then the declared -30 / -20 dBFS escalation, as r187 |
| silent at -20 dBFS, full gain | no line out reaches a transducer, or the amp is held off (an un-declared enable: PMIC GPIO/MPP) | stop and re-plan: the amp-enable search |

**After the line-out streams:** one HPH listen stream. This checks that the
class-H LO restore left the headphones exactly as proven.

**Safety, unchanged:**
- the Volume Down abort is proven at arm time;
- the fail-safe timer is armed;
- one chat approval per stream;
- minimum gain first;
- the pins start OFF;
- a hard abort on an unexpected PA state;
- escalation only with `ESCALATE=declared` and the operator's chat
  "declared".

A line out into an amplifier input is a light load. At the minimum gain and
-40 dBFS the level is millivolts.

## 5. As built (r188 `lineout-rc1`, card `q6-card-rc7`, pkgrel 188), staged 2026-11-09

**Compile:** both modules compile clean at `W=1` in the compile-check tree.

**Built as mapped.** Points worth knowing:

1. **`wcd9320_clsh_lo()`** is its own function, not a third mode of
   `wcd9320_clsh_mode()`. LO shares nothing with the HPH/EAR body: no block,
   no K table, no charge-pump clock, no `comp_req`.
   - The no-trace restore uses `regmap_update_bits` and reads back bypassed.
     A mismatch is counted (`lo_restore_mismatch` in `out_state`) and warned
     about, but it does not fail the teardown. Some buck bits may not read
     back as written; the hardware run will show which.
2. **The RX table grew to five rows.** Channel 3 is RX3 and channel 4 is RX5.
   - The per-channel counters are mapped in one place, `wcd9320_rx_ctrs()`.
   - The interpolator log text is now generic; the `rxN-digital:` prefix
     already names the channel.
3. **`wcd9320_lo_rx()`** is the RX3+RX5 stage: both chains or neither.
4. **`out_vol_put`** keeps one `mutex_lock` site: it validates first, then
   takes the lock once. The lock-balance fence counts sites.
5. **`out_state`** gains three lines:
   - the line-out state;
   - the four gains and DACs, `CNP_EN` and `CONN_MISC`;
   - the five class-H LO registers.

   `dapm_state` gains `lo_held` and `lo_pa`.

**Fences:**
- 5i covers four graphs and 11 controls.
- 5k's stage table is 18 rows, and its abort order includes the line-out PA,
  DAC and prep.
- **5l is new, with 55 checks:**
  - every address;
  - single write sites for `CNP_EN` and `DAC_CTL`;
  - downstream's DAC and PA order;
  - the refusals;
  - gains booting at the minimum;
  - state_lo's 2.15 V branch;
  - no `CLSH_B1` writes;
  - the five-register restore order;
  - RX3/RX5 rows;
  - the select latch.
- **Results:** 574 source checks pass. The 2 expected pre-build failures are
  the module version and the read-bypassed count (139, measured +10 in the
  compile-check tree). Mutation test 19/19.

**Tools:**
- The listen runner takes `OUTPUT=lo` and `LO_SELECT` (1..15), with live,
  after and no-trace checks.
- The digital gate covers four graphs, with every pin off.
- The teardown switches off `Lineout Switch` too.
- Card rc7 is expected everywhere.
- Selftest 96/0.

**Build** (operator):

```
tools/build-wcd9320-kernel.sh --pkgrel 188 --version lineout-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r188 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
```

`pcm-tone` is unchanged from r186.

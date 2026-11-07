# MCLK ownership: from a test-runner switch to a driver-owned clock (r182 map)

**Status:** map only, nothing built. Written 2026-11-07, after r181 passed.

**Why now:**
- C3a only makes sound with the codec on the external 9.6 MHz MCLK
  (`wcd9320-hphl-conversion-proven`).
- Today the MCLK bring-up is choreographed from user space, across two
  drivers and three sysfs attributes, by every runner that needs it.
- The final driver must own it.

This map settles three things:
- how downstream owns MCLK;
- what we have today;
- the smallest design that puts ownership in the driver without changing a
  register sequence already proven on hardware.

## 1. Downstream: three layers, each with one job

**Sources:**
- Nexus 5 (`android_kernel_lge_hammerhead` cm-11.0): machine driver
  `sound/soc/msm/msm8974.c`, the board dtsi, `msm8974-clock.dtsi`,
  `msm-pm8941.dtsi`.
- `hh-wcd9xxx-resmgr.c` and `hh-wcd9320.c` from the cached codec tree.
- The cm11 generic `msm8974.dtsi`, for the DAPM routes.

### 1a. Board: the divider factor and the pin, static from boot

- **Divide factor.** `pm8941_clkdiv1: clkdiv@5b00 { qcom,cxo-div = <2>; }` is
  consumed by the `qcom,qpnp-clkdiv` driver. This is the AP-side owner of the
  divide factor (see `wcd9320-mclk-mapping.md`, "RESOLVED"). Nothing at
  runtime changes it.
- **The `qpnp-clkdiv` source is not in the cache.** Two things are not
  verified:
  - that it writes the factor at probe rather than at first enable;
  - whether it ever restores the factor.
- **The pin.** `gpio@ce00 { /* GPIO 15 */ /* WCD_MCLK */ }` is configured
  once, by the qpnp-pin driver at probe, and never moved again:

  ```
  qcom,mode = <1>        digital out
  qcom,output-type = <0> CMOS
  qcom,pull = <5>        none
  qcom,vin-sel = <2>     VIN2
  qcom,out-strength = <3> medium
  qcom,src-sel = <2>     FUNC_1 (DIV_CLK)
  ```

- **The machine driver** `gpio_request()`s the pin by name and never touches
  its direction or value (already recorded in the mclk map).

**So downstream never "turns the divider on" for audio.** The factor and the
pin mux are board state. The only runtime control is the RPM enable vote.

### 1b. Machine driver: the reference-counted enable

`msm_snd_enable_codec_ext_clk(codec, enable, dapm)`, condensed:

```
enable:  clk_users++; if (clk_users != 1) return;
         clk_prepare_enable(codec_clk);        /* osr_clk = RPM div_clk1 */
         taiko_mclk_enable(codec, 1, dapm);
disable: if (clk_users > 0 && --clk_users == 0) {
             taiko_mclk_enable(codec, 0, dapm);
             clk_disable_unprepare(codec_clk);
         }
```

- **Order:** the vote comes before the codec switch, and the codec switches
  back before the vote is dropped.
- **No `clk_set_rate`.** It only validates `qcom,taiko-mclk-clk-freq ==
  9600000`.
- **Two callers:**
  - The DAPM supply:

    ```
    SND_SOC_DAPM_SUPPLY("MCLK", SND_SOC_NOPM, 0, 0, msm8974_mclk_event,
                        SND_SOC_DAPM_PRE_PMU | SND_SOC_DAPM_POST_PMD)
    ```

    with routes `RX_BIAS <- MCLK`, `LDO_H <- MCLK` and `AIF4 MAD <- MCLK`.
    Any playback path powers RX_BIAS, so MCLK is up exactly while a path is.
  - MBHC, through `mbhc_cfg.mclk_cb_fn`.

### 1c. Codec: `taiko_mclk_enable()` -> resmgr

```
lock BG_CLK
enable:  get_bandgap(AUDIO_MODE); get_clk_block(MCLK)
disable: put_clk_block(MCLK);     put_bandgap(AUDIO_MODE)
unlock
```

`wcd9xxx_resmgr_get_clk_block(MCLK)`:
- **First MCLK user, clock OFF:** `enable_clock_block(config_mode=0)`.
- **First MCLK user, on RCO:** `WARN_ON(!(RC_OSC_FREQ & 0x80))`, then
  `disable_clock_block()`, then `enable_clock_block(0)`. This is the
  sequence r169 implements and proved.

`put_clk_block(MCLK)`:
- **Last MCLK user, no RCO users:** `disable_clock_block`, then OFF.
- **Last MCLK user, RCO users remain:** `disable_clock_block()`, then
  `enable_clock_block(1)`, back on RCO. This is r169's restore.

The codec never touches the PMIC, the pin or the RPM clock.

## 2. What this port has today (r181)

| Layer | Downstream | This port, r181 |
|---|---|---|
| Divide factor | DT `cxo-div = <2>`, set by qpnp-clkdiv | `lumia-mclk-experiment.c`, written from sysfs `mclk_div_test on`, restored to the measured value on `off` |
| Pin mux | qpnp-pin, static func1 | the same experiment node, `pinctrl` state `divclk` selected on `on`, `off` state on `off` |
| Enable vote | machine driver, `clk_users` refcount | codec driver `mclk_test`, `mclk_refs` refcount on `<&rpmcc RPM_SMD_DIV_A_CLK1>` |
| Codec switch | resmgr get/put_clk_block, MCLK users | codec driver `clk_source_test mclk/rco`, no refcount (`-EBUSY` if already on MCLK) |
| CHIP_CTL rate | wcd9xxx-core, at init, from `qcom,cdc-mclk-clk-rate` | inside the switch, after it, retried on MCLK and restored before RCO (r169 finding) |
| Bandgap | taken with MCLK (AUDIO_MODE) | held permanently since core-init stage 2 |
| Who calls it | DAPM supply + MBHC | every runner, in order: divider on, vote on, switch; then switch back, vote off, divider off (`c3_clock_up` / `c3_clock_down`, the vm and zdet gates) |

**Facts that shape the design:**
- **Same module.** The experiment driver is linked into the same
  `wcd9320.ko` as the codec driver (`wcd9320-y := wcd9320-core.o
  lumia-mclk-experiment.o`), and its node is a child of `pm8941_0`.
- **No DAPM yet.** The ASoC component registers with no widgets and no
  routes, and there is no card. Today the "path" is the research attributes
  (`cdc_clk_prereq`, `rx1_digital_test`, `hphl_dac_test`, `hphl_pa_test`).
  There is no DAPM supply to hang MCLK on yet.
- **RCO is the base clock.** The codec runs on RCO from core init onward,
  which is downstream's "RCO users remain" branch, permanently. So the last
  MCLK put always returns to RCO, never to OFF. That is what r169's restore
  already does.
- **Boot-chain state.** The boot chain leaves DIV_CLK1 enabled (`EN_CTL` `80`)
  at factor 0 (19.2 MHz) with gpio15 in `normal`. Linux holds no vote.

## 3. The design for r182 (`mclk-own-rc1`): move ownership, change no sequence

### 3a. Board state becomes static, like downstream

- The experiment node's driver writes `DIV_CTL1` factor 2 **once, at probe**,
  reads it back, and refuses to bind if it did not take.
- It selects the `divclk` pinctrl state as the device's **`default`** state,
  so the driver core applies it before probe. The `off` state is deleted.
- `mclk_div_test` is removed. `mclk_div_state` (read-only) stays, so the
  gates can read the factor and `MODE_CTL` from the PMIC.
- Nothing is restored at remove. Downstream never restores either, and a
  half-restored divider under a codec still on MCLK is the worse failure.
- **The pin's drive strength stays at what r169 to r181 ran with** (no
  explicit `qcom,drive-strength`). Downstream sets "medium" explicitly, so
  this is recorded as a known difference, not changed in this build. One
  variable at a time.

### 3b. The codec driver gains one owner: `wcd9320_mclk_get()` / `_put()`

These are downstream's `msm_snd_enable_codec_ext_clk()` and
`taiko_mclk_enable()` fused, because this port has no separate machine
driver.

```
get:  lock; if (++mclk_users > 1) { unlock; return 0; }
      clk_prepare_enable(mclk)                 /* the RPM vote */
      wcd9320_clk_source_switch(wcd, true)     /* r169, unchanged, incl. CHIP_CTL */
      on failure: the switch has already restored RCO itself;
                  clk_disable_unprepare(mclk); mclk_users = 0; return err
      unlock
put:  lock; if (!mclk_users) { warn; return -EINVAL }
      if (--mclk_users) { unlock; return 0; }
      wcd9320_clk_source_switch(wcd, false)    /* r169 restore, unchanged */
      clk_disable_unprepare(mclk)              /* even if the restore failed */
      unlock
```

- **One mutex** covers the count, the vote and the switch.
- **`wcd9320_clk_source_switch()` is not modified.** Its PA guard, positive
  control, CHIP_CTL ordering and unconditional restore are all proven.
- **The order is downstream's:** vote, then switch; switch back, then unvote.

### 3c. Interface: two attributes become one, with the same name

- **`clk_source_test`:** `mclk` becomes `get`, and `rco` becomes `put`. A
  runner that writes `mclk` twice now takes two references instead of
  getting `-EBUSY`.
- **`mclk_test` is removed.** A second, independent writer of the vote is
  exactly the split ownership this build exists to end.
- **`clk_source_state`** gains `mclk_users=` so gates can check the count.
- **Runners:**
  - `c3_clock_up` becomes one write (`mclk`) plus the existing state checks,
    and `c3_clock_down` becomes one write (`rco`).
  - The divider device lookup is deleted from the C3a runner and from the vm
    and zdet gates.
  - The historical r166 to r169 gates (`wcd9320-mclk-evidence.sh`,
    `-clk-source-evidence.sh`, `-conjunction-evidence.sh`) drive
    attributes that no longer exist. They are retired with a header note,
    not edited.

### 3d. What r182 deliberately does not do

- **No DAPM supply widget.** It arrives with the card. Its event handler will
  be `PRE_PMU -> wcd9320_mclk_get()` and `POST_PMD -> wcd9320_mclk_put()`,
  exactly downstream's `msm8974_mclk_event`. r182 creates the function that
  handler will call.
- **No automatic MCLK inside `hphl_pa_test` / `hphl_dac_test`.** Those
  attributes are research hooks, not the product path. Wiring MCLK into them
  would bake a second, temporary owner into the driver. The runner keeps
  taking one explicit reference, now through the one owner.
- **No 0x314/0x30d recheck.** That is its own follow-up.
- **No bandgap change.** It is held from core init, which covers
  downstream's AUDIO_MODE vote.

## 4. Hazards, and what the gate must check for each

1. **RPM may clobber the factor on a vote transition.** This is untested.
   Every MCLK run so far rewrote the factor immediately before taking the
   vote, so no run has had a static factor survive a vote off and on. The
   mclk map flagged this hazard in August. **The gate reads `DIV_CTL1` after
   every vote on and every vote off, over at least three get/put cycles in
   one boot.** If the factor ever reads other than 2: stop. Downstream's
   static model would not hold here, and the factor would have to be
   rewritten before each vote. That is a small change inside `get`, but a
   different design.
2. **The pin now carries a clock from boot.** With `EN_CTL` `80` from the
   boot chain and factor 2, gpio15 drives 9.6 MHz while the codec sits on
   RCO. `CLK_BUFF_EN1` bit 3 keeps the codec on RCO, and downstream lives in
   exactly this state. Even so:
   - the cold-boot gate and the regcache gate must pass unchanged;
   - `clk_source_state` at boot must still read `source=RCO`, `on_mclk=0`,
     `chip_ctl_0x000=08`.
3. **Ordering between the two drivers.** The first `get` comes from user
   space, long after both drivers in the module have probed, so no deferral
   machinery is added. **The gate checks `mclk_div_state` (factor 2, gpio15
   function 1) before the first `get`.**
4. **A failed switch must not leak the vote.** A synthetic selftest forces
   the switch to fail and checks two things: `mclk_users` returns to 0, and
   the RPM clock's enable count returns to its starting value.
5. **The refcount must not hide a double switch.** With `users 1 -> 2 -> 1`,
   `clk_src_switches` and `clk_src_restores` must not move. Only `0 -> 1` and
   `1 -> 0` switch.

## 5. Order of work

Fences first, then driver, then selftests, then runner (the project rule).

1. **Fences** (`wcd9320-verify-artifact.py`):
   - `clk_prepare_enable(wcd->mclk)` and `clk_disable_unprepare(wcd->mclk)`
     appear only inside `wcd9320_mclk_get`/`_put`.
   - `wcd9320_clk_source_switch(` is called only from `_get`/`_put` and from
     its own restore path.
   - `mclk_test` and `mclk_div_test` are absent.
   - The experiment driver has no runtime write path to `DIV_CTL1` outside
     probe.
2. **Driver:** `get`/`put`, attribute changes, static board state, DT
   (`pinctrl-names = "default"`, `pinctrl-0 = <&wcd9320_mclk_divclk>`).
3. **Selftests:** the refcount and unwind cases above. Also the runner
   selftest (`wcd9320-hphl-pa-expect.sh`) with the one-write clock up/down.
4. **New gate** `tools/wcd9320-mclk-own-evidence.sh`, digital only, PA never
   enabled:
   - **Boot:** factor 2, function 1, `source=RCO`, `mclk_users=0`.
   - **Then three cycles of** `get -> get -> put -> put`, checking all of:
     - `on_mclk`, `cdc_alive` and `chip_ctl` (`0a` on MCLK, `08` after);
     - `mclk_users` at each step;
     - the switch and restore counters moving only on `0 -> 1` and
       `1 -> 0`;
     - `DIV_CTL1` after every vote transition;
     - `cache_check` 0 at the end.
   - **Costs nothing from the forced-write budget.** Forced writes are only
     0x314 and 0x30d, which the switch never touches.
5. **Runner:** `c3_clock_up`/`down` to one write each; vm and zdet gates the
   same.
6. **Hardware:**
   - the regression set: vm, zdet, cache;
   - then one C3a listening run (2 cycles) on a fresh boot, through the new
     path.
   - A pass there closes "MCLK into the driver" up to the point where DAPM
     takes over the call.

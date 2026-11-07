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
   src_sel 2 = FUNC1) before the first `get`.**
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
   - **Boot:** factor 2, gpio15 src_sel 2 (FUNC1), `source=RCO`,
     `mclk_users=0`.
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

## 6. r182 AS STAGED (`mclk-own-rc1`, pkgrel 182)

### Driver (`wcd9320-core.c`)

- **The owner.** `wcd9320_mclk_get()` / `wcd9320_mclk_put()` sit right after
  `wcd9320_clk_source_switch()`.
  - `get`: only the first user votes (`clk_prepare_enable`) and switches. A
    failed switch releases the vote, and users stay 0.
  - `put`: only the last user switches back, then releases the vote. The vote
    is released even if the restore failed.
  - `put` with no reference returns `-EINVAL` and changes nothing.
- **Removed:** `wcd9320_mclk_enable()` and the `mclk_test` attribute.
  `mclk_refs` is renamed `mclk_users`.
- **`clk_source_test`:** `mclk` is now get, and `rco` is now put.
  `clk_source_state` gains `mclk_users=`.
- **The r169 switch is unchanged.** The fence pins its body sha256
  (`757fa0df…`, measured from the r181 patch).

### Divider (`lumia-mclk-experiment.c`)

- `lumia_mclk_apply()` runs once, from probe. It writes the factor,
  chip-verifies it, and then selects the `divclk` pin state. A failure refuses
  the bind.
- `mclk_div_test` is removed, along with the whole restore path.
- `mclk_div_state` gains `div_at_probe=`.

### Two deliberate deviations from section 3

1. **The DT is unchanged.** Section 3a planned to make `divclk` the pin's
   `default` state. That would mux gpio15 before probe writes the factor, so
   the pad would briefly carry the undivided 19.2 MHz. It would also reverse
   the factor-then-pin order that every hardware run since r169 has used.
   Instead probe selects `divclk` itself, after the factor is verified. No DTS
   change, so no DTS checksum change.
2. **No new mutex: get/put run under `c3_lock`.** Every C3 sequence already
   holds `c3_lock`, and the voltmeter and zdet refuse unless the codec is on
   MCLK. Sharing the lock means a `put` can never switch the clock back
   underneath a measurement. Nothing on the switch path takes `c3_lock` (the
   PA guard and the sequences were checked), so this cannot deadlock.

### Fences and gates

- **Fence:** new section 5h in `wcd9320-verify-artifact.py`. It fails the
  r181 patch in 24 places. On the staged r182 patch every source check passes,
  and the only failures left are the five that need the built module.
- **Runners:** `c3_clock_up`/`c3_clock_down` in the C3a runner, and the clock
  steps of the vm gate, the zdet gate and the rxb6 trace, are now:
  - read the board state (refuse unless factor 2 and gpio15 src_sel 2 (FUNC1));
  - one `mclk`, holding the reference only if it succeeded;
  - one `rco`.
- **Check counts:** the vm and zdet gates keep 57 and 34. The "divider on" and
  "mclk vote" checks became "factor 2" and "gpio15 src_sel 2 (FUNC1)".
- **Selftests:** PA 130/0; the evidence lib behaves as expected.
- **New gate:** `tools/wcd9320-mclk-own-evidence.sh`, three cycles by default.
- **Retired:** `wcd9320-mclk-evidence.sh`, `-clk-source-evidence.sh` and
  `-conjunction-evidence.sh` get a header note and are otherwise untouched.

## 7. r182 RESULT (2026-11-07): the driver owns the MCLK, and it plays

**Build:** verify-artifact 329/0, all 28 checks in 5h included.

All runs below are on one fresh boot, in order.

| Run | Result |
|---|---|
| `mclk-own` `212645Z` | FAIL 84/4. A **gate defect**, not a driver one: the gate expected gpio15 `function=1`. The PMIC encodes `src_sel` as 0 normal, 1 paired, **2 func1**, and r168 recorded "gpio15 function 2" for the working state. The same wrong `1` was also in the C3a runner and the vm and zdet gates, and every copy was fixed before the runs below. |
| `mclk-own` `212826Z` | **PASS 88/0** |
| vm `212833Z` | **PASS 57/0** |
| zdet `212851Z` | **PASS 34/0**. Zl 51.3 Ω, Zr 56.2 Ω, DC 14.4 mV within 50. |
| C3a acoustic `213202Z` | **Heard, both cycles.** Cycle 1 analyser PASS (−67.0 dBFS, 1000.00 Hz, 24.9 dB). Cycle 2: the tone was present at −66.4 dBFS, but the analyser REJECTED it on a broadband rise at the mic; the operator had moved the headset. Accepted by the operator. |

**What the gate settled:**

- **Hazard 1 is answered: RPM never touched the factor.** `DIV_CTL1` read
  `02` after every vote on and every vote off, over six transitions across the
  two gate runs.
- **RPM does write the peripheral, though.** `EN_CTL` read `80` at boot (left
  on by the boot chain) and `00` after the first run's vote-off. So RPM
  touches the divider's enable bit on vote transitions and leaves the factor
  alone. Downstream's static-factor model holds on this board.
- **The vote is the active-only clock.** `div_clk1_a` went `0 -> 1 -> 0` with
  each get and put; `div_clk1` stayed 0.
- **The counts behave.** Only `0 -> 1` and `1 -> 0` switched. A put with no
  reference was refused and changed nothing.
- **Clean end state.** `cache_check` 0. The forced journal was untouched by
  the gate (the vm DAC step used its usual 4).
- **The C3a journal shows the new path end to end:**

  ```
  clock: board state: div_ctl1=02 factor=2 gpio15_function=2
  clock: mclk_users=1 on_mclk=1 cdc_alive=1 chip_ctl_0x000=0a ...
  ...
  clock: RESTORED to RCO: mclk_users=0 on_mclk=0 cdc_alive=1 chip_ctl_0x000=08
  ```

  Phone telemetry in both cycles matched r181: `0x1ab=a0`, `1b3=08`, port 16
  clean, OCP 0.

**Status:** "MCLK into the driver" is done up to the DAPM hand-off. When the
card arrives, its `MCLK` supply calls `wcd9320_mclk_get/_put` from `PRE_PMU`
and `POST_PMD`.

**The pin's drive strength** was the last open item, and r183 closed it
(section 7b).

### 7b. r183 (`mclkpin-rc1`): gpio15 driven like downstream (2026-11-07)

**What r169 to r182 actually ran with.** The `divclk` state set neither
strength nor bias, so gpio15 stayed at its POR electrical config:

| register | value | meaning |
|---|---|---|
| `0xce45` DIG_OUT_CTL | `01` | CMOS, strength LOW |
| `0xce42` DIG_PULL | `04` | pull-down 10 µA |

**What the two independent sources set:**
- **Nexus 5** (`gpio@ce00 /* WCD_MCLK */`): raw strength 3 and pull 5 (no
  pull). Its DT comment says "MED", but 3 is HIGH in its own qpnp enum.
- **The Lumia's own ACPI** codec power state:
  `PMICGPIO … 0x0E, 0, 0x02, 0x04, 0x03`, which is VIN2, FUNC1 and strength
  3 (high).

**Encodings checked against mainline `pinctrl-spmi-gpio.c`:**
- register strength: 1 low, 2 medium, 3 high;
- the binding's `PMIC_GPIO_STRENGTH_HIGH` (1) is translated to register 3;
- pull: 4 is pull-down 10 µA, 5 is none.

**r183 change:** DT only, `bias-disable;` and
`qcom,drive-strength = <PMIC_GPIO_STRENGTH_HIGH>;` on `divclk`, applied to
all three DTS copies. The module is unchanged except `MODULE_VERSION`.

**Result, on one fresh boot:**
- **mclk-own gate 90/0.** `0xce42 = 05` and `0xce45 = 03`; FUNC1, the
  factor, the counts and the cache all as on r182.
- **C3a acoustic `003952Z`: PASS 2/2.** −65.3 / −65.8 dBFS, contrast
  28.9 / 25.3 dB, 1000.01 Hz both cycles, heard.
- That is within run-to-run placement variance of r182 (−67 / −66.4); no
  level change is claimed.

### 7a. 0x314 / 0x30d on MCLK: still read 00 (answered from the r182 journal)

The driver's forced-write journal records the chip readback (`fN_hw`) of
every forced write. On the r182 boot it holds 12 entries, every one issued
with the codec on MCLK and CHIP_CTL declaring 9.6 MHz (`0a`):
- f0–f3: the vm gate's DAC step;
- f4–f11: the two-cycle C3a run that was heard.

| entries | register | written | chip reads |
|---|---|---|---|
| f0, f4, f8 | 0x314 | `03` (set) | `00` |
| f3, f7, f11 | 0x314 | `00` (clear) | `00` |
| f1, f5, f9 | 0x30d bit 1 | `02` (set) | `00` |
| f2, f6, f10 | 0x30d bit 1 | `00` (clear) | `00` |

**This is the first time these writes have been observed with the rate
correctly declared.** r165 to r169 wrote CHIP_CTL at 0x001, which is a status
register, so r169's "on MCLK, still refused" ran with no rate declaration at
all.

**Reading:**
- The clock source and the rate declaration are not why these registers
  read 00.
- The HPHL plays with them in exactly this state.
- So the r174 classification stands unchanged: write-effect-unverifiable,
  inverse-write-mandatory, no readback expectation.

**Not answered:** whether the writes are effective, meaning write-only and
read-as-zero, or inert on this part. Only a causal test settles that: a C3a
run with the forced writes omitted, where silence means they are needed.
Downstream issues them and they are harmless, so this is optional.

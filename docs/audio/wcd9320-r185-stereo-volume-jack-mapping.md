# r185: stereo (HPHR), volume controls, jack detection driving the pin

**Status:** MAPPED 2026-11-08, after r184 (`dapm-hphl-rc1`, plain playback
heard on HPHL) passed and was pushed.

**The goal.** A plain stereo stream plays on both earcups. ALSA has volume
controls. Plugging in headphones turns the path on, and unplugging turns it off.

**Operator decisions (2026-11-08):**
- **Jack drives the pin.** Insertion enables the card's `Headphones` pin and
  removal disables it. The manual switch stays, and so does the Volume Down
  abort.
- **Volume:**
  - analog `HPHL Volume` / `HPHR Volume`, 21 steps, booting at the minimum;
  - `RX1 Digital Volume` / `RX2 Digital Volume`, capped at 0 dB.
- **HPHR's DC is measured on-chip before the first stereo acoustic run,**
  against the same 50 mV contract as HPHL.

**Sources:**
- `~/ds-hdr/src/hh-wcd9320.c`:
  - `taiko_hphr_dac_event`
  - `taiko_hph_pa_event`
  - `taiko_codec_enable_interpolator`
  - widgets and routes at lines 3630-3830 and 5236-5327
  - controls at 1315 and 1511
- `~/.cache/wcd9320-downstream/wcd9xxx-common.c`: the class-H FSM, states
  `hph_l`, `hph_r` and `hph_st`, plus `clsh_comp_req`.
- `mbhc/nemo310-wcd9xxx-mbhc.c`:
  - `wcd9xxx_insert_detect_setup`
  - `wcd9xxx_swch_irq_handler`
  - `wcd9xxx_swch_level_remove`
  - `wcd9xxx_jack_report`
- `audref/ds/cm11-wcd9xxx-slimslave.c`: the RX port payload.

## 1. HPHR, from downstream, per stage

Each HPHR stage is the HPHL stage it mirrors, with the differences listed.
Nothing here is new hardware behaviour: every register is downstream's, and
every write goes through the same verified helpers (`c2b_write`,
`forced_write`).

### 1a. The RX2 digital chain

Downstream: `RX2 MIX1 INP1 = RX2` (SLIM RX2), the interpolator event, and
`RX2 MIX2` / `RX2 CHAIN` on the RX2 bits.

| step | RX1 (proven) | RX2 |
|---|---|---|
| rate asserted, not written | `0x2b4 & e0 == 60` | `0x2bc & e0 == 60` (reset `78`, the same) |
| MIX1 INP1 | `0x380 [3:0] = 5` ("RX1") | `0x383 [3:0] = 6` ("RX2") |
| interpolator reset pulse | `0x301` bit 0 | `0x301` bit 1 |
| interpolator clock | `0x30f` bit 0 | `0x30f` bit 1 |
| gain latch (read, write back) | `0x2b7` | `0x2bf` |
| chain | `0x2b5` bit 5 | `0x2bd` bit 5 |

**Built as one function, `wcd9320_rx_digital_path(wcd, ch, on)`,** with a
two-row table. `wcd9320_rx1_digital_path()` stays as the channel-0 wrapper, so
every RX1 caller and log line is unchanged. The table approach avoids a second
copy of the sequence, per [fix every copy].

### 1b. The HPHR DAC

Downstream: `HPHR DAC` is `DAC_E` on `RX_HPH_R_DAC_CTL` (`0x1b7`) bit 7, fed
by `RX2 CHAIN` with `RX_BIAS` as its supply. It has no DSM mux; the mux is
HPHL's and SPKR's only. `taiko_hphr_dac_event`:

```
PRE_PMU:  0x30d |= 0x04 (RDAC HPHR clock);  0x1b7 |= 0x40;  clsh_fsm(HPHR, ENABLE, PRE_DAC)
(widget): 0x1b7 |= 0x80
(widget): 0x1b7 &= ~0x80
POST_PMD: 0x30d &= ~0x04;  0x1b7 &= ~0x40
```

`wcd9320_hphr_dac_path(wcd, on)`:
- **Prerequisites, refused rather than supplied:**
  - the HPHL DAC path is up (so class-H is in state HPHL, RX bias is held,
    and the 0x314 prereq is issued);
  - RX2 is on;
  - register-gain mode only, with `0x1b4` chip-verified as source bit 5 plus
    the HPHR gain field (mirroring the `0x1ae` check).
- **Enable:**
  1. `rx_bias(true)`, refcounted;
  2. forced `0x30d` bit 2;
  3. `0x1b7` bit 6;
  4. the class-H join (1c);
  5. `0x1b7` bit 7.

  The PA guard runs before and after.
- **Teardown,** best-effort and complete:
  1. `0x1b7` bit 7 off;
  2. forced `0x30d` bit 2 clear (mandatory inverse);
  3. bit 6 off;
  4. the class-H leave if still joined;
  5. `rx_bias(false)` if this path took it.
- **`wcd9320_hphl_dac_path(off)` first tears HPHR down if it is up,** so
  nothing can leave the right DAC running on a left teardown, the C3 abort
  included.

### 1c. Class-H for the second channel

The FSM state is a bitmask: `PRE_DAC` ORs the channel in, and `POST_PA`
disable ANDs it out. Our proven HPHL path runs `IDLE -> HPHL` (full enable)
and `HPHL -> IDLE` (`comp_req(L, off)` plus `turnoff_postpa`).

| transition | downstream function | register effect here (no resmgr, `COND_HPH` clear) |
|---|---|---|
| `HPHL -> HPHL+HPHR` (HPHR PRE_DAC) | `state_hph_st(enable)`: `comp_req(L, on)`, `comp_req(R, on)` | `CLSH_B1` bit 3 <- 0 (already 0), **bit 2 <- 0** |
| `HPHL+HPHR -> HPHL` (HPHR POST_PA off) | `state_hph_l(disable, req R)`: `comp_req(R, off)` | `CLSH_B1` bit 2 <- 0 |
| `HPHL -> IDLE` | unchanged, proven | unchanged |

**The order.**
- Downstream itself powers the HPHR DAC first, because mainline sorts DAC
  before MIXER (7 before 8). The end state is the same either way.
- We keep HPHL first, because that is the proven entry from IDLE. HPHR joins
  second and leaves first. Both orders are legal transitions of downstream's
  FSM.

**Baseline consequence.**
- `CLSH_B1` bit 2 is POR 1 (`e4`), and downstream never sets it back.
- After the first stereo stream, `0x320` therefore reads `a3` live and `a2`
  idle, instead of `a7` / `a6`.
- The C3a runner's `clsh_0x320` live check accepts only `a7`. So **the HPHL
  C3a and listen regressions run before the first stereo stream on a boot,**
  or with the stereo-aware expectation. The gates handle this.

**`COND_HPH` stays clear.** Downstream's MBHC sets it from its jack report,
which would make bits 3 and 2 equal 1 while plugged. That is a change to the
proven class-H sequence, and r185 does not take it. Recorded as a deviation.

### 1d. The HPHR PA

Downstream: `HPHR` is `PGA_E` on `0x1ab` bit 4, with `taiko_hph_pa_event`
(`w->shift == 4`). The steps are the same as HPHL's, with `req_clsh_state =
HPHR`.

`wcd9320_hphr_pa_path(wcd, on)`:
- **Prerequisites, refused:**
  - the HPHL PA is on (stereo only, and HPHL first);
  - the HPHR DAC is up;
  - `0x1b7` reads `c0` on the chip;
  - prep is applied;
  - no OCP latched (`INTR_STATUS2` bit 0 OCPL **or bit 1 OCPR**).
- **Enable:**
  1. guard `20`;
  2. `0x1ab` bit 4;
  3. guard `30`;
  4. the settle (13 ms, compander off);
  5. the OCP sample;
  6. the `POST_PA` writes;
  7. guard `30`.

  The four `POST_PA` writes are `wcd9xxx_clsh_enable_post_pa()`, which
  downstream runs for every PA. They are moved into one helper,
  `wcd9320_clsh_post_pa()`, called by both PA paths. After HPHL they are
  value no-ops.
- **Teardown:**
  1. bit 4 clear;
  2. the settle;
  3. the class-H leave (bit 2 <- 0);
  4. guard `hphl_pa_on ? 20 : 00`.
- **`wcd9320_hphl_pa_path(off)` tears HPHR down first if it is up.** So
  `wcd9320_c3_abort()` is unchanged: its first call now takes both PAs down,
  right then left.

**The OCP sample now treats OCPR (bit 1) as a fault too,** for both
channels. On HPHL-only runs bit 1 must be 0, so this only adds a stop
condition.

### 1e. Prep: the HPHR gain

`wcd9320_pa_prep_set[]` gains two rows: `0x1b4` bit 5 (register gain source)
and `0x1b4 [4:0]` (the HPHR field). That makes 8 rows, all snapshotted and
restored to their measured baseline.
- The field row takes `pa_gain_field_r`, which defaults to `0x14` (minimum)
  at probe like `pa_gain_field`.
- Writing `0x1b4` with the PA off is inert.

## 2. Stereo transport

**Ports.** `taiko_rx_chs[]` maps slave port 16 + n to channel shift n:
port 16 is SLIM RX1 (channel 144) and port 17 is SLIM RX2 (channel 145).
`wcd9xxx_cfg_slim_sch_rx()` ORs `1 << shift` over every channel in the
stream, and writes that payload to **each** port's multi-channel register.
- Stereo is therefore `0x180 = 03` and `0x181 = 03`, both ports enabled.
- Mono stays `0x180 = 01` (today's proven delta).

**Changes:**
- **`wcd9320_rx_port_program(wcd, first, n, on)`** programs ports
  `first..first+n-1` with payload `GENMASK(n-1, 0) << (first - 16)`.
  - The IFD before/after snapshots bracket the whole set.
  - The state is `rx_port_on`, `rx_port_num` (the first port) and
    `rx_port_n`.
  - Every caller is updated; the research hooks keep n = 1.
- **`__wcd9320_slim_config(..., nch)`:**
  - `ch_count = n`;
  - `chs = {144, 145}`;
  - `port_mask = BIT(16) | BIT(17)`;
  - `slim_chs[2]`.
- **The NGD needs no change.** `qcom_slim_ngd_enable_stream()` already
  packs every port of the runtime into one `DEF_ACT_CHAN`.
- **The codec DAI:**
  - `channels_min = 1`, `channels_max = 2`;
  - `hw_params` programs as many ports as `params_channels()` (1 or 2);
  - `get_channel_map` reports `{144, 145}`.
- **The card's BE fixup pins 2 channels.**
  - The relay to the AFE (`q6slim_set_channel_map`) already passes whatever
    the codec reports.
  - The FE stays free (1 or 2 channels), and the ADSP's matrix maps a mono
    FE onto both.

**The r150s single-port delta (`0x040: 00->05, 0x180: 00->01`) is a 1-channel
fact.** It stays true for the research hooks. The BE now always opens 2 ports.

## 3. DAPM (`stereo-vol-jack-rc1`)

**Every stage is now a `SUPPLY_S`, subsequences 0 to 8,** feeding one NOPM
PGA `HPH` with no event:

| subseq / stage | widget | proven function |
|---|---|---|
| 0 | `MCLK` | `wcd9320_mclk_get` / `_put` |
| 1 | `CLASS_H PREP` | `wcd9320_pa_prep` |
| 2 | `CDC PREREQ` | `wcd9320_cdc_clk_prereq` |
| 3 | `RX1 CHAIN` | `wcd9320_rx_digital_path(0)` |
| 4 | `RX2 CHAIN` | `wcd9320_rx_digital_path(1)` |
| 5 | `HPHL DAC` | `wcd9320_hphl_dac_path(reggain)` |
| 6 | `HPHR DAC` | `wcd9320_hphr_dac_path` |
| 7 | `HPHL PA` | `wcd9320_hphl_pa_path` |
| 8 | `HPHR PA` | `wcd9320_hphr_pa_path` |

**Why all supplies.** Two `PGA_E` widgets for the PAs would have no defined
order between them, because `dapm_seq_compare()` falls through to list
order. Subsequences give one ordering mechanism for all nine:
- ascending on the way up: L before R at each level;
- descending on the way down: R before L.

**Routes:** `AIF1 PB -> HPH -> HEADPHONE`, with all nine supplies on `HPH`.

The ownership chain, idle check, abort and power-down rules are r184's,
unchanged. The full mask is `1ff`, and `dapm_state` prints `held=%03x`.
`wcd9320_dapm_idle()` adds `rx2_digital_on`, `hphr_dac_on`, `hphr_pa_on` and
`clsh_r_on`.

**Forced budget per stereo stream: 6.**
- 0x314 set;
- 0x30d bit 1 set, bit 2 set, bit 2 clear, bit 1 clear;
- 0x314 clear.

The log ring grows from 16 to 64 entries. 16 was a recording limit, not a
hardware one. It was binding on every boot, and a stereo test day needs
about 40.

## 4. Volume controls

All four are `SOC_SINGLE_EXT` controls on the codec component. Each one:
- has a custom get/put;
- takes `c3_lock`;
- writes through `c2b_write` (chip-verified).

They are not register-backed, because the prep restores `0x1ae` and `0x1b4`
to their measured baseline (`00`, the maximum) when idle. A register-backed
control would read "maximum" whenever nothing plays.

| control | range | maps to | default |
|---|---|---|---|
| `HPHL Volume` | 0..20 | field = 20 - v (inverted control) | 0 (field `0x14`, minimum) |
| `HPHR Volume` | 0..20 | the same, `pa_gain_field_r` | 0 |
| `RX1 Digital Volume` | 0..84 | `0x2b7` = (s8)(v - 84), 1 dB per step, TLV -84..0 dB | 84 (0 dB, the chip's reset value) |
| `RX2 Digital Volume` | 0..84 | `0x2bf`, the same | 84 |

- **Analog put.**
  - It sets the field.
  - If the prep is live, it also writes the field on the chip, so a running
    stream changes level, as downstream's register-backed control does.
  - The DAC path's chip check reads the same field, so the two cannot
    disagree.
  - The research `hphl_pa_gain` attribute keeps its own rule: it refuses
    while the path is live.
- **The analog controls have no TLV.** Downstream's `line_gain` TLV (0 dB,
  0.07 dB step) is not a real scale, and the step size of this field has
  not been measured here. The listen run measures it (section 7).
- **Digital is capped at 0 dB,** so it only cuts. Downstream allows +40 dB.
  The cap is the operator's decision.

## 5. Jack detection

**What is proven** (`wcd9320-irq-proven`, rc6):
- `0x14a <- 6f` (base `6c`, `DET_INS`, `DET_EN`) arms insertion;
- `MBHC_JACK_SWITCH` (source 26) fires on insertion;
- `0x14b` bit 2 is the level: 1 = removed, 0 = inserted.

**Never run:** removal.

**Downstream** (`wcd9xxx_swch_irq_handler` plus `insert_detect_setup`):
1. debounce 5 ms;
2. read the level, `!(0x14b & BIT(2))` = inserted;
3. report;
4. re-arm the opposite polarity: `6c | (ins ? 2 : 0)`, written as EN off,
   value, then EN on.

`wcd9xxx_jack_report()` also updates `COND_HPH`, which r185 does not take
(1c).

**r185:**
- **The component gains `.set_jack`.** The card creates `Headphone Jack`
  (`SND_JACK_HEADPHONE`, pin `Headphones`) and passes it in `late_probe`,
  after it disables the pin.
- **Enable:**
  1. read `0x14b`;
  2. arm the polarity that waits for the *other* state;
  3. request the `MBHC_JACK_SWITCH` virq (threaded, one-shot);
  4. report the current state.

  So a jack already in at boot turns the pin on. This differs from
  downstream's codec-insert-detect path, which only arms insertion; their
  GPIO path does read the level at boot.
- **The handler:**
  1. `usleep(5 ms)`;
  2. under `wake_lock`: read the level, and re-arm the opposite polarity
     with downstream's three writes, reusing `wcd9320_insert_detect_set()`
     with a polarity argument;
  3. drop the lock, then `snd_soc_jack_report()`.

  The report takes the DAPM mutex, which takes `c3_lock` in the events.
  That order is never reversed.
- **Headphone only.** There is no headset typing, no mic and no buttons.
  `SND_JACK_HEADPHONE` and nothing else.
- **`jack_detect` attribute (on/off), for research runs.**
  - **off:** free the irq, set `0x14a` back to `00`, and report removal, so
    the pin goes off.
  - **on:** re-arm and report the real state.
  - **Why runs need it off:** the voltmeter and zdet require insert
    detection off and the certified interrupt masks. Jack detection breaks
    both, so they refuse.
  - **Which runners turn it off:** the research runners (C3a, vm, zdet,
    mclk-own) do it as their first write. The DAPM gates leave it on.
- **`mbhc_test` and `mbhc_detect` refuse while jack detection is on,** and
  vice versa. They share `0x14a` and the source.

## 6. The safety model, r185

**The bounds:**

| r184 bound | r185 |
|---|---|
| pin off at boot, operator turns it on | pin follows the jack. Nothing plays to an empty jack; a plugged jack is a headphone, which is the point. Manual override and Volume Down remain. |
| gain at minimum, no control | the gain still boots at minimum on both channels; the controls let the operator raise it. Digital can only cut. |
| electrical contract measured (HPHL) | HPHR measured the same way before any stereo acoustic run (section 7, step 4) |
| HPHL only | HPHL + HPHR, each PA bit written only in its own function, HPHR only while HPHL is on |

**PA write sites.** There are exactly six:
- `hphl_pa_path`: 2, masked HPHL;
- `hphr_pa_path`: 2, masked HPHR;
- the zdet static PA: 2, masked both.

**The guard.** Its allowed states are `{00, 20, 30}`, and `30` is legal only
from the HPHR PA path and the zdet. It still compares for equality.

## 7. Gates and order of work

Fences first, then driver and card, then the selftests, then the gates.

**Fences:**
- 5d becomes six PA sites, with HPHR confined to `wcd9320_hphr_pa_path`.
- 5i is the nine-stage table.
- 5j is new, covering:
  - the RX2 table;
  - the two HPHR functions;
  - the class-H join and leave;
  - stereo ports;
  - controls;
  - jack.

**Tools:**
- `pcm-tone` gains `--channels 2 --side L|R|B`.
- The C3a runner gains `C3A_STEREO=1` and `C3A_VM_CH=r`.
- The DAPM gates are stereo-aware.
- `tools/wcd9320-jack-evidence.sh` is new.

**Hardware, one fresh boot of r185:**
1. **Jack gate, no stream.** Unplug, then plug, prompted:
   - the jack control and the pin follow;
   - the JACK_SWITCH count rises by 1 each time;
   - `0x14a` alternates `6d` / `6f`;
   - `held=000` throughout, `mclk_users` 0.
2. **Digital gate, pin off** (jack detection on, pin forced off): a stereo
   stream powers nothing.
3. **Regressions, jack detection off:** mclk-own, vm, zdet. The zdet
   supplies the HPHR scale, 50 mV / (R2 - R0).
4. **HPHR DC:** C3a `onchip`, `C3A_STEREO=1`, `C3A_VM_CH=r`, 2 cycles,
   compared against the zdet R scale.
   - |Von - Voff| <= 50 mV;
   - drift <= 10 mV;
   - hard abort at the existing count limit.
5. **Stereo listen** (jack on, chat approval per stream):
   - L-only tone, mic on the left cup;
   - R-only tone, mic on the right cup;
   - R again with `HPHR Volume` 4 steps lower;
   - R with `RX2 Digital Volume` at -6 dB.

   The analyser's level delta measures the analog step and confirms the
   digital step.

**Forced budget for that boot:**

| step | forced writes |
|---|---|
| vm characterisation | 4 |
| HPHR DC, 2 cycles | 12 |
| listen, 4 streams | 24 |
| **total** | **40 of 64** |

## 8. Not in r185

- No headset mic, buttons or headset typing, and no `COND_HPH`.
- No compander or class-H mode controls; the register-gain mode stays fixed.
- No TLV on the analog volume until the step is measured.
- No ANC, IIR, EAR, line-out or speaker paths.

## 9. As built (r185 `stereo-vol-jack-rc1`, card `q6-card-rc5`, pkgrel 185), staged 2026-11-08

**Sources:**
- Driver: `~/corepatch/new/drivers/slimbus/wcd9320-core.c`, 11024 -> 12108
  lines.
- Card: `~/q6card/new/sound/soc/qcom/lumia1520-q6.c`.
- Both compile clean at `W=1` in a private 6.16.12 tree, with no warnings.
  That tree is `~/r185chk` (`scratchpad r185cc.sh`; flex and bison were
  unpacked from the Ubuntu archive without root).

**Deviations from sections 1 to 5, found while building:**

1. **`wcd9320_rx1_write()` is gone.** Its only caller was the RX1 path,
   which now goes through `wcd9320_rx_write(ch)`. The compander code never
   called it, despite an old comment saying so.
2. **The HPHR DAC refuses while either PA is on,** instead of tripping the
   latching guard. The HPHR DAC comes up before any PA, in DAPM and in the C3a
   runner alike.
3. **The voltmeter's HPHR reading is a verb, not a mode.** `measure-r` and
   `window-r` set `vm_right`. The `hphl_vm` show line gains `ch=l|r`.
4. **`jack_detect` reports removal when turned off,** so the pin goes off
   with it.

**Fences:**
- 5d now has six PA sites (HPHR confined to `hphr_pa_path`, which refuses
  without HPHL), allowed guard states `{00, 20, 30}`, and POST_PA in one
  helper called once per PA path.
- 5f gains the HPHR mux and the `-r` verbs.
- 5i is the nine-stage table, the event-less `HPH` PGA, the four controls,
  `set_jack`, the card's jack pin and the 2-channel BE.
- 5j is new (RX table, HPHR DAC order both ways, class-H join/leave, prep
  rows, ports, volume caps, jack locking).
- The read-bypassed relocation expectation is 116 (109 + 7).
- **A checker defect fixed on the way:** `func_body()` matched forward
  declarations. The two new ones for the HPHR paths made it read the wrong
  bodies until it skipped declarations.
- **Results:** 440 source checks PASS. The 5 failures are artefact-only and
  expected against the old r184 `.ko`. Mutation test 21/21 caught.

**Tools:**
- `pcm-tone --side L|R|B` (mono stays the default; the audit pins
  `TONE_CHANNELS_STEREO 2`, selftest 22 cases, 0 wrong).
- DAPM expectations for r185 (`1ff`, `000`, nine stages, `DAPM_PA_LIVE 30`,
  six forced writes per stream, listen specs).
- The digital gate is stereo and forces the pin off first.
- The listen runner plays the four-stream plan of section 7 step 5 and puts
  every volume back to its boot value at the end.
- C3a gained `C3A_STEREO=1` and `C3A_VM_CH=r`, and turns jack detection off
  on an armed run.
- vm, zdet and mclk-own call `jack_quiesce`.
- The new `wcd9320-jack-evidence.sh`.
- `wcd9320-dapm-selftest.sh` passes 70/0.

**Build** (operator, sudo), from the repository in WSL:

```
tools/build-wcd9320-kernel.sh --pkgrel 185 --version stereo-vol-jack-rc1 \
    --expect-asoc --expect-dais 1 --stage ~/r185 \
    --extra-module sound/soc/qcom/qdsp6/q6core.ko \
    --extra-module sound/soc/qcom/qdsp6/q6inventory_probe.ko \
    --extra-module sound/soc/qcom/snd-soc-lumia1520-q6.ko
tools/build-c3a-helpers.sh --stage ~/r185 --force
```

The second command rebuilds `pcm-tone` (and `input-gate`, unchanged) for
`--side`.

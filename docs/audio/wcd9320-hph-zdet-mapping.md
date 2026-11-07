# The HPH channel's scale, from downstream impedance detection (r179 design)

**Status:** MAPPED, nothing written.

- **Purpose:** turn option 1's on-chip DC result, a repeatable PA-on shift
  of +59.6 HPH-channel counts (`wcd9320-hphl-dc-vm-mapping.md` §10c),
  into millivolts, and so pass or fail the §22 DC contract.
- **Research:** `wcd9320-mbhc-voltmeter-research.md`, addendum.
- **Operator decision, 2026-11-07: faithful, both channels.** The HPHR PA
  is permitted inside this one measurement and nowhere else.

Sources, cached:

- `mbhc/nemo310-wcd9xxx-mbhc.c`: `wcd9xxx_detect_impedance()`.
- `gen3-wcd9320.c`, all Taiko's own:
  - `taiko_setup_zdet()`
  - `taiko_compute_impedance()`
  - `wcd9xxx_prepare_static_pa()`
  - `wcd9xxx_enable_static_pa()`
  - `TAIKO_WG_TIME_FACTOR_US = 240`

## 1. What it measures

Six raw STA readings, in downstream's order:

| # | mux | name | meaning |
|---|---|---|---|
| 0 | `MUX_2 = F0` | L0 | HPHL, static PA on, output at rest |
| 1 | `MUX_1 = A0` | R0 | HPHR, the same |
| 2 | `MUX_2 = F8` | R1 | HPHR with ical injected |
| 3 | `MUX_1 = C0` | L1 | HPHL with ical injected |
| — | PA ramp up to the "50 mV" height | | |
| 4 | `MUX_2 = F0` | L2 | HPHL, ramp held |
| 5 | `MUX_1 = A0` | R2 | HPHR, ramp held |

Computed:

- **Impedance, Taiko's formula:**
  `Z = (L0 - L1) * 1000 / (L0 - L2) * 11333 * 364 >> 16 * 3855 >> 16` mΩ,
  about 3.7 Ω per unit of ratio, the same for R. **This is the
  cross-check:** a plausible headset (about 16-64 Ω on both channels)
  says the chain was reproduced correctly.
- **The scale:** `50 mV / (L2 - L0)` mV per count at **navg 16**.

### The navg problem, and the two extra passive readings

`taiko_setup_zdet()` sets `CDC_MBHC_TIMER_B5 = 0x10`, so navg is 16.
Option 1's counts were taken at navg 4. If STA is a sum rather than a
mean, the scale does not transfer. The voltmeter map (§3 there) avoided
the question by design, and it cannot be avoided here.

So the measurement adds **two passive readings at navg 4**, mux `F0`, no
ical:

- **L0'**, at the end of phase 1, with the static PA at rest
- **L2'**, at the end of phase 2, with the ramp still held

That gives `scale4 = 50 mV / (L2' - L0')` directly, in the units option 1
used, and comparing `L2 - L0` with `L2' - L0'` answers the sum-or-mean
question as a by-product. Both are reads only; nothing they do reaches
the headphone.

## 2. Preconditions, refused rather than supplied

| | |
|---|---|
| codec on MCLK | `wcd9xxx_detect_impedance()` turns the external MCLK on around zdet; r178's voltmeter requires it too |
| **the whole analog path idle:** PA off (`0x1ab & 0x30 == 00`), no C3a prep, DAC, RX1, compander, class-H, or forced `0x314` outstanding | downstream runs zdet at headset insertion, from idle. The static-PA list rewrites class-H, buck, NCP and both DACs wholesale, and must not land on a live C3a state |
| insert detect off; certified interrupt masks | as for the voltmeter |
| `c3_lock` | serialised with every PA/DAC sequence |

**The headset load is not checked.** It cannot be without arming insert
detection. With no load, L0 − L1 is large and Z reads very high. The
result is then reported as "no load, scale not trusted", which is safe
either way.

## 3. The sequence (one atomic operation)

```
Z0  preconditions; PA guard expects 00
Z1  snapshot, bypassed: every register below (section 4), plus the FIR bank
Z2  the MBHC engine, exactly as r178 S2 (def_taiko_mbhc_cal, 9.6 MHz)
Z3  MAD_ANA_CTRL bit 4 <- 0; CDC_MBHC_B1_CTL bit 2 <- 1 (override)
Z4  wcd9xxx_prepare_static_pa(), the 25 writes in downstream's order:
      RX_HPH_OCP_CTL     0x1aa  m18 <- 00     RX_HPH_L_TEST   0x1af m01 <- 00
      RX_HPH_R_TEST      0x1b5  m01 <- 00     BIAS_WG_OCP     0x1a9     <- 1A
      CNP_WG_CTL         0x1ac      <- DB     CNP_WG_TIME     0x1ad     <- 15
      CDC_RX1_B6         0x2b5      <- 81     CDC_CLK_RX_B1   0x30f m01 <- 01
      HPH_CHOP_CTL       0x1a5      <- A4     HPH_L_GAIN      0x1ae     <- 2C
      CDC_RX2_B6         0x2bd      <- 81     CDC_CLK_RX_B1   0x30f m02 <- 02
      HPH_R_GAIN         0x1b4      <- 2C     NCP_CLK         0x193     <- FC
      BUCK_CTRL_CCL_3    0x18b      <- 60     RX_COM_BIAS     0x1a2     <- 80
      BUCK_MODE_3        0x183      <- C6     BUCK_MODE_4     0x184     <- E6
      BUCK_MODE_5        0x185      <- 02     BUCK_MODE_1     0x181     <- A1
      NCP_EN             0x192      <- FF     BUCK_MODE_5     0x185     <- 7B
      CDC_CLSH_B1        0x320      <- E6     HPH_L_DAC_CTL   0x1b1     <- C0
      HPH_R_DAC_CTL      0x1b7      <- C0
    The DAC is powered with neither 0x314 nor 0x30d written. That is
    downstream's static PA, copied, not adjusted.
Z5  wcd9xxx_enable_static_pa(true): RX_HPH_CNP_EN 0x1ab mask 30 <- 30,
    then wait CNP_WG_TIME * 240 us = 0x15 * 240 = 5040 us
    PA guard now expects 30
Z6  taiko_setup_zdet PRE_MEAS, the rest:
      PA_RAMP_B1 0x361 <- 1C, 1F, 03      reset, connect, release
      PA_RAMP_B3 0x363 <- 36              FS_48K, L shift 1, 24 samples
      PA_RAMP_B4 0x364 <- C0              the "50 mV" height
      MUX_1 <- C0; MUX_2 <- F0; TX_7_MBHC_TEST_CTL <- 78; TX_7_MBHC_EN <- 8C
      TIMER_B4 m40 <- 40; TIMER_B5 <- 10  navg 16
      CLK_CTL <- 0A; EN_CTL <- 02; CLK_CTL <- 02
      MBHC_HPH m B3 <- 80
Z7  phase 1: for each of L0, R0, R1, L1: the mux write, MUX_1 |= 80,
    wait 25 us, STA (t_sta at navg 16 = 128000*17/9600 + 250 = 477 us)
Z7' L0' : TIMER_B5 <- 04, MUX_2 <- F0, MUX_1 <- C0|80, 25 us, STA (316 us);
          TIMER_B5 <- 10
Z8  POST_MEAS: PA_RAMP_B2 0x362 <- 05; wait 18 ms; <- 00; wait 18 ms
Z9  phase 2: L2, R2 as in phase 1
Z9' L2' : as Z7'
Z10 PA_DISABLE: PA_RAMP_B2 <- 0A (ramp both back to zero); wait 18 ms;
    <- 00; PA_RAMP_B1 <- 00; then CNP_EN mask 30 <- 00, wait 5040 us.
    PA guard expects 00, chip-verified, BEFORE anything else is restored
Z11 restore every Z1 register in reverse, each read back from the chip;
    override and MAD_ANA_CTRL with them
Z12 PA guard expects 00; publish
```

**On any failure from Z5 onwards the error path is Z10 then Z11**: ramp
down, PAs off, then restore. The PAs are never left on.

## 4. The write set, closed (for the fence)

The r178 voltmeter's 20-register set plus FIR data port, and:

```
0x1aa 0x1af 0x1b5 0x1a9 0x1ac 0x1ad 0x2b5 0x30f 0x1a5 0x1ae 0x2bd
0x1b4 0x193 0x18b 0x1a2 0x183 0x184 0x185 0x181 0x192 0x320 0x1b1
0x1b7 0x361 0x362 0x363 0x364                                  (static PA, ramp)
0x1ab                                   (the PA: see section 5)
```

Live values this boot, all to be snapshotted rather than assumed:

```
1aa=69 1af=00 1b5=00 1a9=2a 1ac=da 1ad=15 2b5=80 30f=00 1a5=a4 1ae=00
2bd=80 1b4=00 193=94 18b=60 1a2=00 183=ce 184=ff 185=00 181=25 192=fe
320=a6 1b1=00 1b7=00 1ab=80 361-364=00
```

**Never written by r179:** `0x314`, `0x30d`, `0x14a`, `INTR_MASK*`.

## 5. The PA fence, relaxed for this measurement only

Today (§5d of the artefact gate):

- exactly two `0x1ab` write sites, both masked HPHL, in `wcd9320_hphl_pa_path()`
- `WCD9320_HPH_PA_MASK` (0x30) is never a write mask
- `WCD9320_HPH_PA_HPHR` is named by nothing
- the only non-zero guard expectation is HPHL

r179 changes, each one fenced:

| rule | becomes |
|---|---|
| 0x1ab write sites | **four**: the two HPHL ones in `wcd9320_hphl_pa_path()` (unchanged), **plus exactly two in `wcd9320_zdet_static_pa()`**, masked `WCD9320_HPH_PA_MASK`, values `WCD9320_HPH_PA_MASK` and `0` |
| 0x30 as a write mask | permitted **only** inside `wcd9320_zdet_static_pa()` |
| guard expectation 0x30 | permitted **only** inside `wcd9320_hphl_zdet()` |
| `WCD9320_HPH_PA_HPHR` | still named by no write |
| zdet entry | refuses unless the PA is off and the whole analog path idle (section 2) |

`wcd9320_zdet_static_pa()` must be called only from `wcd9320_hphl_zdet()`.

## 6. The stimulus, stated

- Both earcups receive the static PA bias and a ramp to about 50 mV,
  held for about 36 ms and ramped back down. That is what downstream
  does on every headset insertion.
- ical is a small injected current through the load. Its value is folded
  into Taiko's constants and not published.
- No audio content and no PCM stream are involved.
- OCP: the static-PA list clears `RX_HPH_OCP_CTL` bits 4:3, as downstream
  does. The snapshot restores them.

## 7. Characterisation (r179 gate, headset plugged in, no listening)

1. **Refusals:** on RCO; with the C3a prep or DAC up; with the PA on.
   Each must refuse and write nothing.
2. **Repeatability:** zdet five times. Spread of L0..R2, of Zl/Zr, and of
   the scale.
3. **The cross-check:** Zl and Zr plausible for a headset (16-64 Ω) and
   within 10 % of each other. **That is graded.** Implausible means the
   chain was not reproduced, and the scale is not used.
4. **Sum or mean:** `(L2 - L0) / (L2' - L0')`, about 4 if STA sums, about
   1 if it averages.
5. **Restore:** the full write set identical before and after, `0x1ab`
   back to `80`.
6. **The answer:** option 1's +59.6 counts times scale4, in mV, against
   §22's 50 mV, printed with the cross-check result beside it.

A pass on 3 and a converted shift within 50 mV would close the §22
contract, qualified as on-chip.

## 8. r179 AS BUILT (`zdet-rc1`, pkgrel 179)

- **Order of work:** fence first this time.
  - The section 5d changes and the new section 5g were written before any
    driver code and proven to fail r178 in 48 places (43 in 5g, 5 in 5d).
  - One naming conflict surfaced and was settled in the fence's favour:
    5f forbids any `WCD9320_VM_*` constant at `0xf8`, so the ical mux
    constants are `WCD9320_ZDET_*`.
- **Driver:** `hphl_zdet` (RW), verb `measure`. `wcd9320_hphl_zdet()` is
  Z0-Z12.
  - `wcd9320_zdet_wr()` refuses `0x1ab` and anything outside the voltmeter
    set plus the zdet set.
  - The PA is written only by `wcd9320_zdet_static_pa()`: two
    chip-verified C2b writes, mask `0x30`.
  - Errors before the static PA go straight to the restore. Errors after
    it go through the teardown first: ramp back to zero, both PAs off,
    then the restore.
- **Shared with the voltmeter:** the MBHC engine setup is now one function,
  `wcd9320_vm_engine()`, used by both. `wcd9320_vm_sta()` takes its
  `t_sta` as a parameter (316 µs at navg 4, 477 µs at navg 16).
- **show** publishes the raw L0-L2, R0-R2, L0', L2'; Taiko Zl and Zr in
  mΩ; and the scale in µV per count at navg 16 and at navg 4.
- **`read_bypassed_calls`:** 93 to 97 (snapshot and restore of each of the
  zdet's two tables).
- **Gate:** `tools/wcd9320-hphl-zdet-evidence.sh`, section 7 steps 1-6.

## 9. RESULT (2026-11-07): THE DC CONTRACT IS WITHIN, ON-CHIP. Gate 30/4, one side effect

- **Evidence:** `wcd9320-hphl-zdet-20260831T191642Z.txt`, a fresh boot of
  `zdet-rc1`, headset plugged in.
- **The PA:** chip-verified `b0` (both channels) inside every zdet, `80`
  after every one, and `00` (masked) at every sample outside it. No
  forced writes.

| | result |
|---|---|
| refusals | on RCO, and with the C3a prep up: both refused, nothing written |
| **Zl / Zr** | **51.4 Ω / 56.0 Ω**, spread 0.5 / 0.4 Ω over five runs, L and R within 8.4 % |
| **cross-check** | **PASS**: a plausible headset, consistent on both channels |
| L0..R2 | repeatable to ±4 counts at navg 16 |
| **sum or mean** | `(L2-L0)/(L2'-L0')` = **4.007**: **STA is a SUM** of navg samples |
| **scale, navg 4** | **244 µV per count** (spread 5), 60 µV at navg 16 |

**The answer:**

- Option 1's PA-on shift of +59.6 counts at navg 4, times 244 µV per
  count, is **14.5 mV. The contract allows 50 mV: WITHIN.**
- Option 1's drift of at most 6 counts per 250 ms is **≤ 1.5 mV, inside
  the 10 mV limit.**
- `|Voff| ≤ 100 mV` is met by the physics, not by a reading. With the
  headphone as the load and the PA off, the node is held at 0 V, and the
  HPH channel has no absolute zero of its own (§10b of the voltmeter map).
  That clause is the one part of §22 stated by argument rather than
  measurement.

**The micbias scale was about 4.75 times too coarse for this input.** The
"≈ 69 mV, over the limit" reading from option 1 was an artefact of that
assumption, which is why it was never taken as a verdict.

**The four failures are ONE hardware side effect, not a restore defect:**

- **What happened:** run 1 left `CDC_RX1_B6_CTL` (`0x2b5`) and
  `CDC_RX2_B6_CTL` (`0x2bd`) reading `88` where the snapshot read `80`.
  Writing `80` back does not clear bit 3.
- **Why the other runs passed:** runs 2-5 snapshotted `88` and restored
  `88`, so they restore cleanly. The two write-set comparisons that span
  run 1 show the same two registers.
- **Not new:** this project has seen `0x2b5 = 88` before. HANDOFF records
  "`0x2b5` moved `hw=88 -> a8`" from the r165 era. So bit 3 is a state the
  silicon sets itself (most likely when the RX interpolator or the PA
  ramp path first runs) and does not clear on write. It belongs with
  `0x1fd` as hardware-populated.
- **Downstream:** it restores these registers the same way and never
  reads them back, so it would leave the same bit set without noticing.
- **Open:**
  - classify the bit properly (volatile-or-not) before the regcache
    tables next change
  - confirm the C3a path still plays with it set, which r165-era runs
    suggest

### 9a. The side effect, classified (rxb6 trace, 2026-11-07) and fixed in r180

Evidence: `wcd9320-rxb6-trace-20260831T192546Z.txt`, a fresh boot of
`zdet-rc1`, with `cache_check` taken after each step.

| step | cache | chip | mismatches |
|---|---|---|---|
| idle, MCLK, the voltmeter | `80` | `80` | 0 |
| **RX1 chain on** | `a0` | **`a8`** | **1** (0x2b5) |
| RX1 chain off | `80` | **`88`** | 1 |
| a stream, chain on and off | same | same | 1 |
| one zdet | 0x2bd `80` | **`88`** | 1 (0x2bd) |

**Bit 3 of CDC_RX1/RX2_B6_CTL is a sticky status the chip sets when that
RX chain runs.** Enabling the chain bit (bit 5) sets it, disabling does not
clear it, and neither does writing 0. RX1 is set by the C3a chain, RX2 by
the zdet's static PA.

So:

- It has been set in **every** C3a run since r161, including the
  heard-sound run. Playback with it set is therefore already proven, and
  no separate check is needed.
- **The regcache certification never saw it** (it was certified at idle),
  so every RX run left the cache stale on 0x2b5.
- `rx1_digital_state` and the RX1 write's readback both read the cache:
  they reported `a0`/`80` while the chip held `a8`/`88`. The trace
  table's "chip" column above is that cached view. `cache_check` is the
  true one.

**r180 (`rxb6-rc1`):**

- **Cache tables:** `0x2b5` and `0x2bd` join `0x1fd` in the generator's
  `HW_POPULATED` (measured, never inferred) and are regenerated from the
  fullmap evidence. The diff against r179 is exactly two volatile bits and
  two removed defaults: volatile 401 to 403, defaults 460 to 458,
  `cache_check` 458 cacheable / 211 volatile. RX3-7 B6 stay cacheable:
  this driver never enables those chains, so it is unmeasured.
- **zdet restore:** the compare excuses `wcd9320_hw_owned_bits()`, which
  is only RX1/RX2_B6 bit 3 (pinned by the fence).
- **Every gate that hard-coded the old classification is updated:**
  - regcache, adoption-cache, asoc-callback, asoc-component and rx-dai:
    the counts
  - rx1-digital and comp1-observable: the chain is checked as bit 5, not
    an exact `a0`/`80`

### 9b. r180 regression, and the second stale-cache register (r181)

On a fresh boot of `rxb6-rc1`:

- **The voltmeter gate passed 57/0** (span ratio 0.665).
- **The zdet gate passed 34/0:** Zl 51.5 Ω, Zr 55.9 Ω, sum ratio 3.99,
  PA-on DC **14.5 mV, WITHIN**. The RX_B6 side effect is gone.
- **The rxb6 trace:** cache and chip now agree on `0x2b5`/`0x2bd` through
  RX1 on/off, a stream and a zdet. The RX1 write's own readback now shows
  the real `a8`/`88`.

The `cache_check` after the gates still showed **2 mismatches**, the first
`0x328` (cache `00`, chip `08`).

- **What it is:** `CDC_CLSH_K_ADDR`, the class-H K-table **index, which
  auto-increments** as the eight K entries are pushed through `K_DATA`
  (`0x329`). The voltmeter gate's DAC-path step ran class-H on that boot.
  The idle-time regcache certification never ran class-H.
- **The second mismatch** is almost certainly `K_DATA` itself:
  `cache_check` names only the first. A data port returns the indexed
  entry, not the last value written. `taiko_volatile()` covers the IIR
  and ANC coefficient ports for exactly that reason, and misses this one.
- **One process failure, recorded:** the first trace run was a 0-byte
  script. It was copied into place without a `sync` and then the phone
  was hard-power-cycled. The gates themselves were verified intact by
  sha256.

**r181 (`clshk-rc1`):**

- **Cache tables:** `0x328` joins `HW_POPULATED` (measured) and `0x329`
  joins `SEMANTIC_VOLATILE` (the data port), regenerated. The diff is two
  volatile bits and two defaults: volatile 405, defaults 456, zero
  defaults 229, `cache_check` 456 / 213.
- **Gates:** the five count checks are updated again.
- **Trace:** gains a C3a DAC-path step, so class-H is exercised under
  `cache_check`.

**Tag consequence:** the §22 contract is now measured and within, on-chip:
14.5 mV against 50, drift 1.5 mV against 10, both cross-checked. That
meets the bar §10 of the voltmeter map set for
`wcd9320-hphl-electrical-proven`, qualified as on-chip. **It is not
awarded here.** The gate's verdict is FAIL on the side effect above, and
the tag is the operator's call.

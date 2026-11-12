# r191: the loudspeaker amplifier, "VISA", on I2C5 (design map)

**Status:** mapping, 2026-11-10. Steps 1 and 2 (identify, then power) are
to be built.

## 0. Why

Every WCD9320 analog output was driven live on the chip up to -20 dBFS at
full gain, and none sounds:
- **SPK_OUT and EAR** (r187);
- **SPK_OUT with VDD_SPKDRV at 5 V** (r190);
- **LINEOUT1-4** (r188);
- **LINEOUT1-4 with the 5 V rail held up** (r190, `HOLD_5V=i2s`).

Secondary MI2S was silent on both data lines (r189). The headphones work.

The loudspeaker is behind a part that nothing has ever switched on. It is in
the ACPI tables, but under its own device, not under the audio node.

**Sources:**
- **[DSDT]:** this phone's ACPI (analysis only).
- **[REG]:** its MainOS registry export (analysis only).
- **[VISA]:** `Windows\System32\drivers\Visa.sys`, copied from a
  **read-only** ntfs3 mount of `mmcblk0p27` (MainOS), unmounted
  immediately. Kept for analysis in `~/winaudio`, never committed.
  Disassembled with `arm-none-eabi-objdump -M force-thumb` (ARMNT, Thumb-2).
  Only the facts below are recorded here.
- **[KSRC]:** mainline 6.16.12: `qcom-msm8974.dtsi`, `pinctrl-msm8x74.c`,
  `qcom,gcc-msm8974.h`.
- **[LIVE]:** the running phone.

## 1. The device

**[DSDT]** `Device (VISA)`, `_HID "VISA"`, `_DEP` on PEP0 and I2C5:
- `I2cSerialBusV2 (0x0040, 400 kHz, "\\_SB.I2C5")`: 7-bit address `0x40`.
- `GpioIo` on `\\_SB.PM01`, pin `0x698`.

**The pin number:** in `BTN0`, `\\_SB.PM01` pins `0x610`/`0x618`/`0x620`
are shutter, focus and volume-up, which are PM8941 GPIO 3/4/5 (the
mainline DT). So pin = `0x5F8 + 8·n`, and `0x698` is **PM8941 GPIO20**.

**The bus:**
- Windows `I2Cn` = BLSP1 QUP *n*. Touch `TSC1` on `I2C2` @ `0x4B` is
  Linux's `1-004b` on `f9924000`, which confirms the mapping.
- So `I2C5` = **BLSP1 QUP5, `f9927000`**, interrupt SPI 99, clock
  `GCC_BLSP1_QUP5_I2C_APPS_CLK`.
- Its pins are TLMM 25/26, function `blsp_i2c5`. The PEP muxes 25 to
  function 4 and 26 to function 5, which are exactly `blsp_i2c5`
  [KSRC pinctrl].

**[KSRC]:** mainline's msm8974 dtsi has **no `f9927000` node**, so Linux has
never had this bus.

**[LIVE]:** PM8941 GPIO20 is an input, low, pulled down. The amplifier has
been held off on every Linux boot.

**[REG]:** `Nokia.Driver_Visa.MSM8974.reg`: service `Visa`, "Nokia Visa
Device", class System, no parameters. The R&D overrides
(`...\\Services\\Visa\\RnDFeatures`: `I2CRegisters_Dump`,
`I2CRegisters_WriteVerify`, `DefaultFixedGain`,
`I2COverride_PowerOnSequence`, and a `PowerOnSequence.txt` file) are absent,
so the defaults apply. **[VISA]** `.pdb` path `...\\output\\audio\\fre\\Visa.pdb`:
it is an audio driver.

## 2. The driver's protocol [VISA]

**A KMDF IOCTL device**, private device type `0xfde9`, functions `0x801` and
up, driven by another driver (the audio stack).

**On the first IOCTL:** GPIO20 ← 1 (`0x403898(dev, 1)`), once, tracked by a
flag.

**Power on** (IOCTL function `0x810` → `0x403168(state = 1)` →
`0x403c34`):
- It runs a byte-coded script from `.data` (va `0x406040`), 3 bytes per
  step:
  - `'w' (0x77) reg val` → a one-byte I2C register write (`0x4039a0`), read
    back and compared when WriteVerify is on;
  - `'d' (0x64) _ ms` → a delay of the third byte in **ms** (×10000, a
    relative 100 ns wait);
  - `'e' (0x65)` → end.
- The script, in order:

```
w 01 12   w 03 00   w 03 4d   w 05 00   w 07 c1   w 08 20
w 0b 8a   w 0c d0   w 0d a9   w 0e 38   w 0f 08   w 12 16
w 14 0c   w 21 02   w 21 01   w 21 04   w 21 07   w 21 00
w 20 06   w 01 10   w 02 78   d 50 ms   w 02 fe   w 20 00
w 00 00   e
```

**Power off** (`0x403168(state ≠ 1)`):
1. `0x403d38`: read reg `0x01`, OR `0x02`, write it back;
2. then, if the GPIO flag is set, GPIO20 ← 0 (`0x403898(dev, 0)`).

**Reset** (its own IOCTL → `0x4030d4` → `0x403bb4`): reg `0x01` ← `0x01`,
then reg `0x01` ← `0x10`.

**Other IOCTLs** (`0x402e9c`, `0x402f84`, `0x403224`, `0x403320`,
`0x403460`; `0x403dec` reads reg `0x12`):
- These are register access and gain. They are not needed for a first
  sound.
- Reg `0x12` = `0x16` comes from the script.

**Register `0x01`, as far as the code shows:**
- bit 0 = reset;
- bit 1 = shutdown/standby (set to power off; the script writes `0x12`
  first and `0x10` later, so it leaves standby late);
- bit 4 = set in every state written.

**The chip's identity is unknown** (7-bit `0x40`, registers `0x00` to
`0x21`). Step 2a reads it.

**Its input is unknown.** Windows' AUDD.PPNF switches the PM8941 5 V boost
together with the codec for endpoints `0x45`/`0x43`, so the amplifier
probably takes an analog codec output and may run from the boost. Which
output is unknown.

## 3. Plan

**Step 2a: identify (read-only on the chip).** DT:
- the I2C5 node (`qcom,i2c-qup-v2.1.1`, `f9927000`, SPI 99, the QUP5/AHB
  clocks, `blsp_i2c5` on TLMM 25/26);
- the amplifier node at `0x40` with `enable-gpios = <&pm8941_gpios 20
  GPIO_ACTIVE_HIGH>`.

Driver:
- **Probe:** GPIO low, no bus traffic.
- **`visa_identify`:**
  1. GPIO20 high;
  2. a settle;
  3. **read** regs `0x00` to `0x21`;
  4. GPIO20 low.

  No writes to the chip.
- **`visa_state`:** GPIO, powered, counters, the last dump.

**Step 2b: power (same build, used only after 2a):**
- **Power on:** GPIO high, then the script exactly, with read-back verify of
  every write.
- **Power off:** reg `0x01` |= `0x02`, then GPIO low.
- **Runner `AMP=visa`:** the amplifier powered around one codec-output
  stream, off after, and in every teardown and abort.
- **Probe each codec output with the amplifier on**, minimum gain first:
  LINEOUT (all four) and SPK_OUT, then EAR. Then 5 V held, if silent.

## 4. As built (r191 `visa-rc1`, card `q6-card-rc9`, pkgrel 191), staged 2026-11-10

**DT:**
- the `blsp1_i2c5` states (TLMM 25/26, `blsp_i2c5`);
- `blsp1_i2c5: i2c@f9927000` (SPI 99, QUP5/AHB clocks, 400 kHz);
- `visa_amp: speaker-amp@40` (`nokia,lumia1520-visa`, `enable-gpios =
  <&pm8941_gpios 20 GPIO_ACTIVE_HIGH>`).

The compiled DT resolves the GPIO to the PM8941 `gpio@c000` controller, pin
20.

**Card** (`q6-card-rc9`), the `lumia1520-visa` I2C driver:
- **Probe:** GPIO20 low, no bus traffic.
- **`visa_identify`:** GPIO20 high, 10 ms, **read** regs `0x00` to `0x21`,
  GPIO20 low.
- **`visa_power` 1:** GPIO20 high, 10 ms, then Windows' script with every
  write read back. A mismatch is recorded and an I2C error goes to standby.
- **`visa_power` 0:** reg `0x01` |= `0x02`, then GPIO20 low.
- **Remove and shutdown** power off.
- **`visa_state` and `visa_dump`** report the state and the last identify.

**The codec:** only the version string (`visa-rc1`) changed.

**Checks:**
- Verifier 5o: 22 checks.
- Pre-build, against r190's modules: 639 pass, 2 expected failures (the
  version and the built card).
- Mutation: 9/9 caught.

**Runners:**
- **The listen runner, `AMP=visa`** (with a codec output):
  - the amplifier is powered before the pin, after the gate and the
    fail-safe;
  - it must read `powered=1 gpio=1` with no new I2C errors, or the run
    aborts;
  - standby + GPIO low after the pin;
  - per-stream and per-run checks.
- **The preflight** refuses a powered amplifier.
- **`all_pa_off`** requires it off.
- **The teardown** powers it off on every abort.
- **Selftest:** 105/0.

**Order on hardware:**
1. identify (read-only);
2. then `AMP=visa` with LINEOUT, then SPK_OUT, then EAR;
3. minimum gain, -50 dBFS first.

## 5. Hardware (phone clock 2026-09-03/04; PC 2026-11-10): THE LOUDSPEAKER PLAYS

**Gates:**
- I2C5 came up as `i2c-7` (`f9927000`); `7-0040` bound with GPIO20 low.
- Digital gate 82/0, mclk-own 90/0, vm 57/0.

**Identify** (read-only): 34 of 34 registers read, with no I2C errors and
GPIO20 back low.
```
00:00 01:22 02:ef 03:80 04:00 05:00 06:00 07:c0 08:10 09:00 0a:00 0b:8f 0c:80
0d:be 0e:08 0f:04 10:00 11:01 12:00 13:40 14:00 15:00 16:08 17..21:00
```
Reg `0x01` boots `0x22`: the standby bit (`0x02`) that Visa.sys sets to
power off is set. The part is still unidentified.

**Power on** (`AMP=visa`), on every stream:
- 24 writes, no I2C errors.
- Exactly one read-back mismatch, the script's last write: reg `0x00` ←
  `0x00` reads back `0x20`. That looks like a status bit, consistent across
  runs.
- Standby and GPIO20 low after.

**The streams** (headset out, heater off, mic at the grille):

| run | path | dBFS | phone | mic | operator |
|---|---|---|---|---|---|
| 000026Z | LINEOUT ×4, vol 0, VISA on | -50 | 91/0 | 0 events | nothing |
| 000155Z s1 | LINEOUT ×4, vol 0, VISA on | -40 | 120/0 | 0 events | nothing |
| 000155Z s2 | LINEOUT ×4, vol 20, VISA on | -40 | (same run) | 0 events | nothing |
| **000827Z** | **Secondary MI2S DATA1 + VISA on** | **-50** | **78/0** | **PASS: 999.98 Hz, tone -49.2 / silence -89.6 dBFS, 40.5 dB contrast** | **HEARD** |

**Verdict:**
- **The loudspeaker is a digital-input (I2S) amplifier.** It is ACPI
  `VISA`: I2C5 @ `0x40` for control, PM8941 GPIO20 to enable it, and audio
  on the SoC's Secondary MI2S, data line 1 (TLMM 82).
- It needs all three at once:
  - GPIO20 high;
  - Windows' power-on script;
  - an I2S stream (1.536 MHz BCLK, 48 kHz, 16-bit, the CPU as clock
    master).
- r189 had the port right and the amplifier held off; r187 to r190 probed
  the codec, which is not on this path.
- Level: -50 dBFS digital gives -49 dBFS at the mic on the grille. The
  headphones at -40 dBFS gave about -54 dBFS at the earcup, so this is a
  loud output.

**Open, in order:**
- Integrate the amplifier into DAPM on the I2S path: power with the
  `Loudspeaker` pin and the stream, not from the runner.
- Is the 5 V rail needed? The I2S component held it up during the heard
  stream.
- Mono or stereo, and which slot.
- Volume: the amplifier's gain (reg `0x12`? `DefaultFixedGain`) versus
  digital.
- The earpiece: DATA0? the codec EAR? Windows' endpoint `0x4A` muxes DATA0
  alone.
- Remove the r187 to r190 diagnostic paths that the speaker does not use.

## 6. r192 (`spkamp-rc1`, card `q6-card-rc10`, pkgrel 192): the amplifier under DAPM, staged 2026-11-10

**The I2S component** (`nokia,lumia1520-i2s-spk`) now owns the VISA amplifier
through `nokia,visa = <&visa_amp>`:
- **Probe:** it resolves the phandle and defers until the I2C driver has
  bound, holding the device reference for the component's life.
- **The `SPK 5V` supply, up:** rail → pins → **VISA power-on** (Windows'
  script). A refused amplifier puts the pins to sleep and the rail off.
- **Down:** **VISA standby** → pins → rail.
- **Hand control:** `visa_power` is refused (`-EBUSY`) while DAPM holds the
  amplifier. `visa_state` reports `dapm_held`.

So playing to the `Loudspeaker` pin (`SEC_MI2S_RX Audio Mixer MultiMedia1`
on, `Loudspeaker Switch` on) is all it takes. Nothing outside the kernel
touches the amplifier.

**The codec:** only the version string changed.

**Checks:**
- Fences 5p: 7 checks.
- Pre-build: 646 pass, 2 expected failures.
- Mutation: 4/4 caught.

**Runners:**
- `AMP=visa` is refused with `OUTPUT=i2s`.
- i2s streams check `powered dapm_held gpio = 1 1 1` live and `0 0 0`
  after, and the VISA powers equal the streams.
- The digital gate's I2S tone (pin OFF) requires VISA off.
- Selftest 105/0.

## 7. r192 on hardware (phone clock 2026-09-04; PC 2026-11-10): plain playback plays the loudspeaker

**Gates:**
- Digital gate **83/0**, after the r192 runner fix (`26b6b3e`). That
  includes the VISA amplifier off during the I2S tone with the
  `Loudspeaker` pin OFF.
- mclk-own 90/0, vm 57/0.

**Stream `003145Z`:**
- `OUTPUT=i2s`, no `AMP`: the runner never touches the amplifier.
- `B:0:84` at -50 dBFS.
- **77/0.** VISA `powered dapm_held gpio` = `1 1 1` live and `0 0 0`
  after.
- **Analyser PASS:** 999.97 Hz, tone -49.0 / silence -85.3 to -90.0 dBFS,
  36.3 dB contrast.

**The kernel's order:**
1. `visa: POWERED ON (... 0 read-back mismatch(es))`;
2. `i2s-spk: 5 V rail on, sec_mi2s pins active, VISA amplifier powered`;
3. then `visa: standby, GPIO20 low`;
4. `i2s-spk: sec_mi2s pins asleep, 5 V rail off`.

**Reg `0x00`:**
- Under r191's runner (the amplifier powered before the stream, with no I2S
  clocks), the script's final `0x00` ← `0x00` read back `0x20`.
- Under DAPM (BCLK already running from the BE startup), it reads back
  `0x00`.
- So bit 5 of reg `0x00` is most likely a clock or input status flag, not
  a fault.

**Step 1 is done.** The loudspeaker is an ordinary DAPM output: route
MultiMedia1 to `SEC_MI2S_RX`, turn the `Loudspeaker` pin on, play.

**Next:** the 5 V question, volume, channels, the earpiece, and cleanup.

## 8. Step 2: the loudspeaker does not need the PM8941 5 V rail (phone clock 2026-09-04; PC 2026-11-11)

**The variant image:**
- The r192 image with **one byte** changed: the I2S component's
  `vdd-supply` goes `0x93` (`pm8941_5v`) → `0x00`, patched in place with
  `fdtput`.
- `cmp -l` shows the single byte.
- The live devicetree reads `00000000`.
- The regulator core gave the component its **dummy** ("supply vdd not
  found, using dummy regulator"; `vdd_uV=-22`).
- The real 5 V regulator (PM8941 s4) stayed **disabled, 0 users** at boot,
  during the stream and after.

**Results:**
- Digital gate 83/0.
- Stream `235214Z`, `OUTPUT=i2s RAIL5V=off B:0:84 -50 dBFS`: **77/0**.
  - VISA was DAPM-powered `1 1 1` live and `0 0 0` after.
  - The runner required the rail disabled live.
- **Analyser PASS:** 999.97 Hz, tone -49.8 / silence -87.6 dBFS, 37.7 dB
  contrast.

For comparison, with the rail (r192) it was tone -49.0 / 36.3 dB contrast:
the same within the measurement.

**Verdict:**
- The speaker amplifier does not run from the 5 V boost. It is presumably
  on VBAT/VPH; it is not in the PEP.
- The 5 V supply on the I2S path was r189's guess, and it only costs power.
- **Next build:** drop `vdd-supply` from the I2S node and make the
  component's regulator optional.
- Windows' PPNF ties the boost to codec endpoints `0x45`/`0x43`; what those
  endpoints are remains open.

## 9. Step 4: the amplifier is mono, on the LEFT I2S slot (phone clock 2026-09-05; PC 2026-11-11)

**The run:** the no-rail variant boot, `OUTPUT=i2s RAIL5V=off SPECS=L:0:84,R:0:84 DBFS=-50`.

| stream | the VISA amplifier | 1 kHz at the grille | neighbours | verdict |
|---|---|---|---|---|
| L only | DAPM-powered (`1 1 1`) | **-49.2 dBFS** | -92.6 dBFS | **plays**, 43 dB tonal |
| R only | DAPM-powered, 973.12 → 974.10 s in dmesg (the full stream, BCLK on 973.03 → off 974.09) | -66.9 dBFS at best | -71.5 dBFS | **silent**: a broadband blip; the window's 1 kHz median is -92.2 |

**The R stream's abort** (`visa=00`) was the runner, not the path:
- the amplifier sample sat after the slower reads, and landed after the 1 s
  tone had ended;
- the amplifier's own counters (2 powers on, 2 off) and dmesg show it was
  powered through the whole R stream.

Fixed: the amplifier is now sampled in the early path-up snapshot.

**Verdict:** the loudspeaker amplifier plays the left slot of the I2S frame.
It drops the right one.

**Next build:** downmix to mono instead of sending only the left channel:
- the speaker back end at 1 channel;
- the DSP matrix mixes (L+R) into it, or the AFE's mono mode, whichever
  the mapping supports.

## 10. Step 3: the amplifier is a TI TAS2552, and its volume is reg 0x12 (2026-11-11)

**The identity.** In r191's read-only dump, every power-on value equals
mainline's `tas2552_reg_defs`:

| register | name | value |
|---|---|---|
| `0x01` | CFG_1 | `22` |
| `0x02` | CFG_2 | `ef` |
| `0x03` | CFG_3 | `80` |
| `0x07` | OUTPUT_DATA | `c0` |
| `0x08` | PLL_CTRL_1 | `10` |
| `0x0b` | BTIP | `8f` |
| `0x0c` | BTS_CTRL | `80` |
| `0x0d` | — | `be` |
| `0x0e` | LIMIT_RATE_HYS | `08` |
| `0x0f` | LIMIT_RELEASE | `04` |
| `0x11` | PDM_CFG | `01` |
| `0x13` | EDGE_RATE | `40` |

Its address is `0x40`, and `0x16` (VER_NUM) reads `08`. **The part is a TI
TAS2552**, a mono class-D speaker amplifier with I2S input and an
integrated boost. Mainline has `sound/soc/codecs/tas2552.c` (`ti,tas2552`),
but it is not enabled in our config.

**Windows' script, decoded** with mainline's `tas2552.h`:

| step | write | meaning |
|---|---|---|
| 1 | `01 ← 12` | CFG_1: SWS (software shutdown) held |
| 2 | `03 ← 00`, then `03 ← 4d` | CFG_3: I2S_OUT_SEL, **DIN_SRC_SEL = LEFT** (bits 4:3 = 01), WCLK 44.1/48 kHz |
| 3 | `05 ← 00` | SER_CTRL_1: I2S, 16-bit, the chip as slave |
| 4 | `07 ← c1`, `08 ← 20` | OUTPUT_DATA, PLL_CTRL_1 |
| 5 | `0b ← 8a`, `0c ← d0`, `0d ← a9`, `0e ← 38`, `0f ← 08`, `14 ← 0c` | **Nokia's tuning** of the boost (BTIP, BTS, BOOST_APT) and the limiter (rate/hysteresis, release) |
| 6 | `12 ← 16` | **PGA gain +15 dB** |
| 7 | `21 ← 02, 01, 04, 07, 00`; `20 ← 06` … `20 ← 00` | test-page accesses (undocumented) |
| 8 | `01 ← 10` | SWS released |
| 9 | `02 ← 78`, then 50 ms, then `02 ← fe` | BOOST_EN + APT_EN + PLL_ENABLE first, the PLL settles, then CLASSD_EN |
| 10 | `00 ← 00` | the end of the script |

**Explained by the decode:**
- **Step 2 (no 5 V):** the TAS2552 makes its own boost.
- **Step 4 (left only):** Windows selects DIN = LEFT.
- **r191's `0x00` read-back** (`0x20` without clocks): DEVICE_STATUS, a status
  register.

**Volume** [Visa.sys]:
- Get (`0x403dec`) = `(reg 0x12 & 0x1f) - 7`; set (`0x403eec`) writes
  `reg 0x12 = gain + 7`.
- Mainline's `tas2552.c` agrees: "Speaker Driver Playback Volume" on
  `PGA_GAIN`, 5 bits, `DECLARE_TLV_DB_SCALE(-700, 100)`.
- That is **−7 to +24 dB in 1 dB steps**; Windows runs **+15 dB**.

**The choice: our driver plus additions, not mainline `tas2552` (for now).**
- Mainline's init enables boost and APT with its own defaults.
- It does not write Nokia's boost or limiter tuning, or the test-page
  writes. Those are this speaker's protection, and nothing verifies that
  they are optional.
- Keep replaying Windows' sequence exactly. Revisit mainline once each
  tuning register is understood.

**r193 adds:**
1. **No 5 V:** drop `vdd-supply` from the I2S node; the regulator becomes
   optional (step 2).
2. **Mono:** CFG_3 `0x4d` → **`0x5d`** (DIN_SRC_SEL = AVG_L_R, an (L+R)/2
   mix in the amplifier) instead of LEFT. This is a documented deviation
   from Windows that changes only the channel mix (step 4).
3. **Volume:** a "Loudspeaker Volume" control on PGA_GAIN, TLV −7..+**15**
   dB.
   - Capped at Windows' own +15 until the limiter tuning is understood, and
     defaulting to +15.
   - Applied after the script at every power-on, and written live (read
     back) while the amplifier is powered.

## 11. r193 (`spkvol-rc1`, card `q6-card-rc11`, pkgrel 193): no 5 V, a mono mix, the volume (staged 2026-11-11)

**What changed:**
- **DT:** the I2S node has no `vdd-supply`. The codec's `vdd-spkdrv` is
  unchanged.
- **The I2S component:** `devm_regulator_get_optional("vdd")`; `-ENODEV` is
  no rail. Every regulator call is guarded. `i2s_spk_state` adds
  `vdd_present`.
- **VISA:** Windows' script is unchanged, and 5o still pins it byte for
  byte. After it:
  1. CFG_3 DIN_SRC_SEL → AVG_L_R (`0x18` in bits 4:3; Windows' LEFT is
     `0x08`);
  2. PGA_GAIN ← the control's value.

  Both are read-modify-writes through `visa_write`, so they are read back.
  A failure goes to standby before "powered".
- **"Loudspeaker Volume"** on the I2S component:
  - raw 0..22 = **-7..+15 dB** (TLV -700/100, mainline tas2552's own
    scale);
  - default +15 dB, Windows' value;
  - capped at +15 dB until Nokia's limiter tuning is understood;
  - stored when the amplifier is off, written live (read back) when it is
    on.
- **The codec:** only the version string changed.

**Checks:**
- Verifier 5q: 15 checks.
- 5m follows the optional rail, `rc11` and the absent DT supply.
- Pre-build, against r192's modules: 661 pass, 2 expected failures.
- Mutation: 6/6 caught.

**Runners:**
- **`RAIL5V=auto`** (the default): a component with `vdd_present=0`
  expects the rail off, with no flag.
- **I2S streams** check `gain_raw` at the expected volume (`SPK_GAIN_RAW`,
  default 22).
- **Card** `rc11`.
- **Selftest:** 105/0.

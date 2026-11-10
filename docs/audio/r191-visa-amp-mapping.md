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

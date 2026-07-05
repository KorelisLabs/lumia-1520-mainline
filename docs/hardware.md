# Hardware facts (verified on an AT&T RM-940)

Facts below were verified on live hardware or extracted from the device's
own stock configuration. The stock ACPI tables live on the **PLAT**
partition (`mmcblk0p24`, plain FAT12, `/ACPI/dsdt.aml`) and describe every
peripheral's wiring — decompile with `iasl -d`. The tables themselves are
Nokia/Microsoft-copyrighted and are not included here; the facts are.

Codename: **bandit** (confirmed from stock firmware package names,
`Nokia.DEVICE_BANDIT_LTE_ATT`).

## Display

- The UEFI leaves a live 1080×1920 framebuffer at physical **`0x00400000`**
  (stride `0x10E0`, 32bpp) — read from the MDP5 `RGB0` pipe registers
  (`SRC0_ADDR` @ `0xFD901E14`) while the splash was on screen.
- `simple-framebuffer` + SimpleDRM inherit it; no panel driver needed for
  console output. A real MDSS/DSI panel driver is future work (needed for
  display power management).

## Touchscreen

| Property | Value |
|---|---|
| Controller | Synaptics **PLG0175-02** (RMI4, fw id 1554007) |
| Bus | `blsp1_i2c2` (`0xF9924000`), 400 kHz |
| Address | `0x4B` |
| Interrupt | TLMM GPIO **61**, edge falling (pull-up) |
| Enable/reset | TLMM GPIO **60**, must be driven high (gpio-hog) |
| Power | `vdd` = pm8941 **l22** (3.0 V), `vio` = pm8941 **l6** (1.8 V) |

The chip is completely silent (no I2C ACK) until both rails are up and
GPIO 60 is high. `rmi4_f34` logs an "Unrecognized bootloader version" probe
error — harmless (firmware-flash subfunction only).

## I2C bus map (kernel numbering, 6.16)

`i2c-0..6` = `f9923000, f9924000, f9925000, f9928000, f9964000, f9967000,
f9968000`. Empty/unpinmuxed buses probe very slowly (QUP timeouts); the
adapter cannot do SMBus quick-write, so use `i2cdetect -r`.

## Regulators

Full pm8941 tree ported from mainline `qcom-msm8974-lge-nexus5-hammerhead`
(same PMIC, upstream-verified voltages). All rails `regulator-always-on`
during bring-up — see trustzone-quirks.md for why that is load-bearing.
eMMC: `vmmc` = l20, `vqmmc` = s3. USB PHY: `v1p8` = l6, `v3p3` = l24.

## Buttons (unverified, from the Lumia 930 out-of-tree port)

Volume-up `pm8941_gpios 5`, camera snapshot `3`, camera focus `4`,
volume-down = PMIC `resin`. Power = PMIC pwrkey (works today).

## eMMC / partitions

Stock WP GPT (30 partitions) is preserved. Notable:
`p24` PLAT (ACPI/firmware), `p25` EFIESP (BootShim lives here), `p27`
MainOS (Windows, untouched), `p28` Data (12.9 GB — the Linux rootfs goes
here as pmOS "subpartitions"). `IS_UNLOCKED` (p30) marks the WPInternals
unlock.

## Boot image parameters

- lk2nd **ignores** boot.img header addresses (see the load-address patch);
  deviceinfo offsets are documentation only.
- `qcom,msm-id` in the bandit lk2nd dts is seeded from the Lumia 930 and has
  a wrong cell count (LK warns "(16) not a multiple of (12)") — harmless for
  the single-device lk1st build, fix before multi-device lk2nd use.

# Mainline Linux on the Nokia Lumia 1520 ("bandit")

postmarketOS / mainline Linux bring-up for the Nokia Lumia 1520 (RM-940,
Snapdragon 800 / MSM8974, 2 GB RAM, ARMv7) — a 2013 Windows Phone flagship.
To our knowledge this is the first public mainline Linux port for this device.

The port boots a mainline 6.16 kernel to a full postmarketOS system running
from eMMC, with working display, multitouch, storage, and USB networking —
installed and operated entirely over USB, with Windows Phone's boot chain
left intact.

## Status

| Subsystem | State | Notes |
|---|---|---|
| Boot (BootShim → lk1st → fastboot) | ✅ | see [docs/boot-chain.md](docs/boot-chain.md) |
| Display (framebuffer console) | ✅ | SimpleDRM on the UEFI framebuffer @ `0x00400000` |
| Touchscreen | ✅ | Synaptics PLG0175-02, RMI4, full multitouch |
| eMMC | ✅ | all stock partitions visible; pmOS runs from `Data` |
| USB gadget (network + SSH) | ✅ | NCM at `172.16.42.1`, plus ACM serial |
| PMIC regulators (pm8941) | ✅ | ported from mainline hammerhead (same PMIC) |
| microSD | ⚠️ enabled | polling card-detect; not yet validated with a card |
| Buttons (volume, 2-stage camera) | ✅ | wiring from stock ACPI, verified by press test |
| SMP (4 cores) | ❌ | WP TrustZone rejects SCM bring-up — **`nosmp` mandatory** |
| Suspend/resume | ❌ | masked; USB PHY never re-powers (see quirks doc) |
| Wi-Fi (wcnss) | ❌ blocked | Pronto times out after PAS reports success; see quirks doc |
| Bluetooth (wcnss) | ❌ blocked | shares the WCNSS remoteproc with Wi-Fi |
| Modem / telephony | ⚠️ at risk | PAS-compatibility risk (shared secure-firmware path); **not yet tested** |
| Sensors, camera, audio | ❌ | not started |

Read [docs/trustzone-quirks.md](docs/trustzone-quirks.md) **before** changing
anything boot-related — this device's Windows-flavored TrustZone hard-resets
the SoC on several code paths that are routine on Android siblings.

## Repository layout

```
pmaports/                 postmarketOS packages (drop into a pmaports checkout,
                          device/testing/) — device package + kernel dts/config
lk2nd/                    lk1st device entry + required load-address patch
tools/check-bootimg.py    pre-flight verifier for built boot images
tools/patch-cmdline.py    edit a boot.img cmdline in place (no repack)
docs/                     boot chain, hardware facts, TrustZone quirks
```

## Quick start

Prerequisites: a WPInternals-unlocked RM-940, `pmbootstrap`, and
`gcc-arm-none-eabi` for the bootloader build.

1. **Bootloader** — clone [lk2nd](https://github.com/msm8916-mainline/lk2nd),
   apply `lk2nd/0001-*.patch`, copy the bandit dts in, and build:
   ```
   make TOOLCHAIN_PREFIX=arm-none-eabi- DEBUG=1 DEBUG_FBCON=1 \
        LK2ND_BUNDLE_DTB=msm8974-nokia-bandit.dtb lk1st-msm8974
   ```
   Ship `build-lk1st-msm8974/lk_s.elf` — **the ELF**, not the flat
   `emmc_appsboot.mbn` the build also produces. Install per
   [docs/boot-chain.md](docs/boot-chain.md).
2. **OS** — copy `pmaports/*` into your pmaports checkout under
   `device/testing/`, then `pmbootstrap init` (device `nokia-rm940`),
   `pmbootstrap install`, `pmbootstrap export`.
3. **Verify then boot** — `python3 tools/check-bootimg.py boot.img`
   must PASS, then `fastboot boot boot.img`. Flash the rootfs image to the
   `Data` partition (`fastboot flash Data nokia-rm940.img`) or write it to
   an SD card.
4. SSH in at `172.16.42.1` over the USB network gadget.

## Warnings

- Installing to `Data` **erases Windows Phone user data**. Windows itself
  stays bootable, but booting it afterwards may reformat `Data` and destroy
  the Linux install. Treat the device as Linux-first from that point.
- A full WPInternals FFU flash restores factory state at any time.
- Everything here worked on one AT&T RM-940. Other RM-93x/94x variants
  should be close, but values marked VERIFY in the sources are exactly that.
- No warranty. Phones are involved; read the docs before flashing anything.

## Credits

This port stands on a great deal of prior work:

- The [postmarketOS](https://postmarketos.org) project
- [msm8974-mainline](https://github.com/msm8974-mainline/linux) kernel effort
- [lk2nd](https://github.com/msm8916-mainline/lk2nd) (the Lumia 930 "martini"
  port was the direct template)
- imbushuo's [boot-shim](https://github.com/imbushuo/boot-shim), which makes
  chainloading LK on Lumias possible
- René Lergner (HeathCliff) — [WPInternals](https://github.com/ReneLergner/WPinternals)
- The mainline Snapdragon-400 Lumia ports, whose conventions this follows

## License

MIT (see [LICENSE](LICENSE)). Device tree sources carry their own
SPDX `BSD-3-Clause` headers for kernel compatibility.

Copyright (c) 2026 Korelis Labs LLC.

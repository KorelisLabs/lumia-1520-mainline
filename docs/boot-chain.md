# Boot chain

The 1520 has no Android-style `aboot` partition — it boots
SBL → Qualcomm UEFI → Windows Boot Manager. This port chainloads LK
(lk2nd's single-device "lk1st" build) from inside that UEFI environment:

```
SBL → Lumia UEFI → BootShim (as resetphone.efi) → lk1st → fastboot → kernel
```

## Installing the bootloader

Prerequisite: bootloader unlocked with WPInternals (the 1520 is a
supported "Spec B" device). Use WPInternals mass-storage mode to edit the
EFIESP partition:

1. Back up `resetphone.efi`, then replace it with **BootShim.efi** from
   imbushuo's [boot-shim](https://github.com/imbushuo/boot-shim) (build it or
   use a trusted release; not redistributed here).
2. Copy your built `lk_s.elf` to the **root of the same volume**, renamed to
   exactly `emmc_appsboot.mbn`. BootShim looks for that file name, validates
   it as an ARM ELF, copies the load segment to `0x0FF00000` and jumps.
   It must be the ELF (`lk_s.elf`) — the flat `emmc_appsboot.mbn` that the
   lk2nd build also produces will fail BootShim's ELF checks.
3. Trigger the boot path that runs `resetphone.efi`. lk1st starts, exposes
   fastboot over USB, and (built with `DEBUG_FBCON=1`) logs to the panel.

Note: lk1st has no panel driver for the 1520, so after the BootShim text the
screen does not update while in fastboot — the device is alive; check
`fastboot devices`.

## Why the load-address patch is required

lk2nd force-overrides the boot image header addresses
(`ABOOT_FORCE_KERNEL_ADDR`). The stock msm8974 value (`0x00008000`) places
the kernel directly over the UEFI framebuffer, which on this device lives at
physical `0x00400000` (read from the MDP5 `RGB0` pipe registers on live
hardware). The decompressing kernel overwrites the active scanout buffer
(symptom: full-screen noise) and the display is unusable.

`0001-msm8974-raise-forced-load-addresses.patch` moves the kernel to
`0x10008000` and tags/ramdisk to `0x13e00000`/`0x14000000`, clear of both
the framebuffer and lk's fastboot download window at `0x11000000`.

Caveat: the patch changes the *global* msm8974 defaults, which is fine for a
1520-only lk1st build but needs device-scoping before any lk2nd upstreaming.

## Useful lk1st commands

```
fastboot oem log            # stage the LK boot log
fastboot get_staged log.txt # fetch it
fastboot oem ramoops console # previous kernel's ramoops (if it survived)
fastboot oem debug readl <addr> # peek MMIO (how the fb address was found)
```

## Day-to-day boot

The port is operated RAM-boot style: `fastboot boot boot.img` each time
(nothing Android-bootable is flashed; the Windows boot chain stays intact).
Run `tools/check-bootimg.py` against every freshly built image first — it
catches every mistake we made so you don't have to repeat them.

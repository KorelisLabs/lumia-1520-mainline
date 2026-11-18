# SMP (all four cores): mapping

**Status:** mapped, and patch 0011 written and staged as r209 (section 6), 2026-11-18. Not built or booted yet. The phone still runs `nosmp maxcpus=1`.

**Sources:**
- **[ACPI]** the phone's own ACPI tables (`PLAT` partition, `mmcblk0p24:/ACPI/*.acp`, mounted read-only and unmounted after). Copied to WSL `~/winacpi` for analysis only; never committed.
- **[RAM]** the four parking mailbox pages, read from the running Linux system through a read-only `mmap` of `/dev/mem` (`0x301000`-`0x304fff`, RAM only, no MMIO touched). Copied to WSL `~/winfw/smp/mailboxes.bin`; firmware code, never committed.
- **[WIN]** Windows' `QCpep8974.sys`, `HAL.DLL` and `FXPPM.SYS` from MainOS (read-only), strings only so far. In WSL `~/winfw/smp`; never committed.
- **[ML]** mainline `arch/arm/mach-qcom/platsmp.c` and `arch/arm64/kernel/acpi_parking_protocol.c`.

## 1. Why the phone runs on one core

`trustzone-quirks.md` §1 says the Windows Phone TrustZone rejects mainline's SMP calls and resets the SoC. Two parts of that are now known to be wrong or unproven:
- **The SCM interface does work.** The ADSP and the modem both boot through legacy SCM calls on this TrustZone (PAS, and the SSD calls 0x1C05-0x1C08, modem doc §§12-30).
- **The LK message `SCM call: 0x2000601 failed` is not evidence.** 0x02000601 is the ARMv8 SMC-convention probe (SIP owner, `SCM_SVC_INFO`, `IS_CALL_AVAIL`). A 32-bit TrustZone answering "no" is normal, and LK falls back to the legacy convention.

The step that resets the phone was never isolated. What we now know (section 2) explains why mainline's method is wrong for this phone, whichever step resets it.

## 2. How Windows starts the cores [ACPI] [RAM]

**MADT** (`madt.acp`, OEM `QCOMEDK2`, revision 3): four GICC entries, all enabled, all using **parking protocol version 1**:

| CPU | MPIDR Aff0 | Mailbox (phys) |
|---|---|---|
| 0 | 0 | `0x00301000` |
| 1 | 1 | `0x00302000` |
| 2 | 2 | `0x00303000` |
| 3 | 3 | `0x00304000` |

GICD at `0xF9000000`, GICC at `0xF9002000` (the same as our DT). There is no PSCI, so Windows wakes the cores through Microsoft's *Multiprocessor Parking Protocol*, not through TrustZone.

**The mailboxes are live under Linux** [RAM]:
- Every mailbox header reads `cpu_id = 0xFFFFFFFF` (no CPU selected) and jump address 0.
- Each page holds the same firmware parking loop at offset `0x800`, in ARM state.
- Mailboxes 1-3 also hold firmware stack data at the top of the page; mailbox 0 does not, because CPU0 is the boot CPU and never parked. That stack data includes the GICD and GICC base addresses, which suggests the firmware prepared each parked core's GIC CPU interface to be woken by an interrupt.
- Linux never touches this memory: its RAM begins at `0x10000000` (`/proc/iomem`), because the kernel loads at `0x10008000`.

**What the parking loop does** (disassembled; a behavioural summary, not a copy):
1. Compute its own mailbox base from the PC.
2. Read `cpu_id` (offset 0) and compare its low byte with this core's MPIDR Aff0.
3. If it matches and the 64-bit jump address (offset 8) is non-zero: clear the jump field, then branch (`bx`) to the jump address with `r0` = mailbox address. ARM or Thumb is taken from bit 0.
4. Otherwise: `dsb`, `wfi`, clear bit 10 of a Krait implementation-defined CP15 register (`p15, 7, c15, c0, 2`), `isb`, and loop.

**Consequences:**
- **CPUs 1-3 are already powered and sleeping in firmware code** when Linux boots. Mainline's `qcom,kpss-acc-v2` method instead asks TrustZone for a cold-boot address and then drives the ACC/SAW power sequence on cores that are **already running**. That alone is enough to explain an instant reset, whichever step trips it.
- **Starting a core needs no TrustZone call at all.** It needs a mailbox write and an interrupt.

[WIN] strings agree that Windows "unparks" cores ("UnPark-Selection", "AdditionalUnparkCores"), with per-core power states in the PEP. Core *power collapse* (deep idle) is a separate question, not needed here.

## 3. The Linux side [ML]

- **arm64** has this exact protocol (`acpi_parking_protocol.c`): `ioremap` the mailbox, write the entry point, then the CPU id, then send a wake-up IPI.
- **arm32** has no parking-protocol enable method. Qualcomm arm32 boards use `qcom,kpss-acc-v1/v2`, `qcom,gcc-msm8660` or `qcom,msm8226-smp`, which all power cores up from reset.
- **No prior Linux implementation** for 32-bit Lumias turned up in a search; this would be new.

## 4. Unknowns the first boot answers

1. **The parked cores' CPU state.** The loop branches as-is. If the firmware left the MMU or caches on, Linux's `secondary_startup` must not be entered directly. Answer: a small ARM-mode trampoline that forces SVC mode, masks IRQ/FIQ, turns the MMU, D-cache and branch predictor off, invalidates the I-cache and TLB, then branches to `secondary_startup`. That is correct whatever state the firmware left.
2. **Whether a GIC SGI wakes them after Linux has re-initialised the distributor.** Linux reprograms the distributor but not the other cores' banked CPU interfaces, which the firmware set up. Expected to work; the boot shows it.
3. **Cache coherency of the mailbox.** The parked core reads with caches possibly off, so Linux writes through an uncached (`ioremap`) mapping, as arm64 does.

**The failure mode is mild.** If a core never wakes, Linux prints `CPU1: failed to come online` and carries on single-core. A reset is possible only if a core does wake and then runs into wrong state, which the trampoline guards against. Ramoops is armed for that case.

## 5. Plan

1. **Kernel patch:**
   - a new arm32 enable method in `arch/arm/mach-qcom/platsmp.c` (`smp_boot_secondary` = mailbox write + `arch_send_wakeup_ipi_mask`);
   - the trampoline;
   - a per-CPU mailbox address from the DT.

   No `cpu_die` or hotplug in the first version, since the firmware loop cannot be re-entered once left. A core that goes offline would sleep in a kernel WFI loop instead.
2. **DT:**
   - override `enable-method` on the four cpu nodes;
   - set the mailbox addresses;
   - reserve `0x300000`-`0x305000` `no-map`, as hygiene in case the memory layout ever changes.
3. **Test boot**, at the user's go, after the user builds:
   - a test image without `nosmp maxcpus=1`, keeping `cpuidle.off=1`;
   - check `nproc`, `/proc/cpuinfo` and dmesg;
   - a parallel CPU load;
   - the modem/audio regressions (rmtfs/MM up, bam-dmux restart, playback), since interrupts and workqueues now spread across cores;
   - a suspend/resume cycle.
4. **Later:** CPU frequency scaling for the secondaries (they run at whatever clock the firmware left), and hotplug if it is ever needed.

## 6. Patch 0011 (r209): written, compile-checked, staged

`patches/0011-ARM-qcom-boot-secondary-CPUs-through-the-parking-protocol.patch`, pkgrel 209.

- **`arch/arm/mach-qcom/platsmp.c`:** a new `microsoft,parking-protocol` enable method.
  - At prepare time, each secondary's mailbox is `ioremap`ped (uncached) from `cpu-release-addr` and checked. If a jump address is pending, or there is no firmware code at `+0x800`, that CPU is marked not present and never touched.
  - To boot a CPU: write the jump address (the trampoline's physical address), then the CPU id, then send the wake-up IPI. Then poll up to 100 ms for the firmware to clear the jump field. If it never clears, disarm the mailbox and fail.
  - No `cpu_die`, so the CPUs cannot be offlined. Suspend here is s2idle only, which does not offline them.
  - The prepare-time message carries the tag `[park-rc1]`.
- **`arch/arm/mach-qcom/park-entry.S`:** the trampoline from section 4.
  - It masks interrupts, turns the MMU, D-cache, branch predictor and I-cache off, and invalidates the I-cache, branch predictor and TLB.
  - It then reaches `secondary_startup_arm` through a PC-relative offset (`R_ARM_REL32`).
  - The D-cache is deliberately not cleaned, because its dirty lines are the firmware's.
- **DT** (`qcom-msm8974-microsoft-common.dtsi`): the four cpu nodes get the new `enable-method` and `cpu-release-addr`. `0x301000`-`0x304fff` is reserved `no-map`.
- **Checks done here:**
  - gcc W=1 compile of both objects in the check tree: no warnings. The real build uses clang; the assembly is plain ARMv7.
  - Disassembly of the trampoline.
  - The DT compiles, and the dtb carries the new properties.
  - The patch applies to a pristine tree.
  - Every APKBUILD checksum matches its file in order, and the live and repo APKBUILDs are identical.
- **The default image stays single-core:** deviceinfo still passes `nosmp maxcpus=1`. The test image is the r209 boot image with those two removed by `tools/patch-cmdline.py`.

**Test:** `tools/msm8974-smp-check.sh [--suspend]`, on the phone as `~/wcd9320-tools/msm8974-smp-check.sh`. It refuses on a `nosmp` boot (checked). Pass means:
- 4 CPUs online, and each one did work in the parallel run;
- a parallel speedup of at least 3x;
- no oops, BUG, WARNING or lockup lines in the kernel log;
- with `--suspend`, 4 CPUs still online after one s2idle cycle.

Then rerun the modem tests (bam-dmux restart, crash recovery) and an audio playback check.

### 6a. r209 built and verified (by artefact)

- Package `linux-postmarketos-qcom-msm8974-6.16.12-r209.apk`. The codec artefact gate passed: 729 PASS, 0 FAIL.
- **Kernel:** the zImage's xz payload decompressed to the raw Image contains `park-rc1`, the new enable method and both boot messages.
  - The trampoline, as clang built it, is byte-for-byte the instruction sequence of the gcc check build, at Image `+0x12cbc0` (phys `0x10134bc0`).
  - Its PC-relative literal resolves to Image `+0x10d000` (phys `0x10115000`). That code is `secondary_startup_arm`: `bl __hyp_stub_install_secondary` (ARM_VIRT_EXT=y), then `safe_svcmode_maskall`, then the processor-id read.
- **DTB:** all four cpu nodes have `enable-method = "microsoft,parking-protocol"` and their `cpu-release-addr`, and `memory@301000` is reserved `no-map`.
- **Test image** `boot-1520-park-rc1-smp.img`: the r209 image with `nosmp maxcpus=1` removed and `ignore_loglevel` restored, so a hang leaves its last lines on screen. It is otherwise byte-identical to the r209 image.
- **`tools/check-bootimg.py`:** a cmdline without `nosmp` now passes only if every CPU node uses `microsoft,parking-protocol`.
  - The test image passes, and the default r209 image (with `nosmp`) passes.
  - A kpss-acc image with `nosmp` removed still fails, as before.

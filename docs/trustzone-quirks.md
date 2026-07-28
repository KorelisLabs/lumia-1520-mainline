# Windows-Phone TrustZone quirks (READ THIS FIRST)

The 1520 runs the Windows Phone flavor of Qualcomm's TrustZone firmware. It
does **not** implement the SCM interface mainline Linux expects on MSM8974
Android devices, and several routine kernel paths cause an instant,
log-less SoC reset. The findings below were established by experiment
on real hardware and by reading the mainline driver source.

## 1. SMP bring-up resets the SoC → `nosmp maxcpus=1` is mandatory

Mainline starts secondary Krait cores via SCM calls (set boot address +
power-up through kpss-acc/SAW). The WP TZ rejects these hard enough to reset
the SoC before any console output exists. Even LK logs
`SCM call: 0x2000601 failed` / `Failed to initialize SCM` at startup.

Until someone implements an alternate enable-method, the device runs
single-core. Removing `nosmp` produces a boot that dies in the first
fraction of a second and usually falls through to Windows.

## 2. The USB PHY `-22` — *not* a TrustZone problem (SOLVED)

For a long time this device looked like it had a hardware/firmware wall:

```
phy phy-ci_hdrc.0.ulpi.0: phy poweron failed --> -22
```

USB would die whenever the PHY was powered down — after a suspend, or when
the SMBB charger touched the shared USB connector — and only a cold boot
brought it back. It was tempting to blame the Windows-Phone TrustZone along
with everything else in this document. **That was wrong.**

The real cause was a device-tree constraint of our own making. The kernel
logs it plainly, one line, at every boot:

```
l24: voltage operation not allowed
```

`qcom_usb_hs_phy_power_on()` calls `regulator_set_voltage_triplet()` on its
v3p3 supply (pm8941 **l24**) and `regulator_set_load()` on both v1p8 (l6) and
v3p3. Our regulator hardening had pinned every rail to a *fixed* voltage
(`regulator-min-microvolt == regulator-max-microvolt`); the regulator core
only grants `REGULATOR_CHANGE_VOLTAGE` when min ≠ max, so it refused the
request and the PHY power-on returned `-EINVAL`.

USB appeared to work anyway **only because the Windows firmware leaves the
PHY powered** — the driver had never actually initialised it, so the PHY
could never be brought back up once something powered it down.

The fix is two lines: give l24 a 3.05–3.3 V *range* instead of a fixed
3.075 V, and allow `set_load` on both rails. With that in place the PHY
survives repeated `phy_power_off`/`phy_power_on` cycles (verified by
unbinding and rebinding `ci_hdrc`), and both of the "blocked" subsystems
below came back to life on their own.

**Lesson worth repeating:** a fixed-voltage regulator constraint silently
disables voltage operations for every consumer of that rail. If a driver
reports `-EINVAL` from a power-on path, check for
`voltage operation not allowed` before blaming firmware.

## 2a. Suspend/resume — works

`systemctl suspend` (s2idle) resumes cleanly: 10/10 cycles with an RTC wake,
`suspend_stats` success with zero failures, no resets, and USB, networking,
SSH, udevd and NetworkManager all intact afterwards.

Two things had masked this. The PHY bug above was one. The other was
self-inflicted: driving suspend with a raw `echo mem > /sys/power/state`
*while systemd's sleep targets were masked* leaves systemd's 3-minute
service watchdogs running across the sleep, so on resume systemd SIGABRTs
`journald`, `udevd` and `NetworkManager` — which is what actually killed the
USB network. Use `systemctl suspend`, not `echo mem`.

The device package no longer masks the sleep/suspend targets. It *does*
still mask `sleep-inhibitor.service`, so an idle device will not suspend
itself — on a USB-attached bring-up box suspend should stay a deliberate
action. Make sure a wake source is armed (the PM8941 RTC wakealarm works)
before suspending, or the device will sleep until you press power.

## 3. Deep CPU idle goes through the TZ → `cpuidle.off=1`

The `qcom,idle-state-spc` standalone-power-collapse state performs SCM calls.
It is kept off as a precaution; WFI-only idle is used. (Cost: some battery,
irrelevant during bring-up.)

## Debugging aids that survive this environment

- `lk2nd.pass-ramoops` + `ramoops.mem_address=0x30fc0000 ...` on the cmdline:
  if the kernel gets far enough to arm pstore, a panic survives a warm reset
  and can be read back from lk1st (`fastboot oem ramoops console`).
  Note: if the crash falls through to Windows, a full Windows boot scrubs it.
- The framebuffer console (`console=tty0 ignore_loglevel`) is the primary
  boot-time diagnostic — the display works from the first kernel second.
- `clk_ignore_unused pd_ignore_unused` are required: much of the hardware
  runs on state the WP firmware left behind, and the kernel must not turn
  "unused" clocks/domains off. The same logic drove marking all ported
  pm8941 regulators `regulator-always-on` — the kernel's ~30s
  unused-regulator cleanup otherwise cuts power to the eMMC out from under
  the running system.

## 4. Wi-Fi/BT (WCNSS/Pronto) blocked after PAS reports success

The integrated WCNSS radio (Wi-Fi + Bluetooth) is driven by the Pronto
remote processor, brought up by `qcom-wcnss-pil`. On the 1520 the firmware
loads correctly (a valid signed ELF extracted from the stock partitions),
but startup never completes.

What the driver (`drivers/remoteproc/qcom_wcnss.c`, `wcnss_start()`) does,
in order: enable the power domains, regulators and the iris; call
`qcom_scm_pas_auth_and_reset(WCNSS_PAS_ID)`; then wait up to 5 s for the
Pronto `ready` interrupt. Observed on the 1520:

```
remoteproc0: Booting fw image wcnss.mdt, size 8896
qcom-wcnss-pil fb204000.remoteproc: start timed out
remoteproc remoteproc0: can't start rproc fb204000.remoteproc: -110
```

Note the failure is the **timeout** branch, not the "failed to authenticate
image" branch — so `qcom_scm_pas_auth_and_reset()` **returned success**.
That return value is either the SCM transport error or TrustZone's own
result; a zero proves secure world *reported* success, **it does not prove
Pronto actually executed**. After the timeout the driver calls PAS shutdown
and unwinds the power domains — which is why the CX power domain reads
"off" if you inspect it afterwards (an effect of the failure, not a cause).

**Stated conclusion:** WCNSS startup is blocked after the PAS
authentication/reset call reports success — Pronto never raises its ready
interrupt.

> **Correction (see §5): the earlier "the WP TrustZone's PAS path is
> broken" hypothesis is DISPROVEN.** The ADSP boots through the very same
> `qcom_scm_pas_auth_and_reset()` path on this device. PAS works. Whatever
> stops Pronto is specific to WCNSS, not a platform-wide secure-world
> limitation.

Remaining candidates, none yet eliminated: an immediate firmware failure
after release, a WP-specific Pronto/iris startup requirement (clocks,
regulators or the iris XO), or incorrect `ready`-interrupt wiring in the
device tree.

Ruled out along the way: the device-tree supplies match a known-working
mainline board (Fairphone 2, msm8974pro) almost line-for-line; the reserved
memory map is correct (`wcnss@d200000` reserved `nomap`, flat 2 GB injected
by lk2nd); the firmware `.mdt` is a valid ELF that PIL loads without error.

Consequence: Pronto is left `status = "disabled"` on the default branch.
When it was enabled, letting `wcn36xx` probe *after* the failed startup
triggered full device resets — hence disabled, not merely non-functional.
The experimental enabled configuration lives on the `research/pronto-pas-timeout`
branch of the pmaports tree for anyone continuing the investigation.

**Modem outlook:** the cellular modem (MSS / Q6V5) uses the same PAS
mechanism, which §5 shows works on this device. That is encouraging rather
than conclusive: the modem is a *separate* processor with its own PAS ID,
firmware package and startup sequence, and it additionally needs the
modem filesystem partitions. Untested — do not record it as either working
or blocked.

## 5. PAS *does* work — the ADSP boots

The Q6 audio DSP (ADSP) starts cleanly on this device:

```
remoteproc remoteproc0: Booting fw image adsp.mdt, size 9280
remoteproc remoteproc0: remote processor adsp is now up
```

`/sys/class/remoteproc/remoteproc0/state` reads `running`, and the SMD
edge brings up `apr`, `apr_apps2`, `apr_audio_svc`, `DIAG`, `IPCRTR`,
`fastrpcsmd-apps-dsp` and `sys_mon`.

This matters twice over. It proves `qcom_scm_pas_auth_and_reset()` and the
full ready handshake work on the Windows-Phone TrustZone — so the WCNSS
timeout in §4 is a WCNSS problem, not a secure-world one. And
`apr_audio_svc` is the channel the Q6 audio stack binds to, so audio is a
matter of enabling the APR/Q6 drivers rather than fighting firmware.

Enabling it is one line — everything else (cx power domain, xo clock,
`adsp_region`, smp2p) is inherited from `qcom-msm8974.dtsi`:

```
&remoteproc_adsp {
	status = "okay";
};
```

### Getting the firmware (you must extract it yourself)

The DSP firmware is Nokia/Microsoft property and is **not** redistributed
here. It is already on your device, in the stock Windows install:

| File (on MainOS, `/Windows/system32/`) | Processor |
|---|---|
| `qcadsp8974.mbn`  | ADSP (audio DSP) |
| `qcwcnss8974.mbn` | WCNSS (Wi-Fi/BT) |
| `qcdsp1v28974.mbn`, `qcdsp28974.mbn`, `qcvss8974.mbn` | other DSPs |

Mount the Windows partition read-only and copy the blob out:

```
mount -t ntfs3 -o ro /dev/disk/by-partlabel/MainOS /mnt/mainos
cp /mnt/mainos/Windows/system32/qcadsp8974.mbn /tmp/
```

Then split it into the `.mdt` + `.bNN` files the mainline loader expects
and install them:

```
python3 tools/pil-split.py /tmp/qcadsp8974.mbn /lib/firmware adsp
```

(`.bNN` is program header N's file data; `.mdt` is `b00`, the ELF header
and program-header table, concatenated with `b01`, the hash segment. The
tool was validated by re-splitting `qcwcnss8974.mbn` and checking it
reproduces a known-good `wcnss.mdt`/`.bNN` set byte for byte.)

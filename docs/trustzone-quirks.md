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

## 2. Suspend permanently kills the USB PHY → all sleep paths masked

The `qcom,usb-hs-phy` on this device powers **off** fine but its power-on
path fails (`phy poweron failed --> -22`) — once anything suspends the
controller, USB is dead until a cold boot. Worse, the full suspend path also
goes through the TZ and (pre-`cpuidle.off`) hard-reset the phone.

postmarketOS's `sleep-inhibitor` auto-suspends an idle phone about two
minutes after boot, which manifested as "USB mysteriously dies at +2min."
The device package therefore masks `sleep.target`, `suspend.target`,
`hibernate.target`, `hybrid-sleep.target`, `systemd-suspend.service` and
`sleep-inhibitor.service`.

Do not re-enable suspend until the PHY power-on failure is root-caused
(likely candidates: ULPI init sequencing or the por reset on re-power).

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
interrupt. The **leading hypothesis** is an incompatibility or incomplete
implementation in the Windows-Phone TrustZone/PAS path (consistent with the
`SCM call ... failed` / `Failed to initialize SCM` messages lk2nd prints at
boot). Other possibilities have **not** been eliminated: immediate firmware
failure after release, a WP-specific startup requirement, or an incorrect
`ready`-interrupt wiring in the device tree.

Ruled out along the way: the device-tree supplies match a known-working
mainline board (Fairphone 2, msm8974pro) almost line-for-line; the reserved
memory map is correct (`wcnss@d200000` reserved `nomap`, flat 2 GB injected
by lk2nd); the firmware `.mdt` is a valid ELF that PIL loads without error.

Consequence: Pronto is left `status = "disabled"` on the default branch.
When it was enabled, letting `wcn36xx` probe *after* the failed startup
triggered full device resets — hence disabled, not merely non-functional.
The experimental enabled configuration lives on the `research/pronto-pas-timeout`
branch of the pmaports tree for anyone continuing the investigation.

**Modem outlook (unconfirmed):** the cellular modem (MSS / Q6V5) also relies
on secure firmware services and its own PAS path, so a platform-wide
limitation is plausible — but it is a *separate* processor, PAS ID, firmware
package and startup sequence. The WCNSS result is a strong warning, not a
completed modem diagnosis. Do not record the modem as blocked until tested.

# MSM8974 audio: SLIMbus / LPASS map and upstream gap analysis

Pre-code research for the WCD9320 audio effort. Nothing here has been
compiled or booted as a test image — this document exists to decide *what*
to build before any of it is built. It was substantially revised once the
downstream source was actually acquired: **the original plan (write an
MSM8974 LPASS clock driver, use the upstream `qcom-ctrl` manager driver) is
dead**, for reasons that are better than the plan was.

**Provenance is marked on every fact.**

- **[DSDT]** — this device's own stock ACPI tables
  (`mmcblk0p24:/ACPI/dsdt.aml`, decompiled with `iasl -d`).
- **[LIVE]** — read from the running phone's physical registers
  (read-only `/dev/mem` mmap, 2026-07-29, stable image, no writes).
- **[KSRC]** — mainline 6.16.12 kernel source (the tree this port builds).
- **[DS]** — downstream vendor source, now concretely pinned:
  `LineageOS/android_kernel_lge_hammerhead` (Nexus 5, MSM8974, msm-3.4
  vendor kernel), branches `cm-11.0` (has the full audio stack) and
  `cm-14.1` (register-offset headers). Files: `arch/arm/mach-msm/clock-8974.c`,
  `arch/arm/boot/dts/msm8974.dtsi`, `drivers/slimbus/slim-msm-ngd.c`,
  `slim-msm.c`, `slim-msm.h`, `slim-msm-ctrl.c`.
- **[UNKNOWN]** — stated as unknown rather than guessed.

## 1. The headline discovery: MSM8974 SLIMbus is NGD, not manager

Downstream MSM8974 does **not** run the SLIMbus manager on the APPS
processor. The hammerhead DT node is:

```
slim_msm: slim@fe12f000 {
    cell-index = <1>;
    compatible = "qcom,slim-ngd";
    reg = <0xfe12f000 0x35000>, <0xfe104000 0x20000>;
    reg-names = "slimbus_physical", "slimbus_bam_physical";
    interrupts = <0 163 0 0 164 0>;
    interrupt-names = "slimbus_irq", "slimbus_bam_irq";
    ...
};
```
[DS]

The **ADSP is the bus master**: it owns the framer/manager, programs the
LPASS clock tree, and powers the audio-core GDSC. The APPS side is an
**NGD (non-generic device) satellite** that asks the ADSP to power the bus
via a QMI service and moves data through the BAM. Three independent
confirmations:

- The APPS clock table maps the controller's core clock to a dummy:
  `CLK_DUMMY("core_clk", NULL, "fe12f000.slim", OFF)` — the Android APPS
  kernel *never* programs the SLIMbus clock on MSM8974. [DS]
- This device's DSDT places `SLM1` (the SLIMbus node) *under the ADSP
  device*, with the codec beneath it — Windows models the same ownership.
  [DSDT]
- The live register dump (§3) shows the APPS-visible SLIMbus RCG has never
  been programmed, on a phone whose audio worked for years under Windows.
  [LIVE]

**Consequences:**

- **No `lcc-msm8974.c` is needed.** The APPS kernel never touches the
  LPASS clock tree for SLIMbus. The RCG-parent question this research set
  out to answer is moot on the APPS side.
- The upstream driver to use is **`qcom-ngd-ctrl.c`** (`qcom,slim-ngd`),
  not `qcom-ctrl.c`. The earlier analysis of `qcom-ctrl`'s PIO register
  model (one IRQ, no BAM) survives as an explanation of *why that driver
  was the wrong fit*: it is the manager-role driver for apq8064-era
  designs.

## 2. Hardware windows and interrupts (all confirmed on this device)

| Resource | Address | Length | IRQ | Source |
|---|---|---|---|---|
| SLIMbus controller | `0xFE12F000` | `0x2C000` [DSDT] / `0x35000` [DS] | SPI **163**, level-high | [DSDT]+[DS] agree |
| SLIMbus BAM | `0xFE104000` | `0x20000` | SPI **164**, edge | [DSDT]+[DS] agree |

The DSDT declares GSIV `0xC3`/`0xC4` = SPI 163/164 (GSIV − 32), level
vs. edge exactly matching the downstream DT. Use the DSDT's `0x2C000`
window unless something is shown to access beyond it.

## 3. Live LPASS register snapshot (stable image, read-only)

LPASS CC base `0xfe000000` [DS], offsets per `clock-8974.c` cm-14.1
(`SLIMBUS_CMD_RCGR 0x12000`, `AUDIO_CORE_SLIMBUS_CORE_CBCR 0x12014`,
`AUDIO_CORE_SLIMBUS_LFABIF_CBCR 0x12018`, `AUDIO_CORE_GDSCR 0x7000`,
`AUDIO_CORE_IXFABRIC_CBCR 0x1B000`, `LPASS_LPA_PLL_VOTE_APPS_REG 0x2000`)
— offsets [DS], values [LIVE]:

| Register | Value | Decoded |
|---|---|---|
| LPAPLL MODE `0x0000` | `0x00104000` | FSM vote-mode enabled (bit 20); enabled by processor votes, not direct control |
| LPAPLL L `0x0004` | `0x33` (51) | |
| LPAPLL M `0x0008` | `0x1` | VCO = 19.2 MHz × (51 + 1/5) = **983.04 MHz** |
| LPAPLL N `0x000c` | `0x5` | |
| LPAPLL USER_CTL `0x0010` | `0x01000101` | postdiv **/2** → **491.52 MHz** PLL output |
| LPAPLL CONFIG/TEST/STATUS | `0x00341600` / `0` / `0x6004` | |
| APPS PLL vote `0x2000` | `0x0` | APPS does not vote |
| AUDIO_CORE_GDSCR `0x7000` | `0x00000001` | SW_COLLAPSE set, PWR_ON clear — **audio-core GDSC off** |
| SLIMBUS_CMD_RCGR `0x12000` | `0x80000000` | ROOT_OFF; **CFG/M/N/D all zero — never programmed** |
| SLIMBUS_CORE_CBCR `0x12014` | `0x80000000` | CLK_OFF |
| SLIMBUS_LFABIF_CBCR `0x12018` | `0x80000ff0` | CLK_OFF |
| IXFABRIC_CBCR `0x1b000` | `0x80000000` | CLK_OFF |

Notes. The snapshot was taken on a boot **without** the ADSP running (see
§6), so "everything quiesced, RCG virgin" is the expected ADSP-master
picture, and 491.52 MHz = 20 × 24.576 MHz is the natural SLIMbus root
source. The earlier ÷16-from-393.216 MHz inference in a previous revision
of this document was **wrong**; the PLL is 491.52 MHz, read from silicon.

Do **not** read the SLIMbus controller window (`0xfe12f000`) while
`SLIMBUS_LFABIF` is CLK_OFF — the register interface behind an ungated
fabric clock is exactly the bus-hang case. Downstream reads the version
register only after enabling `iface_clk`. [DS]

## 4. The codec: WCD9320 Taiko, confirmed

The downstream reference DT names it outright, as a child of the SLIMbus
node [DS]:

```
taiko_codec {
    compatible = "qcom,taiko-slim-pgd";
    elemental-addr = [00 01 A0 00 17 02];
    qcom,cdc-reset-gpio = <&msmgpio 63 0>;
    cdc-vdd-buck-supply = <&pm8941_s2>;      /* 2.15 V, 650 mA */
    cdc-vdd-tx-h-supply = <&pm8941_s3>;      /* 1.8 V */
    ... (further pm8941 rails in the hammerhead dtsi)
};
```

Cross-checks against **this phone's own** tables [DSDT]:

- Reset GPIO: the DSDT's `AUDD` node holds a GpioIo on **TLMM 63** —
  identical to `qcom,cdc-reset-gpio = <&msmgpio 63 0>`.
- Headset detect: DSDT `MBHC` node (WCD-family Multi-Button Headset
  Control) interrupt on **TLMM 72**, edge, active-high, pull-down.
- Elemental address: manufacturer `0x0217` (Qualcomm) appears in the
  DSDT's `FNOC` buffer bytes `17 02`; full EA `[00 01 A0 00 17 02]` =
  device-index 01, product `0x00A0` (Taiko), instance 00. The DSDT and
  downstream agree wherever they overlap.

**Codec identity is settled: WCD9320.** Supplies come from pm8941 rails we
already have (s2, s3, plus the remaining entries in the hammerhead node to
be ported when the codec is attempted). The remaining per-device unknown is
whether the 1520 deviates from the reference wiring anywhere beyond the
GPIOs already confirmed.

## 5. Mainline NGD driver vs this hardware

`drivers/slimbus/qcom-ngd-ctrl.c` [KSRC] vs downstream `slim-msm-ngd.c`
[DS]:

| Aspect | Mainline | Downstream 8974 | Verdict |
|---|---|---|---|
| QMI service | `0x0301`, msgs SELECT_INSTANCE `0x0020`, POWER `0x0021` | identical IDs and message structure | **protocol match** |
| QMI instance | `INS_ID 0` | `INS_ID 1` | flag — verify at test time which instance the WP ADSP publishes |
| NGD reg offset | `v1_5_offset_info = 0x1000` | `NGD_BASE_V2(1) = 0x1000` (V2 hw), `0x800` (V1 hw) | matches **if** 8974's NGD is the V2 layout; downstream selects by reading a version register at runtime — verify on hardware |
| Clocks | none required | `core_clk` was a dummy anyway | no clock driver needed |
| Data path | `dma_request_chan("rx"/"tx")` — needs a **`bam-dma`** node for `0xfe104000` | sps/BAM direct | mainline `qcom_bam_dma` + `qcom,controlled-remotely` (ADSP initializes the BAM) |
| Power notify | `pdr_add_lookup("avs/audio", "msm/adsp/audio_pd")` + SSR notifier on `"lpass"` | no PDR (predates protection domains) | risk: if the 2013-era WP firmware has no PD service, does the driver still power up on QMI service arrival alone? Read the up-path carefully before the test boot |
| Transport | QMI over QRTR; on 8974 that means `CONFIG_QRTR_SMD` over the ADSP SMD edge's `IPCRTR` channel | IPC router over SMD | config requirement, not code |
| Binding enum | `qcom,slim-ngd-v1.5.0`, `qcom,slim-ngd-v2.1.0` | n/a | an msm8974 compatible must be added (or v1.5.0 shown to fit) |

## 6. Live-system gap found during this survey

The currently-installed boot image predates the ADSP work: its DT has no
ADSP remoteproc node, and its kernel config lacks `CONFIG_QCOM_APR`,
`CONFIG_SLIMBUS`, and has `CONFIG_QRTR*=m` with no auto-load. The QRTR
service scan therefore returned nothing *by construction* — it says nothing
about the WP firmware. The first test image must carry: the frozen
baseline's ADSP enablement, `QRTR`/`QRTR_SMD`, `SLIMBUS` +
`SLIM_QCOM_NGD_CTRL`, `QCOM_BAM_DMA`, `QCOM_PDR_HELPERS`, and APR/Q6
configs.

## 7. What upstream actually needs (revised, evidence-based)

| # | Item | Size | Status |
|---|---|---|---|
| 1 | ~~MSM8974 LPASS clock driver~~ | — | **not needed** (ADSP owns the tree) |
| 2 | `bam-dma` DT node at `0xfe104000`, `qcom,controlled-remotely`, IRQ 164 | DT only | BAM hw version to confirm (v1.4 expected for 8974-era) |
| 3 | `slim-ngd` DT node at `0xfe12f000`, IRQ 163, `rx`/`tx` DMA refs | DT only | window `0x2c000` per DSDT |
| 4 | msm8974 compatible in `qcom-ngd-ctrl.c` + binding (or validate v1.5.0 fits) | small patch | NGD version register check decides |
| 5 | Kernel configs (§6) | config | trivial |
| 6 | QMI instance / PDR-absence behavior on WP firmware | unknown until test | **the key test-boot question** |
| 7 | WCD9320 codec driver | large — nothing upstream | still the endgame gap; unchanged |
| 8 | msm8974 ASoC machine driver | moderate | after 7 |

The first test boot should aim only at: ADSP up → `IPCRTR` visible → QRTR
scan shows (or doesn't) service `0x0301` → if present, NGD probes, QMI
POWER succeeds, and the bus enumerates a device whose EA matches
`[00 01 A0 00 17 02]`. Enumeration alone would confirm the codec from live
hardware without a single codec-driver line.

## 8. NGD start-path trace: three defects before the bus can ever come up

Traced against 6.16.12 source [KSRC] before building anything. The
conclusion is that an **unmodified** `qcom-ngd-ctrl` would almost certainly
sit forever on this device, and a test boot would have proved only that it
waits.

**Defect 1 — QMI service discovery can silently never match.**
`qmi_add_lookup()` packs the lookup as
`QRTR_INSTANCE(version, instance) = (instance << 8) | version`
(`qmi_interface.c:177`), and the QRTR name server's `server_match()`
(`net/qrtr/ns.c:96`) promotes any non-zero filter to an exact match:

```c
if (!ifilter && f->instance) ifilter = ~0;
return (srv->instance & ifilter) == f->instance;
```

Upstream's `SLIMBUS_QMI_SVC_V1=1, SLIMBUS_QMI_INS_ID=0` packs to **1**, so
only a server whose packed instance is exactly 1 is reported. Downstream
MSM8974 uses instance **1**, which packs to **0x101**. If the WP ADSP
follows the downstream convention, `new_server` never fires at all — which
would also defeat any QMI-arrival workaround, since such a workaround
triggers *from* `new_server`. A service-id-only lookup (`0, 0` → packed 0)
is treated as a wildcard and lets the first boot *report* the true value.

**Defect 2 — PDR failure is completely silent.** The driver
unconditionally calls `pdr_add_lookup(ctrl->pdr, "avs/audio",
"msm/adsp/audio_pd")` during probe. That call returns a valid pointer after
merely queueing a locator search (`pdr_interface.c:544`). Then:

- `pdr_locator_work()` returns early with only a `pr_debug` if
  `locator_init_complete` is false — the entry stays pending, no callback.
- `pdr_notify_lookup_failure()` **returns before** `pdr->status()` *and*
  before the `list_del` when `err == -ENXIO`, leaving the entry in the list
  with `need_locator_lookup` still true.

Either way: no UP, no error, pending forever. On 2013-era firmware with no
protection-domain infrastructure, this is the expected outcome.

**Defect 3 — `AFTER_POWERUP` is an event, not a state.**
`ssr_notify_start()` is an rproc subdevice `.start` callback
(`qcom_common.c:471`), so `QCOM_SSR_AFTER_POWERUP` fires only when the
remoteproc boots. A driver registering its notifier *after* the ADSP is
already running receives nothing. The notifier name does match (`"lpass"`
in `qcom-ngd-ctrl.c:1635` vs `.ssr_name = "lpass"` for the ADSP resource
that `qcom,msm8974-adsp-pil` binds to), so the path is wired correctly —
it is purely an ordering problem. Mainline already provides the fix:
`qcom_ssr_last_status("lpass")`, exported, documented with `"lpass"` as its
example, and used exactly this way by `drivers/soc/qcom/qcom_sns_reg.c`.

**Patch** (`pmaports`, branch `research/audio-wcd9320`,
`0001-slimbus-ngd-research-start-without-pdr.patch`): wildcard lookup +
log the discovered version/instance; start on QMI arrival; query
`qcom_ssr_last_status()` at probe for the already-booted case;
`complete()` → `complete_all()` on `qmi_up` (safe — `del_server()` already
does `reinit_completion()`, so the latch clears on service loss); an
idempotency guard on `ctrl->qmi.handle` (verified to be set only on full
success in `qcom_slim_qmi_init()` and cleared in `qcom_slim_qmi_exit()`)
so three triggers cannot double-`slim_register_controller()`; and logs
naming which trigger fired. PDR and SSR registration are left intact.

Honest scoping: items 1 and 2 are **research-only** — relaxing service
matching and starting the bus without confirming the audio PD are both
wrong on platforms that have a PD. Item 3 and the idempotency guard look
like genuine upstream fixes.

One incidental confirmation from the same trace: `qcom_slim_ngd_enable()`
calls `qcom_slim_qmi_init(ctrl, false)`, and that function sends
`req.mode = SLIMBUS_MODE_MASTER_V01` when `apps_is_master` is false — the
mode field describes the *ADSP's* role. Mainline already tells the ADSP it
is the master, which is exactly the architecture §1 establishes.

## 9. PROBE RESULT — the transport works (2026-07-29)

One boot of `boot-1520-audio-ngd-probe.img` (kernel r111, `#112`) settled it.
The ADSP had to be started by hand (see the regression below), after which:

```
remoteproc0: Booting fw image adsp.mdt, size 9280
slim-ngd: SLIM NGD: LPASS SSR AFTER_POWERUP
remoteproc0: remote processor adsp is now up
slim-ngd: SLIM NGD: QMI service 0x0301 discovered (version 1 instance 0)
                                                   at node 5 port 3
slim-ngd: SLIM SAT: Rcvd master capability
slim-ngd: SLIM controller Registered
```

Answering the seven probe questions [LIVE]:

| # | Question | Result |
|---|---|---|
| 1 | ADSP boots? | **Yes** — `state = running` |
| 2 | QRTR announces `0x0301`? | **Yes** |
| 3 | Version / instance? | **version 1, instance 0** |
| 4 | QMI select-instance succeeds? | **Yes** |
| 5 | Remote power request succeeds? | **Yes** |
| 6 | BAM initialises? | **Yes** — no DMA errors; messaging works |
| 7 | Controller registers, capabilities exchange? | **Yes** — "Rcvd master capability" |

**The APPS-to-ADSP NGD architecture is validated on this device.** The
2013 Windows Phone ADSP firmware exposes the SLIMbus satellite control
service and accepts APPS satellite control.

### Correction: the wildcard lookup was not needed

The service publishes at **version 1, instance 0**, which packs to exactly
`1` — precisely what upstream's `SLIMBUS_QMI_SVC_V1` / `SLIMBUS_QMI_INS_ID`
already request. **Upstream's exact-match lookup would have matched.** The
concern in §8 (defect 1) that downstream's `SLIMBUS_QMI_INS_ID 1` implied
a packed `0x101` did not materialise on this firmware. The wildcard change
is harmless but unnecessary, and should be dropped before this work goes
anywhere near upstream.

### Which trigger actually started the controller

`LPASS SSR AFTER_POWERUP` fired first (at 253.295), because the ADSP was
started *after* the driver had registered its notifier — the one ordering
in which the stock path works. The QMI-arrival fallback fired 6 ms later
and the idempotency guard did its job: exactly one "SLIM controller
Registered". So §8 defects 2 and 3 remain unproven *on this path* — they
would bite on a boot where the ADSP comes up before the driver probes,
which is exactly what happens when the remoteproc is built in.

### Regression found: PAS built-in loses its firmware

Making `CONFIG_QCOM_Q6V5_PAS=y` moved the ADSP probe to **t=3.08 s**, before
the rootfs is mounted:

```
remoteproc0: Direct firmware load for adsp.mdt failed with error -2
remoteproc0: request_firmware failed: -2
```

`/lib/firmware/adsp.mdt` exists (9280 bytes) but lives on the rootfs, which
the initramfs has not yet mounted. As a module it used to probe after
switch_root and worked. Fix for the next image: either revert
`QCOM_Q6V5_PAS` to `=m`, or ship the ADSP firmware in the initramfs. This
is also the boot ordering that would finally exercise defects 2 and 3.

### Cosmetic: stale modules for now-built-in code

```
qrtr: exports duplicate symbol qrtr_endpoint_post (owned by kernel)
qmi_helpers: exports duplicate symbol qmi_add_lookup (owned by kernel)
qcom_common: exports duplicate symbol qcom_add_glink_subdev (owned by kernel)
```

The eMMC rootfs still carries `.ko` files for subsystems this build makes
built-in. Harmless — the loads are rejected — and it clears when a rootfs
built from the same config is installed.

### No codec enumerated (expected)

`/sys/bus/slimbus/devices/` is empty. The bus is up and the controller is
registered, but nothing reported itself. That is the expected result with
no codec child in the DT: the WCD9320's reset line (TLMM 63) is never
driven, so the part stays in reset and never announces. Enumerating it is
the next image's job.

## 10. Open questions after this survey

| Question | Status |
|---|---|
| ~~RCG parent / divider~~ | Moot for APPS. PLL = 491.52 MHz [LIVE] for the record. |
| ~~Upstream qcom-ctrl register fit~~ | Moot — wrong driver for this SoC's role split. |
| ~~Codec identity / reset / supplies~~ | **WCD9320 confirmed**; reset TLMM 63 [DSDT]+[DS], MBHC irq TLMM 72 [DSDT], supplies from hammerhead node [DS]. |
| Does WP ADSP firmware publish QMI `0x0301`? | **The** open question. Needs one boot of a properly-configured image. |
| QMI instance id (0 vs 1) | Resolved by the same scan. |
| NGD hw version (V1 `0x800` vs V2 `0x1000` layout) | Read the NGD version register once `iface` clocking is up — not before (§3 warning). |
| Does mainline NGD power up without PDR? | Read `qcom-ngd-ctrl.c`'s up-path before building the test image. |
| BAM hardware version at `0xfe104000` | Confirm at probe time; expected v1.4-era. |

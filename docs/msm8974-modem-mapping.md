# Lumia 1520 cellular modem and calls: first mapping pass

Status: mapping, 2026-11-14. Nothing is enabled yet. This follows the audio work: the codec full duplex is done (`docs/audio/wcd9320-duplex-mapping.md`). A cellular call needs two further pieces, the modem (MSS) and the DSP voice stack. The README lists the modem as untested, and `docs/trustzone-quirks.md` asks that it be recorded as neither working nor blocked until tried.

## 1. What Windows does (the phone's ACPI DSDT)

| device | HID | what it is | resources and dependencies |
|---|---|---|---|
| `AMSS` | QCOM242C | the modem subsystem | interrupt 0x38 (GIC SPI 24); `_DEP` PEP0, SMD0, PILC, RFS0, RPEN; 8 child endpoints `QCMS\QCOM0EA0` |
| `PILC` | QCOM2429 | the subsystem image loader (`qcpil8974.sys`) | `_DEP` SCM0 (TrustZone); IMEM 0xFE805000, 0x94C long |
| `RFS0` | QCOM2423 | the remote file system, Windows' rmtfs | **0x0FD80000, 0x180000 long** and 0x0FD60000, 0x20000 long; `_DEP` IPC0 |
| `QMUX` | QCOM244F | QMI multiplexer (`qcqmux8974.sys`) | — |
| `DMUX`, `RMNT`, `RMAT`, `MBRG` | QCOM2406 / 2148 / 2155 / 2145 | the data path: BAM-DMUX and RmNet | — |

The eMMC carries the modem file-system partitions `MODEM_FS1`, `MODEM_FS2`, `MODEM_FSC` and `MODEM_FSG`. These are Android's modemst1/modemst2/fsc/fsg, under different labels. It also has `DPP` and `SSD`.

## 2. The firmware (header analysis only, never redistributed)

`MainOS/Windows/system32/` carries both images. Their ELF program headers:

| file | role | loads at | size | flags |
|---|---|---|---|---|
| `qcdsp1v28974.mbn` (238 KB) | **MBA** (modem boot authenticator) | 0x0D100000 | one segment, 0x3A254 | not relocatable |
| `qcdsp28974.mbn` (43 MB) | **modem**, 29 program headers | 0x08000000 – 0x0D100000 | **0x5100000** (81.0 MB) | not relocatable; the hash segment loads at 0x0D100000 |

## 3. Mainline already matches

`qcom-msm8974.dtsi` (upstream) and this kernel:

| item | mainline | Windows / firmware |
|---|---|---|
| `remoteproc_mss: remoteproc@fc880000`, `qcom,msm8974-mss-pil` | present on the phone, **`status = "disabled"`** | — |
| `mpss_region` | 0x08000000, 0x5100000 | the modem's span, **exactly** |
| `mba_region` | 0x0D100000, 0x100000 | the MBA (and the modem's hash segment) ✓ |
| `rmtfs@fd80000` (`qcom,rmtfs-mem`, client-id 1) | 0x0FD80000, 0x180000 | `RFS0`'s first region ✓ |
| `memory@fd60000` (reserved) | 0x0FD60000 | `RFS0`'s second region ✓ |
| the wdog interrupt | GIC SPI 24 | `AMSS` 0x38 ✓ |

**The board supplies.** The Fairphone 2 and the Nexus 5 enable the modem identically:

```
&remoteproc_mss {
	status = "okay";
	mss-supply = <&pm8841_s3>;
	mx-supply = <&pm8841_s1>;
	pll-supply = <&pm8941_l12>;
};
```

The phone has those rails up already: PM8841 S1 at 675 mV, PM8841 S3 at 1.05 V, PM8941 L12 at 1.8 V. The SoC dtsi supplies the rest: registers, clocks, reset, the CX power domain, the halt registers, smp2p, the modem SMD edge (`label = "modem"`) and the `bam-dmux` data path.

**The driver** (`qcom_q6v5_mss.c`, `msm8974_mss`):
- firmware `mba.b00` and `modem.mdt` (+ `.bNN`, the split format the ADSP already uses);
- proxy supplies pll and mx, the active supply mss, the CX power domain;
- `need_mem_protection = false`;
- **no TrustZone call on msm8974**. Its one SCM call, `qcom_scm_pas_mem_setup`, runs only for MSM8953. The Hexagon boot ROM verifies the MBA, and the MBA verifies the modem. So this TrustZone's refusals (the secondary cores, Pronto's PAS timeout) should not apply, but that is unconfirmed until tried.

## 4. What is missing

| piece | state |
|---|---|
| kernel config | `CONFIG_QCOM_Q6V5_MSS` not set; `CONFIG_QCOM_BAM_DMUX` and the WWAN control device (`CONFIG_RPMSG_WWAN_CTRL`) not set; QRTR (`=m`) and `QCOM_RMTFS_MEM` (`=y`) are |
| device tree | `&remoteproc_mss` with the three supplies |
| firmware on the phone | `mba.b00`, `modem.mdt` + `.bNN`, split from the Windows images on the device (never committed) |
| rmtfs daemon | not installed. It looks partitions up by Android's names, so the WP labels need mapping (a udev rule or a symlink) |
| QRTR userspace, ModemManager | not installed |
| **call audio** | **no `q6voice` in the tree.** The ADSP advertises MVM/CVS/CVP. postmarketOS carries an out-of-tree q6voice for MSM8916; whether it fits MSM8974 is a separate mapping |

## 5. Risks

- **The modem file systems hold this phone's calibration and identity** (NV items, IMEI). Through rmtfs the modem writes to them, and a bad write is not recoverable from anywhere else. They must be backed up, read-only and to the PC, before the modem first runs. The backups contain device identifiers: they stay private and are never committed or uploaded.
- **Device resets.** Starting Pronto on this TrustZone failed, and the follow-up probe reset the phone. A misbehaving modem start may do the same. That is harmless to hardware, but it is why every step is its own boot.
- **Firmware:** split on the phone, never committed, never redistributed.

## 6. Proposed order (each step its own go)

| step | what | changes |
|---|---|---|
| **M0** | read-only backups of `MODEM_FS1/FS2/FSC/FSG`, `DPP` and `SSD` to the PC, with checksums | nothing on the phone |
| **M1** | split the two images into `/lib/firmware/mba.b00`, `modem.mdt` and `.bNN` on the phone (`tools/pil-split.py`) | phone rootfs only |
| **M2** | kernel: `QCOM_Q6V5_MSS=m` (a module, so nothing starts before rmtfs is ready), `QCOM_BAM_DMUX`, the WWAN ctrl; DT: `&remoteproc_mss` with the supplies | a kernel build |
| **M3** | first start, by hand, with rmtfs not yet running: MBA up, modem authenticated, then the modem waiting on its file system. Watch for resets | one boot |
| **M4** | rmtfs with the WP partition names (read-only first if the daemon allows), then a full start | packages, udev |
| **M5** | QRTR, ModemManager: the SIM, network registration, SMS, data over bam-dmux | packages |
| **M6** | call audio: map and port q6voice (modem MVM ↔ ADSP CVS/CVP ↔ AFE SLIMBUS_0_RX/TX, with r201's duplex) | kernel |

## 7. M0 done (2026-11-14): read-only backups taken

- **What was copied:** `MODEM_FS1`, `MODEM_FS2`, `MODEM_FSG` (1.5 MB each), `MODEM_FSC` (16 KB), `DPP` (8 MB) and `SSD` (16 KB). None was mounted, and nothing was written to the phone.
- **Verification:** each copy matched a SHA-256 taken on the phone right after the copy. A second read of every partition matched its backup, so nothing writes them while the modem is off. The copy verifies against its checksum file.
- **Contents:** the three modem file systems are full of data (0.4 % zero bytes). `DPP` is 92 % zero, `SSD` 87 %, `MODEM_FSC` almost all zero.
- **Where the backups are:** private, on the PC, outside the repository. They hold this phone's identifiers and are never committed or uploaded. Restoring is a `dd` of each image back to its partition label.

**There is no SIM and no service for this phone.** Steps M1–M4 (the modem starts and serves its file system) and the QMI part of M5 (the modem is visible, IMEI and firmware readable, no-SIM state) can be done. Network registration and real calls cannot. M6, call audio, can be built, but end-to-end it can only be proven with a network. Emergency numbers are never to be dialled as a test.

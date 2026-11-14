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

## 8. M1 and M2 done (2026-11-14)

**M1, the firmware on the phone.**
- `mba.b00` is the MBA's single segment, 238 164 bytes; it runs at 0x0D100000.
- `modem.mdt` (b00 + the hash segment, 10 112 bytes) and `modem.b00`–`b28` (43.4 MB in all) come from `tools/pil-split.py`.
- All 31 files were copied as one tar and checksum-verified in `/lib/firmware`.

**M2, r203 (pkgrel 203).** A device-tree-only change: `&remoteproc_mss` okay, with the three supplies.
- `dtc` printed no new warnings (the same 14 as before). Verifier 742/0; build gate 746/0.
- The audio gates on r203: digital 83/0, MCLK ownership 90/0, vm 57/0, cache 0 mismatches. The modem node changes nothing for audio.

**One more problem on the way: stale modules on the phone.**
- The build script installs only the audio modules. The rest of `/lib/modules` comes from the original rootfs install, built when `qcom_common`, `qcom_q6v5`, `qcom_pil_info`, `qcom_q6v5_pas`, `qmi_helpers`, `qrtr` and `qrtr-smd` were modules. The current config builds them all in.
- So the phone's old `qcom_q6v5_mss.ko` wanted those modules, and `depmod`, which cannot see built-in symbols without System.map, kept that dependency even for the new module. The load failed with `qcom_common: exports duplicate symbol qcom_add_glink_subdev (owned by kernel)`.
- **Fix, on the phone:** `qcom_q6v5_mss`, `qcom_bam_dmux` and `rpmsg_wwan_ctrl` were installed from the r203 package (their dependencies are built-ins only), with the old files kept. The seven now-built-in stale files were moved aside (none was loaded), and `depmod` was re-run.
- **Result:** `modprobe qcom_q6v5_mss` binds, and **`remoteproc1` (`fc880000.remoteproc`) is `offline` with firmware `mba.b00`**. The modem does not start by itself.
- **For the future:** after a config change that moves code into or out of the kernel, compare the phone's module tree with the package's.

## 9. M3 result (2026-11-14): the Windows Phone images are SSD-encrypted

**The first start** (`tools/msm8974-modem-start.sh`; recovery off; no rmtfs) failed safely, with no reset:

```
remoteproc remoteproc1: Booting fw image mba.b00, size 238164
qcom-q6v5-mss fc880000.remoteproc: PBL returned unexpected status -283311616   (0xef1d0200)
remoteproc remoteproc1: Boot failed: -22
```

**Why: the MBA is encrypted.** Its single segment does not begin with an MBN signing header but with Qualcomm **SSD** ("Secure Software Download") metadata:

```
<?xml version="1.0" encoding="UTF-8"?> <SSD_METADATA> <MD_SIGN> <MD_VERSION>2.0</MD_VERSION>
<MFG_ID>Nokia</MFG_ID> ... <IMG_ENC_ALGO>AES-128-ENCRYPT</IMG_ENC_ALGO> ... <IMG_ENC_OPERATION_MODE>CBC_MODE</IMG_ENC_OPERATION_MODE>
<IEK_ENC_ALGO>RSA-2048</IEK_ENC_ALGO> <IEK_ENC_PUB_KEY_ID>0iWmeuUN…</IEK_ENC_PUB_KEY_ID> ...
<MD_SIG_ALGO>RSA-2048</MD_SIG_ALGO> <MD_SIG_DGST_ALGO>SHA-256</MD_SIG_DGST_ALGO> ...
```

- **The scheme:** the image is AES-128-CBC. Its key is RSA-wrapped to a key only the device's TrustZone holds. The metadata is signed with the OEM key, and the payload's entropy is 7.997 bits/byte.
- **What the PBL saw:** it was handed ciphertext, so its status is an error, not a stale register.
- **Windows' loader** (`qcpil8974.sys`: `PIL_MSA_LOAD_STATE_MBA`, `scm_api.c`, `_DEP` on `SCM0`) does the decryption through TrustZone first.

**The modem is encrypted the same way.**
- Every code segment has entropy 7.999 and no readable text.
- The plaintext hash segment (`b01`) carries the signed MBN header (certificates from "Nokia Windows Bootloader Trustroot CA"). It is followed by 1 764 bytes of SSD metadata with the same image-key ID; the metadata is signed with OEM key `P8stssAu…`.

**So is the ADSP, and it boots.**
- `adsp.b01` ends in SSD metadata, and its code segments have entropy 7.999.
- It starts through PAS (`qcom_scm_pas_auth_and_reset`). So this TrustZone decrypts SSD images itself when it authenticates them through PAS.

**What this means.** Mainline's msm8974 modem driver uses the self-authenticating MBA path. That path bypasses TrustZone, so it cannot run these images unchanged (section 3's "no TrustZone call" was true of the driver, not of what these images need). Two ways forward:

1. **PAS (preferred: the ADSP's proven path).** Give `modem.mdt` to TrustZone (`pas_init_image`, `mem_setup`, `auth_and_reset`) and let it decrypt, authenticate and start the modem, with no Linux-loaded MBA.
   - This works only if this TrustZone supports PAS for the modem.
   - Downstream PAS ids: modem 0, Q6/ADSP 1 (the one in use), modem SW 4, modem FW 5, WCNSS 6.
   - `qcom_scm_pas_supported(id)` asks TrustZone without side effects.
2. **SSD from Linux.** Use TrustZone's SSD service (protect keystore, parse metadata, decrypt fragments; open-source reference: Qualcomm LK `platform/msm_shared/scm.c`) to decrypt the MBA and the modem segments, then take the normal MBA path. This is more work, and it may need the keystore from the `SSD` partition loaded first.

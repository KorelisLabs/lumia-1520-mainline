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

## 10. r204 (pkgrel 204): the PAS support probe, staged 2026-11-14

- **What it is:** patch 0006 adds `qcom_pas_probe` (`CONFIG_QCOM_PAS_PROBE=m`, default off). When loaded by hand, it asks `qcom_scm_pas_supported()` about PAS ids 0–15 and logs one line per id; the summary is in `/sys/module/qcom_pas_probe/parameters/result`.
- **The ids:** the ADSP's id 1 is the positive control (mainline's PAS driver already asks for it, and the ADSP runs). 0, 4 and 5 are the modem candidates.
- **A pure query:** nothing is loaded, authenticated, reset or assigned.
- **The runner:** `tools/msm8974-pas-probe.sh` loads it once from the tools directory. It is never installed in `/lib/modules`, so nothing autoloads it.
- **Checks:**
  - The patch was generated against the package's own source tarball and dry-run-applies to it.
  - The module compiles `W=1` clean.
  - Both APKBUILDs list 0006 with computed sums, and the three config copies agree.
  - Verifier 742/0. The codec module is unchanged (`quietlog-rc1`).
- **What the answer decides:**
  - If the modem ids are supported, the next step is a PAS description of the modem (TrustZone decrypts, authenticates and starts it, as for the ADSP).
  - If none is, the SSD route of section 9.

## 11. The PAS probe's answer (r204, 2026-11-14): no PAS for the modem

`tools/msm8974-pas-probe.sh` (`qcom_pas_probe`, loaded once and unloaded; nothing started):

```
qcom_pas_probe: PAS id  1: SUPPORTED      (ADSP -- the positive control)
qcom_pas_probe: PAS id  6: SUPPORTED      (WCNSS)
qcom_pas_probe: PAS id  7: SUPPORTED      (secure app)
qcom_pas_probe: PAS id  9: SUPPORTED      (video)
qcom_pas_probe: 4 of 16 ids supported (supported: 1 6 7 9)
```

- **Ids 0, 4 and 5 (the modem candidates) and every other id: not supported.**
- **So the modem cannot be booted through PAS on this TrustZone.** It has to take the MBA (MSA) path, as Windows' `PIL_MSA_LOAD_STATE_MBA` says, with the SSD decryption done through TrustZone first.
- **For later:** WCNSS (6) and video (9) are PAS-supported. That fits Pronto's `auth_and_reset` succeeding before its ready timeout, and it matters for hardware video decoding.

**Next: map the SSD route.**
- **The interface:** TrustZone's SSD service. Qualcomm's open-source LK (`platform/msm_shared/scm.c`) carries the calls: protect the keystore, parse the metadata, decrypt image fragments. Windows' `qcpil8974.sys` can confirm the ids (analysis only).
- **The keystore:** where it comes from. The 16 KB `SSD` partition, backed up in M0, is the candidate, which is what LK loads.
- **The Linux shape:** decrypt the MBA and each modem segment in place before the normal MSA path. That means new `qcom_scm` SSD calls and a decrypt step in the MSS loader; physically contiguous buffers are handed to TrustZone.

## 12. The SSD route, mapped (2026-11-14)

### The TrustZone interface (service 0x07, legacy 32-bit calls)

Taken from Qualcomm's LK in lk2nd (`platform/msm_shared/scm.c`, `include/scm.h`, `target/msm8974/init.c`) and confirmed in Windows' `qcpil8974.sys` (analysis only). Windows builds the same legacy command buffers, `{len, buf_offset, resp_hdr_offset, id}` + request + response:

| call | id (`svc<<10 \| cmd`) | request (32-bit words) | response | LK | Windows |
|---|---|---|---|---|---|
| protect keystore | 0x1C05 | `{keystore_ptr, keystore_len}` | `{status}` | yes, msm8974 reads 8 KB of `ssd` | **never** |
| parse metadata | 0x1C06 | `{md_len, md_ptr}` | `{status, md_ctx_id, md_end_ptr}` | yes | yes (len 0x30, req 0x10, resp 0x18) |
| decrypt image fragment | 0x1C07 | `{md_ctx_id, last_frag, frag_len, frag_ptr}` | `{status}` | yes | yes (req 0x10..0x20) |
| decrypt ELF segment fragment (name inferred) | 0x1C08 | **6 words** (req 0x10..0x28) | `{status}` | no | yes |

- **Parse metadata** is called with a growing `md_len`: 128, then doubled while TrustZone answers `SSD_PMD_PARSING_INCOMPLETE` (6). It answers `SSD_PMD_ENCRYPTED` (0) with a context and a pointer to the end of the metadata, where the ciphertext starts.
- **Decrypt** works in place.
- **The other status codes:** not encrypted 1, no metadata 3, busy 4, bad pointer 5, parsing failed 7, cipher setup failed 8.

**0x1C08.** Windows picks it in place of 0x1C07 when a flag on the image object is 1, which is most likely "an ELF image" (the modem); the flat MBA takes 0x1C07. Its 6 words, from the disassembly:
- word 0: the context id;
- words 4 and 5: the fragment length and address, as for 0x1C07;
- word 1: a third field of the fragment descriptor (probably the segment number);
- word 2: the caller's last argument (probably a last-segment or last-fragment flag);
- word 3: not written by that function.

No public header defines it: the downstream `smcmod.h` has only the metadata and image-fragment requests, which match LK. Pinning its exact semantics needs a look at its callers in `qcpil8974.sys`, or an experiment.

### The keystore is already in TrustZone

- The MBA, the modem and the ADSP all carry the same image-key id (`0iWmeuUN…`) and the same signing key (`P8stssAu…`).
- TrustZone decrypts the ADSP under Linux today, so it already holds that key. The Windows Phone UEFI presumably protects the keystore at boot, and Windows never sends 0x1C05.
- The `SSD` partition (backed up in M0, private) is a 2 128-byte keystore blob: version word 1, then ciphertext. It should not be needed.

### Clocks

The SSD service uses crypto engine 1. The msm8974 `scm` node already lists `GCC_CE1_CLK`, `GCC_CE1_AXI_CLK` and `GCC_CE1_AHB_CLK`, and `qcom_scm.c`'s `qcom_scm_clk_enable()` / `qcom_scm_bw_enable()` switch them on around the PAS calls. So the SSD calls belong in `qcom_scm.c`, written like `qcom_scm_pas_init_image()`: a physically contiguous DMA buffer, clocks and bandwidth on, the call, off. A legacy response carries up to 3 words, exactly parse-metadata's.

### Proposed experiments

| step | what | proves |
|---|---|---|
| **E1** | patch: `qcom_scm_ssd_parse_md()` and `qcom_scm_ssd_decrypt_img_frag()` in `qcom_scm.c`, and a default-off probe that decrypts `mba.b00` in a DMA buffer and reports **structure only** (TrustZone's status codes, the metadata and payload lengths, whether the plaintext starts with an MBN header loading at 0x0D1xxxxx and carries a DER certificate chain). No plaintext leaves kernel memory | TrustZone does SSD for Linux; the MBA decrypts |
| **E2** | the MSS loader decrypts the MBA before loading it | the MBA boots ("MBA booted ..., loading mpss") |
| **E3** | pin 0x1C08 (its callers in `qcpil8974.sys`, or an experiment) and decrypt each modem segment before loading | the modem authenticates and starts |
| then | M4 (rmtfs), M5 (QMI without a SIM) | |

## 13. E1 result (r205, 2026-11-14): TrustZone decrypts the MBA for Linux

`tools/msm8974-ssd-probe.sh` loaded `qcom_ssd_probe` once. The phone did not reset, the modem stayed offline, and the buffer was wiped:

```
parse_md(len 128)  -> ret 0 status 6        (incomplete; also at 256, 512, 1024)
parse_md(len 2048) -> ret 0 status 0 ctx 1 md_end = buffer + 0x6e4
metadata 1764 bytes, ciphertext 236400 bytes (a multiple of 16)
decrypt_img_frag(ctx 1, last 1, len 236400) -> ret 0 status 0
```

The plaintext is a genuine image:
- 61 506 of 236 400 bytes are zero (the ciphertext was uniform), and it carries 2 DER certificates.
- Its first words are the **80-byte header the boot ROM loads**: codeword `0x844BDCD1`, magic `0x73D71034`, two reserved `0xFFFFFFFF`, image offset `0x50`, destination `0xFCC08000` (the Hexagon's internal memory), image size `0x39B20`, code size `0x38220`, then the signature and certificate pointers.
- The probe printed those under 40-byte header names, so its labels are off; the values are what matter.

**So the SSD route works:** this TrustZone parses and decrypts Nokia's images on Linux's behalf, using the key it already holds, and the decrypted MBA is in the boot ROM's own format.

**E2, next:** in `qcom_q6v5_mss`, recognise an SSD MBA (`<?xml` at its start), have TrustZone decrypt it in the MBA region (parse at `mba_phys`, decrypt at `md_end`), move the plaintext down to `mba_phys`, then boot it. (As staged in r206, it decrypts in a DMA buffer instead: section 14.)
- **Expected:** "MBA booted …, loading mpss". The encrypted modem segments will then fail authentication, which is E3's job (0x1C08).

## 14. r206 (pkgrel 206): E2 staged, 2026-11-15

Patch 0008 changes `q6v5_load()` in `qcom_q6v5_mss`. On MSM8974, an MBA that starts with `<?xml` is SSD-encrypted and goes through `q6v5_mba_ssd_load()`; any other MBA loads exactly as before.

It decrypts in a DMA buffer, not in the MBA region as section 13 first planned. That is the path E1 proved: the same buffer type, the same growing `parse_md` and the same single-fragment decrypt. It avoids handing TrustZone a no-map carveout it has never been shown.

Before anything goes to the MBA region, the plaintext must be a boot-ROM image:

- codeword `0x844BDCD1` and magic `0x73D71034`;
- the image at offset 80;
- its size within the payload.

Otherwise the load fails with an error and nothing is copied. If it passes, the plaintext is copied to the start of the region, and the buffer is zeroed and freed either way. On success the log line is `SSD MBA: decrypted by TrustZone (metadata N bytes, image N bytes)`.

The run uses `tools/msm8974-modem-start.sh`, as M3 did: recovery off, one start, stop. Expected results:

- **E2 passes** if the log shows `MBA booted without debug policy, loading mpss`.
- **What follows then:** the modem image is still encrypted (E3), so the MBA should reject it ("MPSS header authentication failed" or "MPSS authentication failed"), the driver reclaims, and the modem stays offline.
- **Worst case:** a phone reset.

## 15. E2 result (r206, 2026-11-15): the decrypted MBA boots

`tools/msm8974-modem-start.sh` ran once on r206 with recovery off. The log:

```
remoteproc remoteproc1: Booting fw image mba.b00, size 238164
qcom-q6v5-mss fc880000.remoteproc: SSD MBA: decrypted by TrustZone (metadata 1764 bytes, image 236400 bytes)
qcom-q6v5-mss fc880000.remoteproc: MBA booted without debug policy, loading mpss
qcom-q6v5-mss fc880000.remoteproc: MPSS authentication failed: -19
remoteproc remoteproc1: Boot failed: -19
```

- **Decrypt:** 185 ms from "Booting" to the decrypt line.
- **MBA boot:** the boot ROM accepted the decrypted MBA, and it reported XPU unlocked 89 ms later. E2 passes.
- **The MPSS header passed:** there was no "MPSS header authentication" error. So the MBA accepted the signed ELF headers and hash table from `modem.mdt` as they are: the hash segment and its signature are not encrypted, or are not checked encrypted.
- **Then the segments failed:** the MBA's status register went to -19 during the segment loop, not at the final wait. The failure came 156 ms after the MBA booted, far too soon for all 0x5100000 bytes to have been copied. So the MBA hashes each segment as it arrives and rejected the first loaded one. The segments are still SSD ciphertext, and the hashes are presumably over the plaintext.
- **Afterwards:** the driver reclaimed, and the modem went back to offline. There was no reset and no new kernel warning, and recovery was restored.

**E3, next:** decrypt the modem segments before they are copied, with TrustZone's ELF-segment call 0x1C08 (section 12). Its arguments are not public. Map them from the callers in Windows' `qcpil8974.sys` before building anything. The metadata to parse first is at the tail of hash segment b01 (section 9).

## 16. E3 mapped (2026-11-15): TrustZone call 0x1C08 and how Windows decrypts the modem

From the disassembly of Windows' `qcpil8974.sys` (analysis only; nothing from it is committed). The addresses are the driver's virtual addresses, image base 0x400000.

### The call chain

| function | role |
|---|---|
| 0x4041c4 | modem load state: loads the image (0x40888c, 0x408fec), **then** the SSD pass (0x406198), then the MBA steps |
| 0x403ea4 | MBA load state: the same order, flat image |
| 0x406198 | SSD pass: finds the metadata (0x4060d8), builds the segment list (0x405f88), runs 0x407a30 |
| 0x407a30 | SSD driver logic: SCM clocks on, parse metadata (0x4077b4), decrypt (0x4073f4) per list entry, clocks off |
| 0x4073f4 | fills the decrypt request: 0x1C07 for a flat image, 0x1C08 for ELF (image flag at +8 == 1) |
| 0x4063c8 | SCM command-buffer header per call id |

### Parse metadata (0x1C06)

- **Flat MBA:** metadata = {first segment's address, its size}. The XML is at the start.
- **ELF modem:** metadata = {the **hash segment's** `p_paddr`, its `p_filesz`}: the whole hash segment, with the XML at its tail (here +0x1cc8 of 0x23ac, 1764 bytes).
- **One call with the full length, no growing loop:** TrustZone finds the metadata within the buffer itself. The call is retried only while the status is 4 (busy), up to 5 times.
- **Status 0** = encrypted: go on. **1** (not encrypted) and **3** (no metadata) = skip decryption and load as is. Anything else is an error.

### Decrypt ELF segment (0x1C08)

The command header is {len 0x38, request at 0x10, response at 0x28}: 6 request words, then the legacy 3-word response header and one status word. The request:

| word | value | source |
|---|---|---|
| 0 | metadata context id | from parse metadata |
| 1 | segment index | list node |
| 2 | last segment: 1 on the final list entry, else 0 | 0x407a30 |
| 3 | 1 | preset by the header builder, never overwritten (last fragment: each segment goes as one fragment) |
| 4 | length = `p_filesz` | list node |
| 5 | address = `p_paddr`, the segment **in place** in the modem region | list node |

- **Response:** status 0 = success.
- **Same pattern for 0x1C07:** the header builder presets `last_frag` = 1 there too, and Windows never sends anything else, as E1/E2 did.

**The segment list** (0x405f88) walks the program headers:
- **Index:** every `PT_LOAD` that is not the hash segment (Qualcomm type 2 in `p_flags` bits 24-26) advances it from 0.
- **List entry:** only segments with a nonzero `p_vaddr` and `p_filesz` get one.
- **For this modem:** the index is phdr − 2. Entries are 0-3, 6, 8-9, 11-20 and 23-25 (20 segments); phdr 27 (index 25) carries the last flag.
- **Skipped:** the empty phdrs 6, 7, 9, 12 and the bss-only 23, 24, 28.

**On a failure,** 0x407a30 sends 0x1C07 with length 0, address 0 and last 1 on the same context, presumably to release it.

### What this means for Linux (E3 design)

Windows decrypts every segment before the MBA hashes it. Mainline's `q6v5_mpss_load()` streams instead: after each segment it raises `RMB_PMI_CODE_LENGTH`, and the MBA hashes as it goes (E2's -19 came on the first segment). So E3 slots into that loop:

1. **Before the loop:** if the hash segment in `modem.mdt` carries SSD metadata, copy it into a DMA buffer (E1's buffer type) and call parse metadata once with its full length (retry on busy) to get the context. Keep the buffer until the last segment is done.
2. **For each segment with data, after it is copied into the modem region and before the code length is raised:** 0x1C08 {ctx, Windows index, last, 1, `p_filesz`, the segment's physical address}, in place, exactly as Windows does.
3. **On any failure:** release the context (0x1C07 with length 0, address 0, last 1) and fail the load.
4. **Calls:** a new `qcom_scm_ssd_decrypt_elf_seg_frag()` in `qcom_scm.c` beside the E1 pair, with the same clocks and bandwidth.

**Expected:** the MBA authenticates the plaintext segments, and the driver waits for the modem's start. With no rmtfs running (M4), the modem may then wait or crash over its file systems. That is safe: only the rmtfs daemon writes the `MODEM_FS*` partitions, and recovery is off for the run.

## 17. r207 (pkgrel 207): E3 staged, 2026-11-15

**Patch 0009** builds section 16's design:

- **`qcom_scm_ssd_decrypt_elf_seg_frag()`** (svc 7, cmd 8, six words).
- **`q6v5_mpss_ssd_begin()`:** runs after the MBA accepts the headers. It copies the hash segment from `qcom_mdt_read_metadata()` into a DMA buffer and parses it once over its full length, retrying while TrustZone is busy.
- **`q6v5_mpss_ssd_segment()`:** for each segment with data, after the copy and before `RMB_PMI_CODE_LENGTH`, it decrypts the segment in place at `mpss_phys + offset`. The index and last flag are Windows', and a `wmb()` goes before the call.
- **`q6v5_mpss_ssd_end()`:** on every exit it releases an unfinished context with an empty 0x1C07 and frees the buffer.

An MDT whose hash segment carries no SSD metadata, or that TrustZone reports as unencrypted, loads as before.

**Checks:** generated on top of 0007 and 0008, and 0006-0009 apply in order on the package's sources. `qcom_scm.c` and the driver compile W=1 clean.

**New log lines:**
- `SSD MPSS: metadata parsed (context N, at +0x1cc8 of the 9132-byte hash segment)`
- `SSD MPSS: decrypted by TrustZone (20 segments)`
- on a failure: which segment, TrustZone's status, and the release of the context.

**The run** (same runner):

| outcome | what it means |
|---|---|
| **E3 passes** | no "MPSS authentication failed", and the remoteproc reaches `running` |
| fails at the first segment | TrustZone could not reach the modem region, or the index or flag conventions are off. The status says which |
| fails at the final wait | the MBA rejected the image as a whole |

Without rmtfs, a running modem may then crash over its file systems. Recovery is off, and nothing writes `MODEM_FS*`.

## 18. E3 result (r207, 2026-11-15): the modem boots on Linux

`tools/msm8974-modem-start.sh 30` ran once on r207, with recovery off and no rmtfs:

```
remoteproc remoteproc1: Booting fw image mba.b00, size 238164
qcom-q6v5-mss fc880000.remoteproc: SSD MBA: decrypted by TrustZone (metadata 1764 bytes, image 236400 bytes)
qcom-q6v5-mss fc880000.remoteproc: MBA booted without debug policy, loading mpss
qcom-q6v5-mss fc880000.remoteproc: SSD MPSS: metadata parsed (context 1, at +0x1cc8 of the 9132-byte hash segment)
qcom-q6v5-mss fc880000.remoteproc: SSD MPSS: decrypted by TrustZone (20 segments)
remoteproc remoteproc1: remote processor fc880000.remoteproc is now up
remoteproc remoteproc1: stopped remote processor fc880000.remoteproc        (30 s later, by the runner)
```

- **Decrypt:** TrustZone found the metadata exactly where section 16 put it, and decrypted all 20 segments in place in 1.6 s.
- **Start:** the MBA authenticated the plaintext and started the modem.
- **Running:** it stayed `running` for the whole 30 s watch. There was no fatal error, watchdog or crash, even without rmtfs.
- **New SMD channels on `remoteproc1`:**
  - `IPCRTR`: QRTR, the transport QMI services run over (M5);
  - `SSM_RTR_MODEM_APPS`.
- **Stop:** clean, back to offline. Recovery was restored, and there were no new kernel warnings.
- **The partitions are untouched:** `MODEM_FS1/FS2/FSC/FSG`, `DPP` and `SSD` still hash identical to the M0 backup, read back after the run.

**Correction to sections 16-17:** Windows' list for this modem has 20 entries (indices 0-3, 6, 8-9, 11-20, 23-25), not 17. The driver follows the rule, not the count.

**The modem route is open:** the MBA and modem decrypt and boot on mainline, on the stock Windows Phone firmware.

**Next:**
- **M4, rmtfs:** serve `MODEM_FS1/FS2/FSC/FSG` to the modem. Read-only first, so EFS can be read while the partitions stay byte-identical.
- **M5:** the QMI services over QRTR without a SIM: device ids, firmware version, operating mode, and the SIM-absent state.

## 19. M4 mapped (2026-11-15): rmtfs on the WP partitions, read-only

### What Windows does

WP's `qcremotefs8974.sys` (MainOS `system32\DRIVERS`, analysis only) registers the QMI remote-storage service, `qmi_rmtfs_register_service`. It serves exactly four paths and finds their partitions by walking the GPT (`EFI PART`, `\Device\Harddisk0\Partition0`, `PartitionNum`):

```
/boot/modem_fs1   /boot/modem_fs2   /boot/modem_fsc   /boot/modem_fsg
```

The partitions carry Qualcomm's standard type GUIDs, so their roles are certain:

| WP label | device | type GUID | Qualcomm role |
|---|---|---|---|
| `MODEM_FS1` | mmcblk0p3, 1.5 MiB | `ebbeadaf-22c9-e33b-8f5d-0e81686a68cb` | modemst1 |
| `MODEM_FS2` | mmcblk0p4, 1.5 MiB | `0a288b1f-22c9-e33b-8f5d-0e81686a68cb` | modemst2 |
| `MODEM_FSC` | mmcblk0p5, 16 KiB | `57b90a16-22c9-e33b-8f5d-0e81686a68cb` | fsc |
| `MODEM_FSG` | mmcblk0p2, 1.5 MiB | `638ff8e2-22c9-e33b-8f5d-0e81686a68cb` | fsg |

The driver also runs **RFSA**, a file service for the modem and ADSP rooted at `C:\Program Files\Qualcomm\RFSA\{MPSS,aDSP}\`. That directory is not on MainOS: it lived on the old Data partition, which is now postmarketOS's root, so the modem's runtime files there are gone. rmtfs does not serve RFSA. E3's modem ran 30 s without it or rmtfs. M4 will show whether the modem asks for it.

### The Linux side

**Kernel, already in place:**
- `CONFIG_QCOM_RMTFS_MEM=y`: `rmtfs@fd80000` (0x180000, client id 1, matching WP's `RFS0`) is `/dev/qcom_rmtfs_mem1`.
- `CONFIG_QRTR=y` / `QRTR_SMD=y`, with the in-kernel name service. E3 brought up the modem's `IPCRTR` channel.

**Userspace (not installed; the phone has no internet):**
- `rmtfs` 1.3: 12 235 bytes, needs `libqrtr` + `libudev`. `libudev` is present.
- `qrtr-libs` 1.2: 6 951 bytes.
- `qrtr` 1.2: 7 242 bytes, for `qrtr-lookup`, which lists the modem's QMI services (M5).

These are in the phone's configured repositories (postmarketOS edge / Alpine edge).

**rmtfs 1.3** (upstream source, `linux-msm/rmtfs`):

- **Path table:** the same four paths, to partlabels `modemst1`, `modemst2`, `fsc` and `fsg`. An unknown path is rejected with an error to the modem.
- **Partition lookup:** `-P -o <dir>` opens `<dir>/<partlabel>`, case-sensitively, with no fallback. So the WP labels need no renaming: a directory of four symlinks maps them.
  ```
  /run/rmtfs-parts/modemst1 -> /dev/disk/by-partlabel/MODEM_FS1
  /run/rmtfs-parts/modemst2 -> /dev/disk/by-partlabel/MODEM_FS2
  /run/rmtfs-parts/fsc      -> /dev/disk/by-partlabel/MODEM_FSC
  /run/rmtfs-parts/fsg      -> /dev/disk/by-partlabel/MODEM_FSG
  ```
- **`-r` read-only:** never opens a partition for writing. Each open reads the partition into an in-memory shadow, the modem's writes go into the shadow so it reads back what it wrote, and the shadow is discarded on close. The disk is never written.
- **Startup:** writes nothing until the modem asks. It publishes QMI service 14 (version 1, instance 0) over QRTR.
- **Not used:** `-s` would let rmtfs start and stop the remoteproc itself. The runner keeps doing that, as in E3.

### The M4 run (proposed)

`tools/msm8974-rmtfs-start.sh`, one run, with recovery off as in E3:

1. **Preflight:** the four partitions and `DPP`/`SSD` are hashed on the phone, and the modem must be offline.
2. **Start:** make the symlink directory and start `rmtfs -r -P -o /run/rmtfs-parts -v` in the background, logging to a file. Wait for its QMI service to be published, then start the modem.
3. **Watch:** N seconds. Record which paths the modem opens, the reads and shadowed writes per file, the services `qrtr-lookup` lists, and any RFSA request.
4. **Stop:** stop the modem, then rmtfs. Hash the partitions again; they must be identical.

**Passes if:** the modem opens and reads `/boot/modem_fs1`, `fs2`, `fsc` and `fsg`, stays running, and every partition hash is unchanged.

**Then:** M5, QMI without a SIM over the services the modem publishes. Write-enabling rmtfs is a separate decision for later, made only once the EFS traffic is understood. The M0 backup is the fallback.

**Prepared (2026-11-15):**
- **Packages:** `qrtr-libs` 1.2-r1, `qrtr` 1.2-r1 and `rmtfs` 1.3-r0, fetched on the PC from Alpine edge `community` (sizes match the index). Installed with `apk add --no-network` and their signatures verified against the phone's keys. No service is installed or enabled (`rmtfs-systemd` not pulled in).
- **QRTR check:** `qrtr-lookup` already lists the ADSP's 12 services on node 5.
- **The runner:** `tools/msm8974-rmtfs-start.sh [watch-seconds]`. Exit codes: 0 pass, 1 not, 2 refused, **3 a partition changed**.

## 20. M4 result (2026-11-15): the modem reads its EFS through rmtfs; partitions unchanged

`tools/msm8974-rmtfs-start.sh 60` ran once on r207. rmtfs ran read-only, and recovery was off.

**What the modem asked for**, from the rmtfs log:

```
open /boot/modem_fs1 => 0      open /boot/modem_fs2 => 1
open /boot/modem_fsg => 2      open /boot/modem_fsc => 3
alloc 0, 1572864 => 0xfd80000            (the whole RFS0 carveout)
iovec 0: read 1:1      iovec 1: read 1:1  (the header sector of FS1, then of FS2)
iovec 1: read 2:3070                      (all of FS2: the newer EFS copy)
iovec 0: write 0:3072                     (a full EFS sync to FS1, the alternate copy: held in rmtfs's shadow, never on disk)
```

- **Requests:** only the four expected paths. There were no unknown-path requests, no RFSA request and no errors.
- **The EFS ping-pong:** the modem picked FS2 by its header and wrote its sync to FS1, the standard Qualcomm alternation. Read-only mode absorbed the write.
- **The modem's 13 QMI services on QRTR (node 0):** subsystem control 43, test 15, thermal 23/24, time 22, persistent device config 36, coexistence 34, SAR 17, QCHAT 13, RF performance 41, location 16 v2, data system determination 42, sensor manager 256.
- **The SMD channels:** `DATA1-4/12-16/23-26/40` (+`_CNTL`), `DIAG*`, `sys_mon`, `IPCRTR`, `SSM_RTR_MODEM_APPS`, and **`apr_voice_svc`**: the voice path for M6.
- **The modem control ports:** `rpmsg_wwan_ctrl` attached `wwan0at0`, `wwan0at1` and **`wwan0qmi0`**. The core QMI services (DMS, NAS, WDS, UIM, VOICE) go over QMUX on that port, not QRTR, as on other MSM8974 phones.
- **Running:** the modem stayed `running` for the full 60 s and stopped cleanly. rmtfs stopped, and the links were removed.
- **The six partitions** (MODEM_FS1/FS2/FSC/FSG, DPP, SSD) **hash identical before and after.**

**M4 passes** (read-only).

**Next, M5:** QMI over `/dev/wwan0qmi0` with `qmicli` (libqmi), without a SIM: device revision and capabilities, operating mode, card status (absent), and serving system (no service).
- **Identifiers stay private:** IMEI, MEID and serial numbers are never logged in the repo.
- **rmtfs:** stays read-only for M5.
- **Write-enabling EFS** stays a separate decision. The modem would rewrite the whole alternate 1.5 MiB copy on each sync.

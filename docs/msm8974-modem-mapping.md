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

## 21. M5 prepared (2026-11-15): QMI over wwan0qmi0, read-only, identifiers redacted

**Packages:** fetched on the PC from Alpine edge `community` (sizes match the index), installed with `apk add --no-network`, signatures verified. glib was already present, and no service is installed or enabled.

| package | version |
|---|---|
| `qmi-utils` (`qmicli` 1.39.1) | 1.38.0_git20261005-r0 |
| `libqmi` | 1.38.0_git20261005-r0 |
| `libmbim` | 1.34.0-r1 |
| `libqrtr-glib` | 1.4.0-r0 |
| `libgudev` | 238-r1 |

**The runner:** `QMI_PROBE=1 sh tools/msm8974-rmtfs-start.sh 60`. It is the M4 runner, so rmtfs stays read-only and all six partitions are hashed before and after. Once the modem is running and `/dev/wwan0qmi0` exists, it runs these queries:

- **CTL:** `--get-service-version-info`
- **DMS:** manufacturer, model, revision, capabilities, band capabilities, operating mode, power state
- **IDs:** `--dms-get-ids`
- **UIM:** card status
- **NAS:** system selection preference, serving system, signal strength
- **VOICE:** config
- **WDS:** packet service status

Every query is a `get`, so nothing is set and the operating mode is not changed.

**Identifiers never reach the log:**
- `--dms-get-ids` is reduced on the phone to "present, N chars" per field.
- Every other answer passes a filter that blanks the quoted values on IMEI/ESN/MEID/serial/ICCID/IMSI/MSISDN/EID lines, and masks any run of 14+ digits.
- Both filters were tested with made-up values on busybox.

**Passes if:** M4 passes again and the modem answers the CTL service-version query on `wwan0qmi0`. The other answers are evidence for M5's status: the SIM should be absent and the network should show no service.

## 22. M5 result (2026-11-16): the modem answers QMI without a SIM

`QMI_PROBE=1 tools/msm8974-rmtfs-start.sh 60` ran once on r207:
- **M4 parts pass again:** the four EFS paths were read, and all six partitions hash unchanged.
- **QMI:** `wwan0qmi0` appeared 2 s after start, and every query answered.

| query | answer |
|---|---|
| CTL services | ctl 1.5, wds 1.36, dms 1.14, nas 1.25, qos, wms 1.10, auth, at, **voice 2.1**, cat2, **uim 1.33**, pbm, test, loc 2.0, sar, ts, tmd, wda 1.11, tsync, **csvt**, coex, pdc, rfrpe, dsd, ssctl |
| manufacturer / model | `Nokia` / `1520` |
| revision | `MPSS.DI.2.0.1.c1.10-00039-M8974AAAAANAZM-1`, Oct 17 2014, product `BANDIT_LTE` |
| capabilities | GSM, UMTS, LTE; non-simultaneous CS/PS; SIM supported; 50 Mbit/s up / 100 Mbit/s down |
| bands | GSM 850/900E/1800/1900; WCDMA 850/900/1700/1900/2100; LTE 2, 4, 5, 7, 17 |
| ids | IMEI present (15 characters), MEID present, ESN empty; values redacted, never logged |
| UIM card status | slot 1 **absent**, no provisioning sessions: as expected, no SIM |
| system selection | GSM/UMTS/LTE, automatic network selection, voice-centric, voice domain CS-only |
| serving system | `not-registered-searching`, CS/PS detached, no radio interface |
| signal | -128 dBm (none) |
| voice config | TTY off, GSM AMR enabled |
| WDS | disconnected |
| **operating mode** | **`shutting-down`**, not HW-restricted |
| **power state** | external source, **battery level 0 %** |

**Two findings to map before anything is set:**

1. **The operating mode is `shutting-down`**, 2 s after boot, while NAS says it is searching. A healthy modem starts `low-power` or `online`. The battery level the modem sees, **0 %**, is a likely cause, since a Qualcomm modem refuses to go online at a critical battery level. Where WP fed the modem its battery level (a QMI client on the apps side, or the modem reading the PMIC fuel gauge itself) is the next thing to map. Nothing was set to test it.
2. **bam-dmux reported "Channel already open: 0-7"** when the modem came up. This was the second modem start in this Linux boot (M4 was the first), so the data-path driver likely kept channel state across the restart. It matters for mobile data later, not for QMI.

**Also seen:**
- **The ADSP's extra services:** with the modem up, the ADSP published 24 more services (instance 50, services 260-299). These are probably its modem-facing audio/voice side, relevant to M6.
- **The voice path's pieces are present:** the QMI `voice` 2.1 service, the `csvt` service and the `apr_voice_svc` SMD channel.

**M5 passes.**

**Next:**
- **Map the operating-mode/battery question** from WP (read-only) before any `set-operating-mode`.
- **For a daily phone:** rmtfs at boot (read-only until a write decision), modem autostart, and ModemManager.
- **M6:** the call-audio path (q6voice over `apr_voice_svc`), mapped from WP.

## 23. The operating-mode / battery question, partly mapped (2026-11-16)

**WP components for the cellular and battery side** (MainOS, analysis only):
- **RIL stack:** `qcmbb8974.sys` (Qualcomm mobile broadband) and `msril.sys` / `WMRil.dll` / `RILAdaptationService.exe`.
- **Battery:** `qcbms8974.sys` (the BMS fuel gauge and charger, apps side: `IOCTL_BMS_GET_PERCENT_CHARGE`, `IOCTL_BMS_GET_BATTERY_VOLTAGE`, ...).
- **Subsystems:** `qcsubsys8974.sys` (SSR hooks `ssr:modem:before_shutdown` ..., `sys_mon`, a QMI client).

**Where WP watches the battery voltage.** `qcsubsys8974.sys` keeps a VBATT monitor:
- **Reading:** it resolves the PMIC ADC channel `"VBATT"` by name and reads it.
- **Thresholds:** it compares the reading with two registry thresholds, `VbattLowThreshold` and `VbattHighThreshold`, with an above/below state for hysteresis.
- **On each crossing:** it re-arms the ADC alarm on the other threshold and sends a 16-byte message through a WDF function-table call to an I/O target the driver holds: `{0x01000008, 16, vbatt, threshold}`.

Which target that is (the modem over `sys_mon`, or a Windows power component) is not resolved: that needs the WDF function index and how the target is opened. So it is **not yet shown that WP gave the modem its battery level**.

What is known:
- **DMS reports** `battery level 0 %` with `external-source` power.
- **The mode:** `shutting-down`, read **2 s after the modem came up**.

**Next, cheapest first:**
1. **Read-only:** query the operating mode, power state and serving system again at the end of a 60 s run. Then we know whether `shutting-down` is a start-up transient or persists.
2. **If it persists, and only with the user's consent:** `--dms-set-operating-mode=low-power`. Low-power mode keeps the radio off. This tests whether the modem leaves `shutting-down` when the host asks, which is what ModemManager would do. Going `online` turns the radio on, and is a separate decision.

## 24. Step 1 result: `shutting-down` persists (2026-11-16)

**Conditions.** This is the same boot as M5, the modem's fourth start in it (uptime 26 h). The runner is `QMI_PROBE=1`, with the operating mode sampled every 15 s through the 60 s watch and a read-only re-query at its end. Nothing was set.

**Operating mode:** `shutting-down` at every sample, from 3 s to 65 s after the modem came up (6 reads). It is **not a start-up transient**.

**Power state:** still `external-source`, battery level `0 %`, at the end as at the start.

**NAS:** still `not-registered-searching`, CS/PS detached, no radio interface, -128 dBm. It says "searching" while in `shutting-down`, so the NAS state is probably only the default report.

**UIM changed during the run:**
- At 2 s the card state was `absent`.
- At 65 s it was `error: no-atr-received (3)`.

So the UIM powered the slot and tried to activate a card. With no SIM fitted, no answer-to-reset is expected. The card-detect handling is worth a look when a SIM goes in, but nothing is wrong yet.

**Everything else matched M5:**
- the 20 segments decrypted, and the modem opened and read fs1, fs2, fsg and fsc;
- one 3072-sector write to FS1 went to the shadow;
- partitions unchanged;
- no new kernel warnings;
- clean stop, recovery restored.

`bam-dmux: Channel already open: 0-7` appeared again, as on every start after the first one in a boot.

**Reading.** The modem holds `shutting-down` on its own. One possible cause, not established: its own low-battery handling. It reports battery 0 %, and WP had a VBATT path (section 23) that Linux does not have. The other possibility is that `shutting-down` is simply this firmware's state until the host sets a mode.

**Next, only with the user's consent:** `--dms-set-operating-mode=low-power` (radio stays off), then re-read the mode. The answer decides between the two readings:
- **The modem accepts it:** the host just has to set a mode, which is what ModemManager does.
- **It refuses** (for example "invalid transition"): the modem wants something first, most likely its battery or power state, so the WP VBATT target becomes the lead.

`online` (radio on) is a separate decision.

## 25. Step 2 result: the modem takes `low-power` when asked (2026-11-16)

**Run.** User consent in chat ("yes, go"). Runner `QMI_PROBE=1 SET_LOW_POWER=1`, the modem's fifth start in the same boot. After the read-only probe it ran one `--dms-set-operating-mode=low-power`, then the 60 s watch with the 15 s mode samples and the late re-query.

**Before:** `shutting-down`, read 3 s after the modem came up, as in sections 22 and 24.

**Set:** "Operating mode set successfully" at +3 s.
- **Read back:** `low-power` at once, 3 s later, and at all five samples to the end of the run (+67 s).
- **NAS:** went from `not-registered-searching` to `not-registered`, which is what radio-off should report.
- **Signal:** -128 dBm before and after (no radio interface).

**Unchanged:**
- **Power state:** `external-source`, battery 0 %. The modem accepts a mode with that report, so **battery level does not gate the operating mode**.
- **UIM:** `absent`, then `no-atr-received` later in the run (the empty slot), as in section 24.
- **The rest:**
  - rmtfs traffic identical; partitions unchanged;
  - no new kernel warnings;
  - clean stop; recovery restored.

The mode is not persistent, and the modem started clean at the next start.

**Conclusion.** `shutting-down` is this firmware's state until the host sets a mode. That is ModemManager's normal job: it sets `low-power`, or `online` when the user enables the modem. The WP VBATT path (section 23) does not need to be reproduced to bring the modem up, so it is set aside. The 0 % battery report remains cosmetic, as far as the modem's mode is concerned.

**Still open, for daily use:**
- **Services:** rmtfs and the modem start at boot (EFS read-only until the write decision), then ModemManager.
- **bam-dmux:** "Channel already open" on every start after the first one in a boot.
- **Radio on:** `online` (RF) needs the user's separate decision.
- **Calls:** M6 call audio.

## 26. Daily-use steps 1-2 mapped: rmtfs + modem at boot, then ModemManager (2026-11-16)

**What the phone has now:**
- **Packages:** `rmtfs` and `qrtr` are binaries only. They were installed offline from files, so the `-systemd` and `-udev` subpackages that `install_if` would add never came with them.
- **Services:** none run; no ModemManager.
- **NetworkManager** is installed and enabled, with **WWAN enabled**. It turns on any modem ModemManager reports, which would mean `online`, the radio on.
- **No UI shell** is installed: no phosh, Plasma Mobile or sxmo.

**How the sibling ports do it** (pmaports: fairphone-fp2, lg-hammerhead and samsung-klte, all MSM8974; and soc-qcom):
- they depend on Alpine's `msm-modem` (which pulls `msm-modem-uim-selection`) plus ModemManager;
- rmtfs runs from the packaged `rmtfs.service`;
- `tqftpserv` and `pd-mapper` are for newer SoCs and are not needed here (E3 and M4 ran without them).

**rmtfs -s.** The binary looks for the MSS remoteproc under `/sys/bus/platform/drivers/qcom-q6v5-mss/` and starts the modem once its service is published, then stops it when rmtfs exits. That replaces the test runner's manual start.

**Step 1, starting at boot. The plan:**
- `rmtfs-systemd` + `rmtfs-udev` (about 4 KB) for the stock unit and device permissions;
- a drop-in that creates the `/run/rmtfs-parts` links (modemst1/2, fsc and fsg to MODEM_FS1/FS2/FSC/FSG) and runs `rmtfs -r -P -s -o /run/rmtfs-parts`, **read-only as in M4/M5**;
- remoteproc recovery stays enabled.

The stock unit is to be read before use. The six partitions are hashed once before enabling it, and again after the first boots.

**Step 2, ModemManager.** The cached pmbootstrap indexes (2026-11-15) resolve against the phone's installed database:

| package | bytes |
|---|---|
| modemmanager 1.25.95_git20261005-r0 | 1194971 |
| modemmanager-systemd | 2007 |
| modemmanager-udev | 15474 |
| mobile-broadband-provider-info 20261111-r0 | 80544 |
| pkgconf 3.0.10-r0 (a dependency of the above) | 80663 |

**Left out:**
- `modemmanager-lang`: translations.
- `postmarketos-base-ui-modemmanager`: a meta package via `install_if`, which would pull **fwupd** (2 MB, plus 1 MB of language files) and pipewire extras. fwupd has a ModemManager plugin that can flash modem firmware, and is not wanted near this modem. A later online `apk upgrade` would pull it, so this has to be pinned or masked then.
- `msm-modem` / `msm-modem-uim-selection`: these select the SIM's USIM application. With no SIM there is nothing to select; they come when a SIM goes in.
- `msm-modem-wwan-port`: purpose to be read from its source first.

**The radio-off guarantee.** ModemManager on its own leaves a modem disabled, which puts it in `low-power`, as tested in section 25. What would turn the radio on is NetworkManager's WWAN switch, so `nmcli radio wwan off` (NetworkManager keeps it across boots) has to happen **before** ModemManager's first start. That is a settings change: the user's call.

**Checks on the first runs:**
- MM detects the modem through the qcom-soc plugin: `mmcli -L`, and `mmcli -m 0` shows state `disabled`, power `low`, SIM missing;
- `qmicli` reads `low-power`;
- the partition hashes are unchanged;
- after a reboot, the same with nothing done by hand.

## 27. Steps 1-2 installed, held disabled; service test prepared (2026-11-16)

**Downloads** (user approved), Alpine edge armv7. Each file's size matched the current index and starts with the gzip magic, and apk verified the signatures:
- modemmanager, modemmanager-udev and modemmanager-systemd 1.25.95_git20261005-r0;
- mobile-broadband-provider-info 20261111-r0 and pkgconf 3.0.11-r0;
- rmtfs-udev and rmtfs-systemd 1.3-r0;
- **libmm-glib 1.25.95_git20261005-r0**, approved separately: modemmanager pins its exact version. It upgrades the phone's git20260527-r1, which networkmanager-wwan also uses (same soname).

1.72 MB in total. apk is atomic: the first attempt, without libmm-glib, installed nothing.

**What the packages bring:**
- **`rmtfs.service`** runs `rmtfs -r -P -s`, `Before=NetworkManager.service`, `Restart=always`. So **the stock unit is read-only too**.
- **`rmtfs-udev`'s `rmtfs.rules`** wants `rmtfs.service` whenever `qcom_rmtfs_mem*` appears, **whether or not the unit is enabled**.
- **`ModemManager.service`** is `Type=dbus`, with `Requires=polkit.service` and the D-Bus alias `dbus-org.freedesktop.ModemManager1.service`.
- **`77-mm-qcom-soc.rules`** matches `wwan` ports under `qcom-q6v5-mss` and `net` ports from `bam-dmux`, under one physdev `qcom-soc`. MSM8974 is named in it.
- **The pmOS install trigger** applies presets (`enable ModemManager.service`, `enable rmtfs.service`) and **enabled both**. mkinitfs also rebuilt `/boot`, which is irrelevant while the kernel is booted with `fastboot boot`.

**State left on the phone:**
- **NetworkManager:** `nmcli radio wwan off` (user approved), persistent.
- **Read-only override:** `/etc/systemd/system/rmtfs.service.d/lumia1520.conf` (repo `tools/modem-services/rmtfs-lumia1520.conf`) does three things:
  - it requires the four MODEM_FS* device units;
  - it creates the `/run/rmtfs-parts` links;
  - it runs `rmtfs -r -P -s -o /run/rmtfs-parts`.
- **Udev hold:** `/etc/udev/rules.d/rmtfs.rules` is a comment-only override of the udev auto-start (repo `tools/modem-services/rmtfs.rules.hold`). It is removed after the tests.
- **Services:** `rmtfs` and `ModemManager` are **disabled again**, which also removes the D-Bus alias, so nothing D-Bus-activates ModemManager. Both are inactive and the modem is offline.

**The test:** `tools/msm8974-modem-services-test.sh`.
- **Preflight:**
  - the modem is offline and both services are inactive;
  - the NetworkManager WWAN radio is disabled;
  - the override is in effect.
- **Run:**
  - hash the six partitions;
  - `systemctl start rmtfs` (the modem must come up on its own through `-s`);
  - `systemctl start ModemManager`;
  - `mmcli -L` within 90 s, then `mmcli -m any` (identifiers redacted on the phone);
  - a 60 s watch of state, power, registration and NM WWAN every 15 s.
- **Guard:** power `on`, or any enabling, registered or searching state, stops ModemManager and rmtfs at once (exit 4).
- **Pass:** the state is `disabled`, or `failed` (sim-missing is expected), with power `low` or `off`, and the partitions are unchanged. Then stop both and confirm the modem goes offline through rmtfs.

**After a pass, before enabling at boot:**
- remove the udev hold and enable both units;
- a cold boot with the same checks, read-only, with nothing done by hand.

## 28. Service test 1: rmtfs.service passes; ModemManager finds no net port (2026-11-16)

**Run:** the user's go, same boot, the modem's sixth start in it.

**rmtfs.service: PASS.**
- **Start:** `systemctl start rmtfs` with the override created the four links, and `rmtfs -r -P -s -o /run/rmtfs-parts` started the modem itself: running after 2 s, `wwan0qmi0` after 1 s more.
- **Stop:** `systemctl stop rmtfs` stopped the modem (offline at once). The unit was "Deactivated successfully".
- **Partitions:** unchanged.
- **Read-only, as in M4:** the modem's file-system traffic matched the earlier runs, so its write again went to the in-memory copy.

**ModemManager: no modem.**
- **Probe:** it started, and the qcom-soc plugin probed `wwan0qmi0` (QMI) and `wwan0at0`/`wwan0at1` (AT).
- **Failure:** creating the modem with 3 ports ended in `couldn't create modem for device 'qcom-soc': Failed to find a net port in the QMI modem`.
- **Radio:** never a modem object, so never any power or state, and NetworkManager WWAN stayed disabled throughout.

**Cause.** bam-dmux registers its net devices (`wwan0`-`wwan7`, under `fc880000.remoteproc:bam-dmux`) **once per boot**, at the first modem start: here, uptime 4419 s. That was before `77-mm-qcom-soc.rules` was installed, so their udev records have no `ID_MM_QCOM_SOC` / `ID_MM_PHYSDEV_UID` (`udevadm info wwan0`: only DEVPATH, INTERFACE and USEC_INITIALIZED).
- **The control ports work:** they are re-created at every modem start, so they were tagged.
- **The net devices never re-announce:** on later starts, `bam_dmux_cmd_open()` finds the channel bit still set (`__test_and_set_bit`, "Channel already open"), because the modem never sends CLOSE when it is stopped. So it does nothing: no new device, no uevent.

**This is not a boot-time problem.** On a fresh boot the rules are present before the first start.

**The stale bitmap is a separate kernel issue,** for later and for data:
- `remote_channels` and the netdevs' attach state survive a modem stop;
- `pc_state` probably does too.

The fix belongs in qcom_bam_dmux: reset the channel state when the modem goes down (power-collapse off, or an SSR notifier).

**Also seen on stop:** `qcom_sysmon: timeout waiting for ssctl service`. sysmon waits 0.5 s for the SSCTL service before the graceful shutdown request. The modem still stopped cleanly within 0.6 s. Watch whether it recurs.

**Runner changes:**
- **Preflight** now refuses if any `wwanN` net device lacks `ID_MM_QCOM_SOC=1`.
- **The run** lists the net ports with operstate and tag.

**Next, two options:**
1. **Retag in this boot:** `udevadm trigger --action=change` on `/sys/class/net/wwan*` (re-runs the udev rules, changes nothing else), then the same test.
2. **Or go straight to the cold-boot test** (enable both units, remove the hold, reboot).

## 29. Service test 2: PASS, ModemManager holds the modem with the radio off; enabled at boot (2026-11-16)

**Run:** the user's go, same boot, the modem's seventh start in it. First `udevadm trigger --action=change` on `/sys/class/net/wwan0..7`. After it, all eight carry `ID_MM_QCOM_SOC=1`, `ID_MM_PHYSDEV_UID=qcom-soc` and `ID_MM_CANDIDATE=1`.

**rmtfs.service:** as in section 28. `rmtfs -r -P -s -o /run/rmtfs-parts`, the modem running after 2 s, `wwan0qmi0` after 2 s more.

**ModemManager:**
- **Modem created:** `mmcli -L` listed `/org/freedesktop/ModemManager1/Modem/0 [Nokia] 1520` 32 s after the service started. That time includes about 19 s of SIM-lock retries.
- **Ports:** plugin `qcom-soc`, primary port `wwan0qmi0`, 11 ports in all: `wwan0qmi0` (qmi), `wwan0at0`/`wwan0at1` (at), and `wwan0`-`wwan7` (net). Drivers `bam-dmux`, `qcom-q6v5-mss`.
- **Hardware:** supported gsm-umts and lte, all 2G/3G/4G mode combinations, the bands from M5, IPv4/IPv6/IPv4v6 supported.
- **State:** `failed`, reason **`sim-missing`**, **power `off`** (the modem still reports `shutting-down`, and MM sets nothing in the failed state). Registration `--`, no SIM object. It held the same at all five samples over 60 s, with NetworkManager WWAN `disabled` throughout.

**Journal:**
- "Couldn't get SIM lock status after 7 retries", then locked → failed.
- "couldn't build device ids: Unsupported subsystem: platform", which is harmless.
- "couldn't load supported assistance data types", which is GPS assistance data.
- The mtk/rolling plugins fail to load (missing symbols in this Alpine snapshot; not used here).

**Stop:** clean, with the modem offline at once. The `ssctl` timeout did not recur.

**Partitions:** unchanged. Kernel warnings: none new.

**Redaction:** `mmcli` also prints a `device id` (a SHA1 over hardware data). It is now redacted with the other identifiers.

**Enabled at boot** (the agreed step after a pass):
- `/etc/udev/rules.d/rmtfs.rules` (the hold) removed;
- `systemctl enable rmtfs ModemManager` (with the D-Bus alias);
- NetworkManager WWAN stays `disabled`.

**Cold-boot check:** `tools/msm8974-modem-boot-check.sh`, read-only. It checks:
- both units active, with rmtfs on the exact read-only command line;
- the modem running, and the boot sequence from dmesg;
- the net ports tagged;
- MM in `disabled`/`failed` with power `low`/`off`;
- NetworkManager WWAN disabled;
- the six partition hashes against the M4 reference.

## 30. Cold boot: PASS -- the modem comes up by itself

The user power-cycled the phone into fastboot, and the r207 image (`boot-1520-quietlog-rc1.img`, sha256 `76235a06...b5091d2`) was booted with `fastboot boot`. Nothing was started by hand. `msm8974-modem-boot-check.sh` was run once ModemManager had settled, at uptime 106 s. Exit 0.

**Timeline (seconds since boot):**
- 58.0: `rmtfs.service` active (`/usr/bin/rmtfs -r -P -s -o /run/rmtfs-parts`, links to mmcblk0p3/p4/p5/p2).
- 58.3: MBA boots, and TrustZone decrypts it at 59.2.
- 60.2: `ModemManager.service` active.
- 65.4: MPSS decrypted (20 segments), and the modem is up at 65.5.
- 67.9: `wwan0qmi0` attached; `wwan0`-`wwan7` registered **already carrying the MM tags** (the udev rules were installed before this boot, so the section-28 problem does not occur on a normal boot).
- 75.8: MM creates the modem (`qcom-soc`, 11 ports).
- 95.0: SIM lock status fails after 7 retries, then locked → failed (`sim-missing`), power `off`.

**Checks:**
- **Kernel:** no "Channel already open" (first modem start of the boot), no ssctl timeout, and **0 kernel WARNINGs** this boot.
- **NetworkManager WWAN:** `disabled`.
- **Partitions:** all six unchanged against the M4 reference.
- **Journal:** the only new line is "Error loading cached location from /var/lib/ModemManager/location.ini", which is harmless and expected on a first start.

**Notes:**
- Userspace reaches the services only at about 58 s. That is a general boot-time issue (not modem-specific), worth its own look later.
- The phone's clock read 2026-09-09: there is no RTC sync without network time.

**Daily-use steps 1-2 are complete:** the modem and ModemManager come up at every boot, read-only and with the radio off.

**Still open:**
- the bam-dmux stale `remote_channels` fix (needed for data, and for restarts and subsystem recovery);
- pin/mask fwupd before any online `apk upgrade`;
- the EFS write decision (rmtfs `-r`);
- `online`/RF only with the user's consent;
- M6 call audio.

## 31. bam-dmux: forget the modem's channels when it goes down (patch 0010, r208)

**The bug** (seen since section 28): `qcom_bam_dmux` records the modem's OPEN commands in `remote_channels`. The modem sends no CLOSE when it is stopped or crashes, so after any modem restart in the same boot, every OPEN is rejected with "Channel already open", and the netdevs are never detached or reattached. That breaks mobile data after a restart and after subsystem-restart recovery.

**Mainline** (torvalds master, checked 2026-11-17): no restart handling at all. `remote_channels` is cleared only by CLOSE, and the last functional change was in 2024.

**Downstream** (msm8974 `arch/arm/mach-msm/bam_dmux.c`, `restart_notifier_cb`):
- BEFORE_SHUTDOWN only sets `in_global_reset`.
- AFTER_SHUTDOWN does the cleanup:
  - power down the uplink and `power_vote(0)`;
  - clear `BAM_CH_REMOTE_OPEN` on every channel (re-creating the channel devices that were open);
  - free the TX pool.
- While in reset it skips every A2 BAM register access (`sps_disconnect` and `sps_device_reset`) and the ACK toggles.
- The power-control ACK parity is kept across the restart.

**Patch 0010** (`net: wwan: qcom_bam_dmux: reset remote channels when the modem goes down`). The driver registers for the `"mpss"` SSR notifications, like `drivers/net/ipa`. On `QCOM_SSR_BEFORE_SHUTDOWN`, while the modem-powered BAM is still clocked, it:
- stops every netdev's queues and cancels the TX wakeup work;
- releases both DMA channels (`bam_dmux_power_off`);
- completes TX buffers the old modem will never finish, so their runtime-PM references are returned;
- clears `remote_channels` and detaches the netdevs that were open, which is what the missing CLOSEs would have done.

What it leaves alone, and the safety changes:
- **`pc_state` is not reset.** It follows the edges of the modem's power-control bit, and those keep toggling consistently across the restart.
- **TX safety:** if the driver was runtime-active when the modem went down, the TX channel is gone while the PM core still thinks the driver is awake. So the TX submit and wakeup paths drop packets when there is no channel, instead of dereferencing NULL. The next runtime resume requests the channel again.
- **Locking:** a mutex serializes the pc interrupt thread with the shutdown path. Lock order is rtnl, then `pc_lock`.
- **Kconfig:** `depends on QCOM_RPROC_COMMON || QCOM_RPROC_COMMON=n`.
- **Build ID:** `MODULE_VERSION("ssr-rc1")`.

**Checks:**
- W=1 compile is clean in the r185chk tree.
- checkpatch `--strict` reports 0/0/0.
- Staged as pkgrel 208, with every sha512 matching its file in source order.
- `qcom_bam_dmux` is a module (`=m`), and `MODVERSIONS` and no module signing mean the r208 `.ko` matches the r207 kernel's symbols.

**Why no live module swap:** unloading the old driver with the modem stopped may free a DMA channel on the modem's BAM after the MSS is in reset (the old driver may still hold RX). That register access could hang the bus. So the plan is to install the module, then cold boot.

**Test** (`tools/msm8974-bam-dmux-restart-test.sh`, read-only for the partitions, with the same radio-on guard):
- bam-dmux dynamic debug is switched on for the run.
- Each of N cycles stops and restarts ModemManager and rmtfs. Each cycle must show a shutdown reset, channel opens, no "Channel already open", no warnings, ModemManager back at `failed`/`disabled` with power `off`/`low` and 11 ports.
- All six partitions are hashed before and after.

**Not yet covered:**
- A modem crash (true SSR with `recovery enabled`). This test covers graceful stops only.
- Data traffic across a restart, which needs the radio on (`online`), and that needs separate consent.

### 31a. r208 test: PASS

**Setup:**
- Module `qcom_bam_dmux.ko` `ssr-rc1` installed (sha256 `10693a650e468c0c`). The old `.ko.zst` is kept in `~/modules-r207-replaced/`.
- Cold boot into r208 (`boot-1520-quietlog-rc1.img`, sha256 `cee35ed952f6310c`).

**Boot check:** exit 0, the same timeline as section 30. Modem up at 65 s; ModemManager `failed`/`sim-missing`, power `off`; ports tagged; partitions unchanged.

**Restart test, 3 cycles:** exit 0. Each cycle ran the same sequence:
- **stop:** `modem going down, open channels: 0-7` (the reset ran);
- **start:** about 4 s after rmtfs starts, `pc: 1`, then `open channel: 0` … `7` accepted;
- **result:** **no "Channel already open"**, ModemManager back to `failed`/`sim-missing`/power `off` with 11 ports in 24-34 s;
- **power collapse:** `pc: 0` 2 s after the opens. The modem power-collapses the A2 when nothing votes, so the bam-dmux DMA is already released before each stop.

Afterwards: 0 kernel WARNINGs or Oopses this boot, partitions unchanged, both services running, NetworkManager WWAN disabled.

**New observations:**
- **The modem announces channels 8 and 10-15 as well** ("Unsupported channel", dev_dbg only). The mainline driver handles 0-7. Downstream maps 8+ to USB tethering/control channels, which are not needed here.
- **The shutdown path ran with no DMA live,** because the A2 was idle-collapsed every time. Teardown with the A2 powered (traffic in flight) is still untested, and needs `online`.

**Still open for bam-dmux:**
- a real modem crash (SSR with `recovery enabled`);
- data across a restart.

## 32. Modem crash recovery: PASS (2 crashes, r208)

**Method:** `tools/msm8974-modem-crash-recovery-test.sh` writes crash type 1 (watchdog) to `/sys/kernel/debug/remoteproc/remoteproc1/crash`.
- That runs the host side of a real crash: `rproc_report_crash`, then crash handling, then `rproc_boot_recovery` (`rproc_stop(crashed=true)`: no sysmon shutdown request, SSR BEFORE_SHUTDOWN, then a stop request over smp2p, a coredump, then the firmware reloaded and started).
- The modem firmware itself does not fault.
- The coredump is `disabled` by default in this kernel, and the test refuses otherwise. A dump would reload the MBA (`qcom_q6v5_dump_segment`) and copy the decrypted modem region into memory.
- Both TrustZone decrypt hooks are on the recovery path: the MBA in `q6v5_load` (patch 0008) and the modem segments in `q6v5_mpss_load` (patch 0009).

**Result:** exit 0, both crashes the same.

**Timeline of crash 1 (crash 2 the same):**

| Time | Event |
|---|---|
| +0 ms | crash reported; handling crash #1; recovering |
| +1 ms | bam-dmux `modem going down, open channels: 0-7` (patch 0010) |
| +5-8 ms | `wwan0at0`, `wwan0at1`, `wwan0qmi0` disconnected |
| +21 ms | stopped |
| +0.34 s | SSD MBA decrypted |
| +0.47 s | MBA booted |
| +0.70 s | SSD MPSS metadata parsed |
| +2.03 s | 20 segments decrypted |
| +2.15 s | **modem up** |
| +3.5 s | ports attached; `pc: 1`; channels 0-7 opened; **no "Channel already open"** |
| +5.5 s | `pc: 0` (idle power collapse) |

**Userspace:** ModemManager was back at `failed`/`sim-missing`, power `off`, 11 ports, about 25 s after the crash.
- Transient: the AT ports appear before the QMI port, so ModemManager logs "could not recreate modem: at least a QMI port is required", then creates it 4 s later.
- **rmtfs and ModemManager kept the same PIDs.** Recovery is transparent to both, and rmtfs logged nothing.

**Afterwards:** 0 kernel warnings or Oopses this boot, partitions unchanged, NetworkManager WWAN disabled, coredump still `disabled`.

**Note:** crash 1 logged `qcom-q6v5-mss: port failed halt` once. One AXI halt request was not acked in time during `q6v5_stop`, and the reset that follows covers it. It did not recur on crash 2 or on any of the graceful stops. Watch for it.

**bam-dmux status:**
- Graceful restarts (section 31a) and crash recovery are both clean.
- Still untested: teardown with the A2 powered and data in flight. That needs `online`.

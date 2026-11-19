# RegenX-AE kernel feature check (r210, 2026-11-19)

**Question:** what does the 1520's kernel already give the RegenX-AE layers (concept doc §6-7, substrate v0.5)? What has to change before the PoC (concept doc §12)?

**Method:** run `tools/regenx-kernel-check.sh` on the running r210 kernel (4 CPUs, `#211`). It reads `/proc/config.gz` per layer, runtime state, installed tools, and `tools/regenx-bpf-probe.py`. The probe loads minimal eBPF programs and maps through the raw `bpf(2)` syscall and attaches nothing. Package availability was checked against the cached armv7 APKINDEX. Report on the phone: `/var/log/regenx-kernel-check-20260912T010027Z.txt` (the phone clock is wrong; there is no network time).

## Verdict per layer

| Layer | Today | Blocking for the PoC? |
|---|---|---|
| L0 verified root | dm core built in; `dm-verity` is a **module**; `veritysetup`/`dmsetup` installed. No FEC, root-hash signature, IMA/EVM, fs-verity, module signing or lockdown. | Yes, for criterion 4. Make `DM_VERITY=y` (the initramfs then needs no module). |
| L1 snapshot/heal | btrfs and f2fs built in; overlayfs and dm-thin modules; no dm-snapshot; inotify yes, **fanotify no**; pstore/ramoops yes; **no watchdog driver**. | No. The substrate's LocalCopy store works now. fanotify gives real-time detection instead of polling. |
| L2 telemetry | **eBPF works** (see below). **Audit is off** (`CONFIG_AUDIT` n), so the substrate's `AuditLogWatcher` has no source. The process-events connector is off. | Partly. The polling and eBPF paths work. The audit backend needs `AUDIT`+`AUDITSYSCALL`. |
| L3 network | nftables as modules (ct, log, limit, reject, nat, masq); `nft` installed; WireGuard and TUN modules. No `NFT_SOCKET` (cgroup-v2 matching), NFLOG, ctnetlink, NFQUEUE or `xt_owner`. | No. `block_endpoint` can work now. Per-app egress and the planned NFLOG/conntrack stream need the missing options. |
| L4 sandbox | seccomp-filter, all namespaces and cgroup v2 work. **The only active LSM is `capability`**: AppArmor, SELinux, Landlock and Yama are all off. | Not for criteria 1-4. Yes for the L4 per-app story. |
| L5 data at rest | dm-crypt, XTS and GCM built in, but AES is **`aes-generic` only**. No NEON AES, no Adiantum, no QCE driver. Keyrings yes; encrypted/trusted keys no (no TPM/TEE anyway, concept §3). | Not for the PoC criteria. LUKS would be slow on generic AES. |
| Hardening | stack protector strong, strict RWX, VMAP stack, SW PAN, branch-predictor hardening, dmesg restrict, unprivileged BPF off. Off: hardened usercopy, fortify, slab freelist hardening/random, init-on-alloc, Yama, `STRICT_DEVMEM`. `LEGACY_TIOCSTI` is on. | No. These are cheap upgrades. |

## eBPF on armv7: the concept doc's [Open] question, answered

Every one of these loads on this kernel (as root):
- **Maps:** hash, array, LRU hash, per-CPU hash, perf event array and **ring buffer**.
- **Program types:** socket filter, kprobe, tracepoint, raw tracepoint, perf event, cgroup skb, cgroup sock and **cgroup sock_addr** (inet4 connect).
- **Features:** a tracepoint program calling `bpf_get_current_pid_tgid` then `bpf_ringbuf_output`, and a BPF-to-BPF subprogram call.

Hook points present: kprobes, uprobes, `raw_syscalls/sys_{enter,exit}`, `sched_process_{exec,fork,exit}`, `task_newtask`, `sock/inet_sock_set_state`, and the `tcp_*` events.

Limits, stated plainly:
- **The JIT is built but off.** `net.core.bpf_jit_enable=0`, so every program above ran in the interpreter. That is correct but slower. Turning it on is a sysctl, but the arm32 JIT has not been exercised yet; see next steps.
- **No BTF.** `DEBUG_INFO_BTF` needs `pahole` in the build. Without BTF there is no CO-RE, so programs have to be built against this kernel's headers. That is acceptable for one fixed kernel.
- **No fentry/fexit and no BPF-LSM.** These need the BPF trampoline (`DYNAMIC_FTRACE_WITH_DIRECT_CALLS`), which arm32 does not have. `CONFIG_BPF_LSM=y` is therefore useless here. Enforcement goes through cgroup programs instead: `cgroup_sock_addr` connect hooks give **per-cgroup (per-app) egress blocking without nftables**.
- **No per-syscall tracepoints** (`FTRACE_SYSCALLS` n). `raw_syscalls` covers them with a syscall-number filter.

So the substrate's planned `aya` backend is viable on armv7 for tracepoint, kprobe and cgroup programs. It cannot use LSM or fentry programs on this device. The polling and audit backends remain the fallbacks the concept doc expected.

## Userspace (Alpine armv7 index)

Installed on the phone: `nft`, `cryptsetup`, `veritysetup`, `dmsetup`, `btrfs`.

Available in Alpine but not installed: `audit`, `bpftool`, `bpftrace`, `bcc`, `libbpf`, `bubblewrap`, `flatpak`, `apparmor` and `apparmor-utils`, `wireguard-tools`, `squashfs-tools`, `erofs-utils`, `fsverity-utils`, `ima-evm-utils`, `aide`, `libseccomp`, `iptables`, `rust` and `cargo`. The phone has no internet yet, so these go on via scp'd `.apk` files or after tethering.

**Substrate note:** the README's `auditctl ... -F arch=b64 -S execve` rule is for x86-64. On the 1520 it must be `-F arch=b32` (armeabi).

## Module caveat

The phone's rootfs still carries kernel package **r4** (and device package r4). Boot images are `fastboot boot`ed, so `/lib/modules/6.16.12` is r4's. Those modules load into r210 only because the symbol CRCs (`modversions`) still match; `nf_tables`, `tun` and `qcom_rng` are loaded. Any option newly set to `=m` will be **absent** on the phone until the matching kernel package is installed on the rootfs. Options the PoC depends on should therefore be `=y`, or the kernel package must be installed alongside each test image.

## Proposed r211 "regenx-base" config (not staged)

**PoC-required:**
- `DM_VERITY=y`;
- `AUDIT=y`, `AUDITSYSCALL=y`;
- `CONNECTOR=y`, `PROC_EVENTS=y` (cheap fork/exec/exit events);
- `FANOTIFY=y`, `FANOTIFY_ACCESS_PERMISSIONS=y`;
- `NF_TABLES=y` with `NFT_CT`, `NFT_LOG`, `NFT_REJECT`, `NFT_LIMIT`=y, plus `NFT_SOCKET`, `NFT_FIB_INET`, `NETFILTER_NETLINK_LOG` and `NF_CT_NETLINK` (=y).

**L4/L5:**
- `SECURITY_NETWORK`, `SECURITY_PATH`, `SECURITY_APPARMOR`, `SECURITY_LANDLOCK`, `SECURITY_YAMA`, with `LSM="landlock,lockdown,yama,integrity,apparmor"`;
- `CRYPTO_AES_ARM`, `CRYPTO_AES_ARM_BS` (NEON bit-sliced AES-XTS), `CRYPTO_ADIANTUM`, `CRYPTO_NHPOLY1305_NEON`, `CRYPTO_CHACHA20_NEON=y`. Krait has no AES instructions, and Adiantum was designed for exactly this class of CPU;
- `FS_VERITY=y` (kernel-verified golden-store files for L1).

**Cheap hardening:**
- `HARDENED_USERCOPY`, `FORTIFY_SOURCE`, `SLAB_FREELIST_HARDENED`, `SLAB_FREELIST_RANDOM`, `SHUFFLE_PAGE_ALLOCATOR`, `LIST_HARDENED`, `SCHED_STACK_END_CHECK`, `STRICT_DEVMEM`;
- `LEGACY_TIOCSTI` n.

`STRICT_DEVMEM` still lets the bring-up tools read the parking mailboxes, because they are reserved `no-map`, not System RAM. `IO_STRICT_DEVMEM` would block MMIO peeks and waits.

**Later, each its own test:**
- `WATCHDOG` + `QCOM_WDT`. The DT node `watchdog@f9017000` is enabled, but whether the WP firmware tolerates the kernel driving the APSS watchdog is [Open], and a wrong answer is a reset loop;
- `MODULE_SIG` + lockdown;
- IMA/EVM;
- BTF;
- `CRYPTO_DEV_QCE` (the hardware crypto engine may be TrustZone-owned on WP).

**Runtime, no rebuild:**
- `net.core.bpf_jit_enable=1`, then re-run the BPF probe; every program should report "jited". This needs a go, because it changes a kernel setting;
- `kernel.kptr_restrict=1`;
- a panic/oops policy for self-healing (`panic_on_oops=1`, short `kernel.panic`) belongs to RegenX's L6 policy, not the kernel.

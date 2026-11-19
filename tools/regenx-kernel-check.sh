#!/bin/sh
#
# RegenX-AE kernel feature check -- docs/regenx-kernel-features.md.
#
# Read-only inventory of what the running kernel gives the RegenX-AE layers
# (concept doc section 6/7): the config options per layer, what is active at
# runtime (LSMs, crypto drivers, tracing, watchdog, sysctls), which userspace
# tools are installed, and -- through regenx-bpf-probe.py next to this script --
# which eBPF program and map types load and JIT on this armv7 kernel.
#
# Changes nothing: no module loads, no sysctl writes, no mounts. The BPF probe
# loads tiny "return 0" programs and closes them again; nothing is attached.
#
# Usage (as root on the phone): sh regenx-kernel-check.sh
# Output: /var/log/regenx-kernel-check-<stamp>.txt
# Exit: 0 report written; 2 refused (no /proc/config.gz, or not root)

set -u
[ "$(id -u)" = 0 ] || { echo "run as root (the BPF probe and some sysctls need it)"; exit 2; }
[ -r /proc/config.gz ] || { echo "no /proc/config.gz -- nothing to check against"; exit 2; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUT="/var/log/regenx-kernel-check-$STAMP.txt"
CFG=$(mktemp); zcat /proc/config.gz > "$CFG"; trap 'rm -f "$CFG"' EXIT

# opt LAYER NAME...: one line per option: y / m / n (set off) / - (not in this config)
opts() {
	layer=$1; shift
	for o in "$@"; do
		v=$(awk -v k="CONFIG_$o" '
			index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1; exit }
			$0 == "# " k " is not set" { print "n"; f = 1; exit }
			END { if (!f) print "-" }' "$CFG")
		printf '  %-6s %-42s %s\n' "$layer" "$o" "$v"
	done
}
sysctl_show() { for k in "$@"; do f=/proc/sys/$(echo "$k" | tr . /); printf '  %-40s %s\n' "$k" "$( [ -r "$f" ] && cat "$f" || echo absent)"; done; }

{
echo "== RegenX kernel feature check $STAMP"
echo "kernel: $(uname -r) $(uname -v)"
echo "cpus online: $(cat /sys/devices/system/cpu/online)   mem: $(awk '/MemTotal/ {print $2, $3}' /proc/meminfo)"
echo
echo "== config (y built in, m module, n off, - not in this config)"
echo "-- L0 verified/immutable root, boot integrity"
opts L0 BLK_DEV_DM DM_INIT DM_VERITY DM_VERITY_FEC DM_VERITY_VERIFY_ROOTHASH_SIG \
	SQUASHFS SQUASHFS_ZSTD SQUASHFS_XZ EROFS_FS FS_VERITY FS_VERITY_BUILTIN_SIGNATURES \
	IMA IMA_APPRAISE EVM INTEGRITY_SIGNATURE MODULES MODULE_SIG MODULE_SIG_FORCE \
	SECURITY_LOCKDOWN_LSM DEVMEM STRICT_DEVMEM IO_STRICT_DEVMEM KEXEC
echo "-- L1 snapshot / rollback / self-heal / supervision"
opts L1 OVERLAY_FS BTRFS_FS F2FS_FS DM_SNAPSHOT DM_THIN_PROVISIONING \
	FANOTIFY FANOTIFY_ACCESS_PERMISSIONS INOTIFY_USER WATCHDOG QCOM_WDT PSTORE PSTORE_RAM
echo "-- L2 telemetry (eBPF, audit, process events)"
opts L2 BPF BPF_SYSCALL BPF_JIT BPF_JIT_ALWAYS_ON BPF_JIT_DEFAULT_ON HAVE_EBPF_JIT \
	BPF_UNPRIV_DEFAULT_OFF BPF_EVENTS BPF_LSM CGROUP_BPF DEBUG_INFO DEBUG_INFO_BTF \
	PERF_EVENTS KPROBES KPROBE_EVENTS UPROBES UPROBE_EVENTS FTRACE FTRACE_SYSCALLS \
	DYNAMIC_FTRACE DYNAMIC_FTRACE_WITH_DIRECT_CALLS FUNCTION_TRACER \
	AUDIT AUDITSYSCALL CONNECTOR PROC_EVENTS TASKSTATS TASK_DELAY_ACCT PSI \
	NET_CLS_BPF NET_ACT_BPF
echo "-- L3 network defense"
opts L3 NETFILTER NF_TABLES NF_TABLES_INET NF_TABLES_IPV4 NF_TABLES_IPV6 NF_TABLES_NETDEV \
	NFT_CT NFT_LOG NFT_LIMIT NFT_REJECT NFT_NAT NFT_MASQ NFT_SOCKET NFT_FIB_INET NFT_QUEUE \
	NF_CONNTRACK NF_CT_NETLINK NETFILTER_NETLINK_LOG NETFILTER_NETLINK_QUEUE \
	NETFILTER_XT_MATCH_OWNER NETFILTER_XT_MATCH_CGROUP IP_NF_IPTABLES IP6_NF_IPTABLES \
	WIREGUARD TUN CGROUP_NET_CLASSID SOCK_CGROUP_DATA
echo "-- L4 sandboxing / least privilege"
opts L4 SECCOMP SECCOMP_FILTER NAMESPACES USER_NS PID_NS NET_NS UTS_NS IPC_NS \
	CGROUPS MEMCG CGROUP_PIDS CGROUP_DEVICE CGROUP_FREEZER \
	SECURITY SECURITY_NETWORK SECURITY_PATH SECURITY_APPARMOR SECURITY_SELINUX \
	SECURITY_LANDLOCK SECURITY_YAMA SECURITY_SAFESETID LSM
echo "-- L5 data at rest / secure storage"
opts L5 DM_CRYPT CRYPTO_XTS CRYPTO_AES CRYPTO_AES_ARM CRYPTO_AES_ARM_BS CRYPTO_ADIANTUM \
	CRYPTO_CHACHA20_NEON CRYPTO_NHPOLY1305_NEON CRYPTO_GCM CRYPTO_SHA256_ARM CRYPTO_SHA512_ARM \
	CRYPTO_USER_API_HASH CRYPTO_USER_API_SKCIPHER CRYPTO_USER_API_AEAD \
	CRYPTO_DEV_QCE CRYPTO_DEV_QCOM_RNG HW_RANDOM \
	FS_ENCRYPTION FS_ENCRYPTION_INLINE_CRYPT \
	KEYS ENCRYPTED_KEYS TRUSTED_KEYS KEY_DH_OPERATIONS PERSISTENT_KEYRINGS
echo "-- hardening"
opts HARD STACKPROTECTOR STACKPROTECTOR_STRONG FORTIFY_SOURCE HARDENED_USERCOPY \
	STRICT_KERNEL_RWX STRICT_MODULE_RWX INIT_ON_ALLOC_DEFAULT_ON INIT_STACK_ALL_ZERO \
	SLAB_FREELIST_HARDENED SLAB_FREELIST_RANDOM SHUFFLE_PAGE_ALLOCATOR VMAP_STACK \
	RANDOMIZE_KSTACK_OFFSET_DEFAULT LIST_HARDENED BUG_ON_DATA_CORRUPTION \
	SCHED_STACK_END_CHECK CPU_SW_DOMAIN_PAN HARDEN_BRANCH_PREDICTOR \
	SECURITY_DMESG_RESTRICT PROC_KCORE LEGACY_TIOCSTI HIBERNATION PANIC_ON_OOPS
echo "-- crypto families present (for the dm-crypt cipher choice)"
grep -E '^CONFIG_CRYPTO_(.*(AES|CHACHA|ADIANTUM|NHPOLY|POLY1305|XCHACHA|ESSIV|HCTR2|POLYVAL).*)=' "$CFG" | sed 's/^/  /'

echo
echo "== runtime"
echo "-- active LSMs: $(cat /sys/kernel/security/lsm 2>/dev/null || echo 'securityfs not mounted')"
grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs):' /proc/self/status | sed 's/^/  /'
echo "-- sysctls"
sysctl_show kernel.unprivileged_bpf_disabled net.core.bpf_jit_enable net.core.bpf_jit_harden \
	net.core.bpf_jit_kallsyms kernel.kptr_restrict kernel.dmesg_restrict kernel.perf_event_paranoid \
	kernel.yama.ptrace_scope user.max_user_namespaces kernel.modules_disabled kernel.kexec_load_disabled \
	kernel.panic kernel.panic_on_oops fs.protected_symlinks fs.protected_hardlinks
echo "-- btf: $( [ -e /sys/kernel/btf/vmlinux ] && echo "/sys/kernel/btf/vmlinux $(wc -c < /sys/kernel/btf/vmlinux) bytes" || echo 'no /sys/kernel/btf/vmlinux')"
T=/sys/kernel/tracing; [ -d $T/events ] || T=/sys/kernel/debug/tracing
if [ -d $T/events ]; then
	echo "-- tracefs $T: $(ls $T/events | wc -l) event systems, syscalls events: $(ls $T/events/syscalls 2>/dev/null | wc -l), sched_process_exec: $( [ -d $T/events/sched/sched_process_exec ] && echo yes || echo no)"
else
	echo "-- tracefs: not mounted"
fi
echo "-- device-mapper: $(grep -c device-mapper /proc/misc) misc node; targets: $( command -v dmsetup >/dev/null && dmsetup targets | awk '{printf "%s ", $1}' || echo 'dmsetup not installed')"
echo "-- cgroup mounts:"; mount | grep cgroup | sed 's/^/  /'
echo "-- watchdog: $(ls /dev/watchdog* 2>/dev/null | tr '\n' ' ')$(for w in /sys/class/watchdog/*; do [ -e "$w/identity" ] && printf '%s(%s, timeout %s s, state %s) ' "${w##*/}" "$(cat $w/identity)" "$(cat $w/timeout 2>/dev/null)" "$(cat $w/state 2>/dev/null)"; done)"
echo "-- hwrng: $(cat /sys/class/misc/hw_random/rng_current 2>/dev/null || echo none)"
echo "-- /proc/crypto drivers for the dm-crypt candidates and hashes (name / driver / priority):"
awk '/^name/ {n=$3} /^driver/ {d=$3} /^priority/ {p=$3} /^$/ { if (n ~ /xts|aes|adiantum|chacha|sha256|sha512|gcm|nhpoly|essiv|hctr2/) printf "  %-32s %-36s %s\n", n, d, p; n=d=p="" }' /proc/crypto | sort -u
echo "-- audit: loginuid $( [ -e /proc/self/loginuid ] && echo present || echo absent)"
echo "-- userspace tools:"
for t in nft iptables auditctl auditd cryptsetup veritysetup dmsetup bpftool bpftrace bwrap flatpak \
	apparmor_parser aa-status setenforce wg fsverity mksquashfs mkfs.erofs btrfs evmctl; do
	printf '  %-16s %s\n' "$t" "$(command -v $t || echo -)"
done

echo
echo "== eBPF probe (load-only, nothing attached)"
if command -v python3 >/dev/null && [ -f "$HERE/regenx-bpf-probe.py" ]; then
	python3 -I "$HERE/regenx-bpf-probe.py" 2>&1 | sed 's/^/  /'
else
	echo "  skipped: python3 or regenx-bpf-probe.py missing"
fi
} 2>&1 | tee "$OUT"
echo "report: $OUT"
exit 0

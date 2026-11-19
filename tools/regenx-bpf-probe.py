#!/usr/bin/env python3
"""eBPF capability probe for RegenX-AE telemetry -- docs/regenx-kernel-features.md.

Answers the concept doc's [Open] question "which eBPF features does the armv7
kernel support" by trying, through the raw bpf(2) syscall:
  - creating the map types a telemetry backend uses (hash, array, LRU, per-CPU,
    perf event array, ring buffer);
  - loading minimal programs of the types a backend would attach (socket
    filter, kprobe, tracepoint, raw tracepoint, perf event, cgroup skb/sock/
    sock_addr), and whether each was JIT-compiled;
  - two feature programs: a helper call (get_current_pid_tgid) plus
    bpf_ringbuf_output from a tracepoint program, and a BPF-to-BPF call.

Programs and maps are closed straight away; nothing is attached to anything.
Needs root (or CAP_BPF + CAP_PERFMON). Standard library only.
"""
import ctypes
import errno
import os
import struct

NR = {"armv7l": 386, "armv6l": 386, "aarch64": 280, "x86_64": 321}.get(os.uname().machine)
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

MAP_CREATE, PROG_LOAD, OBJ_GET_INFO_BY_FD = 0, 5, 15


def bpf(cmd, attr):
    buf = ctypes.create_string_buffer(bytes(attr), len(attr))
    r = libc.syscall(ctypes.c_long(NR), ctypes.c_int(cmd), buf, ctypes.c_uint(len(attr)))
    return r, (ctypes.get_errno() if r < 0 else 0)


def ins(code, dst=0, src=0, off=0, imm=0):
    return struct.pack("<BBhi", code, (src << 4) | dst, off, imm)


MOV_R0_0 = ins(0xB7, 0, 0, 0, 0)
EXIT = ins(0x95)


def map_create(mtype, key, val, entries):
    a = bytearray(128)
    struct.pack_into("<IIII", a, 0, mtype, key, val, entries)
    return bpf(MAP_CREATE, a)


def prog_load(ptype, insns, attach=0, gpl=True):
    code = ctypes.create_string_buffer(b"".join(insns))
    lic = ctypes.create_string_buffer(b"GPL" if gpl else b"MIT")
    log = ctypes.create_string_buffer(4096)
    a = bytearray(128)
    struct.pack_into("<II", a, 0, ptype, len(insns))
    struct.pack_into("<Q", a, 8, ctypes.addressof(code))
    struct.pack_into("<Q", a, 16, ctypes.addressof(lic))
    struct.pack_into("<II", a, 24, 1, len(log))
    struct.pack_into("<Q", a, 32, ctypes.addressof(log))
    struct.pack_into("<I", a, 68, attach)
    fd, err = bpf(PROG_LOAD, a)
    lastlog = [l for l in log.value.decode(errors="replace").splitlines() if l.strip()]
    return fd, err, (lastlog[-1] if lastlog else "")


def jited(fd):
    info = ctypes.create_string_buffer(256)
    a = bytearray(16)
    struct.pack_into("<II", a, 0, fd, len(info))
    struct.pack_into("<Q", a, 8, ctypes.addressof(info))
    r, err = bpf(OBJ_GET_INFO_BY_FD, a)
    if r < 0:
        return "info: %s" % errno.errorcode.get(err, err)
    j, x = struct.unpack_from("<II", info.raw, 16)
    return "jited %d bytes (xlated %d)" % (j, x) if j else "NOT jited (interpreter, xlated %d)" % x


def report(label, fd, err, extra=""):
    if fd >= 0:
        print("  %-34s ok   %s" % (label, extra if not callable(extra) else extra(fd)))
        os.close(fd)
        return True
    print("  %-34s FAIL %s%s" % (label, errno.errorcode.get(err, err), ("  [" + extra + "]") if isinstance(extra, str) and extra else ""))
    return False


def main():
    if NR is None:
        print("unknown machine %s -- no bpf syscall number" % os.uname().machine)
        return
    print("bpf(2) syscall %d on %s" % (NR, os.uname().machine))
    ncpu = os.cpu_count() or 1

    print("maps:")
    for name, args in (("hash", (1, 4, 8, 64)), ("array", (2, 4, 8, 64)),
                       ("perf_event_array", (4, 4, 4, ncpu)), ("percpu_hash", (5, 4, 8, 64)),
                       ("lru_hash", (9, 4, 8, 64)), ("ringbuf (64 KiB)", (27, 0, 0, 65536))):
        fd, err = map_create(*args)
        report(name, fd, err)

    print("program types (r0 = 0; exit):")
    simple = [MOV_R0_0, EXIT]
    for name, ptype, attach in (("socket_filter", 1, 0), ("kprobe", 2, 0), ("tracepoint", 5, 0),
                                ("perf_event", 7, 0), ("cgroup_skb", 8, 0), ("cgroup_sock", 9, 0),
                                ("raw_tracepoint", 17, 0), ("cgroup_sock_addr (inet4_connect)", 18, 10)):
        fd, err, log = prog_load(ptype, simple, attach)
        report(name, fd, err, jited if fd >= 0 else log)

    print("features:")
    rb, err = map_create(27, 0, 0, 65536)
    if rb >= 0:
        prog = [
            ins(0x85, imm=14),                    # call bpf_get_current_pid_tgid
            ins(0x7A, 10, 0, -8, 0),              # *(u64 *)(r10 - 8) = 0
            ins(0x18, 1, 1, 0, rb), ins(0),       # r1 = ringbuf map (ld_imm64, pseudo map fd)
            ins(0xBF, 2, 10),                     # r2 = r10
            ins(0x07, 2, 0, 0, -8),               # r2 += -8
            ins(0xB7, 3, 0, 0, 8),                # r3 = 8
            ins(0xB7, 4, 0, 0, 0),                # r4 = 0
            ins(0x85, imm=130),                   # call bpf_ringbuf_output
            MOV_R0_0, EXIT,
        ]
        fd, err, log = prog_load(5, prog)
        report("tracepoint: pid_tgid + ringbuf_output", fd, err, jited if fd >= 0 else log)
        os.close(rb)
    else:
        print("  %-34s skipped (no ringbuf map)" % "tracepoint: pid_tgid + ringbuf_output")
    prog = [ins(0x85, 0, 1, 0, 1), EXIT, MOV_R0_0, EXIT]   # call subprog at +1; exit / subprog: r0 = 0; exit
    fd, err, log = prog_load(1, prog)
    report("bpf-to-bpf call (subprogram)", fd, err, jited if fd >= 0 else log)


if __name__ == "__main__":
    main()

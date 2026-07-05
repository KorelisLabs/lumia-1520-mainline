#!/usr/bin/env python3
"""Pre-flight verifier for Nokia Lumia 1520 (RM-940) mainline boot images.

Run this against every freshly built boot.img BEFORE `fastboot boot`:

    python3 check-bootimg.py [path/to/boot.img]

It parses the Android boot image, extracts the DTB appended to the zImage,
and asserts the things that must be true for the image to have any chance of
reaching a root filesystem on the 1520:

  FAIL (exit 1)  - structural problems or hardware left disabled (eMMC/USB)
  WARN           - suspicious but not provably fatal (quiet cmdline, base addr,
                   placeholder GPIOs, unverified framebuffer address)

Stdlib only; no device access required.
"""

import re
import struct
import sys

# ---------------------------------------------------------------- reporting
errors = []
warnings = []
infos = []


def fail(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def info(msg):
    infos.append(msg)


# ------------------------------------------------------------- FDT parsing
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


class Node:
    def __init__(self, path):
        self.path = path
        self.props = {}
        self.children = []


def parse_fdt(blob):
    """Minimal flattened-device-tree parser -> {path: Node}."""
    off_struct, off_strings = struct.unpack(">II", blob[8:16])
    size_struct = struct.unpack(">I", blob[36:40])[0]
    strings = blob[off_strings:]

    def getstr(o):
        return strings[o:strings.index(b"\0", o)].decode()

    nodes = {}
    stack = []
    pos = off_struct
    end = off_struct + size_struct
    while pos < end:
        tok = struct.unpack(">I", blob[pos:pos + 4])[0]
        pos += 4
        if tok == 1:  # BEGIN_NODE
            e = blob.index(b"\0", pos)
            name = blob[pos:e].decode()
            pos = (e + 1 + 3) & ~3
            parent = stack[-1].path if stack else ""
            path = (parent + "/" + name) if name else "/"
            if path.startswith("//"):
                path = path[1:]
            node = Node(path if path else "/")
            nodes[node.path] = node
            if stack:
                stack[-1].children.append(node)
            stack.append(node)
        elif tok == 2:  # END_NODE
            stack.pop()
        elif tok == 3:  # PROP
            ln, nameoff = struct.unpack(">II", blob[pos:pos + 8])
            pos += 8
            stack[-1].props[getstr(nameoff)] = blob[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
        elif tok == 4:  # NOP
            continue
        elif tok == 9:  # END
            break
    return nodes


def prop_str(node, name):
    v = node.props.get(name)
    return v.rstrip(b"\0").decode(errors="replace") if v is not None else None


def prop_strlist(node, name):
    v = node.props.get(name)
    return v.rstrip(b"\0").decode(errors="replace").split("\0") if v else []


def status_of(node):
    # no status property == enabled
    return prop_str(node, "status") or "okay"


# --------------------------------------------------------------- boot image
def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "boot.img"
    try:
        d = open(path, "rb").read()
    except OSError as e:
        print(f"cannot read {path}: {e}")
        return 1

    print(f"== checking {path} ({len(d)} bytes) ==\n")

    if d[:8] != b"ANDROID!":
        fail("not an Android boot image (bad magic)")
        return report()

    (ksize, kaddr, rsize, raddr, ssize, saddr,
     tags, page) = struct.unpack("<8I", d[8:40])
    hdr_ver_or_dt = struct.unpack("<I", d[40:44])[0]
    cmdline = d[64:576].rstrip(b"\0").decode(errors="replace")

    info(f"kernel {ksize:#x} @ {kaddr:#x} | ramdisk {rsize:#x} @ {raddr:#x} | "
         f"tags {tags:#x} | page {page}")
    info(f"cmdline: {cmdline}")

    if page not in (2048, 4096):
        fail(f"unusual page size {page} (msm8974 expects 2048)")
    if hdr_ver_or_dt not in (0,):
        warn(f"header word 10 is {hdr_ver_or_dt:#x} -- expected 0 "
             "(v0 image, no dt.img) for the lk2nd appended-dtb path")

    # VERIFIED on hardware 2026-07-03: the 1520's UEFI framebuffer lives at
    # phys 0x00400000 (read from MDP5 RGB0 SRC0_ADDR). A kernel loaded at a
    # low base decompresses straight through it (and a ~15MB Image needs the
    # room), so the load address must stay well above the framebuffer.
    FB_PHYS = 0x00400000
    FB_SIZE = 0x00800000
    if kaddr < FB_PHYS + FB_SIZE + 0x1000000:
        fail(f"kernel load address {kaddr:#x} is too low -- it overlaps or "
             f"crowds the live UEFI framebuffer at {FB_PHYS:#x}. Use "
             'deviceinfo_flash_offset_base="0x10000000" (kernel at '
             "0x10008000); do NOT use base 0x0 on this device")

    # ----- kernel ---------------------------------------------------------
    k = d[page:page + ksize]
    if len(k) < ksize:
        fail("file truncated: kernel_size exceeds file")
        return report()

    if k[0x38:0x3c] == b"ARMd":
        fail("kernel is ARM64 -- the 1520 is 32-bit ARMv7")
    if k[0x24:0x28] != b"\x18\x28\x6f\x01":
        fail("kernel is not an ARM zImage (magic 0x016f2818 missing at 0x24)")
    else:
        info("kernel: ARMv7 zImage OK")

    # ----- ramdisk --------------------------------------------------------
    roff = page + ((ksize + page - 1) // page) * page
    r6 = d[roff:roff + 6]
    if r6[:2] == b"\x1f\x8b":
        info("ramdisk: gzip OK")
    elif r6[:4] == b"\x28\xb5\x2f\xfd":
        info("ramdisk: zstd")
    else:
        warn(f"ramdisk compression not recognized (starts {r6.hex()})")

    # ----- appended DTB ---------------------------------------------------
    hits = [m.start() for m in re.finditer(re.escape(FDT_MAGIC), k)]
    # keep only hits whose totalsize is sane and that end at/inside the kernel
    dtbs = []
    for h in hits:
        if h + 8 > len(k):
            continue
        total = struct.unpack(">I", k[h + 4:h + 8])[0]
        if 64 <= total <= 2 * 1024 * 1024 and h + total <= len(k):
            dtbs.append((h, total))
    # the appended dtb is the one that ends exactly at kernel end
    tail = [(h, t) for (h, t) in dtbs if h + t == len(k)]
    if not tail:
        fail("no DTB appended at the end of the zImage -- "
             "deviceinfo_append_dtb did not take effect")
        return report()
    if len(dtbs) > 1 and len(tail) == 1:
        info(f"{len(dtbs)} FDT blobs in kernel; using the appended one "
             f"at {tail[0][0]:#x}")
    h, total = tail[0]
    nodes = parse_fdt(k[h:h + total])
    root = nodes.get("/")
    if root is None:
        fail("appended DTB did not parse")
        return report()

    model = prop_str(root, "model")
    compat = prop_strlist(root, "compatible")
    info(f"DTB: model={model!r} compatible={compat}")
    if "qcom,msm8974" not in compat:
        fail("DTB compatible does not include qcom,msm8974 -- wrong dtb appended")
    if not any(c.startswith("microsoft,") or c.startswith("nokia,")
               for c in compat):
        warn("DTB compatible has no microsoft,*/nokia,* entry -- is this the "
             "rm940 tree?")

    def find(sub):
        return [n for p, n in nodes.items() if sub in p]

    # ----- the checks that would have caught the dead boot.img ------------
    # eMMC: sdhc_1 = mmc@f9824900 on msm8974
    emmc = nodes.get("/soc/mmc@f9824900")
    if emmc is None:
        emmc_c = [n for n in find("mmc@") if "f9824" in n.path]
        emmc = emmc_c[0] if emmc_c else None
    if emmc is None:
        fail("eMMC node (mmc@f9824900 / sdhc_1) missing from DTB")
    elif status_of(emmc) != "okay":
        fail(f"eMMC (sdhc_1) is status={status_of(emmc)!r} -- kernel will see "
             "NO internal storage; pmos_root_uuid can never be found")
    else:
        info("eMMC (sdhc_1): enabled")

    usb = nodes.get("/soc/usb@f9a55000")
    if usb is None:
        fail("USB controller node (usb@f9a55000) missing from DTB")
    elif status_of(usb) != "okay":
        fail(f"USB controller is status={status_of(usb)!r} -- no USB gadget, "
             "no pmOS initramfs debug/telnet fallback")
    else:
        info("USB controller: enabled")
        phys = [n for p, n in nodes.items()
                if p.startswith("/soc/usb@f9a55000/") and "/phy-" in p]
        if phys and not any(status_of(p) == "okay" for p in phys):
            fail("USB controller enabled but every USB PHY is disabled -- "
                 "USB still cannot come up")
        elif phys:
            info("USB PHY: at least one enabled")

    serials = [n for n in find("/soc/serial@")]
    if serials and not any(status_of(s) == "okay" for s in serials):
        warn("no UART enabled -- fine if you have no serial hookup, but "
             "consider enabling blsp1_uart2 once the pad is identified")

    # framebuffer
    fbs = [n for p, n in nodes.items() if "/chosen/framebuffer@" in p]
    if not fbs:
        fail("no simple-framebuffer under /chosen -- you will have zero "
             "display output even on a successful boot")
    else:
        fb = fbs[0]
        reg = fb.props.get("reg", b"")
        fb_base = struct.unpack(">I", reg[:4])[0] if len(reg) >= 8 else None
        info(f"framebuffer: {fb.path} base={fb_base:#x}" if fb_base is not None
             else f"framebuffer: {fb.path}")
        if fb_base is not None and fb_base != FB_PHYS:
            fail(f"framebuffer base {fb_base:#x} does not match the "
                 f"hardware-verified scanout address {FB_PHYS:#x} (read "
                 "from MDP5 RGB0 SRC0_ADDR on the live device 2026-07-03)")
        # matching reserved-memory carve-out
        rm = [p for p in nodes if p.startswith("/reserved-memory/")
              and "framebuffer" in p]
        if not rm:
            warn("framebuffer has no /reserved-memory carve-out -- kernel may "
                 "hand the scanout region to the allocator")

    # memory node (bootloader must fill this; zero size is normal pre-boot)
    mem = nodes.get("/memory@0") or nodes.get("/memory")
    if mem is not None:
        regv = mem.props.get("reg", b"")
        if len(regv) >= 8 and struct.unpack(">II", regv[:8]) == (0, 0):
            info("memory@0 is <0 0> (normal: lk2nd/aboot patches it from SMEM)")

    # gpio-keys placeholder detection (all keys on the same GPIO)
    for p, n in nodes.items():
        if "gpio-keys" in p and n.children:
            pins = []
            for c in n.children:
                g = c.props.get("gpios")
                if g and len(g) >= 12:
                    pins.append(struct.unpack(">I", g[4:8])[0])
            if len(pins) > 1 and len(set(pins)) == 1:
                fail(f"{p}: all {len(pins)} keys claim GPIO {pins[0]} -- "
                     "placeholder values made it into the build")

    # ----- cmdline hygiene -------------------------------------------------
    if "quiet" in cmdline.split():
        warn('cmdline contains "quiet" -- you will not see kernel messages. '
             "Remove it for bring-up")
    if "splash" in cmdline.split():
        warn('cmdline contains "splash" -- plymouth will paint over the '
             "console. Remove it for bring-up")
    if "console=" not in cmdline:
        warn("no console= in cmdline -- add console=tty0 loglevel=8 so panics "
             "stay on screen")
    for good in ("clk_ignore_unused", "pd_ignore_unused"):
        if good not in cmdline:
            warn(f"cmdline is missing {good} -- first boots on msm8974 "
                 "usually need it")
    # CONFIRMED by experiment 2026-07-04: the 1520's Windows-Phone TrustZone
    # rejects the SCM calls mainline uses to start secondary Krait cores; the
    # SoC resets before any log exists. Single-core is mandatory until an
    # alternate SMP enable-method is implemented.
    if "nosmp" not in cmdline.split():
        fail("cmdline lacks 'nosmp' -- SMP bring-up SCM calls crash the "
             "WP TrustZone instantly on this device; add 'nosmp maxcpus=1'")
    if "cpuidle.off=1" not in cmdline.split():
        warn("cmdline lacks 'cpuidle.off=1' -- deep idle (SPC) also goes "
             "through the WP TrustZone; keep it off until proven safe")
    if "pmos_root_uuid" not in cmdline and "pmos_root" not in cmdline:
        warn("no pmos_root*/pmos_boot* in cmdline -- initramfs won't know "
             "where the rootfs lives")

    return report()


def report():
    print()
    for m in infos:
        print(f"  info  {m}")
    for m in warnings:
        print(f"  WARN  {m}")
    for m in errors:
        print(f"  FAIL  {m}")
    print()
    if errors:
        print(f"RESULT: FAIL ({len(errors)} fatal, {len(warnings)} warnings) "
              "-- do NOT fastboot boot this image")
        return 1
    if warnings:
        print(f"RESULT: PASS with {len(warnings)} warnings -- bootable in "
              "principle, read the warnings")
        return 0
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

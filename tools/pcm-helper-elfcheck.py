#!/usr/bin/env python3
"""Confirm a built binary is a 32-bit little-endian ARM ELF.

The host toolchain here is x86_64 and `file` is not guaranteed to be
installed, so the ELF header is read directly rather than shelled out for.
Getting this wrong once already cost a hardware cycle in this project -- a
binary that is not for the device fails on the device, where the failure is
expensive and ambiguous.

Exit: 0 it is a 32-bit ARM ELF, 1 it is not, 2 usage error.
"""

import struct
import sys

EI_CLASS_32 = 1
ELFDATA2LSB = 1
EM_ARM = 40


def check(path: str) -> int:
    with open(path, "rb") as f:
        hdr = f.read(20)

    if len(hdr) < 20 or hdr[:4] != b"\x7fELF":
        print("  not an ELF file")
        return 1

    eclass = hdr[4]
    edata = hdr[5]
    etype, emachine = struct.unpack("<HH", hdr[16:20])

    print("  ELF    : class=%s data=%s type=%d machine=%d (%s)" % (
        "32-bit" if eclass == EI_CLASS_32 else "64-bit",
        "LSB" if edata == ELFDATA2LSB else "MSB",
        etype, emachine,
        "EM_ARM" if emachine == EM_ARM else "NOT ARM"))

    ok = (eclass == EI_CLASS_32 and edata == ELFDATA2LSB
          and emachine == EM_ARM)
    if not ok:
        print("  REFUSED: this will not run on the device")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(check(sys.argv[1]))
    except OSError as e:
        print("cannot read %s: %s" % (sys.argv[1], e), file=sys.stderr)
        sys.exit(2)

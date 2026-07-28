#!/usr/bin/env python3
"""Split a Qualcomm PIL firmware .mbn into the .mdt + .bNN files that the
mainline qcom_mdt loader expects.

    python3 pil-split.py <firmware.mbn> <output-dir> <basename>
    e.g. python3 pil-split.py qcadsp8974.mbn /lib/firmware adsp

Format: each .bNN holds program header N's file data; the .mdt is b00
(the ELF header plus program-header table) concatenated with b01 (the
hash segment).

Validated by re-splitting the stock qcwcnss8974.mbn and confirming it
reproduces a known-good wcnss.mdt/.bNN set byte for byte.

The firmware blobs themselves are Nokia/Microsoft property -- extract them
from your own device (see docs/trustzone-quirks.md), do not redistribute.
"""
import os
import struct
import sys


def split(path, outdir, base):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF (got magic {d[:4]!r})")
    e_phoff, = struct.unpack("<I", d[0x1c:0x20])
    e_phentsize, e_phnum = struct.unpack("<HH", d[0x2a:0x2e])
    os.makedirs(outdir, exist_ok=True)

    parts = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        _, off, _, _, filesz, _, _, _ = struct.unpack("<8I", d[o:o + 32])
        blob = d[off:off + filesz] if filesz else b""
        fn = os.path.join(outdir, f"{base}.b{i:02d}")
        with open(fn, "wb") as f:
            f.write(blob)
        parts.append(fn)

    if len(parts) < 2:
        raise SystemExit("expected at least 2 program headers (image + hash)")
    mdt = open(parts[0], "rb").read() + open(parts[1], "rb").read()
    mdt_path = os.path.join(outdir, f"{base}.mdt")
    with open(mdt_path, "wb") as f:
        f.write(mdt)
    return mdt_path, len(mdt), len(parts)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        raise SystemExit(1)
    mdt, size, n = split(sys.argv[1], sys.argv[2], sys.argv[3])
    print(f"wrote {mdt} ({size} bytes) and {n} segment files")

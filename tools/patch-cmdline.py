#!/usr/bin/env python3
"""Patch the kernel cmdline of an Android boot image in place.

    python3 patch-cmdline.py <in.img> <out.img> "<extra args>"     # append
    python3 patch-cmdline.py <in.img> <out.img> = "<full cmdline>" # replace

The cmdline lives in a fixed 512-byte header field, so no repack is needed.
Used for fast bring-up experiments over `fastboot boot` without a pmbootstrap
rebuild cycle.
"""
import sys

def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    d = bytearray(open(src, "rb").read())
    assert d[:8] == b"ANDROID!", "not a boot image"
    cur = bytes(d[64:576]).rstrip(b"\0").decode()
    if sys.argv[3] == "=":
        new = sys.argv[4]
    else:
        new = (cur + " " + sys.argv[3]).strip()
    enc = new.encode()
    assert len(enc) <= 512, f"cmdline too long ({len(enc)} > 512)"
    d[64:576] = enc.ljust(512, b"\0")
    open(dst, "wb").write(d)
    print(f"old: {cur}\nnew: {new}\nwrote {dst}")
    return 0

if __name__ == "__main__":
    sys.exit(main())

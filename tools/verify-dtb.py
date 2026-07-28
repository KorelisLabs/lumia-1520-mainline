#!/usr/bin/env python3
"""Check that a built boot.img's appended DTB actually contains expected
node/property names. Catches builds that silently reused stale artifacts."""
import re, struct, sys
img, needles = sys.argv[1], sys.argv[2:]
d = open(img, "rb").read()
ks, = struct.unpack("<I", d[8:12]); ps, = struct.unpack("<I", d[36:40])
k = d[ps:ps+ks]
hits = [m.start() for m in re.finditer(b"\xd0\x0d\xfe\xed", k)]
tail = [h for h in hits if h + struct.unpack(">I", k[h+4:h+8])[0] == len(k)]
if not tail: sys.exit("no appended DTB found")
h = tail[0]; dtb = k[h:h+struct.unpack(">I", k[h+4:h+8])[0]]
ok = True
for n in needles:
    found = n.encode() in dtb
    print(f"  {'FOUND  ' if found else 'MISSING'} {n}")
    ok &= found
print("DTB CONTENT:", "OK" if ok else "STALE / MISSING CHANGES")
sys.exit(0 if ok else 1)

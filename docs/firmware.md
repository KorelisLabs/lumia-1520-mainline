# Firmware (not redistributed here)

The WCNSS (Wi-Fi/BT) radio needs firmware that is proprietary to
Nokia/Microsoft and lives in the device's own stock partitions. **It is not
included in this repository** — its redistribution terms are unknown. This
page documents how to extract it yourself and lists hashes so you can verify
what you produced.

Note that WCNSS is currently **disabled** on the default branch anyway
(see [trustzone-quirks.md](trustzone-quirks.md) §4) — Pronto times out after
the PAS reset call reports success. These instructions exist for anyone
continuing that investigation on the `research/pronto-pas-timeout` branch.

## Where it comes from

The stock Windows Phone firmware carries the WCNSS image as
`qcwcnss8974.mbn` (a Qualcomm MBN / signed ELF). Mainline's `qcom-wcnss-pil`
loader expects it split into an MDT header plus `.bNN` segment files. The
split is a mechanical operation on the MBN's ELF program headers — the
standard `pil-squasher`/`mdt` tooling (or a short script over the ELF
phdrs) produces `wcnss.mdt` + `wcnss.b00`..`wcnss.b09`, which go in
`/lib/firmware/` on the device.

Source of the MBN on a live device: it is present in the mounted stock
firmware/OS partitions. Extract it from your own device; do not obtain it
from third parties.

## Verification hashes (SHA-256)

These are the exact files that were loaded on the reference RM-940 (AT&T).
Yours should match if you extracted from equivalent stock firmware; a
mismatch is expected across different firmware revisions and is not
necessarily wrong.

```
7d4deb9b92d3ad0c19c62d3cd5191fb1d4cf59e56ce8b2d6c342c38756641258  wcnss.mdt
4bcca67fdf7bbfe49ce5163d451f6964f3a99b7f6a44106c8ebf70fe76f7017e  wcnss.b00
e61119b56afcc4df43a5d169a47d82656bb00903bbe34998fc677c6423b7e7dc  wcnss.b01
7a7641b469521ca4d3bac4e1974cd0fe543ea3053555beaa41bf84f391177ae5  wcnss.b02
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  wcnss.b03  (empty segment)
ff72250b797e43fab6da8c9f50a36df8cc279fd243d5b4290706fc45f751094a  wcnss.b04
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  wcnss.b05  (empty segment)
673ecc8bb04307080dd1b45a2cbf98b8af9d4fe502d2fb0914c748b36a5536b9  wcnss.b06
2fe403ee4aa2bf697576ca860c232d11e167432c03fbed19cf821e8960359325  wcnss.b07
c7b5316c9d8578884876093771a600656b2d802f6dcfb26b6cc899bd03bbd645  wcnss.b08
b2c9a7d8eb544c67cfb0a3f426d41f931e37db14788fa16058049f36794b9af1  wcnss.b09
```

(`.b03` and `.b05` are zero-length ELF segments — the identical hash there
is the SHA-256 of the empty input, which is correct.)

# The class-H power state is reversible

**Status:** proven on hardware, 2026-08-23 (C2a).
**Kernel:** 6.16.12 r163, codec `clsh-rc1`.
**Evidence:** `wcd9320-clsh-reversibility-20260823T172253Z.txt` — cold boot,
82 checks, 0 failed.
**Also kept:** `wcd9320-clsh-reversibility-20260823T171837Z.txt` — 76/2, the
run whose two failures were defects in the gate, recorded because the
corrections are the useful part.

## What is proven

The HPHL class-H support circuitry — buck, negative charge pump, class-H block —
can be brought from its pristine idle state into the downstream-required
configuration and returned, **twice**, with the DAC and PA off throughout.

```
cycle 1:  e4 -> a7 -> a6
cycle 2:  a6 -> a7 -> a6
```

exactly as derived. 46 writes in per enable, 6 out per teardown, 104 total.

| bucket | result |
|---|---|
| power bits | returned to their pre-run values, both cycles |
| configuration | reached its mapped value and stayed programmed |
| DAC 0x1b1, PA 0x1ab, EAR 0x1bc | did not move |
| charge pump | refcount back to 0, no warning in dmesg |
| cycle 2 vs cycle 1 | identical |

Cycle 1 converts the reset configuration into the downstream steady state;
cycle 2 is reversible from that steady state. That is a reusable lifecycle, not
a one-way transition, which is what the DAC milestone needs to inherit.

## What this does not claim

Nothing was converted and nothing was audible. The DAC and PA were off, no audio
data was streamed. This is a power-state lifecycle result only.

## Two things the hardware taught us, both by failing my gate first

### 1. Three registers do not reset to their header POR

`BUCK_MODE_3` read `ce` against a header `cc`, `BUCK_CTRL_CCL_1` read `5b`
against `ab`, and `BUCK_CTRL_CCL_4` read `51` against `58`. All three are in
**0x180–0x1e4**, the fuse-loaded analog trim range this project had already
documented as diverging from the header — a fact recorded during the
register-map work and not applied here until the gate refused.

The gate rightly exited INVALID rather than proceeding. The fix was to make
every expectation **baseline-relative**: take what the device actually reads and
apply the transcribed masked writes to it. The transforms still come from the
downstream tables, so nothing is weakened — only the starting point is measured
instead of assumed, and the result is immune to per-device fuse variation.

All three then matched exactly: `ce→c2`, `5b→5b` (unchanged), `51→50`.

### 2. Power and configuration are per-bit, not per-register

The second run failed two checks asserting that power registers return to their
baseline. They do not: `B1_CTL` ends at `a6` from a base of `e4`, and
`BUCK_MODE_1` at `25` from `21`.

**Both registers hold configuration bits alongside their power bits.** The
enable sets configuration that the teardown has no reason to undo. The
three-bucket model had to become per-bit for those two, with masks for the bits
the teardown actually restores:

| register | power mask | bits |
|---|---|---|
| `CDC_CLSH_B1_CTL` | `0x19` | clsh block, comp req, EAR compute |
| `BUCK_MODE_1` | `0x80` | buck enable |
| `NCP_EN` | `0x01` | NCP enable |
| `CDC_CLK_OTHR_CTL` | `0x01` | charge pump |

Both errors were mine, both were in the gate rather than the driver, and both
surfaced only because the expectations were **derived rather than observed**. A
gate written to record what the hardware did would have passed on the first run
with the model still wrong.

## Also corrected

The C2a map predicted `CDC_CLSH_B2_CTL = 0x31`; composing its three masked
writes properly gives **`0x35`**, which is what the hardware shows. That value
was written by hand instead of derived, which is exactly the mistake the
derivation script now prevents.

## What this unblocks

C2b — the HPHL DAC — may now be built, because its teardown is proven before the
conversion path is ever powered. The remaining pieces are the compander→HPH gain
handoff (`0x1ae`, `0x1b4`, `0x373`), the `CLASS_H_DSM` mux (`0x3b0`), the RDAC
clock (`0x30d`), the DAC enable (`0x1b1`) and RX bias — still stopping before
the PA.

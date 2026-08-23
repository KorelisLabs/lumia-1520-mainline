# The RX1 digital chain operates

**Status:** proven on hardware, 2026-08-23 (Branch C, first milestone).
**Kernel:** 6.16.12 r161, codec `rx1-digital-rc1`, card `q6-card-rc3`.
**Evidence, all from one cold boot:**

| file | run | result |
|---|---|---|
| `msm8974-slim-stream-20260823T131234Z.txt` | B1 regression | 31/31 |
| `wcd9320-rx1-digital-20260823T131238Z.txt` | **RX1 experiment** | 23/23 |
| `msm8974-q6-data-plane-20260823T131246Z.txt` | B2 regression | 29/29 |

## What is proven

The five-register RX1 digital chain can be programmed on hardware, running
underneath the proven QDSP6 loop and SLIMbus stream, and torn down cleanly.

| step | register | wrote | read back |
|---|---|---|---|
| input mux -> RX1 | `CDC_CONN_RX1_B1_CTL` 0x380 | 0x05 | **05** |
| interpolator reset | `CDC_CLK_RX_RESET_CTL` 0x301 | pulse 1 then 0 | **00** |
| interpolator clock | `CDC_CLK_RX_B1_CTL` 0x30F | bit 0 | **01** |
| digital gain latch | `CDC_RX1_VOL_CTL_B2_CTL` 0x2B7 | re-write | **00** |
| chain output | `CDC_RX1_B6_CTL` 0x2B5 | bit 5 | **a0** |
| rate (asserted, not written) | `CDC_RX1_B5_CTL` 0x2B4 | — | **78** = 48 kHz |

Six writes, because the reset is a pulse. The QDSP6 loop stayed healthy in both
phases — one ASM RUN each, 154 and 155 period completions, the SLIMbus stream
up each time — so enabling the RX chain does not disturb anything proven
earlier. Teardown restored the exact idle baseline (`00`/`00`/`80`), and the six
guarded analog registers did not move.

**The clock question is answered in practice.** The interpolator was enabled and
its clock gate took, on RCO, with no MCLK anywhere on this board and no source
switch requested — exactly as `wcd9320-rx-clock-resolution.md` predicted from
source.

## What is NOT proven, and a correction to the evidence file

`0x376` read `03` across all 48 samples, in both phases.

**The evidence file's own finding text overreaches, and is wrong.** It says the
hypothesis "is NOT supported" and that "no receiver-side digital observable has
been found". That is not what this run shows, because **the compander was never
enabled**: `COMP1_B1_CTL` sat at its POR `0x30` throughout, since enabling it
was outside the frozen five-register scope.

A disabled block reporting its reset status is exactly what should happen. So:

- **shown:** the RX1 chain alone does not move `0x376`
- **not shown:** that `0x376` is useless as an observable

The hypothesis is **untested, not refuted**, and conflating those would have
retired a promising observable on no evidence. The gate's wording has been
corrected for future runs; the evidence file is kept verbatim, with this note as
the correction, because rewriting a machine's output after the fact is worse
than annotating it.

## Resolved: `0x376` is an enable flag

The follow-up ran with the compander actually enabled, four phases on one cold
boot. `0x376` moved `03` -> `00` when the compander was switched on, and then
did not move for a live chain, a live stream, or the transport being removed.

It is an enable-state flag and carries nothing about received data. See
[wcd9320-comp1-observable.md](wcd9320-comp1-observable.md). The "untested, not
refuted" caveat below is now settled: properly tested, and refuted.

## Consequences

Branch B's byte-arrival gap remains open. Nothing here changes it.

The next experiment is small and well-defined: enable compander 1 —
`CDC_COMP1_B1_CTL` 0x370 plus its clock bits in `CDC_CLK_RX_B2_CTL` 0x310 and
the reset in `CDC_CLK_OTHR_RESET_B2_CTL` — and re-run the identical
control/treatment shape. That is three more registers on top of a chain now
proven to work, and it decides whether `0x376` can close the gap before any
analog path exists.

If the compander is enabled and `0x376` still does not distinguish streaming
from idle, *then* the negative result is earned, and the answer is that this
part offers no digital receiver-side observable — which would point squarely at
the analog path as the only remaining route to byte-arrival proof.

## Still open

- **`0x376` semantics.** Untested. See above.
- **Byte arrival at the codec.** Unproven since Branch B; unchanged.
- **The 1.4–1.5% pacing offset.** Unchanged and unexplained; it lives on the
  ASM/host/DSP side, not here.

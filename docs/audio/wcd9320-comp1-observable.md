# `0x376` is an enable flag, not an activity indicator

**Status:** measured negative result, 2026-08-23. Branch C follow-up.
**Kernel:** 6.16.12 r162, codec `comp1-rc1`.
**Evidence:** `wcd9320-comp1-observable-20260823T155316Z.txt` (22/22), with
`msm8974-slim-stream-20260823T155312Z.txt` (31/31) as the B1 regression on the
same cold boot.

## The question

Branch B proved the QDSP6 consumes periods at real time, and proved the codec's
SLIMbus endpoint activates — but its negative control showed those two facts are
**not linked by any available measurement**. Closing that gap needs something on
the receiving end that reacts to data arriving.

`CDC_COMP1_SHUT_DOWN_STATUS` (0x376) was the candidate: a digital block on the
interpolator output, volatile and readable, serving RX1/RX2.

The RX1 chain milestone left it untested — the compander was never enabled, so
its POR reading proved nothing. This is the proper test.

## Four phases, one variable at a time

| phase | compander | RX1 chain | stream | `0x376` |
|---|---|---|---|---|
| **A** baseline | off | off | none | `03` |
| **B** enable only | **on** | off | none | **`00`** |
| **C** treatment | on | **on** | **QDSP6 + SLIMbus** | `00` |
| **D** transport off | on | on | QDSP6 only, codec stream suppressed | `00` |

24 samples per phase, all identical within each phase.

| comparison | differ | meaning |
|---|---|---|
| A → B | **yes** | it tracks compander enable state |
| B → C | **no** | it learns nothing from a chain and a live stream |
| C → D | **no** | it learns nothing from the transport disappearing |

## The result

`0x376` is an **enable-state flag**: `0x03` means both compander channels are
shut down, `0x00` means both are running. It carries no information about what
the block is receiving.

Phase C had 155 period completions and an active SLIMbus stream; phase D had 155
completions with the codec's stream suppressed entirely. The register did not
distinguish them, and did not distinguish either from an idle compander sitting
with no chain at all.

**This is a real negative, unlike the previous attempt.** The compander was
genuinely running — `0x370` read `33` and its clocks `03` — so the hypothesis
was properly exercised rather than sidestepped. The earlier RX1 run could not
say this, and the milestone doc for it was corrected to say so.

## Consequence

**No receiver-side digital observable has been found on this part.** Branch B's
byte-arrival gap cannot be closed from the digital side, and the next
opportunity is the analog path — a DAC that either produces a signal or does
not.

That is worth knowing precisely because it removes a branch from the search.
Two candidate observables have now been eliminated by measurement rather than
by assumption:

- `0x376` — enable state only, shown here
- the QDSP6 `hw_ptr` / period loop — DSP-side only, shown by Branch B's
  codec-absent control

## What was also confirmed

The implementation side passed 22/22:

- compander enables and disables cleanly (`0x370` → `33` → `30`, clocks
  `0x310` → `03` → `00`)
- the RX1 chain still enables and tears down alongside it
- the QDSP6 loop stayed healthy in both streaming phases — one ASM RUN each,
  155 completions each
- phase D genuinely suppressed the codec stream (`slim_stream_enable` = 0
  against 1 in phase C)
- **no analog register moved**, including `RX_HPH_L_GAIN` (0x1AE),
  `RX_HPH_R_GAIN` (0x1B4) and `COMP1_B4_CTL` (0x373) — the three the downstream
  compander sequence would have written and which were deliberately omitted
- teardown restored the exact idle baseline

## Still open

- **Byte arrival at the codec.** Unproven, and now known to be unprovable from
  the digital side of this part.
- **The 1.4–1.5% pacing offset.** Unchanged; lives on the ASM/host/DSP side.

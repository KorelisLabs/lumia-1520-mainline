# The QDSP6 data plane: RUN, WRITE, and what progression actually proves

**Status:** proven on hardware, 2026-08-23 (Branch B2).
**Kernel:** 6.16.12 r160, codec `dataplane-rc2`, card `q6-card-rc3`.
**Evidence, all from one cold boot:**

| file | run | result |
|---|---|---|
| `msm8974-slim-stream-20260823T121201Z.txt` | B1 regression | 31/31 |
| `msm8974-q6-data-plane-20260823T121205Z.txt` | B2 positive | 29/29 |
| `msm8974-q6-data-plane-20260823T121211Z.txt` | **negative control** | 25/25 |

## What is proven

An ordinary PCM open / write / START on the QDSP6 front end drives ASM RUN; the
DSP acknowledges it; and the WRITE / WRITE_DONE loop then runs at real time.

- exactly **one** `q6asm_run_nowait`, with the first `q6asm_write_async`
  following it — the acknowledgement made visible, since that first write is
  issued from the `RUN_DONE` handler
- **155** `q6asm_write_async` and **155** `snd_pcm_period_elapsed`, tracking 1:1
- `hw_ptr` advanced **146880** frames = 155 x 960, matching the completion count
- sustained **48684.3 frames/s** against a 48000 target, zero xruns
- the WCD9320's SLIMbus RX stream was enabled before the first period and torn
  down after the last, and ASoC drove all of it

## What the negative control changed

Running the identical path with the codec performing **no** `slim_stream_prepare()`
and **no** `slim_stream_enable()` — same front end, same ASM session, same AFE
port 0x4000, same channel 144, same geometry:

| | positive | negative |
|---|---|---|
| codec SLIMbus stream | active | none |
| `slim_stream_prepare` / `enable` | 1 / 1 | **0 / 0** |
| `qcom_slim_ngd_enable_stream` | 1, returned 0 | **0** |
| completions | 155 | 155 |
| measured rate | 48684.3 fps | **48677.1 fps** |
| `hw_ptr` advance | 146880 | 146880 |
| xruns | 0 | 0 |

**0.015% apart, with identical pointer advance.**

So period progression is a property of the DSP consuming its own mapped buffer.
It is **not** evidence that anything traversed SLIMbus. The driver issues
`q6asm_write_async()` from its event handler whether or not a sink exists, and
the measurement cannot tell the difference.

This is worth stating plainly because it *weakens* the headline result. Before
the control, "the DSP consumes at 48 kHz while the codec's stream is active"
looked like a chain. It is two concurrent facts. The control is what
distinguishes those, and it cost one boot.

## What may and may not be claimed

**May:** ASM RUN is issued and acknowledged; the DSP consumes periods from the
mapped buffer at real time; concurrently and independently, the codec's SLIMbus
RX stream is correctly established and torn down (that is B1's result, re-proven
here).

**May not:** that the bytes written reached the WCD9320, or arrived intact.
Closing that gap needs a receiver-side counter or a loopback, and this hardware
offers neither. Nothing is audible regardless — the codec has no RX
interpolator and no output path.

## A real defect found and fixed on the way

The ASoC default `TRIGGER_PRE` is backwards for a playback front end at **both**
ends, because `dpcm_fe_dai_do_trigger()` passes `fe_first` for START and
`!fe_first` for STOP. Measured on r158: exactly one period completed before the
codec's stream was enabled, and one after it was disabled — 960 frames, 20 ms,
consumed at each end while the codec channel was not connected.

`TRIGGER_POST` on our own FE link corrects both, because ASoC applies the same
reversal to it. No machine driver under `sound/soc/qcom/` sets this, so every
mainline Qualcomm board carries the same 20 ms glitch; it is inaudible there
only until something is listening.

Head leakage went 1 -> 0. See `msm8974-q6-data-plane-20260823T111621Z.txt` for
the before.

### And a prediction of mine that was wrong

I expected `TRIGGER_POST` to zero both ends symmetrically. It did not, and the
reason matters: the two ends are not the same measurement.
`snd_pcm_period_elapsed` is an **acknowledgement**, and the FE stop is
`q6asm_cmd_nowait(CMD_EOS)` — asynchronous. A `WRITE_DONE` already in flight
still lands, and the transfer it acknowledges happened before the disconnect. At
least one trailing ack is inherent and no driver change removes it.

The tail check now asserts the ordering of the **requests** — EOS issued before
`slim_stream_disable` — and bounds trailing acks rather than forbidding them.
`msm8974-q6-data-plane-20260823T114945Z.txt` is kept as the record of the
mis-specified check.

## Unexplained

The rate is reproducibly **1.4-1.5% fast**: 48676.0, 48686.3, 48743.2, 48708.2,
48684.3, and 48677.1 across six runs, with the helper's independent userspace
figure tracking within 0.1%. That reproducibility rules out drift and
measurement noise. It is a real clock offset, most likely the ADSP's. Notably it
is **unchanged in the negative control**, which means whatever paces the loop is
not the SLIMbus side.

## Next

Byte-level proof needs a receiver, which means the codec's RX path: interpolator,
CLSH, an output stage, and a DAPM graph. That is a separate and much larger
branch, and it is also the first point at which anything becomes audible.

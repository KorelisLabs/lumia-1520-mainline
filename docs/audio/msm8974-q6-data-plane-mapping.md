# Branch B2 design map: RUN, WRITE, WRITE_DONE, period progression

**Status:** design map only. Nothing built, nothing claimed on hardware.
Read `msm8974-slim-rx-stream.md` (B1) first — this begins where that ends.

## Scope

**In:** ASM RUN, the WRITE/WRITE_DONE loop, and measurable period progression,
with the codec's SLIMbus RX stream driven from the DAI's `trigger` rather than
from a debugfs hook.

**Out, deliberately:** the analog codec path. No interpolator, no CLSH, no
HPH/EAR, no DAPM graph, no output routing. Nothing in this milestone will be
audible, and nothing in it should touch that code.

## The mechanism: the DSP drives the loop, not userspace

This is the fact that determines what B2 can honestly claim.

```
trigger(START)              -> q6asm_run_nowait()
   ADSP: RUN_DONE           -> q6asm_write_async()          (the FIRST write)
   ADSP: WRITE_DONE         -> pcm_irq_pos += pcm_count
                               snd_pcm_period_elapsed()
                               q6asm_write_async()          (the NEXT write)
   ...repeats until the state leaves Q6ASM_STREAM_RUNNING
```

Userspace `write()` copies samples into the mapped buffer and nothing more. The
driver issues `q6asm_write_async()` from the event handler **regardless of
whether userspace has supplied anything**, so the DSP consumes the buffer either
way.

**Consequence for the claim.** Period progression proves the DSP is fetching
from the mapped buffer at a real rate. It does *not* prove our bytes were the
bytes consumed. There is no loopback and no codec-side byte counter, so
end-to-end data integrity is not provable at this milestone and must not be
claimed.

## Why hw_ptr is unusually good evidence here

```c
static snd_pcm_uframes_t q6asm_dai_pointer(...)
{
	if (prtd->pcm_irq_pos >= prtd->pcm_size)
		prtd->pcm_irq_pos = 0;
	return bytes_to_frames(runtime, prtd->pcm_irq_pos);
}
```

`pcm_irq_pos` is incremented in exactly one place: the `WRITE_DONE` handler. So
the pointer is not a timer estimate or a DMA register read — **it is a count of
DSP acknowledgements**. Every frame of `hw_ptr` advance is the ADSP saying it
took a period.

That makes the strongest available measurement a **rate**: frames consumed per
second of wall clock. At 48 kHz, sustained progression at ~48000 frames/s means
the DSP is clocking data through at real time rather than merely accepting
commands. A stalled or absent data path shows up as zero or erratic progression,
and an xrun shows up in the PCM state. This is the check B2 should rest on.

## Trigger ordering: the FE runs before the BE

`qcom_snd_parse_of()` sets no trigger order, so the ASoC default applies:

```c
enum snd_soc_dpcm_trigger {
	SND_SOC_DPCM_TRIGGER_PRE  = 0,   /* fe_first = true */
	SND_SOC_DPCM_TRIGGER_POST,
};
```

Zero is `PRE`, and `PRE` sets `fe_first = true`. **No machine driver under
`sound/soc/qcom/` overrides it.** So `q6asm_run_nowait()` is issued *before* the
codec's `trigger(START)` brings the SLIMbus stream up, and the first period or
two may be pushed toward a channel the codec has not yet connected.

Every mainline Qualcomm board ships this way, so it is evidently tolerable, and
B2 should match mainline rather than invent a local deviation. But the gate
should **measure the actual order** from the trace and record it, and if the
evidence shows lost or delayed first periods, the documented fallback is to set
`trigger = {SND_SOC_DPCM_TRIGGER_POST, SND_SOC_DPCM_TRIGGER_POST}` on our FE
link — which we own — so the BEs come up first. Decide from evidence, not taste.

## The channel map should flow codec -> machine -> CPU DAI

Today there are **two independent hardcoded 144s**: one in the machine driver's
`be_hw_params_fixup` for the CPU DAI, and one in the codec's B1 hook. Nothing
makes them agree; they simply happen to.

Mainline solves this properly. `sdm845_snd_hw_params()` calls
`snd_soc_dai_get_channel_map(codec_dai, ...)` and forwards the result to the CPU
DAI, and WCD9335 implements both `.get_channel_map` and `.set_channel_map`. B2
should do the same: the codec becomes the single source of truth for its own
channel numbers, and disagreement becomes impossible by construction rather than
by coincidence.

The port/shift arithmetic already matches: WCD9335 uses
`{.port = p + RX_START, .shift = p}` with `RX_START = 16`, and `payload |=
1 << ch->shift` gives `0x01` for the first RX port — exactly the frozen
`0x180 -> 01` delta this driver already reproduces.

## What has to be written

In `wcd9320-core.c`:

1. `.set_channel_map` / `.get_channel_map`, seeded with port 16 / channel 144.
2. `.startup` / `.shutdown` — allocate and free the stream runtime.
3. `hw_params` fills `sconfig` from the real params instead of the hook's
   constants, and programs the port.
4. `.trigger` — `prepare` + `enable` on START, `disable` + `unprepare` on STOP,
   reusing the B1 production functions unchanged.

The B1 debugfs hook stays. It is the only way to exercise the stream without a
PCM, and it is what makes a B1 regression distinguishable from a B2 failure.

In `lumia1520-q6.c`: replace the hardcoded CPU-DAI map with the
get-from-codec-then-set-on-CPU pattern.

## The instrument: a new helper, not a modified oracle

`pcm-prepare-only` stays frozen and untouched. Its whole value is that it
*cannot* start a stream, and that guarantee underwrites the control-plane
milestone. B2 needs the opposite behaviour, so it gets its own binary.

`pcm-run-measured`:

- `HW_PARAMS` at 48 kHz / 1ch / S16_LE with an explicitly chosen period and
  buffer, so the period size is a known quantity rather than a default.
- fill the buffer with a **known non-zero signal** (a counting ramp or a 1 kHz
  sine), so "we wrote real data" is true and a future readback path has
  something to recognise.
- `SW_PARAMS` with `start_threshold` set high, prefill by `write()`, then an
  explicit `SNDRV_PCM_IOCTL_START` — so the moment of RUN is deterministic and
  observable, instead of being an implicit side effect of the first write.
- poll `SNDRV_PCM_IOCTL_STATUS` on a fixed cadence for a bounded duration,
  recording `hw_ptr`, `avail`, state and xrun count.
- `SNDRV_PCM_IOCTL_DROP`, close, and report: frames written, frames consumed,
  elapsed time, **measured frames/second**, xruns, final state.

It needs its own audit (`runner-audit.py`), whose required/forbidden lists are
the inverse of the prepare-only one: `write()` and `START` are **required**, and
what is forbidden is unbounded looping and any second device being opened. A
bounded runtime is a correctness property here — a helper that can spin forever
on a wedged DSP is not an instrument.

## What this milestone retires

The guarantee "`q6asm_run_nowait` observed zero times" is retired **for B2
only**. `msm8974-q6-playback-control-evidence.sh` keeps it and must keep
passing; if B2 work breaks it, that is a regression in the control plane, not a
new baseline.

## Proposed gate

`msm8974-q6-data-plane-evidence.sh`, kprobing `q6asm_run_nowait`,
`q6asm_write_async`, `snd_pcm_period_elapsed`, plus the B1 stream calls, and
asserting:

- RUN issued exactly once; the codec's `slim_stream_enable` also ran
- the observed FE/BE trigger order, recorded either way
- `q6asm_write_async` called many times, and `snd_pcm_period_elapsed` a
  comparable number — they should track each other one-for-one
- `hw_ptr` advanced monotonically
- **measured rate within tolerance of 48000 frames/s**
- zero xruns, final state not XRUN
- the B1 stream came up and tore down around it

## Open questions

1. **A negative control.** If the DSP consumes at the same rate with the codec's
   stream *not* connected, then progression says nothing about the bus. Worth
   one run routed to a BE with no codec (e.g. `SLIMBUS_1_RX`) to calibrate what
   progression actually proves. I would rather know this than assume it.
2. **Period and buffer size.** The control-plane run got 64-frame periods, which
   is ~750 interrupts/s. Larger periods make the rate measurement steadier and
   the DSP round trip less punishing. Propose 960 frames (20 ms) x 4.
3. **Run duration.** Long enough to average out jitter, short enough to stay a
   gate. Propose 3 s.
4. **Rate tolerance.** Propose +/-2%, tightened later if the measurement proves
   steadier than that.

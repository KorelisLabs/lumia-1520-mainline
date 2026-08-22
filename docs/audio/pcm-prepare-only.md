# The prepare-only PCM helper: the Branch A measuring instrument

Built and proven **before** the Q6 machine driver it will judge, so that a
failure in the coming control-plane work is attributable to Q6 rather than to
the tool measuring it.

## Why it has to exist

The Q6 control-plane milestone must show the ADSP acknowledges ASM, ADM and
AFE setup **without a single sample moving**. ALSA draws that line where we
need it: `hw_params` and `prepare` are the setup phase, `trigger(START)`
begins the stream.

`aplay` cannot express it — its first `write()` drives `trigger(START)`, and
from there `ASM_DATA_CMD_WRITE_V2` goes out. So the instrument is its own
program:

```
open -> HW_PARAMS -> SW_PARAMS -> PREPARE -> STATUS -> DROP -> close

never write(), never SNDRV_PCM_IOCTL_START, never DRAIN, never mmap-commit
```

Deliberately **not** alsa-lib. libasound does things on your behalf, and that
helpfulness is the exact hazard here; raw ioctls mean the sequence in the
source is the sequence on the wire.

## Two kernel facts it relies on, checked in 6.16.12 rather than assumed

**`hw_params` resolves itself.** `snd_pcm_hw_params()` runs
`snd_pcm_hw_refine()` and then `snd_pcm_hw_params_choose()`, so
under-determined parameters are settled by the kernel from the driver's own
constraints. The helper sets only access, format, subformat, rate and channels
and leaves period and buffer "any". Imposing our guesses would test our
guesses rather than the driver.

**`DROP` from `PREPARED` fires no trigger.**

```c
static int snd_pcm_do_stop(struct snd_pcm_substream *substream, ...)
{
        if (substream->runtime->trigger_master == substream &&
            snd_pcm_running(substream)) {          /* RUNNING or DRAINING */
                substream->ops->trigger(substream, SNDRV_PCM_TRIGGER_STOP);
```

From `PREPARED` neither condition holds, so `DROP` is a pure `PREPARED ->
SETUP` transition. **The helper therefore bakes in no expectation about which
driver callbacks fire.** What actually fires is for the kernel-side evidence
to report — which is how the `hw_free`-at-`close` behaviour below was learned
rather than guessed.

## The audit is the part that makes it trustworthy

The helper's value is what it does *not* do, and a plain grep cannot check
that: the source documents the prohibition in its own comments, so
`grep SNDRV_PCM_IOCTL_START` matches the sentence saying it is never used.
**The first version of this guard would have refused to build a correct
program**, and — worse — could have passed a bad one whose forbidden call sat
inside a string literal.

`pcm-helper-audit.py` strips comments and string literals, then checks:

| forbidden | required |
|---|---|
| `SNDRV_PCM_IOCTL_START` | `SNDRV_PCM_IOCTL_HW_PARAMS` |
| `SNDRV_PCM_IOCTL_DRAIN` | `SNDRV_PCM_IOCTL_SW_PARAMS` |
| `SNDRV_PCM_IOCTL_WRITEI` / `WRITEN` | `SNDRV_PCM_IOCTL_PREPARE` |
| `write()`, `writev()`, `pwrite()`, `mmap()` | `SNDRV_PCM_IOCTL_DROP` |

It runs **before compilation**, not after: a binary that starts a stream would
silently invalidate every conclusion drawn with it.

It carries `--selftest`: 5 cases, **4 of which it must reject** (a real START
ioctl, a real `write()`, a real `mmap()`, a missing required ioctl) plus one
proving comments and strings do not trip it. The build aborts if that selftest
ever stops failing on bad input — a checker that cannot fail is worth nothing.

`pcm-helper-elfcheck.py` reads the ELF header directly, since the host
toolchain is x86_64 and `file` is not guaranteed present. Verified to reject
both an x86-64 binary and a non-ELF.

## Proven on hardware — boot #154, against the frozen minimal card

Validated against `wcd9320-lumia-card`, deliberately, because that card is
already a trusted proof oracle. Any later failure is then Q6's, not the tool's.

```
hw_params_rc=0
  actual_rate=48000  actual_channels=1
  actual_period_size=2048  actual_periods=32
  actual_buffer_size=65536
  actual_period_bytes=4096  actual_buffer_bytes=131072
sw_params_rc=0   start_threshold=2147483647
prepare_rc=0     state=PREPARED   reached_prepared=1
drop_rc=0        state_after_drop=SETUP
final_rc=0       exit=0

write_calls=0  frames_submitted=0  start_requested=0
drain_requested=0  mmap_committed=0
```

`4096 x 32 = 131072`, and that card declares `buffer_bytes_max = 128*1024`. So
the kernel resolved period and buffer from the **driver's** constraints, which
is the property that makes the helper honest against a different driver later.

`state_after_drop=SETUP` is the predicted pure transition, observed.

### What the kernel saw

```
RX path invocation: ASoC hw_params (dai wcd9320-slim-rx1, rate 48000, ch 1, fmt 2)
  rx-port 16: multi-channel 0x180 want 01 -> read 01
  rx-port 16: config 0x040 want 05 -> read 05
RX path invocation: ASoC hw_free (dai wcd9320-slim-rx1)
  rx-port 16: config 0x040 want 00 -> read 00
  rx-port 16: multi-channel 0x180 want 00 -> read 00
```

No trigger invocation anywhere. `hw_free` fired at `close()`, not at `DROP` —
correct ALSA behaviour, and observed rather than assumed precisely because the
helper made no claim about it.

### The finding that matters for Branch A

**The frozen WCD9320 RX delta reproduces in a prepare-only run.** `0x040:
00->05` and `0x180: 00->01`, with the clean inverse, and no stream ever
started.

That was not certain in advance. It means the Q6 control-plane gate's step
"WCD9320 frozen RX delta reproduced" is reachable **before** `RUN`, so
tightening the milestone to stop short of `ASM_SESSION_CMD_RUN_V2` costs
nothing in evidence.

## Frozen behaviour

This tool is now the fixed instrument for the Q6 control-plane milestone. Its
sequence, its refusals and its output keys should not change without a reason
recorded here, because gates will be written against them.

Binary: 206096 bytes, sha256
`2bd7c030e1a9f25f6f09685ec2f39ed8c2a38e45645fde7a92f65391d6f6c44e`, 32-bit ARM
LSB, statically linked (no `PT_INTERP`, so no dynamic loader is involved on the
device).

Output keys the evidence harness may rely on: `open_rc`, `pcm_id`,
`hw_params_rc`, `actual_*`, `sw_params_rc`, `start_threshold`, `prepare_rc`,
`state`, `reached_prepared`, `drop_rc`, `state_after_drop`, `close_rc`,
`write_calls`, `frames_submitted`, `start_requested`, `drain_requested`,
`mmap_committed`, `final_rc`.

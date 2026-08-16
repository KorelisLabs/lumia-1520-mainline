# ASoC drives the codec: the minimal card

The RX DAI and its SLIMbus port programming were proven on hardware in
`wcd9320-rx-dai-proven`, but reached through a research hook, because ASoC
never calls a DAI on a component no card has bound. This closes that gap: a
real card, a real PCM, an ordinary ALSA client, and the framework itself
entering the production `hw_params()`.

Evidence, all from one boot (#149) of `asoc-card-rc1` / `lumia-card-rc2`
(pkgrel 148), 2026-08-16:

| run | verdict |
|---|---|
| `wcd9320-coldboot-autoload-20260816T174322Z.txt` | PASS 31/0 |
| **`wcd9320-asoc-callback-20260816T174418Z.txt`** | **PASS** |
| `wcd9320-regcache-20260816T174552Z.txt` | PASS 25/0 |
| `wcd9320-irq-acceptance-20260816T174604Z.txt` | PASS 27/0 |
| `wcd9320-rx-dai-20260816T175132Z.txt` | PASS 33/0, regression |

## The claim, in one comparison

```
manual (rx_port_test)  delta = 0x040:00->05  0x180:00->01
ASoC   (hw_params)     delta = 0x040:00->05  0x180:00->01
```

Two independent callers, one production helper, byte-identical hardware
transitions — compared as **transitions**, not as final values, because
identical endpoints can hide different paths. Residue after teardown is `NONE`
in both cases.

The driver's own log shows the framework carrying the negotiated parameters
into the production path:

```
RX path invocation: ASoC hw_params (dai wcd9320-slim-rx1, rate 48000, ch 1, fmt 2)
rx-port 16: multi-channel 0x180 want 01 -> read 01
rx-port 16: config 0x040 want 05 -> read 05
RX path invocation: ASoC hw_free (dai wcd9320-slim-rx1)
rx-port 16: TORN DOWN
```

Provenance is recorded by the **caller**, immediately before it calls, so the
helper stays caller-agnostic and cannot behave differently for one entry point
than the other. That is what makes the equality meaningful rather than
circular.

## `snd-soc-dummy` cannot be a card's sole platform

**This corrects `wcd9320-minimal-card-mapping.md` §2.** That section concluded
the platform slot must be `COMP_PLATFORM("snd-soc-dummy")` rather than
`COMP_DUMMY()`. That is true and necessary — but **not sufficient**, and the
first attempt failed because of it.

`snd_soc_runtime_calc_hw()` fills only channels, rates and formats into
`runtime->hw`. It does not set `.info`, `.buffer_bytes_max`, `.period_bytes_*`
or `.periods_*`. Those come from the platform calling
`snd_soc_set_runtime_hwparams()`.

soc-utils.c's `dummy_dma_open()` is supposed to install `dummy_dma_hardware`,
but first walks the rtd and returns early if any component is `dummy_platform`:

```c
for_each_rtd_components(rtd, i, component)
        if (component->driver == &dummy_platform)
                return 0;
```

When `snd-soc-dummy` *is* the platform, that is always true of itself. So
`runtime->hw` is never installed and `.info` stays `0`.

`snd_pcm_hw_constraints_complete()` then builds the ACCESS mask **from
`hw->info`**. With `info == 0` neither `INTERLEAVED` nor `NONINTERLEAVED` is
set, the mask is empty, and `snd_pcm_open()` returns `-EINVAL`.

**The failure is silent.** ASoC's own `soc_pcm_open()` succeeds — its last
debug lines print a perfectly sane intersection:

```
rate mask 0x80        (48000)
ch   min 1 max 1
rate min 48000 max 48000
```

and only then does the ALSA core reject the constraints. Nothing is logged,
because it is not ASoC's failure. Dynamic debug on `soc-pcm.c` is what located
it: seeing the intersection printed and *then* `-EINVAL` is what proved the
failure was after ASoC's open, not inside it.

The fixture therefore registers its **own** platform component, whose only job
is to install a sane `runtime->hw`. It allocates no buffer and moves no data —
there is still no DMA.

Confirmation that the diagnosis was right is in *where* `aplay` fails now:

```
before:  aplay: main:850: audio open error: Invalid argument
after:   Playing raw data '/dev/zero' : Signed 16 bit Little Endian, Rate 48000 Hz, Mono
         aplay: pcm_write:2191: write error: Invalid argument
```

The failure moved from `open` to `pcm_write` — past the constraint check, past
`hw_params`, and into the write that genuinely cannot work without a buffer.

## Why `aplay`'s exit status is not a gate

Because the platform preallocates nothing, a write after a successful
`hw_params` is *expected* to fail. So this is a successful experiment:

```
PCM opened -> hw_params reached ASoC -> production helper ran
-> expected two-register delta -> write fails -> aplay exits 1
```

The evidence file marks `aplay rc` as "INFORMATIONAL ONLY, not a check", and
the analyser deliberately does not assert on it. Gating on the tool would fail
a run that proved exactly what the milestone claims.

## The IFD double probe: measured, and not what was predicted

The instrumentation added for this milestone answers the question the previous
one left open — and **contradicts the hypothesis recorded there.**

`wcd9320-rx-dai-mapping.md` noted that probes 1 and 2 are each followed by
`Failed to get logical address` and only the last coincides with
`interface function UP`, and called that "the deferral shape rather than the
double-bind shape". That was a hint from a log, and it was wrong.

Measured, consistently across three boots:

```
IFD probe #1: sdev=65a6922d dev=217:a0:0:0 laddr=0x00 laddr_valid=0 status=0
IFD probe #1: returning 0 (bound)
Failed to get logical address
...
IFD probe #2: sdev=65a6922d dev=217:a0:0:0 laddr=0x00 laddr_valid=0 status=0
IFD probe #2: returning 0 (bound)
interface function UP (#1), logical address 0xca
```

**Both probes return 0 — the driver binds successfully both times — and the
`slim_device` pointer is identical.** That is the double-bind shape, not
deferral. No `remove` is logged between them, which the driver model would
normally require before re-probing a bound device.

The count also varies by build: 3 entries on r146, 2 on r147 and r148. A count
that changes between boots points at a race rather than a fixed sequence.

Consequences today are benign — `devm_regmap_init_slimbus()` simply runs twice
on that device, and the module-scope IFD pointer is republished by each probe
and only cleared by whichever instance still owns it. But this is unexplained
lifecycle behaviour in a driver that now participates in component binding, and
it should be understood before anything depends on IFD probe ordering.

## What this milestone does NOT claim

No DMA. No q6/AFE. No ADSP audio-service response. No SLIMbus channel
allocated, defined or activated. No sample movement, no routing, no audible
playback.

The CPU side is ASoC's dummy and the platform side is a stub that preallocates
nothing. Configuring the codec's side of a slave port is not a data path, and
on this device the ADSP owns the bus master regardless. **Nothing has streamed
and nothing has made a sound.**

The card also does not autoload: it creates its own platform device in
`module_init`, so nothing matches an alias. Every run loads it explicitly and
records that it did.

`aplay` was installed by hand rather than as a package — the device has no
network route, so the binary was extracted from the `alsa-utils` apk and placed
in `/usr/local/bin`. It links only `libasound.so.2` and musl, both already
present. It is still an ordinary ALSA client going through the normal PCM API,
which is the demonstration value that mattered; only the packaging was skipped.

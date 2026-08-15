# The minimal ASoC card: mapping, before any code

Pre-implementation mapping for `wcd9320-asoc-rx-callback-proven`. The objective
is narrow: make the ASoC framework itself invoke the WCD9320 RX DAI's
`hw_params()` — the callback already proven on hardware through the research
hook — and show the resulting register delta is identical.

Everything below is read from the exact sources this port builds:
`msm8974-mainline/linux` at `v6.16.12-msm8974`.

## 1. There is no CPU DAI on this system

```
# CONFIG_SND_SOC_QCOM is not set
CONFIG_QCOM_APR=y          <- APR transport for remoteproc, not the ASoC front end
```

No `q6afe`, no `q6asm`, no `q6routing`, no LPASS macros. A DAI link needs a CPU
endpoint and there is none, so the link's CPU side must be ASoC's dummy.

That is not a workaround, it is the correct scope: enabling `SND_SOC_QCOM`
would drag q6 DT nodes and live ADSP audio services into a gate meant to prove
framework plumbing. The CPU side gets swapped later; the codec side is already
proven and does not change.

## 2. `COMP_DUMMY()` is for CPU and codec only — never platform

From `soc-core.c`, verbatim:

```c
/*
 * COMP_DUMMY() creates size 0 array on dai_link.
 * Fill it as dummy DAI in case of CPU/Codec here.
 * Do nothing for Platform.
 */
for_each_card_prelinks(card, i, dai_link) {
	if (dai_link->num_cpus == 0 && dai_link->cpus) {
		dai_link->num_cpus	= 1;
		dai_link->cpus		= &snd_soc_dummy_dlc;
	}
	if (dai_link->num_codecs == 0 && dai_link->codecs) {
		dai_link->num_codecs	= 1;
		dai_link->codecs	= &snd_soc_dummy_dlc;
	}
}
```

`COMP_DUMMY()` is an **empty macro** — the zero-sized array *is* the signal, and
the core substitutes `snd_soc_dummy_dlc` for CPU and codec. Platform is
deliberately untouched, so a `COMP_DUMMY()` platform slot stays zero-sized and
no platform component is ever resolved.

```c
struct snd_soc_dai_link_component snd_soc_dummy_dlc = {
	.of_node	= NULL,
	.dai_name	= "snd-soc-dummy-dai",
	.name		= "snd-soc-dummy",
};
```

So the platform slot must name it explicitly:

| slot | value |
|---|---|
| CPU | `COMP_DUMMY()` |
| CODEC | `COMP_CODEC("217:a0:1:0", "wcd9320-slim-rx1")` |
| PLATFORM | `COMP_PLATFORM("snd-soc-dummy")` |

## 3. The names are confirmed by the device, not guessed

`snd_soc_dummy_probe()` registers **two** components on one faux device:
`dummy_codec` + `dummy_dai`, then `dummy_platform` with no DAIs. Both take
their name from that device, which is why the codec's own evidence from
`rx-dai-rc1` lists `snd-soc-dummy` twice:

```
components:            dais:
  217:a0:1:0             wcd9320-slim-rx1
  snd-soc-dummy          snd-soc-dummy-dai
  snd-soc-dummy
```

That listing is the confirmation for every name in the table above: the codec
component is `217:a0:1:0` (the slim_device name, since ASoC names components
via `fmt_single_name(dev, ...)`), its DAI is `wcd9320-slim-rx1`, and
`snd-soc-dummy` really is present twice as codec-side and platform-side
components.

**The codec component name is a device name, and device names are not a stable
ABI.** It has been `217:a0:1:0` on every boot recorded, and it derives
deterministically from the SLIMbus enumeration address, but the machine driver
should take it as a module parameter defaulting to that value rather than
hardcoding it unconditionally. A permanent DT topology would use `of_node`
matching instead; that decision stays open.

## 4. The dummy platform has no DMA — and that decides the gate

```c
static const struct snd_soc_component_driver dummy_platform = {
	.open		= dummy_dma_open,
};
```

One callback. No `pcm_construct`, so **no buffer is preallocated and there is no
DMA**. `dummy_dma_open()` only installs `dummy_dma_hardware` as the runtime
constraints.

The consequence matters more than it first appears: a PCM node will exist and
can be opened and configured, but **writing samples cannot work**, and a
userspace tool like `aplay` may well report an error *after* `hw_params` has
already run.

So the acceptance gate must be **"ASoC entered the production `hw_params()`"**,
evidenced by the driver's own log line and the register delta — *not* "the
playback tool exited 0". Gating on the tool's exit code would fail a run that
proved exactly what the milestone claims. This is the same shape of error as
gating on a driver's own log line instead of ASoC's component list, and it is
written down here so it is not discovered during the run.

The dummy CPU DAI accepts essentially anything (`SNDRV_PCM_RATE_CONTINUOUS`,
5512–768000 Hz, 1–384 channels), so the link's intersection with our DAI is
whatever our DAI declares: 48 kHz, S16_LE, mono. Nothing needs relaxing.

## 5. The card is a separate module, and does not go in the codec driver

```
wcd9320 codec driver          RM-940 minimal card
  codec hardware                snd_soc_card
  the RX DAI                    the DAI link
  hw_params()/hw_free()         dummy CPU + dummy platform
  knows no card topology        points at wcd9320-slim-rx1
```

The codec driver must not learn about Lumia card topology, so that the eventual
transition is `dummy CPU -> WCD9320` becoming `q6/AFE CPU -> WCD9320` with the
codec side untouched.

Proposed: a new module `wcd9320-lumia-card.c` under its own Kconfig symbol,
`tristate`, `depends on SND_SOC`. It registers a `platform_device` from module
init and a matching `platform_driver` whose probe calls
`devm_snd_soc_register_card()` — **no DT node**, because the permanent DT
topology is explicitly undecided and a proof card should not invent one.

It is placed beside the codec rather than in `sound/soc/qcom/` only because that
directory is gated behind `SND_SOC_QCOM`, which this milestone deliberately does
not enable. It belongs there when the q6 work starts, and the file says so.

Registration lifetime, stated because it is the thing most likely to bite: the
card probe will fail with `-EPROBE_DEFER` until the codec component and its DAI
are registered. That is normal and self-correcting, but it means the card must
tolerate deferral and the evidence must distinguish "deferred then bound" from
"never bound".

## 6. Two callers, one path — make the equality an assertion

`rx_port_test` stays. It becomes the reference oracle:

```
manual rx_port_test  ─┐
                      ├─> wcd9320_rx_port_program() ─> frozen 2-register delta
ASoC hw_params()     ─┘
```

The gate should not merely observe that both work; it should assert the
**framework-driven delta equals the frozen manual delta** — `0x180: 00→01`,
`0x040: 00→05`, two registers changed in `0x030`–`0x1b0`, zero left changed
after `hw_free()`. Two independent callers entering one production path and
producing byte-identical hardware results is a much stronger claim than either
alone.

## 7. The triple IFD probe: what to capture

Instrumentation goes in this build, per the agreed list. At each entry to
`wcd9320_probe()` for the interface function, log:

| field | why |
|---|---|
| probe sequence number | distinguishes #1/#2/#3 |
| `slim_device` pointer | same device re-probed, or different devices? |
| `dev_name()` | ditto, in readable form |
| `laddr` and `is_laddr_valid` | SLIMbus address state at entry |
| `sdev->status` | `DOWN`/`UP` at entry |
| return path | success / `-EPROBE_DEFER` / error, with the value |

The question being answered:

```
probe #1 -> infrastructure unavailable -> -EPROBE_DEFER
probe #2 -> address/state changes      -> -EPROBE_DEFER
probe #3 -> final successful bind
```

versus

```
probe #1 -> success
probe #2 -> unexpected second bind
probe #3 -> unexpected third bind
```

Those have opposite implications, and component binding is about to make the
difference matter. Note the existing evidence already hints at the answer: the
first two IFD probes are each followed by `Failed to get logical address`, and
only the third coincides with `interface function UP`. That is the deferral
shape rather than the double-bind shape — but it is a hint from a log, not a
measurement, and this instrumentation is what turns it into one.

## 8. Acceptance gate

1. The minimal `snd_soc_card` registers.
2. The dummy CPU DAI and the WCD9320 RX DAI bind in one real DAI link.
3. A real ALSA PCM appears.
4. Userspace performs a real PCM `hw_params`.
5. Evidence proves ASoC entered `wcd9320-slim-rx1`'s production `hw_params()`.
6. The framework-driven register delta **equals** the frozen `rx_port_test`
   delta.
7. Framework-driven `hw_free()` reaches the production cleanup path and
   restores the expected state.
8. The four-run baseline remains intact: 31 cold-boot + 34 RX DAI + 25 regcache
   + 27 IRQ = **117 checks**.
9. The triple IFD probe is classified and documented.
10. Explicitly not proven: DMA, q6/AFE, ADSP audio-service response, SLIMbus
    channel activation, sample movement, routing, or audible playback.

## 9. Decisions taken

1. **Codec component name is a read-only module parameter**, defaulting to
   `217:a0:1:0` — the known RM-940 enumeration value for this experiment, not
   an ABI. Read-only gives three things at once: the normal hardware path needs
   no arguments, an enumeration change fails *visibly* instead of silently
   binding something else, and the fixture stays reusable without a device name
   baked into its logic.

   **No fallback and no scanning.** If component resolution fails, both values
   are printed prominently:

   ```
   codec_component=217:a0:1:0
   codec_dai=wcd9320-slim-rx1
   ```

   A changed component name is evidence, not something the fixture hides.

   The **DAI name stays fixed** at `wcd9320-slim-rx1` — that is the interface
   under test. Only the component/device instance name is the unstable part.

2. **Trigger is ordinary `aplay`** from `/dev/zero`, with an explicit hardware
   PCM and explicit parameters rather than letting plugins negotiate:
   `-D hw:<card>,<device> -t raw -f S16_LE -r 48000 -c 1`. A normal ALSA client
   through the ordinary PCM API is a better demonstration of framework plumbing
   than a bespoke test binary.

   **`aplay`'s exit status is informational.** This part of the gate passes when
   these occur in order:

   ```
   PCM opened
     -> snd_pcm_hw_params() reached ASoC
     -> wcd9320-slim-rx1 hw_params() logged framework entry
     -> production helper ran
     -> expected two-register delta occurred
   ```

   So an outcome of *hw_params proven, registers changed, later write fails
   because there is no DMA buffer, `aplay` exits non-zero* is a **successful
   experiment**. The evidence analyser encodes that distinction explicitly, so
   nobody later promotes an informational `aplay_rc != 0` into an accidental
   gate failure.

3. **The `SNDRV_PCM_IOCTL_HW_PARAMS` helper is a fallback only**, to be built
   only if `aplay` cannot deterministically reach the callback.

4. **Provenance is recorded around the helper call, not inside it.** The
   production helper stays completely caller-agnostic; each call site records
   its origin immediately before calling. The equality proof then becomes
   mechanical:

   ```
   manual entry  delta = {0x180: 00->01, 0x040: 00->05}
   ASoC entry    delta = {0x180: 00->01, 0x040: 00->05}
   assert(manual_delta == asoc_delta)
   ```

   which is stronger than observing the same final register values, because it
   compares the transitions rather than the endpoints.

# Branch A: the real MSM8974 Q6 playback path, mapped before anything is enabled

Research only. **No Kconfig change, no DT change.** Read from the exact tree
this port builds, `msm8974-mainline/linux` at `v6.16.12-msm8974`.

Question 0 is closed: the ADSP advertises CORE, AFE, VSM, VPM, ASM, ADM, MVM,
CVS, CVP, USM and LSM (`msm8974-q6-service-inventory-proven`). So this is no
longer "does the firmware speak Q6" but "which minimum subset must bind to
establish a real control-plane stream path".

## 1. There is no single "CPU DAI" — there is a front end and a back end

The dummy CPU side is not replaced by one driver. Two different drivers, in
two different roles, from two different APR services:

```
userspace PCM  (aplay)
      |
      v
FRONT END   MultiMedia1..8          q6asm-dai.c    APR service ASM (7)
      |     PCM-facing, owns the stream session
      v
ROUTING     mixer FE -> BE          q6routing.c    platform, under q6adm
      |     "MultiMedia1 Playback" -> "SLIMBUS_0_RX"
      v
BACK END    SLIMBUS_0_RX..6_RX      q6afe-dai.c    APR service AFE (4)
      |     physical port, q6slim_ops
      v
SLIMbus  ->  WCD9320 slave port 16  (our wcd9320-slim-rx1, already proven)
```

Calling the replacement "the real CPU DAI" hides that split. In a
`snd_soc_dai_link`, the **FE link** has `MultiMedia1` as its CPU DAI and a
dummy codec; the **BE link** has `SLIMBUS_0_RX` as its CPU DAI and
`wcd9320-slim-rx1` as its codec. Both are needed; neither alone is "the CPU
DAI".

## 2. The endpoint, resolved rather than assumed

| layer | identifier | value | source |
|---|---|---|---|
| codec slave port | RX1 | **16** | our driver; registers `0x180`/`0x040` = `0x140 + 16*4`, `0x030 + 16`, confirmed on every boot |
| SLIMbus channel | RX1 | **144** | `apq8096.c` convention: `rx_ch[] = {144, 145, ...}`, `tx_ch[]` from 128 |
| BE DAI id (DT `reg`) | `SLIMBUS_0_RX` | **2** | `include/dt-bindings/sound/qcom,q6dsp-lpass-ports.h` |
| AFE port id (on the wire) | `AFE_PORT_ID_SLIMBUS_MULTI_CHAN_0_RX` | **0x4000** | `q6afe.c`, via `port_maps[]` |

`qcom,q6afe.h` is a backward-compatibility shim that includes
`qcom,q6dsp-lpass-ports.h`; the DAI ids live in the latter.

**`SLIMBUS_0_RX` is the proposal, not a proven fact.** It is the conventional
primary-playback port and the one `apq8096` uses for a WCD codec, but nothing
measured on this device has yet confirmed the ADSP expects RX1 traffic there.
The correspondence to test is **codec slave port 16 <-> SLIMbus channel 144
<-> AFE port 0x4000**. If the ADSP disagrees, the symptom will be an AFE
command failure at `prepare`, which is observable and is why the gate in §5
requires a successful remote reply rather than merely a bound driver.

## 3. What each component needs, and when it talks to the DSP

| component | file | Kconfig | kind | DT compatible | `reg` |
|---|---|---|---|---|---|
| q6core | `q6core.c` | `SND_SOC_QDSP6_CORE` | APR service | `qcom,q6core` | `APR_SVC_ADSP_CORE` (3) |
| q6afe | `q6afe.c` | `SND_SOC_QDSP6_AFE` | APR service | `qcom,q6afe` | `APR_SVC_AFE` (4) |
| q6afe-dais | `q6afe-dai.c` | `SND_SOC_QDSP6_AFE_DAI` | platform child of q6afe | `qcom,q6afe-dais` | — |
| q6asm | `q6asm.c` | `SND_SOC_QDSP6_ASM` | APR service | `qcom,q6asm` | `APR_SVC_ASM` (7) |
| q6asm-dais | `q6asm-dai.c` | `SND_SOC_QDSP6_ASM_DAI` | platform child of q6asm | `qcom,q6asm-dais` | — |
| q6adm | `q6adm.c` | `SND_SOC_QDSP6_ADM` | APR service | `qcom,q6adm` | `APR_SVC_ADM` (8) |
| q6routing | `q6routing.c` | `SND_SOC_QDSP6_ROUTING` | platform child of q6adm | `qcom,q6adm-routing` | — |

All seven are already **built** — `SND_SOC_QDSP6=m` selects the whole group,
which is why the inventory milestone had to keep them un-instantiated by DT
rather than un-built.

### When each one actually sends a packet

This matters for the gate: a component that binds proves nothing about the
firmware, and we already learned that lesson with `q6core`.

- **`q6afe_probe()` and `q6asm_probe()` send nothing remote.** They `kzalloc`,
  call `q6core_get_svc_api_info()` — the AVCS query already proven — and then
  `devm_of_platform_populate()`. Binding them is not evidence.
- **`q6routing_probe()` sends nothing.** It registers a component.
- **`q6slim_hw_params()` sends nothing.** It records `sample_rate` and
  `bit_width` into `dai_data->port_config[dai->id].slim`.
- **`q6slim_set_channel_map()` sends nothing.** It records `ch_mapping[]` and
  `num_channels`.
- **`q6afe_dai_prepare()` is where the wire traffic happens**:
  `q6afe_slim_port_prepare()` then `q6afe_port_start()`. That is the first
  point at which the ADSP must answer for this path to be real.

Send/wait sites, as a rough measure of how much remote conversation each
service carries: `q6afe.c` 8 send / 1 wait, `q6asm.c` 10 / 3, `q6adm.c` 2 / 3.

## 4. The data plane is somewhere else entirely, and it is ours

`q6afe` configures **the DSP's side** of the SLIMbus port. It does not
allocate or connect SLIMbus data channels. In mainline that is the **codec
driver's** job, via the SLIMbus stream API:

```
wcd9335.c:1779   slim_stream_allocate(wcd->slim, "WCD9335-SLIM")
wcd9335.c:1970   slim_stream_prepare(...)
wcd9335.c:1971   slim_stream_enable(...)
wcd9335.c:1976   slim_stream_disable(...)
wcd9335.c:1977   slim_stream_unprepare(...)
```

`drivers/slimbus/stream.c` exports exactly those six calls. Our wcd9320 driver
uses **none** of them today: it programs the codec's port-config registers
directly and nothing more, which is precisely why the RX milestone was scoped
as "configuring a port is not a data path".

**So the split is clean and the milestone boundary follows it:**

- **control plane (next milestone)** — FE/BE links exist, AFE accepts the port
  configuration, the ADSP replies successfully, our proven codec `hw_params`
  runs.
- **data plane (a later milestone)** — `slim_stream_*` in the wcd9320 driver,
  actual channel allocation, sample movement.

## 5. The next success gate, defined before any DT is written

> Can Linux replace the dummy side with the real QDSP6 FE/BE control path and
> receive successful ADSP acknowledgements while invoking the already-proven
> WCD9320 RX path?

```
required q6 components bind        q6afe, q6afe-dais, q6asm, q6asm-dais,
                                   q6adm, q6routing  (+ q6core, already proven)
        |
   a real FE PCM appears           MultiMedia1, not our dummy platform
        |
   userspace open + hw_params
        |
   ASM session request succeeds    remote reply observed
        |
   routing/ADM request succeeds    if the path requires it
        |
   AFE SLIMbus port config succeeds  q6afe_dai_prepare -> q6afe_port_start,
                                     remote reply observed
        |
   WCD9320 hw_params executes      our proven production helper
        |
   the frozen delta reproduced     0x040: 00->05   0x180: 00->01
        |
   teardown receives success replies
```

**Explicitly NOT required:** a successful `pcm_write`, buffer progression,
SLIMbus sample traffic, `slim_stream_*` calls, or any audible output.

**Anti-vacuity, learned from the inventory milestone:** a bound q6 driver is
not evidence. Every "succeeds" above must be an observed remote reply, not an
absence of error — `q6afe_probe()` binding while sending nothing is exactly
the C0 shape we already have a verdict name for.

## 6. Open questions — three now closed

1. **Is `SLIMBUS_0_RX` right for this device?** STILL OPEN, and deliberately
   provisional. See §2 and §9.
2. ~~Does our codec DAI need `.set_channel_map`?~~ **CLOSED: not for this
   milestone.** See §9.
3. ~~Is `q6adm`/`q6routing` required?~~ **CLOSED: yes, both.**
   `q6routing_stream_open()` calls `q6adm_open()` and `q6adm_matrix_map()`,
   so ADM is on the critical path, not optional. See §8.
4. **Does the FE need `q6afe-clocks`?** Still open, but almost certainly no:
   SLIMbus clocking belongs to the bus, unlike MI2S which needs `sd-lines`
   and clocks.
5. **Which machine driver hosts the FE/BE links?** Still open. See §11.

## 7. The DPCM topology, exactly

`qcom_snd_parse_of()` in `sound/soc/qcom/common.c` decides the roles from the
DT link shape:

```
FE link   (no platform node)          BE link   (platform node present)
  link->dynamic       = 1               link->no_pcm            = 1
  link->codecs        = dummy           link->ignore_pmdown_time = 1
  CPU  = MultiMedia1                    CPU  = SLIMBUS_0_RX
  codec = snd_soc_dummy_dlc             codec = wcd9320-slim-rx1
  both: ignore_suspend = 1, nonatomic = 1
```

`apq8096` then finds its BE links by exactly one test — `if (link->no_pcm == 1)`
— and attaches `be_hw_params_fixup`, `init` and `ops` there. That is the hook
point for the channel map in §9.

## 8. How MultiMedia1 reaches SLIMBUS_0_RX, and why ADM is on the path

**The route is a DAPM mixer that must be explicitly enabled.** It is not
automatic:

```
SND_SOC_DAPM_MIXER("SLIMBUS_0_RX Audio Mixer", ..., slimbus_rx_mixer_controls)
    where slimbus_rx_mixer_controls = Q6ROUTING_RX_MIXERS(SLIMBUS_0_RX)
```

Setting a mixer element records `session->port_id = be_id` in `q6routing`.
Then, when the FE is opened, `q6asm-dai.c` calls
`q6routing_stream_open(dai_link->id, LEGACY_PCM_MODE, ...)`, which does:

```
q6adm_open(dev, session->port_id, ...)      ADM_CMD_DEVICE_OPEN_V5   0x00010326
                                       rsp  ADM_CMDRSP_DEVICE_OPEN_V5 0x00010329
q6adm_matrix_map(dev, session->path_type, ...)
                                            ADM_CMD_MATRIX_MAP_ROUTINGS_V5
                                                                     0x00010325
```

**Operational consequence:** without the mixer set, `session->port_id` is
never assigned and the FE never connects to the BE. Any test must set that
control (`amixer`) before opening the PCM, or it will prove nothing. This is
the DPCM equivalent of the "card does not autoload" trap.

## 9. The channel map: machine driver, not codec ABI — DECIDED

`q6slim_hw_params()` records only `sample_rate` and `bit_width`. It never sets
`num_channels` or `ch_mapping[]`; those come solely from
`q6slim_set_channel_map()`. So without an explicit call the AFE port would be
configured with **`num_channels = 0` and an unset channel map**, and
`q6afe_dai_prepare()` would consume that.

The first Branch A experiment therefore sets it from the **Lumia machine
driver**, in the BE link's `ops->hw_params`:

```
snd_soc_dai_set_channel_map(cpu_dai /* SLIMBUS_0_RX */,
                            0, NULL,      /* tx */
                            1, (u32[]){144} /* rx: one channel */);
```

**The codec keeps its current fixed RX1 selection and gains nothing.** No
`.set_channel_map`, no `.get_channel_map`.

`apq8096` does it the other way — asks the codec for its map and relays it,
treating `-ENOTSUPP` as success — but that only works when something else has
already established the DSP-side map. Copying it here would hide the
assumption instead of testing it.

Stating the assumption plainly is the point:

> This experiment **proposes** WCD9320 RX1 (slave port 16) corresponds to
> SLIMbus channel 144 on AFE port `SLIMBUS_0_RX` (0x4000), and tests that
> proposal against a real AFE response. An AFE rejection is a useful result.

Codec-side channel-map ABI stays deferred until RX1 <-> 144 is
hardware-confirmed **and** the data-plane milestone needs real
`slim_stream_*` allocation. Encoding an unproven channel number into the
codec's permanent interface now would be the wrong order.

## 10. The remote transaction sequence, and its inverse

Every create/start below has its teardown identified before implementation.

| # | stage | command | opcode | inverse |
|---|---|---|---|---|
| 1 | FE open | `q6asm_audio_client_alloc` | local | `q6asm_audio_client_free` |
| 2 | route | `q6adm_open` | `ADM_CMD_DEVICE_OPEN_V5` 0x00010326, rsp 0x00010329 | `q6adm_close` / `ADM_CMD_DEVICE_CLOSE_V5` 0x00010327 |
| 3 | route | `q6adm_matrix_map` | `ADM_CMD_MATRIX_MAP_ROUTINGS_V5` 0x00010325 | re-map on close |
| 4 | FE prepare | `q6asm_map_memory_regions` | `ASM_CMD_SHARED_MEM_MAP_REGIONS` 0x00010D92 | `ASM_CMD_SHARED_MEM_UNMAP_REGIONS` 0x00010D94 |
| 5 | FE prepare | `q6asm_open_write` | `ASM_STREAM_CMD_OPEN_WRITE_V3` 0x00010DB3 | `ASM_STREAM_CMD_CLOSE` 0x00010BCD |
| 6 | BE prepare | `q6afe_slim_port_prepare` + `q6afe_port_start` | `AFE_PORT_CMD_SET_PARAM_V2` 0x000100EF, `AFE_PORT_CMD_DEVICE_START` 0x000100E5 | `q6afe_port_stop` / `AFE_PORT_CMD_DEVICE_STOP` 0x000100E6 |
| 7 | codec | `wcd9320` `hw_params` | SLIMbus register writes | `hw_free` — already proven |
| 8 | trigger | `q6asm_run_nowait` | `ASM_SESSION_CMD_RUN_V2` 0x00010DAA | `ASM_SESSION_CMD_PAUSE` 0x00010BD3 |

**Sample movement is `ASM_DATA_CMD_WRITE_V2` (0x00010DAB) and appears nowhere
above.** That is the line this milestone does not cross.

**One subtlety worth stating**, because it looks like data-plane work and is
not: step 4 maps a DMA buffer to the DSP *before* the session is opened. It is
a control transaction with a reply, not sample traffic — but it does mean the
FE allocates a real buffer, so "no DMA at all" is not an accurate description
of the milestone. "No sample movement, no buffer progression" is.

## 11. Scope and naming for the next milestone

Proposed: **`msm8974-q6-playback-control-plane-proven`**, not "CPU DAI
proven", which understates a topology of two DAIs, a mixer route and three
APR services.

Its claim would be: *a real QDSP6 playback FE/BE path can be instantiated;
ASM, ADM and AFE control operations receive successful DSP responses;
`SLIMBUS_0_RX` accepts the proposed one-channel configuration; and the
existing WCD9320 RX callback still produces its frozen `0x040: 00->05`,
`0x180: 00->01` delta.*

It would explicitly **not** claim `slim_stream_allocate/prepare/enable`,
buffer progression, sample movement, or audible audio.

Still to settle before DT: whether the existing `wcd9320-lumia-card` becomes
the real machine driver or is replaced, and whether the FE's DMA buffer
allocation needs anything platform-specific on MSM8974.

## 12. An upstream observation, recorded not acted on

`q6routing.c:349` keeps `static struct msm_routing_data *routing_data`,
assigned in probe and freed in remove — **the same file-scope-singleton shape
we just fixed in our own driver** (`wcd9320-probe-lifetime-safe`). If
`q6routing` is ever rolled back by a deferred probe, it has the same class of
exposure. Not ours to fix, not in scope, and noted so it is not mistaken for a
new defect if it ever surfaces.

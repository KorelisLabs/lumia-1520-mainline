# The Q6 control plane: mapping, before enabling anything

Research only. No Kconfig change, no DT change. Read from the exact sources
this port builds: `msm8974-mainline/linux` at `v6.16.12-msm8974`.

The milestone this maps toward is narrow: *can Linux's real Qualcomm audio
stack replace the dummy CPU side and negotiate with the ADSP?* Not "can it
play samples".

**Question 0 comes first, and it has a hard-stop branch:** does this Lumia
ADSP firmware expose the Qualcomm audio services mainline expects? The NGD
work proved the DSP participates in SLIMbus satellite control. It proved
nothing about AFE, ASM or ADM.

## 1. Mainline APR does not discover services — it asserts them

This is the first thing to get right, because it decides how Question 0 can be
answered at all.

`of_register_apr_devices()` walks the APR node's **DT children** and creates a
device per child that has a `reg`:

```c
for_each_child_of_node(dev->of_node, node) {
        u32 svc_id;
        if (of_property_read_u32(node, "reg", &svc_id))
                continue;
        domain_id = apr->dest_domain_id;
        apr_add_device(dev, node, svc_id, domain_id);
}
```

There is no enumeration handshake. If DT says there is an AFE at service 4,
Linux creates an AFE device and the driver binds — **whether or not the
firmware has any such service**. A missing service does not fail at probe; it
fails later, as a timeout on the first command.

So "what services does the firmware have" cannot be read out of DT, out of
`lsmod`, or out of any sysfs tree. It has to be *asked*.

| id | service | constant |
|---|---|---|
| `0x3` | ADSP core | `APR_SVC_ADSP_CORE` |
| `0x4` | AFE — front end, ports/clocks | `APR_SVC_AFE` |
| `0x7` | ASM — stream manager | `APR_SVC_ASM` |
| `0x8` | ADM — routing/matrix | `APR_SVC_ADM` |

Destination domain is `APR_DOMAIN_ADSP` = `0x4`.

## 2. The firmware can be asked directly — and the answer *is* the inventory

`q6core` implements exactly the query Question 0 needs:

```c
#define AVCS_GET_VERSIONS       0x00012905
#define AVCS_GET_VERSIONS_RSP   0x00012906

struct avcs_svc_info {
        uint32_t service_id;
        uint32_t version;
} __packed;

struct avcs_cmdrsp_get_version {
        uint32_t build_id;
        uint32_t num_services;
        struct avcs_svc_info svc_api_info[];
} __packed;
```

The ADSP replies with `num_services` and an array of `{service_id, version}`.
**That is the service inventory, reported by the firmware itself**, not
inferred. A newer variant, `AVCS_CMD_GET_FWK_VERSION` (`0x001292c`), returns
api/branch versions per service; `q6core` probes for it and falls back.

`q6core` also exports the two things a gate would assert on:

```c
bool q6core_is_adsp_ready(void);
int  q6core_get_svc_api_info(int svc_id, struct q6core_svc_api_info *ainfo);
```

> **CORRECTED after the first probe boot (2026-08-17).** Three claims that
> stood here were wrong, and they are kept below with their corrections
> because the mechanism they describe is what the milestone was designed
> around. See §7 for the measurements.
>
> 1. ~~"Question 0's experiment is therefore one APR service and one
>    command."~~ **It is not one command — it is zero.** `q6core_probe()`
>    kzallocs, sets drvdata, inits a mutex and a waitqueue, and returns 0.
>    Binding `q6core` puts **no packet on the wire, ever**. The query is lazy,
>    behind `q6core_get_svc_api_info()`, whose only in-tree callers are
>    `q6afe`, `q6asm` and `q6adm` — all of which this milestone forbids
>    instantiating. Without a trigger, a bound `q6core` sits silent forever.
>
> 2. ~~The reply can be observed.~~ **`q6core` never reports the inventory to
>    anyone.** The response is `kmemdup`'d into a private `struct q6core`
>    behind a file-scope `static g_core`, with no sysfs, no debugfs and no
>    printk of the service table. Its only log statement is a `dev_err` in the
>    callback's `default:` arm. Any plan to read `num_services` out of the
>    kernel log could not have worked on any firmware.
>
> 3. ~~"`ADSP_STATE_READY_TIMEOUT_MS 3000` — so 'no reply' is a bounded,
>    observable outcome rather than a hang."~~ Bounded, yes; **observable, no.**
>    `__q6core_is_adsp_ready()` clears `get_state_supported` on entry and
>    ends with *"assume that the adsp is up if we not support this command"* —
>    so on a timeout it returns **true**. `q6core_is_adsp_ready() == true`
>    therefore does not distinguish a real `AVCS_CMDRSP_ADSP_EVENT_GET_STATE`
>    from total silence, and must never be used as evidence that the ADSP
>    answered.
>
> The corrected shape: Question 0 needs **a trigger and an observer**, neither
> of which stock `q6core` provides. The trigger can use only the exported
> `q6core_get_svc_api_info()`; the observer has to be independent of it,
> because that function's `-ENOTSUPP` conflates "service not in the inventory"
> (verdict B) with "no inventory arrived" (verdict C2) — the one conflation
> the verdict design exists to prevent.

## 3. The Kconfig is all-or-nothing — but DT still gates what probes

`SND_SOC_QDSP6` is the **only** symbol in the q6 group with a prompt. Every
sub-symbol is a promptless `tristate`, reachable only by `select`:

```
config SND_SOC_QDSP6
        tristate "SoC ALSA audio driver for QDSP6"
        depends on QCOM_APR
        depends on COMMON_CLK
        select SND_SOC_QDSP6_COMMON   select SND_SOC_QDSP6_CORE
        select SND_SOC_QDSP6_AFE      select SND_SOC_QDSP6_AFE_DAI
        select SND_SOC_QDSP6_AFE_CLOCKS select SND_SOC_QDSP6_ADM
        select SND_SOC_QDSP6_ROUTING  select SND_SOC_QDSP6_ASM
        select SND_SOC_QDSP6_ASM_DAI  select SND_SOC_TOPOLOGY
        select SND_SOC_QDSP6_APM      select SND_SOC_QDSP6_PRM
```

There is no supported way to build `q6core` alone. Writing
`CONFIG_SND_SOC_QDSP6_CORE=m` into the config by hand would be dropped by
`olddefconfig`, because nothing selects it.

**The resolution is that Kconfig controls what is *built*; DT controls what
*probes*.** Enabling the umbrella compiles the whole stack, but every q6
driver binds to an APR device created from a DT child node. With an APR node
carrying **only** a `q6core` child, only `q6core` probes. AFE, ASM, ADM and the
rest are built and idle.

So the minimal Question-0 experiment is:

| layer | scope |
|---|---|
| Kconfig | `SND_SOC_QDSP6=m` — unavoidably the whole group |
| DT | APR node + **one** child, `reg = <APR_SVC_ADSP_CORE>` (3) |
| runtime | one driver probes; one command; one reply |

`QCOM_APR=y` is already set. `COMMON_CLK` needs confirming but is effectively
certain on this platform.

This also protects the 117-check baseline in the way that matters: the existing
codec, cache and IRQ paths are untouched, and no q6 driver other than `q6core`
ever binds.

## 4. Branch A / Branch B — decided before the experiment, not after

**Branch A — the reply enumerates AFE, ASM and ADM.** The conventional Q6 ASoC
stack is physically possible on this firmware. Proceed to map the CPU DAI
taxonomy and DT requirements, then attempt the real CPU-DAI milestone.

**Branch B — the reply is missing those services, or nothing replies.** This is
**not a failed experiment**; it is an architectural finding:

> The Windows Phone ADSP firmware provides the satellite/SLIMbus control
> functionality already observed, but does not provide the conventional
> Qualcomm audio-service interface mainline's Q6 ASoC stack expects.

If that happens, **do not invent shims**. Freeze the finding and treat the
choice between a different DSP interface, reverse-engineering the WP audio
protocol, alternative firmware, or an AP-side path as its own boundary with
its own mapping.

A third outcome is possible and must be distinguished from B: `q6core` itself
gets no reply, which says only that the *core* service is absent or the APR
plumbing is misconfigured — it does not license any statement about AFE or
ASM. The gate must separate "the DSP answered and listed services" from "the
DSP did not answer".

## 5. What a successful control transaction looks like

Defined now, before implementation, so the gate cannot be softened later:

```
something calls q6core_get_svc_api_info()            <- REQUIRED; nothing does
        -> AVCS_CMD_GET_FWK_VERSION (0x0001292c) to domain 4, service 3
        -> APR packet leaves
        -> ADSP core service receives it
        -> AVCS_CMDRSP_GET_FWK_VERSION (0x0001292d) returns
        -> num_services > 0, svc_api_info[] populated

   or, only if the first returns -ENOTSUPP:
        -> AVCS_GET_VERSIONS (0x00012905)
        -> AVCS_GET_VERSIONS_RSP (0x00012906)
```

**The first packet is `AVCS_CMD_GET_FWK_VERSION`, not `AVCS_GET_VERSIONS`.**
And the fallback is narrower than it looks: `q6core_get_fwk_versions()` returns
`wait_event_timeout()`'s `rc`, which is **0 on timeout, not `-ENOTSUPP`**. So
against a silent ADSP the fallback never fires and `0x00012905` is never sent
at all. A C2 verdict therefore means "the *first* request went unanswered" —
it is not evidence that both commands were tried.

Evidence should capture the sent opcode, the response opcode, `num_services`,
and each `{service_id, version}` pair — not merely "the driver probed", and not
`q6core_is_adsp_ready()`, which returns true on timeout (§2, correction 3).

## 6. Deferred until Question 0 is answered

Deliberately recorded as open rather than guessed:

- **CPU DAI taxonomy.** Which Q6 DAI corresponds to the real playback path
  toward a SLIMbus codec on an MSM8974-era part. Must not be chosen because it
  happens to yield a PCM; `q6afe-dai` exposes several endpoint families
  (SLIMBUS, MI2S, etc.) and the SLIMbus one is the only candidate that could
  ever reach the WCD9320.
- **DT requirements** per component: compatible, clocks, regulators, APR/Q6
  references, routing properties, memory/DMA expectations, and which nodes
  RM-940 lacks entirely.
- **Cleanup semantics.** Every control object's inverse (open/close,
  enable/disable, map/unmap, connect/disconnect, start/stop), and — the part
  with no precedent in this port — whether ADSP-side state dies with PCM
  close, module unload, remoteproc restart, AP reboot, or only a cold boot.
  Every milestone so far could assume a clean slate per boot. A session living
  on the remote processor breaks that assumption, and the acceptance gate must
  require evidence of **remote acknowledgement** of teardown, not just Linux
  freeing local structures.

Those three depend on Branch A being taken. Mapping them before Question 0 is
answered would be work spent on a stack that may not exist on this firmware.

## 7. What the first probe boot measured (2026-08-17, boot #150)

The DT node, the config change and the evidence script were built as r149 and
run. The transport chain is **fully established**:

```
ADSP remoteproc0            running
lpass SMD edge              up
apr_audio_svc channel       present
APR device                  aprsvc:service:4:3   (domain 4, service 3)
qcom-q6core                 bound
```

`q6afe`, `q6asm`, `q6adm` and `q6routing` were confirmed **not** instantiated,
and exactly one core instance exists. Verdict: **C0, QUERY_MECHANISM_ABSENT** —
zero packets, because nothing issues one. That is the driver's design, not the
firmware's answer, and it licenses no claim about any service.

### The first run reported C1, and C1 was wrong

The initial script concluded `APR_AUDIO_CHANNEL_ABSENT` on a boot whose own log
contained `Adding APR/GPR dev: aprsvc:service:4:3`. Three faults, all pushing
the same way — toward a false negative about the firmware:

1. **The bus is `aprbus`, not `apr`.** `drivers/soc/qcom/apr.c` registers it
   under that name, so a glob of `/sys/bus/apr/devices` silently returned
   nothing and a bound device read as `none`.
2. **`q6core` was not loaded, and could not have been.** See §8.
3. **The inventory was grepped out of `dmesg`,** which §2 correction 2 shows
   can never match.

The classifier then treated "q6core not bound" as C1 — conflating a missing
driver with a missing channel. The verdict set now separates them: **S**
(setup incomplete) and **C0** (no trigger) are distinct from C1 and C2, and
service-absence language is emitted by a `refuse_absence_language()` function
that only the non-B branches call, so the prohibition is structural rather
than editorial.

## 8. Two standing traps this milestone exposed

Both will recur for every future `=m` symbol and both are silent.

- **`fastboot boot` never updates `/lib/modules`.** It RAM-loads a kernel; the
  eMMC rootfs is untouched. Every module built by a config change is left in
  the package. `q6core.ko` had to be extracted from the r149 apk and installed
  by hand, into a `sound/soc/qcom/qdsp6/` directory that did not yet exist
  because QDSP6 was off when that rootfs was built.
- ~~**`q6core` can never autoload.**~~ **WRONG -- corrected on boot #155.**
  `apr_uevent()` calls `of_device_uevent_modalias()` first and only falls back
  to `MODALIAS=apr:<name>` for a device with no `of_node`, which a DT-declared
  service never is. All eight q6 modules autoloaded unaided once present in
  `/lib/modules`, and all four APR services bound. The original symptom was
  entirely the missing-module trap above; I inferred a second cause from
  `apr.c:399` without reading the line before it.

## 9. The negative control must be a separate build — proven, not assumed

`q6core` keeps its state in a file-scope `static struct q6core *g_core`.
`q6core_probe()` overwrites it unconditionally and `q6core_exit()` sets it to
`NULL` unconditionally, regardless of which instance is leaving. Two
simultaneous instances would leak the first and let either one's removal blind
the other.

**`q6core` is architected as a singleton.** The wrong-service-id control is
therefore a separate boot with the single node's `reg` changed — never a second
DT child alongside the real one. The evidence script asserts at most one core
instance so this cannot be built the forbidden way by accident.

## 10. A cheaper discriminator than the wrong-service control

The probe boot showed the ADSP exposes **three** APR channels, not one:

```
remoteproc0:smd-edge.apr.-1.-1
remoteproc0:smd-edge.apr_apps2.-1.-1
remoteproc0:smd-edge.apr_audio_svc.-1.-1
```

We bound `apr_audio_svc` because that is mainline's msm8974 convention. If the
core query goes unanswered there, plain `apr` should be tried **before** any
conclusion about the firmware: it is a channel-name change rather than an
addressing change, so it tests a different assumption and is cheaper to build.
`fastrpcsmd-apps-dsp` is also up, so this ADSP carries a FastRPC surface —
noted, not pursued.

## 11. THE ANSWER — Question 0 is closed, Branch A is taken

Measured on boot #151, 2026-08-17. One query, one boot, one reply.

```
GET_FWK_VERSION  0x0001292c  ->  APR_BASIC_RSP_RESULT 0x000110E8
                                   original opcode 0x0001292c
                                   status 0x00000003 = ADSP_EUNSUPPORTED
                                   -> the legacy fallback was LICENSED
AVCS_GET_VERSIONS 0x00012905 ->  AVCS_GET_VERSIONS_RSP 0x00012906
                                   96 bytes, untruncated, num_services = 11
```

`callback_hits=2` accounts for exactly those two arrivals and nothing else.
The 96 bytes are exactly `8 + 11 * 8`, so the table length is internally
consistent with the count the firmware reported.

### The inventory, as the firmware reported it

Service IDs resolved from `include/dt-bindings/soc/qcom,apr.h`.

| id | service | version |
|---|---|---|
| 0x3 | `APR_SVC_ADSP_CORE` | 0x00040000 |
| 0x4 | **`APR_SVC_AFE`** | 0x00200000 |
| 0x5 | `APR_SVC_VSM` | 0x00070004 |
| 0x6 | `APR_SVC_VPM` | 0x00070005 |
| 0x7 | **`APR_SVC_ASM`** | 0x00070003 |
| 0x8 | **`APR_SVC_ADM`** | 0x00070001 |
| 0x9 | `APR_SVC_ADSP_MVM` | 0x00010000 |
| 0xA | `APR_SVC_ADSP_CVS` | 0x00010000 |
| 0xB | `APR_SVC_ADSP_CVP` | 0x00010000 |
| 0xC | `APR_SVC_USM` | 0x70000000 |
| 0xD | `APR_SVC_LSM` | 0x10000000 |

Contiguous from `ADSP_CORE` through `LSM` with no gaps — every APR service the
binding header defines below `VIDC`. Not merely the three the Q6 ASoC playback
path needs, but the voice stack and listen as well.

### Two independent readings, no disagreement

The observer captured the raw payload by kprobe before `q6core` consumed it.
The trigger separately called the exported `q6core_get_svc_api_info()` for
services 3, 4, 7 and 8. They agree exactly:

```
svc 3  0x00040000    table 262144  = 0x00040000
svc 4  0x00200000    table 2097152 = 0x00200000
svc 7  0x00070003    table 458755  = 0x00070003
svc 8  0x00070001    table 458753  = 0x00070001
```

All four returned 0 with `poison_intact=0`, so none is the `!g_core` false
success the poison defence exists to catch. The raw payload decodes identically
on the phone and on an x86 host, from the same decoder, to the same 11 rows.

### What this establishes, and what it does not

> The Lumia 1520 Windows Phone ADSP firmware exposes the conventional Qualcomm
> APR audio-service inventory, including AFE, ASM and ADM.

It does **not** establish that any of those services successfully executes an
audio command. Not AFE port configuration, not ASM sessions, not ADM routing,
not CPU DAI operation, not buffer allocation, not DMA, not SLIMbus channel
allocation, not PCM data movement, not routing, and not audible playback.

**Branch B is disproven, not deferred.** The "this firmware does not speak Q6"
outcome the mapping planned for did not occur, and the project does not need to
choose between reverse-engineering the WP audio path and a non-Q6 route.

### Next

Branch A: map the CPU DAI taxonomy and the per-component DT requirements, then
attempt the real CPU-DAI milestone. Data movement is a separate milestone after
that, and cleanup semantics -- whether ADSP-side state dies with PCM close,
module unload, remoteproc restart, or only a cold boot -- remains unmapped and
is the part with no precedent in this port (§6).

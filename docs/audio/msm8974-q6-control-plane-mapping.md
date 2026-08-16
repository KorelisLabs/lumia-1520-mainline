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

with `ADSP_STATE_READY_TIMEOUT_MS 3000` — so "no reply" is a bounded,
observable outcome rather than a hang.

**Question 0's experiment is therefore one APR service and one command.** That
is far smaller than the milestone it gates, which is exactly the shape this
project has been working in.

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
host sends AVCS_GET_VERSIONS (0x00012905) to domain 4, service 3
        -> APR packet leaves
        -> ADSP core service receives it
        -> AVCS_GET_VERSIONS_RSP (0x00012906) returns
        -> num_services > 0, svc_api_info[] populated
```

Evidence should capture the sent opcode, the response opcode, `num_services`,
and each `{service_id, version}` pair — not merely "the driver probed".
`q6core_is_adsp_ready()` returning true is a summary, not the measurement; the
service list is the measurement.

## 6. Still to map — this document is not finished

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

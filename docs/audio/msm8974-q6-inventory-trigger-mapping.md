# The Q6 inventory trigger and observer: mapping, before writing either

Research only. No code yet. Read from `msm8974-mainline/linux` at
`v6.16.12-msm8974`, the tree this port builds.

The C0 run established the transport chain and nothing more: `apr_audio_svc`
present, `aprsvc:service:4:3` created, `qcom-q6core` bound, zero packets sent.
Silence at that point is **host-side design** — `q6core_probe()` sends nothing
— not a firmware response. This document maps what has to exist before the
firmware can be asked anything at all.

**The controlling constraint is that there is one usable query per boot.** §1
explains why. Everything else follows from it: the observer must be armed
before the trigger can fire, because a badly observed first trigger consumes
the only useful query state that boot and the answer is unrecoverable without
a reboot.

## 1. One query per boot — the cache semantics, exactly

`q6core_get_svc_api_info()` is the only exported path to the inventory, and it
gates the whole transaction behind a one-shot flag:

```c
mutex_lock(&g_core->lock);
if (!g_core->is_version_requested) {
        if (q6core_get_fwk_versions(g_core) == -ENOTSUPP)
                q6core_get_svc_versions(g_core);
        g_core->is_version_requested = true;
}
```

`is_version_requested` is set **unconditionally** after the first attempt —
success, unsupported, or silence alike. There is no retry path and no reset
short of unbinding the driver.

And the fallback is narrower than it reads. `q6core_get_fwk_versions()` ends:

```c
rc = wait_event_timeout(core->wait, (core->resp_received),
                        msecs_to_jiffies(Q6_READY_TIMEOUT_MS));   /* 100 ms */
if (rc > 0 && core->resp_received) { ... return 0 or -ENOTSUPP; }
return rc;                                  /* 0 on timeout, NOT -ETIMEDOUT */
```

So on a 100 ms timeout it returns **0**, the `== -ENOTSUPP` test fails, and
`q6core_get_svc_versions()` is **never called**. The legacy `AVCS_GET_VERSIONS`
opcode is not merely unanswered — it is *never transmitted*.

```
fresh boot / fresh q6core bind
        |
    ONE trigger
        |
   AVCS_CMD_GET_FWK_VERSION  (0x0001292c)
        |
        +-- AVCS_CMDRSP_GET_FWK_VERSION -> inventory cached      -> A / B
        |
        +-- APR_BASIC_RSP_RESULT, status == ADSP_EUNSUPPORTED (3)
        |        -> returns -ENOTSUPP -> fallback LICENSED
        |        -> AVCS_GET_VERSIONS (0x00012905)
        |               +-- AVCS_GET_VERSIONS_RSP -> inventory   -> A / B
        |               +-- silence                              -> C2
        |
        +-- silence, 100 ms
                 -> returns 0 -> fallback NEVER ATTEMPTED
                 -> is_version_requested = true                  -> C2
```

**Consequences that shape the design:**

- Querying services 3, 4, 7 and 8 is **not four probes**. The first call
  performs the one transaction; the other three are pure lookups into the
  cached result. Only the first can fail as a *transaction*.
- A silent first request is not evidence about `AVCS_GET_VERSIONS`. The C2
  wording must say so explicitly — see §7.
- Re-running the trigger after a silent first attempt tells you nothing new.
  A genuine retry needs `unbind`/`bind` of the APR device (fresh `q6core_probe`
  → fresh `g_core` → `is_version_requested` clear) or a reboot.

## 2. The observer must be armed first, and must be independent

The trigger's return code cannot carry the result, for two separate reasons.

**It conflates B with C2.** `q6core_get_svc_api_info()` returns `-ENOTSUPP`
both when a complete inventory arrived without the requested service (**B**,
a licensed architectural finding) and when no inventory arrived at all
(**C2**, which licenses nothing). One value, two opposite meanings.

**And `0` does not mean success:**

```c
if (!g_core || !ainfo)
        return 0;
```

If the helper is called when `q6core` is not instantiated, it returns `0`
having written nothing to `ainfo`. A caller that trusts the return code reads
whatever was already in that memory.

**Defence, to be implemented:** poison `ainfo` with `0xFF` bytes before every
call and treat `ret == 0` with the poison intact as `INVALID`, never as a hit.
Combined with the §3 prerequisite this makes the null-`g_core` path
unreachable *and* detectable if it somehow occurs.

So the measurement is the observer's; the trigger only causes it.

## 3. Hard prerequisite: q6core actually bound

Checked in two places, because the failure modes differ.

**In the evidence script**, before the token is written: `q6core` present in
`/lib/modules`, loaded, and bound — the detection the C0 run already
validated against known ground truth on `/sys/bus/aprbus`. On failure it
refuses to trigger and reports **S**, never a C-verdict.

**In the module**, before the helper is called: iterate `aprbus`
(`EXPORT_SYMBOL_GPL(aprbus)`, `drivers/soc/qcom/apr.c:409`) and require a
device whose `dev->driver->name` is `qcom-q6core`. Refuse with `-ENODEV`
otherwise.

The module-side check is what makes the `!g_core` branch unreachable in
practice. The script-side check is what keeps the operator from spending the
boot's single query on a misconfigured run.

Like observer registration (§12), the bound check gates **`arm`**, not just
`fire`: every precondition is settled before the harness can enter a state
from which a query is possible at all.

## 4. kprobe feasibility on this target — checked, not assumed

| requirement | status |
|---|---|
| `arch/arm` `select HAVE_KPROBES if !XIP_KERNEL && !CPU_ENDIAN_BE32 && !CPU_V7M` | satisfied — MSM8974 is ARMv7-A, LE, not XIP |
| `CONFIG_KPROBES` / `CONFIG_KRETPROBES` | `=y` / `=y` |
| `CONFIG_THUMB2_KERNEL` | not set → ARM encoding, `actions-arm.c` path |
| `CONFIG_KALLSYMS_ALL` | `=y` — static module symbols resolvable by name |
| `register_kprobe` / `unregister_kprobe` | `EXPORT_SYMBOL_GPL` |
| `q6core_callback` | plain `static int`, no `notrace`/`noinline`/inline annotations |
| `CONFIG_MODULE_SIG_FORCE` | absent |

`CONFIG_KPROBES_ON_FTRACE` is **not** set, so the probe uses the breakpoint
path rather than the ftrace trampoline. That is fine at a function entry.

`q6core_callback` is reached through `adrv->callback(adev, &resp)` — an
indirect call — but a kprobe at the symbol's entry catches every caller, so
indirection is irrelevant.

**Ordering prerequisite:** `q6core` must be loaded before the probe is
registered, since the symbol lives in its module. `modprobe q6core` →
`insmod q6-inventory-probe` → arm → fire.

**Lifetime is already safe.** The probe module calls
`q6core_get_svc_api_info()`, so it carries a module dependency on `q6core`;
`q6core` therefore cannot be unloaded while the probe module is loaded, and
the kprobe can never point into freed module text. This falls out of the
symbol dependency — no `try_module_get()` needed — but the mapping records it
because it is the failure that would panic the phone.

## 5. `register_kprobe`, not `kprobe_events`

The text interface can fetch scalars at fixed offsets. It **cannot copy a
variable-length array**, which is exactly what the full inventory is. A
C pre-handler can `memcpy` `payload_size` bytes verbatim.

```c
static int q6_obs_pre(struct kprobe *p, struct pt_regs *regs)
{
        struct apr_resp_pkt *data = (struct apr_resp_pkt *)regs->ARM_r1;
        ...
}
```

`regs_get_kernel_argument()` is **not defined for ARM**, so the second
argument is read as `regs->ARM_r1` directly (`arch/arm/include/uapi/asm/
ptrace.h:150`). AAPCS puts arg0 in `r0`, arg1 in `r1`; at function entry,
before the prologue, both are still live.

Offsets, recorded so a `kprobe_events` fallback stays possible and so the
handler's casts can be sanity-checked:

```
struct apr_hdr           __packed, 20 bytes
    hdr_field  +0 (u16)   pkt_size  +2 (u16)
    src_svc    +4  src_domain +5   src_port  +6 (u16)
    dest_svc   +8  dest_domain +9  dest_port +10 (u16)
    token     +12 (u32)   opcode   +16 (u32)

struct apr_resp_pkt      NOT packed
    hdr       +0 (20 bytes)   payload +20 (ptr)   payload_size +24 (int)
```

## 6. What the observer records — full table, not just the four services

The stronger contract is the right one: we are asking the firmware what it
contains, so the firmware's complete answer is what gets preserved. The
exported helper cannot provide it — it answers only for the `svc_id` asked,
while `num_services` and the array stay in the private `g_core` allocation —
but the kprobe sees the raw payload before `q6core` consumes it.

Three materially different arrivals, all captured:

**`AVCS_CMDRSP_GET_FWK_VERSION` (0x0001292d)**
```
build_major +0  build_minor +4  build_branch +8  build_subbranch +12
num_services +16
svc_api_info[] from +20 : { service_id, api_version, api_branch_version }
```

**`AVCS_GET_VERSIONS_RSP` (0x00012906)**
```
build_id +0   num_services +4
svc_api_info[] from +8 : { service_id, version }
```

**`APR_BASIC_RSP_RESULT` (0x000110E8)** — capture **both** fields:
```
struct aprv2_ibasic_rsp_result_t { u32 opcode; u32 status; }
```
The embedded `opcode` is the *original request* being answered and `status`
is the ADSP's verdict on it. `status == ADSP_EUNSUPPORTED` (`0x3`) against
opcode `0x0001292c` is the one thing that mechanically proves the legacy
fallback was **licensed** rather than skipped — and it is what stops an
unsupported-command response being misread as an inventory.

Every arrival is logged in order with its opcode, so the transcript itself
shows which of §1's three paths the firmware took. `payload_size` is recorded
alongside `num_services` so a truncated or malformed reply cannot masquerade
as a complete table: **the table is accepted only if
`payload_size` accommodates `num_services` entries.**

The trigger's lookups for services 3, 4, 7 and 8 are then a **cross-check of
the helper against the captured table**, not the measurement. Disagreement
between the two is itself a finding and must be reported, not reconciled.

Note deliberately *not* assumed: that the core service (3) lists itself. The
observer decides whether a reply arrived; no service's presence is used as a
proxy for that.

## 7. The verdict ladder

```
C0  QUERY_MECHANISM_ABSENT
    transport proven, nothing sent, no trigger present.

A   INVENTORY_RECEIVED_REQUIRED_AUDIO_PRESENT
    observer captured a qualifying inventory reply;
    AFE(4), ASM(7), ADM(8) present in the table.

B   INVENTORY_RECEIVED_REQUIRED_AUDIO_ABSENT
    observer captured a qualifying inventory reply;
    one or more required services absent.
    THE ONLY VERDICT THAT LICENSES SERVICE-ABSENCE LANGUAGE.

C2  CORE_QUERY_UNANSWERED
    request observed leaving; no qualifying inventory response.
    Absence language forbidden.

S   SETUP_INCOMPLETE
    prerequisite, observer-arming or trigger failure.
    No firmware conclusion of any kind.
```

`C1 APR_AUDIO_CHANNEL_ABSENT` is **retained in the script but is not a live
branch** for Run A: the C0 run measured the channel present. It stays because
it becomes live again for the Run B control in §8, and because a guard that
can still fire is worth more than one deleted on the strength of a single
boot.

**C2 must state which of the two silences occurred**, since §1 shows they are
not equivalent:

> *first FWK request silent at 100 ms; `is_version_requested` latched; legacy
> `AVCS_GET_VERSIONS` was never transmitted*

versus a C2 where `ADSP_EUNSUPPORTED` licensed the fallback and the legacy
request also went unanswered. The first says nothing whatever about
`0x00012905`; only the second tests both opcodes. The observer's transcript
distinguishes them mechanically.

## 8. Run A, then — only if needed — Run B

The C0 boot showed the ADSP exposes three APR channels: `apr`, `apr_apps2`
and `apr_audio_svc`. Current evidence establishes only that `apr_audio_svc`
is real and attaches cleanly.

```
Run A : qcom,smd-channels = "apr_audio_svc"     <- first, unchanged
Run B : qcom,smd-channels = "apr"               <- only if Run A yields C2
```

Identical core service, identical query, identical trigger and observer, so
**channel selection is the single changed variable**. Run B is a separate
build and a separate boot; it is not folded into the first run, and its
result does not retroactively reinterpret Run A's.

`apr_apps2` stays documented and untouched until its purpose is mapped.

If Run A yields C2, Run B is attempted **before** any conclusion that this
firmware lacks a responsive AVCS core service. The wrong-service-id control
(§9) comes after both, since it tests addressing rather than transport.

## 9. The negative control stays a separate build

`q6core` keeps its state in a file-scope `static struct q6core *g_core`,
assigned unconditionally by probe and `NULL`ed unconditionally by remove. It
is a singleton. The wrong-service-id control is therefore a separate build
with the single node's `reg` changed — never a second DT child. The evidence
script already asserts at most one core instance so this cannot be built the
forbidden way by accident.

## 10. Scope of the milestone

**In:** one trigger module; one kprobe observer; one APR service (3); the
`q6core` binding prerequisite; capture of the full version-response payload;
the verdict ladder above; the existing 117-check regression contract passing
before any inventory result is accepted.

**Out:** `q6afe`, `q6asm`, `q6adm`, `q6routing` instantiation; any CPU DAI;
any card, PCM, routing or DAPM change; any modification to in-tree `q6core`;
Run B; the wrong-service-id control; and any claim about playback, capture or
audible audio.

The probe module uses only `EXPORT_SYMBOL_GPL` interfaces
(`q6core_get_svc_api_info`, `aprbus`, `register_kprobe`) and modifies no
existing driver.

## 11. Settled decisions

### 11.1 Trigger surface: debugfs, one-way, observer before arm

`debugfs`, not `sysfs`. This is an experimental diagnostic harness with no
intended userspace ABI, which is what debugfs is for; sysfs carries ABI
expectations this fixture must not acquire.

```
/sys/kernel/debug/q6_inventory/
    arm             WO   token-guarded
    fire            WO   token-guarded
    status          RO   text, scalar facts
    inventory_raw   RO   binary, verbatim payload
```

One-way state machine, no path back:

```
UNARMED --(valid arm token)--> ARMED --(valid fire token)--> FIRED
```

- A second `fire` returns `-EALREADY`.
- **No re-arm after FIRED**, even if the query was silent. The experiment
  depends on one observed first transaction; a re-arm would let a second
  attempt be mistaken for the first, and after a silent request §1 shows
  there is nothing left to retry anyway.
- **`arm` fails unless the observer is already registered.** This is the
  ordering that matters: gating only `fire` would permit an
  armed-but-unobserved state to exist.

```
observer registered  ->  arm permitted  ->  fire permitted
```

### 11.2 Placement: beside q6core

```
sound/soc/qcom/qdsp6/q6inventory_probe.c
#include "q6core.h"        /* the real private header, not a redeclaration */
```

Not `drivers/slimbus/`. This interrogates QDSP6/APR state; SLIMbus merely
happens to be part of the same Lumia audio problem. Sitting beside `q6core`
also keeps the public/private boundary visible in one place: the **trigger**
uses the exported QDSP6 API, the **observer** deliberately probes the private
callback.

Its own default-off diagnostic symbol, so this fixture can never be mistaken
for production audio architecture:

```
config SND_SOC_QDSP6_INVENTORY_PROBE
        tristate "QDSP6 service-inventory diagnostic probe (developers only)"
        depends on SND_SOC_QDSP6_CORE && KPROBES && DEBUG_FS
        default n
```

### 11.3 Readout: human `status`, verbatim `inventory_raw`

The observer's job is faithful capture, not presentation. Parsing happens in
userspace, so **both** the firmware's actual bytes and the parser's reading of
them survive — if the parser is later found wrong, the raw evidence is still
there to re-read.

`status` carries scalar facts only:

```
state=FIRED
probe_registered=1        resolved_address=0x...
fire_count=1              callback_hits=N
first_request_opcode=0x0001292c
fwk_response_seen=0/1
basic_rsp_seen=0/1        basic_rsp_original_opcode=0x...
                          basic_rsp_status=0x...
legacy_response_seen=0/1  legacy_response_opcode=0x00012906
inventory_payload_seen=0/1
payload_size=N            captured_size=N        truncated=0/1
svc3_ret=...  svc4_ret=...  svc7_ret=...  svc8_ret=...
```

`inventory_raw` is the verbatim captured inventory-response payload, nothing
else.

**The kprobe handler stays boring.** Buffer preallocated at module init;
bounds-check `payload_size`; one `memcpy`; record metadata; return. No
allocation, no parsing of the variable table, no printk storm — the
pre-handler runs on every hit of the probed instruction, so work done there is
work done in that context.

Hard rule, no exceptions:

```
payload_size > capture_capacity  ->  truncated=1  ->  A/B FORBIDDEN
```

A partial capture is never called "the service inventory".

### 11.4 Retry: no

**A fresh `q6core` instance means a fresh boot.** No `unbind`/`bind`, no
trigger-module reload as a retry, no second query after C2. Rebinding would
introduce a remove/probe lifecycle this port has never validated, and if
anything then went wrong we could no longer tell whether we were observing the
firmware's response or the consequences of tearing down and reconstructing
`q6core`/APR state.

If Run A yields C2, the next discriminator is a **fresh boot** with the same
probe, observer, query and evidence, on the plain `apr` channel (§8) — one
variable changed. `q6core` reinitialisation becomes its own explicitly scoped
experiment only if we later have a reason to study it.

## 12. Probe registration is part of setup validity

The observer reaches into a static function by kprobe and reads `ARM_r1`. If
that registration silently failed, the trigger would still fire, the query
would still leave, nothing would be observed — and the run would report **C2**
on a broken observer rather than a silent DSP. That is the worst outcome this
milestone can produce, because it looks exactly like a real firmware finding.

So registration is a **setup gate**, checked before `arm` is permitted:

```
register_kprobe(q6core_callback) == 0
resolved_address                 != 0
probe_registered                 == 1
capture buffer allocated
        |
        +-- all true  -> arm may succeed
        +-- any false -> S SETUP_INCOMPLETE, and FIRE IS IMPOSSIBLE
```

`register_kprobe()` returns an error when registration fails, and
`kp.addr` after a successful registration gives the resolved address — both
are recorded in `status`. A run that cannot observe must not be able to ask.

## 13. The acceptance contract

```
One FIRE per boot.
No q6core unbind/rebind.
No trigger-module reload used as a retry mechanism.
No second firmware query after C2.
Observer registered before ARM; ARM before FIRE; no path back.
Truncated capture forbids A/B.
Absence language only under B.
117-check regression passes before any inventory result is accepted.
```

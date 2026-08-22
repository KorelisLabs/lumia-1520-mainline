# The QDSP6 playback control plane works

**Status:** proven on hardware, 2026-08-22.
**Evidence:** `msm8974-q6-playback-control-20260822T221532Z.txt` (22 checks, 0 failed).
**Gate:** `tools/msm8974-q6-playback-control-evidence.sh`.
**Kernel:** 6.16.12 r155, codec `lifetime-rc1`, card `q6-card-rc1`.

## The claim

A real QDSP6 FE/BE path can be instantiated from device tree; ASM, ADM and AFE
control operations reach the ADSP and are acknowledged; SLIMBUS_0_RX accepts a
one-channel configuration; and the WCD9320 reproduces its frozen RX register
delta through that path.

## What was observed

The card came up from DT with the FE/BE split the design predicted:

```
front end: MultiMedia1 Playback (id 0)
back end:  SLIM Playback (id 2)
QDSP6 card registered: 2 link(s)
```

The DAPM route was enabled by numid 17, `SLIMBUS_0_RX Audio Mixer MultiMedia1`,
type BOOLEAN, **read back as 1**. Then an ordinary `open` + `hw_params` +
`prepare` drove the whole chain. Each remote call was counted by a kprobe
rather than inferred:

| step | symbol | calls |
|---|---|---|
| ASM shared memory map | `q6asm_map_memory_regions` | 1 |
| ASM stream open | `q6asm_open_write` | 1 |
| ADM device open | `q6adm_open` | 1 |
| ADM matrix map | `q6adm_matrix_map` | 1 |
| AFE port start | `q6afe_port_start` | 1 |
| APR packets to AFE | `afe_apr_send_pkt` | 3 |
| ASM close | `q6asm_cmd` | 1 |
| ADM close | `q6adm_close` | 1 |
| AFE port stop | `q6afe_port_stop` | 1 |
| **ASM RUN** | `q6asm_run_nowait` | **0** |

`prepare_rc=0`, `state=PREPARED`, `buffer_bytes=1024` (64-frame periods x 8).
The codec produced its frozen delta — `0x040 00 -> 05`, `0x180 00 -> 01`,
port 16 PROGRAMMED then TORN DOWN — and no q6 error or kernel WARNING appeared.

### Why counting calls, and not just return codes

A successful `prepare()` does imply the ADSP replied: the AFE and ADM calls are
synchronous and check the returned status. But a return code cannot distinguish
*"the DSP acknowledged"* from *"the path was skipped"*. Counting the calls
proves traffic occurred; the return code proves it was accepted. Each probe's
registration was asserted separately, because an unregistered probe reports
zero calls and would look exactly like a step that never ran.

## The endpoint is now evidence, not inference

`SLIMBUS_0_RX` (AFE port 0x4000) with channel map 144 was carried in the Branch
A design map as a **provisional** choice derived from apq8096, explicitly
flagged as the most likely thing to be wrong. It accepted the configuration.
That promotes it from proposal to hardware evidence.

The mixer control name was likewise only ever read out of `Q6ROUTING_RX_MIXERS`.
Enumerating the card's 1032 controls confirmed it verbatim before the gate ran.

## What this does NOT claim

- No SLIMbus **data** channel was allocated; `slim_stream_*` is untouched.
- No ASM RUN was issued, no sample moved, nothing was audible.
- Nothing is proven about capture, or about any endpoint other than
  SLIMBUS_0_RX.

The absence of RUN was enforced twice, deliberately: the prepare-only helper
contains no `write()` and no START ioctl (audited before it was compiled), and
the `q6asm_run_nowait` kprobe observed zero calls. "No samples moved" is the
one claim that must not rest on a single mechanism.

## What went wrong first, and what it cost

The first run of this gate reported **17 failures that read like ADSP failures
and were nothing of the kind**. The card module had been delivered as two
zero-byte files by a multi-file `scp` — the same trap already recorded in
[wcd9320-zero-byte-module.md](wcd9320-zero-byte-module.md) — so no card existed
and every downstream rung failed vacuously.

Three of my own diagnoses along the way were wrong and are recorded because the
sequence matters more than the conclusion:

1. **"depmod was never run."** Wrong: the alias was already in `modules.alias`
   before `depmod`. Running `depmod -a` then *removed* it, because it refuses
   to index files it cannot parse. The symptom was downstream of the real fault.
2. **"the running kernel may not be r155"** — `uname -v` showed a build
   timestamp an hour *after* the boot. A clock artifact. `/proc/device-tree/sound`
   settled it independently, which is why identity should be checked against
   something structural rather than a timestamp.
3. The `Invalid argument` from both `depmod` and `modprobe` was the real signal:
   `ENOEXEC` means a vermagic mismatch, `EINVAL` here meant unparseable ELF.

The gate now refuses these cases instead of producing a verdict about the DSP:
a missing, empty or unloadable card module, and a missing mixer tool, each exit
2 with the actual cause named.

Two defects in the gate itself were found and fixed, both recurrences:

- `cnt()` carried the `grep -c` trap — `grep -c` **prints 0 and exits 1** when
  nothing matches, so a trailing `|| echo 0` yields a two-line value and every
  comparison fails. This had already failed a correct system once, in build 1.
- Teardown used `:` to truncate `kprobe_events`, which returns `EBUSY` while any
  of its events is enabled. `:` is a POSIX *special* builtin, so the failed
  redirection exited the whole shell — the gate died one line past the finish
  line, after the evidence was written but before it could be printed.

## Tooling this milestone added

`tools/alsa-setctl.c` — a static armv7 helper that opens only
`/dev/snd/controlC*`. The device has no amixer, tinymix or alsactl, and no DNS
with which to install them. It cannot start a stream: no PCM ioctl, no
`write()`, enforced by `tools/setctl-audit.py` on the source before compilation.
Every `--set` reads the value back, because a write returning 0 is not proof
that a control took the value.

## Next

The data plane: `slim_stream_*` channel allocation in the WCD9320 driver, then
ASM RUN. That is the first point at which audio can be audible, and the first
point at which this milestone's central guarantee no longer applies.

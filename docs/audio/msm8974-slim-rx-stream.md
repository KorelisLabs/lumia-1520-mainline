# The codec's SLIMbus RX stream comes up

**Status:** proven on hardware, 2026-08-23 (Branch B1).
**Evidence:** `msm8974-slim-stream-20260823T100610Z.txt` — cold boot, 31 checks, 0 failed.
**Repeatability:** `msm8974-slim-stream-20260823T095532Z.txt` — a second cycle on
one boot, also 31/31, kept because it proves teardown leaves the codec able to
come back up.
**Gate:** `tools/msm8974-slim-stream-evidence.sh`. **Kernel:** 6.16.12 r156,
codec `slim-stream-rc1`.

## The claim

Slave port 16 can be connected to channel 144 and activated on the ADSP's bus:
`slim_stream_prepare()` and `slim_stream_enable()` reach the manager and are
accepted, the codec reproduces its frozen RX register delta, and the whole
thing tears down cleanly.

## What this does NOT claim

No PCM was opened, no ASM RUN was issued, no sample moved, nothing was audible.
This driver has **no RX interpolator, no output path and no DAPM graph**, so
audio could not have been produced by this run under any circumstances. This is
transport, and only the codec's half of it.

## What was observed

| step | calls | result |
|---|---|---|
| `slim_stream_prepare` | 1 | rc 0, one `CONNECT_SINK` to the manager |
| `qcom_slim_ngd_enable_stream` | 1 | **returned 0** — the ADSP accepted `DEF_ACT_CHAN` |
| `slim_stream_disable` | 1 | rc 0, **zero** messages sent |
| `slim_stream_unprepare` | 1 | rc 0, one `DISCONNECT_PORT` |
| `slim_stream_free` | 1 | released; `allocated=0` |

The codec produced its frozen delta through the same production helper the DAI
calls — `0x040 00 -> 05`, `0x180 00 -> 01`, port 16 PROGRAMMED then TORN DOWN,
once each on a clean boot.

## The no-op is now measured, not read

The design map claimed `slim_stream_disable()` sends nothing here, because
`qcom_slim_ngd_xfer_msg()` drops message codes 0x40–0x5F. That was read out of
the source, and reading is not evidence. Call counts cannot settle it either:
disable **is** called and **does** enter the controller.

So the run is sliced by ftrace timestamp into prepare / enable / disable /
unprepare windows, and `slim_alloc_txn_tid()` is counted in each — a TID is
allocated only for a message that actually leaves for the manager, and dropped
codes return before ever reaching it. Measured:

```
  during prepare       : 1     CONNECT_SINK
  during enable        : 2     DEF_ACT_CHAN
  during disable       : 0     <- nothing left the host
  during unprepare     : 1     DISCONNECT_PORT
  xfer_msg during disable: 4   <- but it WAS called
```

Those last two lines are asserted as **separate** checks, because they fail for
opposite reasons and must not be confusable:

- `disable sent NOTHING` failing would mean the controller had started really
  deactivating channels, and the documentation had gone stale.
- `disable did enter the controller` failing would mean the driver had skipped
  the call — which is *not* the documented no-op, merely something that looks
  like it from the outside.

A future kernel that changes this behaviour fails the gate loudly instead of
quietly invalidating the design map.

## Window bounding, and why the first numbers were wrong

The first passing run reported `during unprepare : 121`. That was not 121
disconnects: the window ran to the end of the trace and swept up the
port-teardown register writes and a second of unrelated bus traffic. The enable
window was contaminated the same way.

Both are now bounded tightly — enable by a **return probe** on
`qcom_slim_ngd_enable_stream` (entry/exit brackets exactly the hook), unprepare
by `slim_stream_free()`, which follows immediately. The count fell from 121 to
1. Only the disable window was tight by luck, which is the one that mattered.

The return probe earns its place twice: it bounds the window, and `$retval` is
the ADSP's own answer. The hook *running* proves a request was made; only its
return value distinguishes "we asked" from "it agreed".

## Two gate defects found on hardware

**A stale dmesg snapshot.** `snap_dmesg` ran during setup, before the sequence,
so `$DMESG_FILE` could not contain a single line the run produced. Seven checks
failed against hardware that had in fact worked — the sysfs state said
`rc_prepare=0 rc_enable=0 up=1` the whole time. dmesg is now re-read after the
sequence.

**A contaminated boot could pass quietly.** dmesg is cumulative, so a boot that
had already run one cycle reported `PROGRAMMED : 2`. Every check used `>= 1`, so
it passed while describing two bring-ups rather than one. The gate now reads
`ups=` before starting and exits 2 — a contaminated *setup*, not a driver fault.

## Deviation from the reference implementation

WCD9335 calls `slim_stream_allocate()` in `hw_params` and never calls
`slim_stream_free()`, leaking a runtime onto `sdev->stream_list` on every
`hw_params`. This driver allocates and frees within one bring-up/teardown pair;
`slim_stream_state` reports `allocated=0` after teardown, so the release is
observable rather than assumed.

`slim_stream_disable()` is still called, in order, even though it does nothing
here. It is correct on other controllers, it is what the DPCM state machine will
expect at B2, and a driver that silently skipped a documented step would be
wrong everywhere except this one board.

## Next: B2

Real playback — the DAI ops wired to `trigger`, ASM RUN, and a measured helper
that writes a known signal and polls `hw_ptr` for progression. That is where the
"no sample moved" guarantee is deliberately retired. It will still not be
audible: the analog path remains unbuilt.

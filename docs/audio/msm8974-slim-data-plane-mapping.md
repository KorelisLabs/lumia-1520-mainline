# Branch B design map: the SLIMbus data plane

**Status:** design map only. Nothing built, nothing claimed on hardware.
Read `msm8974-q6-playback-control-plane.md` first — this begins where that ends.

## The honest ceiling, stated first

**Completing this branch will not produce audible sound.** The WCD9320 driver
has no RX audio chain at all: zero interpolator code, zero DAPM widgets, no
output routing, and `wcd9320_soc_component` declares only `.name` and
`.endianness`. Samples can be made to travel across SLIMbus into the codec's
slave port and stop there.

That is still worth doing, and it is the correct next step — the transport is a
precondition for everything downstream, and it is separately falsifiable. But
the milestone must be named for what it proves: **samples move**, not **audio
plays**. The analog path (interpolators, CLSH/class-H, HPH/EAR power-up, a DAPM
graph) is a separate and much larger branch.

## The reference implementation

WCD9335 does exactly this over SLIMbus, in mainline, and is the model:

| call | where WCD9335 puts it |
|---|---|
| `slim_stream_allocate` | `wcd9335_slim_set_hw_params()`, from `hw_params` |
| `slim_stream_prepare` + `slim_stream_enable` | `trigger(START)` |
| `slim_stream_disable` + `slim_stream_unprepare` | `trigger(STOP)` |
| `slim_stream_free` | **nowhere** — see the defect note below |

### The register layout is already proven identical

WCD9335's port registers are `RX_PORT_CFG(p) = 0x30 + p` and
`RX_PORT_MULTI_CHNL_0(p) = 0x140 + 4p`. Our driver derived, from downstream
Taiko, `port_rx_cfg_reg_base = 0x030` and `rx_port_ch_reg_base = 0x140` — the
same two constants. Port 16 therefore gives 0x040 and 0x180, which are exactly
the registers whose delta is already frozen and reproduced on hardware.

This settles a question that would otherwise be guesswork: **the SLIMbus port
id equals the register index**, so `cfg->port_mask = BIT(16)` for slave port 16.
`wcd9320_rx_port_program()` already writes what `wcd9335_slim_set_hw_params()`
writes. The codec-side register work for this branch is done.

## What the four stream calls actually do on *this* controller

This is the part that cannot be taken from WCD9335, because behaviour depends on
the controller. `qcom_slim_ngd_xfer_msg()` opens with:

```c
if (txn->mt == SLIM_MSG_MT_CORE &&
    (txn->mc >= SLIM_MSG_MC_BEGIN_RECONFIGURATION &&
     txn->mc <= SLIM_MSG_MC_RECONFIGURE_NOW))
        return 0;
```

`BEGIN_RECONFIGURATION` is 0x40 and `RECONFIGURE_NOW` is 0x5F, so **every
generic reconfiguration message is silently dropped, returning success.** The
ADSP is the bus manager; a satellite does not reconfigure the bus. Messages
outside that range — `CONNECT_SINK` (0x11), `DISCONNECT_PORT` — are instead
*translated* into `SLIM_USR_MC_*` messages addressed to the manager.

The consequences are not what the API names suggest:

| call | actual effect over NGD |
|---|---|
| `slim_stream_allocate` | pure allocation, no bus traffic |
| `slim_stream_prepare` | **real traffic** — one `CONNECT_SINK` per port, translated to `SLIM_USR_MC_CONNECT_SINK` to the manager |
| `slim_stream_enable` | **real traffic** — `ctrl->enable_stream` hook only, sending `SLIM_USR_MC_DEF_ACT_CHAN`; the generic tail is never reached |
| `slim_stream_disable` | **NO-OP.** NGD provides no `disable_stream` hook, and all three messages it would otherwise send are in the dropped range. Returns 0 having done nothing. |
| `slim_stream_unprepare` | **real traffic** — `DISCONNECT_PORT` per port, translated |
| `slim_stream_free` | pure deallocation |

So on this hardware the real teardown is `slim_stream_unprepare()` plus the
ADSP's own `AFE_PORT_CMD_DEVICE_STOP`, **not** `slim_stream_disable()`. A gate
that asserts bus-level deactivation traffic would be asserting something that
can never appear, and would fail a correct system.

## A defect in the reference implementation

WCD9335 calls `slim_stream_allocate()` inside `hw_params` and **never calls
`slim_stream_free()`**. Each allocation is `kzalloc` plus an insertion into
`sdev->stream_list`, so every `hw_params` leaks a runtime and lengthens a list
that is walked on device teardown. We should not copy this. Proposal: allocate
once per DAI on `startup()`, free on `shutdown()`, and keep `prepare`/`enable`
in `trigger` where the DPCM state machine expects them.

## What has to be written

In `wcd9320-core.c`:

1. Per-DAI state: `struct slim_stream_config sconfig`, `struct
   slim_stream_runtime *sruntime`, and the channel list.
2. `.set_channel_map` — to receive channel 144 for RX port 16.
3. `.startup` / `.shutdown` — allocate and free the runtime.
4. Fill `sconfig` in `hw_params`: `rate`, `bps`, `ch_count`, `chs`,
   `port_mask = BIT(16)`, `direction`.
5. `.trigger` — prepare + enable on START, disable + unprepare on STOP.

The stream attaches to the **control/PGD** device (as WCD9335 uses `wcd->slim`),
while the port registers are written through the **interface** regmap, which is
what `wcd9320_rx_port_program()` already does.

In `lumia1520-q6.c`: the BE `hw_params` currently sets the channel map on the
**CPU** DAI only. The codec DAI needs the same map, or `.set_channel_map` will
never be called and `cfg->chs` will be empty.

## The instrument problem

`pcm-prepare-only` is frozen and must stay frozen: its value is that it cannot
start a stream. This branch needs the opposite, so it needs a *new* audited
helper, not a modification. The guarantee "`q6asm_run_nowait` observed zero
times" is retired **for this branch only**; the control-plane milestone keeps it.

## Proposed split — two builds again

**B1: the SLIMbus stream in isolation, via a debugfs hook.** The driver already
has this pattern: `rx_port_test` drives the same production function ASoC calls.
An equivalent hook can call allocate/prepare/enable/unprepare/free directly,
with no PCM and no ASM RUN. That isolates "does the ADSP accept CONNECT_SINK and
DEF_ACT_CHAN for port 16 / channel 144" from anything about playback.

**B2: real playback.** A measured helper writes a known signal, starts, polls
`SNDRV_PCM_IOCTL_STATUS` for `hw_ptr` progression, and reports frames consumed
and xruns — objective evidence of sample movement that does not depend on
anyone hearing anything.

The same reasoning as Branch A applies: if these were one build, a failure in
the stream bring-up and a failure in playback would be indistinguishable.

## Open questions to settle before writing code

1. **Milestone scope** — confirm this branch is named for transport
   ("samples move over SLIMbus"), with the analog chain deferred.
2. **Allocation lifetime** — deviate from WCD9335 and pair
   allocate/free with startup/shutdown, or match upstream exactly?
3. **Call `slim_stream_disable()` even though it is a no-op here?** It is
   correct on other controllers and keeps the API contract; the alternative is
   skipping it and documenting why.
4. **B1's hook** — debugfs, consistent with `rx_port_test`.
5. **Channel 144 / port 16** — the AFE accepted this pairing; the codec must be
   given the same channel number for the connection to mean anything.

# The IFD double-probe: explained

Measured on boot #152, 2026-08-18, r151 (`ifd-probe-rc1`). Instrumentation
only — no behaviour was changed in the build that produced this evidence.

The interface function's probe had run twice per boot, every boot, since the
dual-function work: the same `slim_device`, both calls returning 0, and no
`remove` in between. It broke nothing across eight milestones, which is
exactly why it was worth explaining before Branch A adds more binding
behaviour.

## The answer: the driver core calls probe twice, and the first bind is rolled back

It is **not** a double bind. The first bind is undone by the driver core
before the second is attempted.

```
probe #1   (udev-worker, pid 436)          module load
    sys_finit_module -> do_init_module -> do_one_initcall
      -> driver_register -> bus_add_driver -> bus_for_each_dev
      -> __driver_attach -> really_probe -> slim_device_probe
      -> wcd9320_probe                     returns 0, publishes ifd_instance
                                           |
    slim_device_probe() then calls slim_get_logical_addr()  -> FAILS
      "Failed to get logical address"
      -> returns -EPROBE_DEFER                              <- OUR 0 IS DISCARDED
                                           |
    really_probe() probe_failed:
      -> device_unbind_cleanup(dev)
           devres_release_all(dev)          <- frees the devm_kzalloc'd wcd
           dev_set_drvdata(dev, NULL)
      -> device added to the deferred-probe list

probe #2   (kworker/u16:1, pid 28)         deferred retry
    Workqueue: events_unbound deferred_probe_work_func
      -> bus_probe_device -> __device_attach -> bus_for_each_drv
      -> __device_attach_driver -> really_probe -> slim_device_probe
      -> wcd9320_probe                     returns 0, publishes a NEW wcd
                                           |
    slim_get_logical_addr() now SUCCEEDS
      "interface function UP (#1), logical address 0xca"
```

The mechanism is entirely in `drivers/slimbus/core.c`:

```c
static int slim_device_probe(struct device *dev)
{
        ret = sbdrv->probe(sbdev);
        if (ret)
                return ret;

        /* try getting the logical address after probe */
        ret = slim_get_logical_addr(sbdev);
        if (!ret) {
                slim_device_update_status(sbdev, SLIM_DEVICE_STATUS_UP);
        } else {
                dev_err(&sbdev->dev, "Failed to get logical address\n");
                ret = -EPROBE_DEFER;
        }
        return ret;
}
```

Our probe returning 0 is not the same as the bus reporting success. The bus
requires a logical address *immediately after* probe, and defers when it
cannot get one.

**This is why the count varied** — three probes on r146, two on r145 and r151.
It is not a lifecycle inconsistency; it is how many deferred retries elapse
before enumeration completes.

## The evidence, verbatim

```
IFD probe #1: sdev=a7872a11 dev=a7872a11 name=217:a0:0:0 laddr=0x00 laddr_valid=0 status=0
IFD probe #1: driver=64ca1e01 name=wcd9320 task=(udev-worker) pid=436
IFD probe #1: before: ifd_instance=00000000 drvdata=00000000 this_wcd=a0c93f0b
IFD probe #1: after:  ifd_instance=a0c93f0b drvdata=a0c93f0b replaced=0
IFD probe #1: returning 0 (bound)
Failed to get logical address                       <- the deferral trigger

IFD probe #2: sdev=a7872a11 dev=a7872a11 name=217:a0:0:0 laddr=0x00 laddr_valid=0 status=0
IFD probe #2: driver=64ca1e01 name=wcd9320 task=kworker/u16:1 pid=28
IFD probe #2: before: ifd_instance=a0c93f0b drvdata=00000000 this_wcd=bf643aac
IFD probe #2: after:  ifd_instance=bf643aac drvdata=bf643aac replaced=1
IFD probe #2: returning 0 (bound)
interface function UP (#1), logical address 0xca
```

Same `sdev` and `dev` pointer in both, so this is one device, not two.
`wcd9320_remove` never ran on either: a grep for it across the whole boot
returns 0.

## A defect this exposed, which was not what we were looking for

Probe #2's `before:` line is the finding:

```
ifd_instance=a0c93f0b   drvdata=00000000
```

The core cleared `drvdata` during rollback but **`wcd9320_ifd_instance` still
points at probe #1's `wcd`** — which `devres_release_all()` has just freed.
The driver's `remove()` is not called on the probe-failure path (`really_probe`
goes `probe_failed: -> device_unbind_cleanup()`, which does not invoke
`bus->remove`), so the only code that clears `wcd9320_ifd_instance` never runs.

**`wcd9320_ifd_instance` is a dangling pointer for ~530 ms** on this boot
(48.53 s to 49.06 s), between the rollback and probe #2 republishing.

It has never bitten because the only dereference is the RX port path, reached
from `hw_params` or the `rx_port_test` hook, both of which happen far later in
a boot. That is luck, not design, and it is the precise class of latent fault
that becomes hard to attribute once several drivers are binding to the same
hardware.

**Not fixed here, deliberately.** Correcting it in the build that measured it
would leave us unable to say which change altered the behaviour.

### Candidate fixes, for a separate milestone — none chosen yet

1. **`devm_add_action_or_reset()`** to clear `wcd9320_ifd_instance` when
   devres unwinds. This runs inside `devres_release_all()`, i.e. exactly when
   the memory is freed, so the pointer and the allocation die together. The
   idiomatic answer, and it needs no knowledge of *why* the unwind happened.
2. **Publish later** — set `wcd9320_ifd_instance` from the
   `device_status(UP)` callback rather than from probe, so it is only ever
   published for a device the bus has actually accepted.
3. **Do nothing but document it** — if the window is provably unreachable.
   Weakest option: it depends on call-path timing that Branch A is about to
   change.

Option 1 looks right, but the choice belongs to a milestone that can test it.

## The control function has no structural protection either — measured, r152

**The hypothesis stated here before boot #153 was wrong**, and it is kept
because the correction is the finding.

> ~~The PGD probe does ~100 ms of real work — seven regulators, reset
> assert/release, hardware settle delays — before returning, by which time
> enumeration has completed and `slim_get_logical_addr()` succeeds on the
> first attempt.~~

Measured on boot #153 (r152, `ctl-lifetime-rc1`), logging `is_laddr_valid` at
probe exit for both functions:

```
IFD probe #1: exit after  0 ms: laddr=0x00 laddr_valid=0 status=0 path=ifd
CTL probe #1: exit after 80 ms: laddr=0x00 laddr_valid=0 status=0 path=fresh
```

**`laddr_valid` is 0 at exit for both.** The control function's 80 ms of
regulator and reset work does not earn it a logical address by return time.
The datum this document previously called decisive was the wrong datum.

### What actually decides it

`slim_get_logical_addr()` does not merely read the cached flag:

```c
int slim_get_logical_addr(struct slim_device *sbdev)
{
        if (!sbdev->is_laddr_valid)
                return slim_device_alloc_laddr(sbdev, false);
        return 0;
}
```

With the flag clear it calls `slim_device_alloc_laddr()` →
`ctrl->get_laddr()` → `qcom_slim_ngd_get_laddr()`, which sends a **synchronous
`SLIM_USR_MC_ADDR_QUERY` to the ADSP-side manager** and returns `-ENXIO` only
when the manager does not recognise the enumeration address:

```c
if (!memcmp(rbuf, failed_ea, 6))
        return -ENXIO;
```

So the discriminator is **whether the remote manager's device table knows that
particular function at the moment it is asked** — not our probe duration, and
not `is_laddr_valid`.

On boot #153:

| when | who | result |
|---|---|---|
| 47.618 | IFD, first query | manager did not know it → `-ENXIO` → deferred |
| ~47.70 | CTL, first query | manager knew it → laddr `0xcb` |
| 48.30 | IFD, retry | manager now knew it → laddr `0xca` |

`CTL probe #2` never appears and no `Failed to get logical address` is logged
for `217:a0:1:0`, so the control function neither deferred nor failed.

### Why this makes the defect worse, not better

The control function survives **because the remote manager happened to have
its address ready**. Nothing about its probe duration, its structure, or its
work protects it. It is exposed to exactly the same rollback the interface
function takes every boot.

And its rollback is the expensive one. The interface function takes no power
and no reset, so its unwind costs only the dangling global. The control
function has `devm_add_action_or_reset(dev, wcd9320_power_release, wcd)`
registered, so a rollback would **drop the supplies and re-assert reset
part-way through bring-up**, and the deferred retry would redo all of it. That
power cycle has never been observed and appears in no baseline.

**This is therefore a shared lifetime design defect**, currently exposed only
by the interface function because its query lands earlier and loses. It should
be fixed as one ownership pattern across the driver, not as a single-global
patch — see `wcd9320-probe-lifetime.md`.

## The RCU expedited stall is not ours — measured, r152

It repeated on r152 with `dump_stack()` removed, so it is **not** an artefact
of the instrumentation:

```
[30.999252] rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks: { P413 } 3 jiffies s: 133
[59.049254] rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks: { P488 } 3 jiffies s: 605
```

But it is also **not adjacent to the codec**. The codec probes at 47.6 s; the
two stalls fall at 31.0 s (during zram/swap setup) and 59.0 s (just after the
ext4 mount). On the r151 trace boot one happened to land immediately before
probe #1, which is what made it look related. Coincidence.

Context: this port boots with `nosmp maxcpus=1`, so an expedited RCU grace
period has a single CPU to wait on, and both reports are 3 jiffies — very
short. Recorded, unexplained, and not attributed to the audio work.

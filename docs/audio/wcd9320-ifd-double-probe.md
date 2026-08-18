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

## An asymmetry worth noting

The control function (PGD, `dev_index` 1) does **not** defer: its bring-up
appears once per boot and `control function UP (#1)` follows a single probe.

A plausible explanation, **not yet measured**: the PGD probe does ~100 ms of
real work — seven regulators, reset assert/release, hardware settle delays —
before returning, by which time enumeration has completed and
`slim_get_logical_addr()` succeeds on the first attempt. The IFD probe takes
no power and no reset and returns almost immediately, ahead of enumeration.

If that is right, the PGD's single probe is a timing accident too, not a
structural difference — and the same rollback could happen to it on a slower
or faster boot. Confirming it needs the same instrumentation on the control
path, which this milestone did not add.

## Unrelated observation, recorded not explained

An RCU expedited-stall warning appears immediately before probe #1 on this
boot:

```
rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks: { P434 } 3 jiffies
```

It is new in this log and has no established connection to the codec. Noted so
it is not silently forgotten; not investigated.

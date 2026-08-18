# Probe lifetime safety: mapping, before writing the fix

Research only. No behaviour changed yet. Written after boots #152 and #153
established what the interface function's double-probe actually is, and that
the control function has no structural protection from the same thing. Full
evidence in `wcd9320-ifd-double-probe.md`.

**What is being fixed is not the double probe.** Deferred probing is normal,
correct bus behaviour and must not be suppressed. What is broken is this
driver's *object lifetime* under that behaviour.

## 1. The defect, stated exactly

`slim_device_probe()` discards our `0` and calls `slim_get_logical_addr()`.
When the ADSP-side manager does not yet know the enumeration address it
returns `-ENXIO`, the wrapper converts that to `-EPROBE_DEFER`, and
`really_probe()` unwinds:

```
probe_failed:
  -> device_unbind_cleanup(dev)
       devres_release_all(dev)     <- frees the devm_kzalloc'd wcd
       dev_set_drvdata(dev, NULL)  <- core clears its own pointer
```

`bus->remove` is **not** called on this path, so `wcd9320_remove()` — the only
code that clears `wcd9320_ifd_instance` — never runs. The global is left
pointing at freed memory until the deferred retry republishes it.

Measured window: **~530 ms per boot**, every boot.

```
IFD probe #2: before: ifd_instance=e8bec876 drvdata=00000000 this_wcd=6b42c0cf
                      ^^^^^^^^^^^^ freed by devres    ^^^^^^^^ core cleared its own
```

## 2. The invariant to establish

> If an instance pointer is published beyond the scope that allocated it, the
> same devres lifetime that owns the instance must also own withdrawal of that
> pointer.

Stated that way it needs no knowledge of *why* the driver core is releasing
resources, which is the whole point: probe unwind, `-EPROBE_DEFER` after our
probe returned success, ordinary remove, and any future error path all become
the same case.

## 3. The fix

```c
static void wcd9320_clear_ifd_instance(void *data)
{
        struct wcd9320 *wcd = data;

        mutex_lock(&wcd9320_ifd_lock);
        if (wcd9320_ifd_instance == wcd)
                wcd9320_ifd_instance = NULL;
        mutex_unlock(&wcd9320_ifd_lock);
}
```

registered immediately after publishing:

```c
mutex_lock(&wcd9320_ifd_lock);
wcd9320_ifd_instance = wcd;
mutex_unlock(&wcd9320_ifd_lock);

ret = devm_add_action_or_reset(dev, wcd9320_clear_ifd_instance, wcd);
if (ret)
        return ret;
```

**The identity check is load-bearing**, not defensive decoration. Even though
today's deferred-probe ordering makes overlap impossible, without it an old
instance's cleanup could clear a *newer* successfully published instance. The
check makes the action correct independently of ordering, which is the only
way it stays correct as Branch A changes the timing.

**`_or_reset` rather than plain `devm_add_action`**: if registration itself
fails, the action is run immediately, so the global cannot be left published
by a probe that is about to return an error.

**Sleeping is fine.** `devres_release_all()` runs in process context on the
probe/unbind path, so taking the mutex is safe.

### Release ordering, which matters and is easy to get wrong

devres releases **LIFO**. The registration order in the interface branch is:

```
devm_kzalloc(wcd)                    <- released LAST
devm_regmap_init_slimbus(...)
devm_add_action_or_reset(clear_ifd)  <- released FIRST
```

So on unwind the global is cleared *before* the regmap it implies is usable is
torn down, and before `wcd` itself is freed. That is the correct order: the
pointer is withdrawn while everything it refers to is still alive. Registering
the action any earlier would invert this.

## 4. The control function

`wcd9320_ifd_instance` is the **only** published pointer global in the driver —
audited across both source files. The control function publishes nothing, so
there is no second pointer to fix.

But it is exposed to the same rollback, and its unwind is more expensive: it
has `devm_add_action_or_reset(dev, wcd9320_power_release, wcd)` registered, so
a deferral would drop supplies and re-assert reset part-way through bring-up,
and the retry would redo it. That is *correct devres behaviour* — the resource
is released with the device — but it has never been observed, appears in no
baseline, and would produce a power cycle mid-init.

**Scope decision:** the fix covers the global. The control function's rollback
behaviour is *audited* in this milestone, not changed. If the audit shows the
retry cannot cleanly re-run bring-up after a mid-flight power drop, that is a
separate finding and a separate milestone — not something to patch blind.

## 5. Acceptance gate

The interface function defers on **every** boot, so the deferred path needs no
contrivance — but it must be **asserted**, not assumed, or a boot where it
happened not to defer would pass vacuously.

Required from one cold boot, with the r152 instrumentation still in place:

```
1.  IFD probe #1 observed              ifd_probe_seq == 1 seen
2.  probe #1 publishes instance A      after: ifd_instance=A  replaced=0
3.  the wrapper defers                 "Failed to get logical address" present
4.  the deferred retry happens         IFD probe #2 observed
5.  THE FIX:  before: ifd_instance=00000000     <- was A, must now be NULL
6.  and:      replaced=0                        <- was 1, must now be 0
7.  probe #2 publishes instance B      after: ifd_instance=B
8.  the wrapper succeeds               "interface function UP", laddr 0xca
9.  no stale pointer at any point after unwind
```

Lines 5 and 6 are the entire proof, and the existing instrumentation already
emits both — `replaced=1` today becomes `replaced=0` with the fix, because the
devres action cleared the global before probe #2 read it. Nothing new has to be
added to observe the fix working.

Then, unchanged from before:

- the RX path still works through instance B (`asoc-callback` run: ASoC delta
  byte-identical to the manual delta, no residue)
- the full 117-check baseline still passes
- the control function still binds once, `CTL probe #2` absent

**A vacuous pass must be impossible.** If `Failed to get logical address` is
absent from the boot, the deferral did not happen and the run proves nothing
about the fix — the gate must report that as INVALID, not PASS.

## 6. Scope of the milestone

**In:** the devres ownership action for `wcd9320_ifd_instance`; the identity
check; an audit of the control function's rollback exposure; the acceptance
gate above; the 117-check baseline.

**Out:** suppressing or avoiding deferred probing in any way; changing when
the instance is published; touching the control function's power handling;
`device_status(UP)` as an ownership primitive; the RCU stall; and Branch A.

`device_status(UP)` was considered and rejected as the ownership primitive.
The problem is allocation lifetime versus global publication, and devres is
already the entity that owns the allocation. Moving publication to a bus
callback would change *when* the pointer is valid — a behavioural change —
rather than fixing *who withdraws it*.

Proposed tag: **`wcd9320-probe-lifetime-safe`**. Not "double probe fixed": the
double probe is legitimate and stays.

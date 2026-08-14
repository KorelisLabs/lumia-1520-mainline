# Nested codec IRQ controller — design, before implementation

Written 2026-08-01. Nothing implemented yet. The purpose is to settle the two
decisions that would otherwise be discovered halfway through writing it.

Topology is already mapped in `wcd9320-irq-topology.md`: 31 sources across
four register bytes, mask polarity 1 = masked, acknowledgement by writing a 1
to a separate `INTR_CLEAR` register, per-source level/edge via `INTR_LEVEL`.

## Decision 1 — regmap-irq, not hand-rolled

The register layout matches `regmap_add_irq_chip()` almost exactly:

| regmap-irq field | WCD9320 | note |
|---|---|---|
| `status_base` | `0x098` | `INTR_STATUS0-3` |
| `mask_base` | `0x094` | `INTR_MASK0-3`, 1 = masked, which is regmap-irq's default sense |
| `ack_base` | `0x09c` | `INTR_CLEAR0-3`, write-1-to-clear, also the default |
| `num_regs` | 4 | |

Three things to get right rather than assume:

- **`INTR_CLEAR` is write-only.** `taiko_reg_readable[]` excludes exactly
  `0x09c`–`0x09f` (`wcd9320-register-map.md` §2a). regmap-irq must not be
  allowed to read it back, and `readable_reg` must continue to exclude it.
- **Bits 6–7 of `MASK2` are read-only zero.** Measured: writing `0xff` reads
  back `0x3f`. They are `RESERVED_0/1` with nothing behind them. Declaring
  only the 29 real sources avoids regmap-irq trying to mask them and
  reporting a mismatch.
- **`MASK3` bit 7 does not exist** — IRQ 31 is past `TAIKO_NUM_IRQS`.

Hand-rolling would mean reimplementing masking, ack and domain allocation
that regmap-irq already does correctly, with no benefit.

## Decision 2 — the parent handler must be replaced, not extended

This is the part that touches proven code.

`wcd9320_irq_setup()` currently owns `msmgpio 72` through
`devm_request_threaded_irq()` with `wcd9320_irq_thread()`, and that
arrangement is what `wcd9320-irq-parent-idle-validated` certifies.
`regmap_add_irq_chip()` requests the parent itself, so the two cannot both
own it.

The existing handler therefore goes, and its behaviour has to be preserved by
other means:

| current behaviour | where it lives afterwards |
|---|---|
| explicit `ff ff 3f 7f` masking before the parent is requested | regmap-irq masks all sources at init; keep the explicit write and readback as a precondition check, before handing the chip over |
| refusing to ack when nothing real is pending | regmap-irq acks only bits it dispatched, which is the same guarantee expressed differently |
| counting spurious assertions | keep, as a counter incremented from a chained handler or from the irq stats, since item 5 needs it |
| bounded pad sampling | keep unchanged; it is independent of who owns the parent |

**The `irq_observe` sysfs interface must keep working**, because
`tools/wcd9320-*-evidence.sh` reads it and the self-test's fixtures are
transcribed from the driver's `printf` formats. Changing those strings breaks
the acceptance harness silently — the self-test is where that would surface,
so run it after any format change.

## Ordering, matching the acceptance sequence

1. Add the `regmap_irq_chip` with all 29 real sources declared and **every
   one masked**. Do not remove the existing handler yet; just build the chip
   description and leave it unregistered, so the tree still boots the proven
   configuration.
2. In one atomic change, remove `devm_request_threaded_irq()` and register
   the chip in its place. Two owners of the parent, or none, are both broken
   intermediate states — this must not be split across builds.
3. Prove the idle case: chip installed, all sources masked, **zero parent
   assertions**, `INTR_STATUS0-3` still `00 00 00 00`, and no change to
   enumeration, identity, ADSP, NGD or SLIMbus health.
4. Only then unmask one MBHC source. MBHC is the right choice for a reason
   now measured twice: `0x3c0`–`0x3ff` is reachable without any clock, and
   the release-not-clock finding confirms accessibility does not depend on
   clocking at all.
5. Generate a real headset insertion/removal and prove the whole chain:
   codec status bit → nested dispatch → parent GPIO → threaded handler →
   write-1-to-clear → line returns low.
6. Re-mask and prove the idle state returns cleanly.

Only after 6 does `wcd9320-irq-proven` become available. Step 3 alone is not
it — it proves the plumbing, which is what
`wcd9320-irq-parent-idle-validated` already claims for the simpler
arrangement.

## Watch for

- **The parent virtual IRQ number varies per boot** (83 and 87 both seen).
  Assert on pin `msmgpio 72` and trigger type `0x1`, never the number.
- The DSDT says edge, downstream requests level. The measured DSDT type is
  what is in DT and what the idle proof was taken against; unmasking a real
  source is the first time that choice is actually exercised, so a missed or
  stuck interrupt at step 5 points here first.
- `INTR_MODE` (`0x090`) reads `00` and has never been written. Downstream
  sets it to `0x02` only on the I2C interface path, not SLIMbus.

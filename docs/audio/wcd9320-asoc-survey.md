# WCD9320 downstream survey for ASoC bring-up

Pre-code research on the `research/audio-wcd9320-asoc-foundation` branch,
taken off `wcd9320-core-bringup-proven`. Nothing here has been built or
booted; the point is to decide what to implement before implementing it.

Source: `LineageOS/android_kernel_lge_hammerhead`, branch `cm-11.0` —
`sound/soc/codecs/wcd9320.c` (6783 lines), `drivers/mfd/wcd9xxx-core.c`,
`drivers/mfd/wcd9xxx-slimslave.c`, `include/linux/mfd/wcd9xxx/
wcd9xxx_registers.h`, `wcd9320_registers.h`, `core.h`, and
`arch/arm/boot/dts/msm8974.dtsi`.

## 1. The second SLIMbus function is required — settled

**The codec presents two SLIMbus devices and both are needed.** This was an
open question; it is now answered from the downstream source.

| Function | EA | dev_index | Purpose |
|---|---|---|---|
| **PGD** (program/general device) | `00 01 A0 00 17 02` | 1 | codec control registers |
| **IFD** (interface device) | `00 00 A0 00 17 02` | 0 | SLIMbus port/channel configuration |

`wcd9xxx-core.c` keeps both handles and selects between them per access:

```c
ret = slim_request_val_element(interface ? wcd9xxx->slim_slave
                                         : wcd9xxx->slim, ...);
```

`wcd9xxx_interface_reg_read/write()` are the `interface = true` wrappers, and
**every caller of them lives in `wcd9xxx-slimslave.c`**, writing:

- `SB_PGD_RX_PORT_MULTI_CHANNEL_0(...)`
- `SB_PGD_TX_PORT_MULTI_CHANNEL_0/1(...)`
- `SB_PGD_PORT_CFG_BYTE_ADDR(...)`

plus `taiko_slim_interface_init_reg()` in the codec driver, which enables
port interrupts by writing `0xFF` to `TAIKO_SLIM_PGD_PORT_INT_EN0 + i` for
each of `WCD9XXX_SLIM_NUM_PORT_REG`.

**Consequence for this port:** the identity, revision and every register
proven so far went through the **PGD**, which is correct — chip ID lives
there. But **audio data transport cannot be configured without the IFD**.
So the DT needs a second child node at `reg = <0 0>` with the same
`slim217,a0` compatible before any DAI work, and the driver needs a handle
to it. That is a structural prerequisite, not a detail to add later.

Note the naming is confusing on purpose in the original: the macros are
called `SB_PGD_*` but are written *through the interface device*.

## 2. Register classification must be derived, not copied

The deliverable asked for readable / writable / volatile / precious ranges.
**Downstream does not have them.** `wcd9320.c` contains no
`taiko_readable_register()`, `taiko_volatile()`, `taiko_writeable()` or
precious-register callback — the driver predates regmap for this part and
goes through `wcd9xxx_reg_read/write` with its own cache.

So these tables have to be *constructed* for a mainline regmap driver, from:

- `wcd9320_registers.h` — the full offset map and every `__POR` reset value
- the shadow-cache and "read from hardware" decisions scattered through the
  downstream driver
- the interrupt registers below, which are inherently volatile

This is real design work, not transcription, and it is the largest single
unknown left in this survey. Until it is done, `REGCACHE_NONE` stays.

## 3. Interrupt registers

From `wcd9xxx_registers.h` (PGD side):

| Register | Offset |
|---|---|
| `WCD9XXX_A_INTR_MODE` | `0x90` |
| `WCD9XXX_A_INTR_MASK0` | `0x94` |
| `WCD9XXX_A_INTR_STATUS0` | `0x98` |
| `WCD9XXX_A_INTR_CLEAR0` | `0x9C` |
| `WCD9XXX_A_INTR_LEVEL0..2` | `0xA0`–`0xA2` |

Acknowledgement is via a separate `CLEAR0` register rather than
write-one-to-clear on `STATUS0`, which matters for a regmap-irq
implementation and for the precious/volatile classification above.

The codec's own interrupt line on this device is **TLMM 72** (from the
DSDT's `MBHC` node), still unwired in our DT.

## 4. Initialisation writes

Downstream applies two separate tables:

- `taiko_reg_defaults[]` — a long list applied at codec probe
- `taiko_codec_reg_init_val[]` — applied by `taiko_codec_init_reg()` using
  read-modify-write (`snd_soc_update_bits`), not blind writes

The **first two entries of `taiko_reg_defaults[]` are the only digital-core
ones**; everything after them is EAR/RX/analog path:

| Register | Value | Comment in source |
|---|---|---|
| `TAIKO_A_CHIP_CTL` (`0x00`) | `0x02` | "set MCLk to 9.6" |
| `TAIKO_A_CDC_CLK_POWER_CTL` | `0x03` | — |

That is the natural content of a first write milestone: two registers, both
digital, both documented, neither touching an analog output. Everything from
`TAIKO_A_RX_EAR_CMBUFF` onward is explicitly an output path and stays out.

Worth noting `TAIKO_A_CHIP_CTL` is register `0x00` — the same one an early
version of the enumeration probe mistakenly read expecting a chip ID. It is
a control register, and writing `0x02` selects the 9.6 MHz MCLK, matching
`qcom,cdc-mclk-clk-rate = <9600000>` in the board DT.

## 5. What this survey has NOT established

Stated plainly, because the next milestone depends on it:

- **Reset defaults as a table.** The `__POR` values exist per register in the
  header but have not been collected, and at least one is already known to
  disagree with silicon: `WCD9XXX_A_CHIP_VERSION__POR` is `0x20` while this
  device reads `0x00`.
- **Which values vary between Taiko minor revisions.** This device is
  `id_minor 0x0001`; downstream's table has entries for minor `0x0` and
  `0x1`, but the per-revision register differences have not been extracted.
- **Power sequencing and delays beyond reset.** Only `wcd9xxx_reset()`'s
  20 ms / 20 ms is established. Any MCLK-ready or post-init settling
  requirement is unknown.
- **Whether the mandatory writes are restorable.** No shutdown/restore
  behaviour has been mapped, so "restored on shutdown" in the write-milestone
  table cannot yet be filled in.
- **The `SB_PGD_*` macro definitions.** The grep for them in
  `wcd9xxx-slimslave.c` returned nothing, so they are defined in a header not
  yet fetched. The port-configuration layout is therefore known to exist and
  known to run through the IFD, but its actual register offsets are not yet
  in hand.

## 6. Revised implementation order

Unchanged in spirit, with the IFD moved earlier because it is a
prerequisite rather than a DAI detail:

1. Describe the IFD in DT and acquire it in the core driver
2. Derive readable/volatile/precious tables from the register header
3. Apply the two documented digital-core writes, with readback
4. Codec IRQ support (`0x90`–`0xA2`, `CLEAR0` acknowledgement, TLMM 72)
5. Minimal ASoC component registration
6. Playback DAI plus SLIMbus port configuration through the IFD
7. MSM8974/Lumia machine driver
8. One fixed 48 kHz playback route
9. First audible tone
10. Speaker, capture, microphones, MBHC, routing

Steps 1–3 need no new hardware capability — the transport, enumeration,
identity and register access are all already proven.

---

## Addendum: port macros and the clock question

### 7. The interface-function port registers

From `include/linux/mfd/wcd9xxx/wcd9xxx-slimslave.h` and
`wcd9320_registers.h`:

| Macro / register | Value | Direction |
|---|---|---|
| `SB_PGD_PORT_BASE` | `0x000` | — |
| `SB_PGD_PORT_CFG_BYTE_ADDR(offset, port_num)` | — | both |
| `SB_PGD_TX_PORT_MULTI_CHANNEL_0(port_num)` | ports 0–7 | TX |
| `SB_PGD_TX_PORT_MULTI_CHANNEL_1(port_num)` | ports 8+ | TX |
| `SB_PGD_RX_PORT_MULTI_CHANNEL_0(offset, port_num)` | — | RX |
| `TAIKO_SB_PGD_OFFSET_OF_RX_SLAVE_DEV_PORTS` | — | RX offset |
| `TAIKO_SLIM_PGD_PORT_INT_EN0` | `0x30` | port IRQ enable |
| `TAIKO_SLIM_PGD_PORT_INT_RX_SOURCE0` | `0x60` | — |

**The 0x800 offset applies to the interface function too.** This was worth
checking rather than assuming, because `SB_PGD_PORT_BASE` is `0x000` and it
would be easy to conclude the interface space starts at zero. It does not:
`wcd9xxx_slim_read_device()` computes
`msg.start_offset = WCD9XXX_REGISTER_START_OFFSET + reg` *before* choosing
between the two devices, so the `interface` flag selects only which
slim_device is addressed. Both functions share the same `0x800` translation.

So `TAIKO_SLIM_PGD_PORT_INT_EN0` is value element `0x830`, and the same
`regmap_config` with `reg_base = 0x800` is correct for both functions.

### 8. The first two writes are not yet safe to make

Both proposed writes need more than the survey established.

**`TAIKO_A_CHIP_CTL = 0x02`** selects the 9.6 MHz MCLK mode. But the codec
does not generate that clock — downstream has an explicit
`taiko_mclk_enable(codec, mclk_enable, dapm)` entry point, and the rate comes
from board data (`pdata->mclk_rate == TAIKO_MCLK_CLK_9P6MHZ`). On MSM8974 the
clock is supplied from the SoC side, which this port has not modelled at all.
Selecting a 9.6 MHz mode without providing 9.6 MHz would fail in a way that
looks like a codec problem and is not.

**`TAIKO_A_CDC_CLK_POWER_CTL` is `0x314`, and its reset value is `0x00`.**
Writing `0x03` is therefore a genuine state change, not the restoration of a
default, despite living in a table called `taiko_reg_defaults[]`. The name
says clock and power control; the header gives no bit definitions; nothing
establishes whether it starts internal digital blocks, whether MCLK must be
running first, or whether it must be undone on shutdown. It should not be
treated as safe merely because it is digital.

**Prerequisites before any write milestone**, restated concretely:

1. Identify and model the 9.6 MHz MCLK source on this SoC, and its enable path
2. Establish the bit semantics of `0x314`, from a datasheet or by tracing
   every downstream user
3. Establish ordering and any delay between the two writes
4. Establish expected readback values (not assumed to equal what was written)
5. Establish whether either register must be restored on shutdown

Until 1 and 2 are answered, the correct next milestone is the dual-function
topology, not register writes.

---

## Addendum: what the silicon dump has since answered

`wcd9320-register-map.md` supersedes parts of sections 2 and 5. Recorded here
so this survey is not read as still-current where it is not.

**Answered:**

- *"Register classification must be derived, not copied"* (§2) — derived, and
  then confirmed against the part. The 673 documented addresses are exactly
  the implemented set: every undocumented address reads `0x00` and every
  documented one reads out.
- *"Reset defaults as a table"* (§5) — collected for all 673 addresses and
  confirmed against silicon at 152 of 154 in `0x000`–`0x1ff`.
- *"`WCD9XXX_A_CHIP_VERSION__POR` is `0x20` while this device reads `0x00`"*
  (§5) — no longer an isolated oddity. It belongs to a set of 124 registers
  differing from `__POR`, most of which fall into two coherent groups: the
  QFUSE readback and analog trims, and the dark digital core.
- *"Whether the mandatory writes are restorable"* (§5) — still unanswered, but
  now moot for `TAIKO_A_CDC_CLK_POWER_CTL`: `0x314` sits inside a region that
  currently cannot report its own contents, so the readback verification every
  previous milestone relied on is unavailable there.

**Sharpened rather than answered:**

- §8's caution about the two first writes stands and now has a second,
  independent reason. `TAIKO_A_CHIP_CTL` (`0x000`) is outside the dark region
  and does read back — it currently holds `0x08` against a `__POR` of `0x00`.
  `TAIKO_A_CDC_CLK_POWER_CTL` (`0x314`) is inside it.
- §6's implementation order is unchanged, but step 2 ("derive
  readable/volatile/precious tables") is now partly done: `readable_reg` is
  settled, `precious_reg` is empty for the interrupt block, and `volatile_reg`
  cannot be established empirically until the digital core is clocked.

**Still open, unchanged:** the `SB_PGD_*` port register offsets, the
per-revision differences between Taiko minor `0x0` and `0x1`, and power
sequencing beyond `wcd9xxx_reset()`.

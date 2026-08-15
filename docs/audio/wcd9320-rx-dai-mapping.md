# RX DAI and the IFD port path: the map, and the result

Written as pre-implementation mapping, and kept as the record of what was
implemented from it. The point was to know exactly which registers, bitfields,
clocks and bus objects are involved *before* writing callbacks that touch
hardware — and two structural problems surfaced during the mapping that had to
be settled first. Both were, and neither would have been found by building.

**PROVEN ON HARDWARE 2026-08-15**, `rx-dai-rc1` (pkgrel 146), one boot, four
runs, 117 checks, zero failures:

| run | verdict |
|---|---|
| `wcd9320-coldboot-autoload-20260815T215351Z.txt` | PASS 31/0 |
| `wcd9320-rx-dai-20260815T215404Z.txt` | PASS 34/0 |
| `wcd9320-regcache-20260815T215415Z.txt` | PASS 25/0 |
| `wcd9320-irq-acceptance-20260815T215455Z.txt` | PASS 27/0 |

The port programming reached hardware exactly as mapped, and reversed:

```
0x180 multi-channel : 00 -> 01 -> 00
0x040 port config   : 00 -> 05 -> 00
bytes changed by programming       : 2  [0x040 00->05  0x180 00->01]
bytes still changed after teardown : 0
```

Two registers moved across the whole `0x030`–`0x1b0` space and no others, which
is what makes every write attributable rather than merely plausible.

This closes an item `wcd9320-asoc-survey.md` §5 recorded as open: *"the
`SB_PGD_*` port register offsets ... are defined in a header not yet fetched.
The port-configuration layout is therefore known to exist and known to run
through the IFD, but its actual register offsets are not yet in hand."* They
are now in hand.

Derived from `wcd9xxx-slimslave.{c,h}` and `wcd9320_registers.h`, fetched on
demand and not checked in.

## 1. The interface function's register map

The IFD is a **completely different register space** from the PGD. Same
`0x800` value-element translation — `wcd9xxx_slim_read_device()` adds
`WCD9XXX_REGISTER_START_OFFSET` before choosing which slim_device to address,
so the `interface` flag selects only the target — but the meaning of every
offset differs.

Downstream computes the Taiko bases by subtracting the RX port offset, so that
**absolute** codec port numbers index correctly:

```c
TAIKO_SB_PGD_MAX_NUMBER_OF_TX_SLAVE_DEV_PORTS = 16
TAIKO_SB_PGD_MAX_NUMBER_OF_RX_SLAVE_DEV_PORTS = 13
TAIKO_SB_PGD_OFFSET_OF_RX_SLAVE_DEV_PORTS     = 16   /* == TX max */

rx_port_ch_reg_base  = 0x180 - (16 * 4) = 0x140
port_rx_cfg_reg_base = 0x040 -  16      = 0x030
port_tx_cfg_reg_base = 0x050
```

with

```c
SB_PGD_PORT_CFG_BYTE_ADDR(offset, p)      = 0x000 + offset + (1 * p)
SB_PGD_RX_PORT_MULTI_CHANNEL_0(offset, p) = 0x000 + offset + (4 * p)
SB_PGD_TX_PORT_MULTI_CHANNEL_0(p)         = 0x000 + 0x100  + (4 * p)
SB_PGD_TX_PORT_MULTI_CHANNEL_1(p)         = 0x000 + 0x101  + (4 * p)
```

Resolved, the IFD space is:

| range | contents |
|---|---|
| `0x30`–`0x3b` | port interrupt enable / status RX,TX / clear RX,TX |
| `0x40`–`0x4c` | **RX port config bytes**, ports 16–28 |
| `0x50`–`0x5f` | TX port config bytes, ports 0–15 |
| `0x60`–`0x6f` | `PORT_INT_RX_SOURCE0` |
| `0x70`–`0x7f` | `PORT_INT_TX_SOURCE0` |
| `0x100`–`0x13f` | TX multi-channel, ports 0–15 |
| `0x180`–`0x1b0` | **RX multi-channel**, ports 16–28 |

The two bases are computed offsets, not real bases: `port_rx_cfg_reg_base`
`0x030` only produces valid addresses for absolute RX port numbers ≥ 16, which
is why RX config bytes start at `0x40` and do not collide with the interrupt
block at `0x30`.

**RX port 16, the first RX port:**

| what | address | value |
|---|---|---|
| multi-channel | `0x140 + 4*16` = **`0x180`** | channel bitmap |
| port config | `0x030 + 16` = **`0x040`** | `WATER_MARK_VAL` |

## 2. The bitfields

Only one register in this path has a decoded layout, and it is small:

```c
SLAVE_PORT_WATER_MARK_6BYTES  0
SLAVE_PORT_WATER_MARK_9BYTES  1
SLAVE_PORT_WATER_MARK_12BYTES 2
SLAVE_PORT_WATER_MARK_15BYTES 3
SLAVE_PORT_WATER_MARK_SHIFT   1
SLAVE_PORT_ENABLE             1

WATER_MARK_VAL = (SLAVE_PORT_WATER_MARK_12BYTES << 1) | SLAVE_PORT_ENABLE
               = (2 << 1) | 1
               = 0x05
```

So the port config byte is `[watermark:2][enable:1]`, and `0x05` means
12-byte watermark with the port enabled. Writing `0x00` disables it, which is
the natural teardown.

The multi-channel register takes a **bitmap of the channels bound to that
port**, built downstream as `payload |= 1 << rx->shift`. For a single channel
on a single port that is `0x01`. It is not a channel *number* — channel numbers
are a separate namespace, `BASE_CH_NUM = 128`.

## 3. Ports are not channels, and we do not own the channels

This is the part that constrains the milestone most.

The IFD port registers configure the **codec's side** of a port: its watermark
and whether it is enabled, and which channels feed it. They do not create a
data path. Downstream reaches an actual stream through the SLIMbus framework:

```
slim_query_ch()    -> get a handle for channel number BASE_CH_NUM + n
slim_define_ch()   -> define the group: SLIM_AUTO_ISO, base rate 4000 Hz,
                      ratem = rate/4000, sampleszbits = bit width
slim_connect_sink()/slim_control_ch()  -> activate
```

**On this device the ADSP is the bus master and owns the NGD** — APPS is a
`qcom,slim-ngd` satellite. Channel allocation, definition and activation are
therefore requests to a remote master, not local register writes. That is a
whole dependency of its own, and none of it is exercised by writing the two
IFD registers above.

The honest split for this milestone:

- **In scope:** the two IFD register writes for one RX port, their readback,
  and their reversal. These are ordinary register accesses over a bus that is
  already proven.
- **Out of scope:** `slim_query_ch` / `slim_define_ch` / channel activation,
  because they require the ADSP master to grant a channel, and nothing about
  that has been established on this port.

## 4. Clocks: what this path does and does not need

`wcd9320-mclk-investigation.md` established that **the codec is fully
responsive over SLIMbus with no 9.6 MHz MCLK present**, because register access
is clocked by the bus, not by the codec's MCLK. MCLK feeds the codec's internal
audio clock block.

Consequences, stated precisely:

- Writing the IFD port registers needs **no MCLK**. It is register access, the
  same class of operation as everything already proven.
- Anything that starts the codec's audio clock — `TAIKO_A_CHIP_CTL = 0x02`
  selecting 9.6 MHz, or `TAIKO_A_CDC_CLK_POWER_CTL` (`0x314`) — is **out**. The
  standing instruction from the MCLK investigation is that no MCLK code is
  written and `TAIKO_A_CHIP_CTL` stays unwritten until the source is
  identified. Selecting a 9.6 MHz mode without providing 9.6 MHz fails in a way
  that looks like a codec fault and is not.
- So this milestone can configure an RX **interface** but cannot make an RX
  **path** work, and must not claim to.

## 5. Two blockers found while mapping

### 5a. The IFD shares the PGD's regmap_config — and now its cache

`wcd9320_probe()` creates the interface function's regmap with the *same*
`wcd9320_regmap_config` as the control function. That was harmless while the
IFD's regmap was never used. It stops being harmless the moment port
programming writes to it, because that config now carries:

- `readable_reg` / `volatile_reg` bitmaps derived from the **PGD's** 673
  documented addresses;
- `reg_defaults` — 460 entries of **PGD** reset values;
- `cache_type = REGCACHE_MAPLE`.

IFD `0x180` is RX port 16's multi-channel register. PGD `0x180` is
`TAIKO_A_BUCK_MODE_1`, which is cacheable and carries a registered default. A
write to the IFD port register would be cached against a PGD default, and a
read could be answered from that cache instead of the chip. That is exactly the
silent-wrong-value failure mode the whole regcache milestone was built to
prevent — and `cache_check` cannot catch it, because it returns
`"interface function: not applicable"` and never walks the IFD.

**This must be fixed before any IFD write.** The IFD needs its own
`regmap_config`: its own `max_register` (`0x1b0` covers the port space), its own
readable/volatile predicates for the port map above, and — at least initially —
`REGCACHE_NONE`, since there is no measured reset state for the interface
space and no reason to cache a register file this small.

### 5b. A DAI on an unbound component gets no callbacks

The stated acceptance is "ASoC sees one RX DAI → callback executes → expected
IFD/register state changes". The first and third are reachable; the second is
not, in the form it implies.

ASoC invokes DAI ops — `startup`, `hw_params`, `prepare`, `trigger`,
`shutdown` — from PCM operations on a **sound card**. `snd_soc_dai_driver.probe`
likewise runs from `soc_probe_component()`, which happens when a card binds the
component. With no card and no machine driver, which this milestone explicitly
excludes, **no DAI callback will ever run**.

Two ways forward, and they are materially different:

1. **A research hook**, in the pattern this port already uses — `mbhc_test`
   armed an interrupt source with no card, `core_reinit` re-entered the
   production decision function. A write-only, token-guarded `rx_port_test`
   attribute would call *the same* port-programming function the DAI's
   `hw_params` will later call, so the register path is production code and
   only the trigger is research. That keeps the milestone honest: the DAI is
   proven *registered*, and the IFD path is proven *exercised and reversible*,
   without claiming ASoC drove it.

2. **Admit a card**, which contradicts "no sound card/machine driver yet" and
   drags in DAPM and PCM to get a callback to fire.

Option 1 is the one consistent with the stated scope and with how every earlier
milestone here was built. It should be an explicit decision, not something
discovered halfway through an implementation.

## 6. `core_ready` guarding

Currently the component registers early in probe, before enumeration
completes, and that is safe only because it is inert — it touches no register.

Once a callback can reach hardware that reasoning expires. Any port-programming
entry point must check `wcd->core_ready` (and `wcd->online`) and refuse with
`-EAGAIN`/`-ENODEV` rather than assuming probe ordering left the hardware
usable. The IFD writes go to the interface function, but the decision to allow
them belongs to the control function's state, which is where `core_ready`
lives — so the hook needs access to both, as the driver already has.

## 7. Proposed acceptance, restated to match what is provable

| claim | how it is measured |
|---|---|
| ASoC has exactly one WCD9320 RX DAI | the DAI appears in `/sys/kernel/debug/asoc/dais`, named for the control function |
| still no card, no TX DAI | `/proc/asound` empty; exactly one DAI |
| the port path executes | the hook returns 0 and the driver logs each write with old/want/readback |
| expected IFD state | `0x180` = channel bitmap, `0x040` = `0x05`, both read back from the interface function |
| every write attributable | before/after snapshot of the IFD port space, `0x30`–`0x1b0` |
| teardown is exact | `0x040` = `0x00`, `0x180` restored; snapshot returns to the before state |
| guarded | the hook refuses when `core_ready` is 0 |
| nothing else moved | cold-boot, regcache (`mismatches=0`), and the headset IRQ chain all unchanged |

Explicitly **not** claimed: PCM, DAI operation driven by ASoC, routing,
playback, capture, audible audio, or any SLIMbus channel being allocated,
defined or activated.

## 8. Which RX path a slave port corresponds to — traced

Traced rather than assumed, because the answer determines whether "port 16" is
a meaningful choice or an arbitrary one.

**The slave port does not correspond to a fixed codec output path.** There are
three separate bindings, and only the first is fixed:

**Fixed — port number to SLIM RX index.** `taiko_rx_chs[]` maps slave port
`TAIKO_RX_PORT_START_NUMBER + n` to channel shift `n`, with
`TAIKO_RX_PORT_START_NUMBER = 16` and 13 RX channels (ports 16–28). So port 16
is SLIM RX1, port 17 is SLIM RX2, and so on. This is a table in the driver, not
a routing decision.

**Runtime — which DAI feeds the port.** Each of the first seven ports has a
mux widget:

```c
SND_SOC_DAPM_MUX("SLIM RX1 MUX", SND_SOC_NOPM, TAIKO_RX1, 0, &slim_rx_mux[TAIKO_RX1]);
...
SND_SOC_DAPM_MUX("SLIM RX7 MUX", SND_SOC_NOPM, TAIKO_RX7, 0, &slim_rx_mux[TAIKO_RX7]);

static const char *const slim_rx_mux_text[] = {
	"ZERO", "AIF1_PB", "AIF2_PB", "AIF3_PB"
};
```

so a port is bound to a playback DAI by a mixer control, at runtime. Note only
**7 of the 13** RX slave ports have a mux widget; ports 23–28 exist on the bus
but this driver never routes them.

**Runtime — which mixer input the port feeds.** The DAPM routes are fully
general: every `SLIM RX1`–`SLIM RX7` appears as a source for every
`RX1 MIX1 INP1/2/3`, and likewise for the other RX mixers. Any SLIM RX port can
feed any RX path.

**Consequence for this milestone.** Port 16 is the first RX slave port and is
SLIM RX1 by a fixed table — that much is evidence, not convenience. What it
eventually *drives* (headphone, earpiece, line, speaker) is a DAPM routing
decision that does not exist yet and cannot be inferred from the port number.
So the correct claim is "slave port 16, which is SLIM RX1", and nothing about
an audio path. Exercising its two interface registers says nothing about where
audio would go, because at this layer that is genuinely undetermined.

## 9. Decisions taken

1. **The IFD gets its own `regmap_config`** (§5a). Prerequisite, not a detail:
   `max_register` `0x1b0`, predicates for the port map in §1, and
   `REGCACHE_NONE` — there is no measured reset state for the interface space
   and no reason to cache a register file this small.
2. **A research hook, not a card** (§5b). A write-only, token-guarded attribute
   calls the same port-programming function the DAI's `hw_params` will later
   call, so the register path is production code and only the trigger is
   research — the pattern `mbhc_test` and `core_reinit` already established.
   The milestone therefore claims the DAI is *registered* and the IFD path is
   *exercised and reversible*; it does not claim ASoC drove it.
3. **Slave port 16 (SLIM RX1)**, chosen on the traced table above, with its
   audio-path association explicitly recorded as undetermined.
4. Every entry point guards on `core_ready` and `online` (§6), rather than
   inheriting the component's current assumption that probe ordering has left
   the hardware usable.

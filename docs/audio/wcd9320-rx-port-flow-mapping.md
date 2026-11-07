# r177: does the codec actually consume the samples it receives?

**Status:** mapped, predictions frozen before any code. Kernel 6.16.12, codec
`port-flow-rc1`, pkgrel 177.

## Why this exists

Three acoustic runs heard nothing from HPHL: at minimum gain, at maximum gain,
and at maximum gain with the earcup sealed on the mic in a quiet room. The last
one puts the output at least about 28 dB below the PC-headset level at the same
digital amplitude, or at nothing. The phone side of every run was clean: the PA
was chip-verified on, the tone helper wrote every frame, and there was no OCP
fault.

Two questions have been open since Branch B and were never separable:

1. do the bytes reach the codec at all (B2's negative control showed the DSP
   loop runs the same with no codec stream, so period progress proves nothing)
2. if they arrive, does the codec's RX path consume them

The project recorded that this part "has no receiver-side counter or loopback".
That is wrong on both counts. Downstream `taiko_slimbus_irq()` reads
per-port status that this driver has never looked at, and the TX muxes take
`RMIX1..7` as inputs, which is a digital loopback. This milestone uses the
first, because it costs one register write.

## The registers (interface function, `217:a0:0:0`)

From `wcd9320_registers.h` and `taiko_slimbus_irq()`:

| addr | name | use here |
|---|---|---|
| `0x030`-`0x033` | `PORT_INT_EN0..` | **never written** — read only |
| `0x034` | `PORT_INT_STATUS_RX_0` | bit `j` = RX port `16 + j` |
| `0x035` | `PORT_INT_STATUS_RX_1` | |
| `0x036`-`0x037` | `PORT_INT_STATUS_TX_0/1` | |
| `0x038` | `PORT_INT_CLR_RX_0` | write `1 << j` to clear |
| `0x060 + j` | `PORT_INT_RX_SOURCE0 + j` | bit 0 OVERFLOW, bit 1 UNDERFLOW, bit 2 PORT_CLOSED |

Port 16 is therefore status `0x034` bit 0, source `0x060`, clear `0x038` value
`0x01`.

## What started it: a measurement, not a hypothesis

Read-only, after the r176 retry, on a boot that had run three C3a cycles:
`0x034 = 01`, `0x060 = 05`, and all four enables `00`
(`wcd9320-port-status-20261106T234303Z.txt`).

- RX port 16 latched **OVERFLOW** and **PORT_CLOSED**.
- **These status bits latch while masked.** That is the opposite of the main
  `INTR_STATUS` block, where a masked source does not latch (measured
  2026-08-15). So no interrupt plumbing is needed: poll, clear, poll.
- The r161 RX-DAI evidence shows the same range all `00` after port
  programming with no stream, so the bit is not a reset artefact.

For a sink port, OVERFLOW reads as "bytes arrived faster than the codec took
them out". That would mean Branch B's question (1) is answered *yes*, and
the failure is (2): the RX path is not reading the port. The prime suspect for
that is `0x314 CDC_CLK_POWER_CTL`, the codec clock power register whose writes
have never read back.

**It is not proof.** The bit is sticky, nothing has cleared it this boot, and
the time it latched is unknown. A transient at stream start or stop with an
otherwise healthy path would leave exactly the same bit. Hence this
experiment: clear it while the stream is in steady state and see whether it
comes back.

## The experiment: two variables, PA never enabled

Every row runs on one cold boot, in this order. A data row runs
`pcm-run-measured` for 6 s, waits 2 s for steady state, clears port 16, reads
straight away (`s0`), waits 2 s and reads again (`s1`). The verdict uses
`s1`, from the steady window, which contains neither the start nor the stop.
A no-data row brings the stream up by `slim_stream_test` with no PCM. Then the
channel is connected and active but the AFE never starts, so the ADSP sends
nothing.

| row | data sent | RX path | setup |
|---|---|---|---|
| A  | yes | **off** | stream only |
| B0 | no  | off | `stream-on`, nothing else |
| B  | no  | **on** | `rx1-on`, then `stream-on` |
| C  | yes | on | `rx1-on` |
| D  | yes | on | `cdc_clk_prereq on` (forced `0x314 = 03`), `rx1-on` |
| E  | yes | on, full C3a analog prep | `prep`, `cdc_clk_prereq on`, `rx1-on`, `dac-on-reggain` — **PA off** |

E is the exact C3a configuration minus the one PA write. The PA guard is armed
throughout, `0x1ab & 0x30` is sampled at every step, and the headset is
unplugged for the run.

## Predictions, frozen before the run

If the RX path works:

| row | expected `s1` on port 16 | why |
|---|---|---|
| A  | **OVERFLOW** | bytes arrive and nothing drains the port |
| B0 | nothing | no producer and no consumer |
| B  | UNDERFLOW, or nothing | the consumer pulls from an empty port, if the part reports that |
| C  | **clean** | bytes arrive and are drained |
| D  | **clean** | same |
| E  | **clean** | same, under the run's conditions |

### What each outcome means

1. **A overflows, and C, D and E all overflow.** Bytes reach the codec and the
   RX path never reads them in any configuration we can build, including the
   forced `0x314` write and the full C3a prep. The silence is upstream of the
   DAC: the digital RX clock domain is not running. The work moves to *why*
   (`0x314` not landing, or a further prerequisite), and it stays digital,
   with no acoustics.
2. **A overflows, C or D is clean.** Consumption works, and comparing C with D
   shows whether the forced `0x314` write matters. The silence is downstream
   of the interpolator: the RDAC clock `0x30d`, the DAC, or the analog stage.
3. **A overflows, C and D clean, E overflows.** Something in the analog prep
   stops the digital path. Unexpected; the prep would be bisected.
4. **A is clean.** OVERFLOW does not mean what this note assumes, or the
   bytes never arrive. Then nothing here says anything about consumption, and
   the result is reported as **inconclusive**, not as a pass. B0 and B tell
   whether UNDERFLOW is a usable signal instead.
5. **Any `s0` already shows the bit straight after a clear.** The clear did
   not take, or the condition re-latches within the read latency. The `s0`
   values are recorded so these two cannot be confused: `s0` set in a row
   where `s1` is meant to be clean makes that row INVALID.

A row's `src` is used only to say *which* kind of event latched. A clear that
leaves `src` non-zero while the status bit clears is recorded as
"source register is sticky", and from then on only the status bit is graded.

## What is written

- **Driver:** one attribute, `slim_port_status` (RW, control function).
  - Reading it reads `0x034`-`0x037` and port 16's source from the interface
    function. That regmap is `REGCACHE_NONE`, so every read reaches the chip.
  - `echo clear` makes exactly one write, `0x038 <- 0x01`, then reads back.
  - No interrupt enable is touched. No control-function register is written.
- **Fence (section 5e of the artefact gate):** the three addresses pinned by
  value, the attribute present, the clear confined to that one write on the
  interface regmap, and no write to `PORT_INT_EN` anywhere.
- **Gate:** `tools/wcd9320-port-flow-evidence.sh`, the six rows above, with
  the same `find_devices`, module-version and PA-guard conventions as every
  gate since C2b.

## Deliberately not done

- No PA, no tone through a headphone, no acoustics.
- No interrupt handler and no `PORT_INT_EN` writes. Polling is enough, and an
  enabled source would route into the codec's main interrupt line, which is
  masked and carries its own proven contract.
- No loopback via the `RMIX` inputs of the TX muxes. That needs a whole
  capture path, and is only worth building if this result is ambiguous.
- None of downstream's probe tables are applied. The differences found
  (`NCP_CLK`, `BIAS_CURR_CTL_2`, `HPH_L_TEST`) are analog tuning recorded in
  the evidence file. They are candidates for outcome 2, not for this run.

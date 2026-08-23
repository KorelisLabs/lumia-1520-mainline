# C2a design map: is the class-H power state reversible?

**Status:** research only. Nothing built, nothing claimed on hardware.

The goal: prove the HPHL class-H support circuitry can be brought from its
pristine idle state into the downstream-required configuration and returned to
that state, **with the DAC and PA held off throughout** — so that C2b inherits a
teardown already proven on hardware.

## A correction to the C2 map

The C2 map said there is *"no inverse sequence to copy"*. **That was wrong**, and
the mistake is worth recording because it nearly split the branch the wrong way.

`wcd9xxx_clsh_state_hph_l(is_enable=false)` really is a stub for the HPHL case —
that part was right. But the FSM dispatches teardown through the **destination**
state, not the source one. `wcd9xxx_clsh_state_idle()` with
`req_state = HPHL, is_enable = false` does:

```
wcd9xxx_clsh_comp_req(codec, clsh_d, CLSH_COMPUTE_HPH_L, false);
wcd9xxx_clsh_turnoff_postpa(codec);
```

So the inverse exists and is reached by transitioning to IDLE. It is still only
*invoked* from the PA lifecycle downstream, which is the real awkwardness — but
we are adopting a real routine, not inventing one by reversing writes.

## The enable path, register for register

`wcd9xxx_clsh_fsm(HPHL, ENABLE, PRE_DAC)` → `wcd9xxx_clsh_state_hph_l(enable)`:

| # | register | addr | POR | mask ← value |
|---|---|---|---|---|
| 1 | `BUCK_CTRL_CCL_4` | 0x18C | 0x58 | 0x0B ← 0x00 |
| 2 | `BUCK_CTRL_CCL_1` | 0x189 | 0xAB | 0xF0 ← 0x50 |
| 3 | `BUCK_CTRL_CCL_3` | 0x18B | 0x6A | 0x03 ← 0x00, then 0x0B ← 0x00 |
| 4 | `CDC_CLSH_BUCK_NCP_VARS` | 0x323 | 0x00 | bits 0–1←0, 2–3←0x04, 4←0 |
| 5 | `CDC_CLSH_B2_CTL` | 0x321 | 0x00 | 0x03←0x01, 0x0C←0x04, 0xF0←0x30 |
| 6 | `CDC_CLSH_B3_CTL` | 0x322 | 0x00 | 0xF0←0x30, 0x0F←0x0B |
| 7 | `CDC_CLSH_B1_CTL` | 0x320 | 0xE4 | bit5←1, bit1←1, bit6←0 |
| 8 | `CDC_CLSH_V_PA_HD_HPH` | 0x32F | 0x00 | 0x3F ← 0x0D |
| 9 | `CDC_CLSH_V_PA_MIN_HPH` | 0x331 | 0x00 | 0x3F ← 0x1D |
| 10 | `CDC_CLSH_IDLE_HPH_THSD` | 0x324 | 0x12 | 0x3F ← 0x13 |
| 11 | `CDC_CLSH_FCLKONLY_HPH_THSD` | 0x326 | 0x18 | 0x1F ← 0x19 |
| 12 | `CDC_CLSH_I_PA_FACT_HPH_L` | 0x32A | 0xD7 | ← 0x97 |
| 13 | `CDC_CLSH_I_PA_FACT_HPH_U` | 0x32B | 0x05 | ← 0x05 |
| 14 | `CDC_CLSH_K_ADDR` | 0x328 | 0x00 | bit7←0, 0x0F←0 |
| 15 | `CDC_CLSH_K_DATA` | 0x329 | 0xA4 | **eight sequential writes**: AE 01 1C 00 24 00 25 00 |
| 16 | `CDC_CLSH_B1_CTL` | 0x320 | | bit0←1 (`enable_clsh_block`) |
| 17 | `CDC_CLK_OTHR_CTL` | 0x30C | 0x00 | bit0←1 (charge pump, **refcounted**) |
| 18 | `CDC_CLSH_B1_CTL` | 0x320 | | bit1←1 (`enable_anc_delay`) |
| 19 | `CDC_CLSH_B1_CTL` | 0x320 | | bit3, via `resmgr_add_cond_update_bits(COND_HPH)` |
| 20 | `BUCK_MODE_5/4/3/1` | 0x185/4/3/1 | | mode set, `BUCK_VREF_2V` = 0xFF, then **50 µs settle** |
| 21 | `NCP_STATIC`, `NCP_EN` | 0x194, 0x192 | 0x28, 0xFE | fclk level 8, enable, then **50 µs settle** |

Item 15 is a coefficient table written through an address/data pair — eight
writes to one register, which any "each register written once" assumption would
get wrong.

## The teardown restores far less than the enable sets

`comp_req(HPH_L, false)` + `wcd9xxx_clsh_turnoff_postpa()`:

| register | action |
|---|---|
| `CDC_CLSH_B1_CTL` bit 3 | conditional update removed |
| `CDC_CLK_OTHR_CTL` bit 0 | charge pump off (**only when the refcount hits zero**) |
| `NCP_EN` bit 0 | ← 0 |
| `BUCK_MODE_1` bit 7 | ← 0 |
| `CDC_CLSH_B1_CTL` bit 4 | ← 0 |
| `CDC_CLSH_B1_CTL` bit 0 | ← 0 (`enable_clsh_block(false)`) |

**Nothing else is restored.** The buck control registers, all the class-H
parameters, the thresholds, the coefficient table, `NCP_STATIC`, `BUCK_MODE_3/4/5`
and several `B1_CTL` bits stay exactly as the enable left them.

That is normal driver behaviour — configuration is idempotent and gets
reprogrammed on the next enable — but it means **"returns to the pristine
baseline" is not what this teardown does**, and a gate written to that criterion
would fail a correct system.

Note also `CDC_CLSH_B1_CTL` bit 4 is cleared by the teardown but never set by
the HPHL enable: it is the EAR compute bit. The teardown is shared across
outputs.

## Predicted post-cycle values

Concrete and falsifiable, from POR plus the write sets:

| register | POR | after one enable+teardown cycle | why |
|---|---|---|---|
| `CDC_CLSH_B1_CTL` | 0xE4 | **0xA6** | bit1 set and bit6 cleared by enable, never restored |
| `BUCK_MODE_1` | 0x21 | **0x25** | bit2 set by enable, only bit7 restored |
| `NCP_EN` | 0xFE | **0xFE** | bit0 set then cleared — fully restored |
| `CDC_CLSH_B2_CTL` | 0x00 | **0x35** | configuration, not restored |
| `CDC_CLSH_K_DATA` | 0xA4 | last value written | table register |

If the hardware disagrees with these, the mapping is wrong and that matters
more than the milestone.

**Two of these were wrong when first written, and hardware caught both.**
`CDC_CLSH_B2_CTL` was given as 0x31 by hand; composing the three masked writes
properly gives **0x35** (corrected above). And three baseline registers --
`BUCK_MODE_3`, `BUCK_CTRL_CCL_1`, `BUCK_CTRL_CCL_4` -- do not reset to their
header POR at all, because they are in the fuse-loaded 0x180-0x1e4 trim range.
Expectations are now derived from the *measured* baseline with the transcribed
masked writes applied, which is both correct and immune to per-device fuse
variation. See `wcd9320-clsh-reversibility.md`.

## What the acceptance criterion must therefore be

Not "final state equals the pre-run snapshot". Three categories instead:

1. **Power state — must restore exactly.** `NCP_EN` bit 0, `BUCK_MODE_1` bit 7,
   `CDC_CLK_OTHR_CTL` bit 0, `CDC_CLSH_B1_CTL` bits 0 and 4.
2. **Configuration — may remain programmed.** Documented above; asserted to
   match the *expected programmed* values, not POR.
3. **Everything else — must not move at all.** Especially the DAC (0x1B1), the
   PA (0x1AB), the earpiece (0x1BC) and all right-channel/speaker registers.

And the decisive one: **cycle 2 must equal cycle 1.** Analog rails can have
hysteresis that digital blocks do not, so a reusable lifecycle is only
established if repeating it changes nothing.

## Two hazards found

**The charge pump refcount is a function-static.** `wcd9xxx_chargepump_request()`
keeps `static int cp_count` inside the function — process-wide, not per-device.
It `WARN_ON(1)`s on an unbalanced disable. Our helper must pair every enable
with exactly one disable, and the gate should check dmesg for that warning.

**`CDC_CLSH_B1_CTL` bit 3 goes through the conditional-update mechanism**
(`resmgr_add_cond_update_bits(WCD9XXX_COND_HPH)`), not a direct write. Whether
it is applied immediately or deferred until a headphone-presence condition is
satisfied is **not yet established**, and it should be resolved before the gate
asserts anything about bit 3.

## `RX_HPH_L_STATUS` stays out of the claim

Recorded throughout as exploratory evidence, with no semantics assigned. It is
volatile, which only means reads reach the chip, and it already reads 0x04
against a POR of 0x00. Same lesson as `0x376`: volatile is not signal-sensitive.

## Open questions

1. **Bit 3 and the conditional-update mechanism** — immediate or deferred?
2. **Does `enable_clsh_block` need the buck already up?** The ordering in
   `state_hph_l` puts block enable *before* `enable_buck_mode`, which is worth
   preserving exactly rather than tidying.
3. **What does this board's buck actually supply?** `BUCK_VREF_2V` is written
   blind as 0xFF into `BUCK_MODE_4`; `taiko_codec_get_buck_mv()` reads platform
   data we do not have.
4. **Is a 50 µs settle enough on this part**, or is it a downstream minimum?

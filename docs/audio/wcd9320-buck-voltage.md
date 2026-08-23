# The codec buck is 2.15 V, so `COMP1_B4_CTL` bit 7 is 0

**Status:** resolved, 2026-08-23. Prerequisite for C2b.

## Why it matters

`taiko_config_compander()` selects the compander's static gain offset from the
codec buck voltage, inside the COMP1 `PRE_PMU` sequence and immediately before
the compander→HPH gain handoff. Leaving it unknown would let a successful
DAC-enable coexist with the wrong compander operating point — and C2b is the
last step before physical output.

## The polarity, exactly

```c
if (comp == COMPANDER_1 && buck_mv == WCD9XXX_CDC_BUCK_MV_1P8) {
        snd_soc_update_bits(codec, TAIKO_A_CDC_COMP0_B4_CTL + (comp * 8),
                            0x80, 0x80);
} else {
        ... 0x80, 0x00);
}
```

Bit 7 is **set only when the buck is 1.8 V**. It is cleared for 2.15 V *and*
for the `WCD9XXX_CDC_BUCK_UNSUPPORTED` case — so an unidentifiable buck and a
2.15 V buck produce the same write, which is worth knowing because it means
"clear" is also the safe default when the voltage cannot be determined.

Constants: `MV_1P8 = 1800000`, `MV_2P15 = 2150000`, `UNSUPPORTED = 0`.

## Three independent sources agree: 2.15 V

| source | evidence |
|---|---|
| our DT, codec node | `vdd-buck-supply = <&pm8941_s2>;  /* 2.15 V */` |
| our DT, regulator | `pm8941_s2: s2 { regulator-min-microvolt = <2150000>; regulator-max-microvolt = <2150000>; ... }` |
| **live** `regulator_summary` | the s2 rail carrying `217:a0:1:0-vdd-buck` reads **2150 mV**, min 2150, max 2150 |

The driver's own supply table already recorded it as well — `"vdd-buck", /* pm8941
s2, 2.15 V, 650 mA */` — but that comment was inherited from downstream
documentation, so it is corroboration rather than a fourth independent source.

The live reading is the decisive one: it confirms the rail is actually at
2150 mV on this board, not merely described that way.

## The locked prediction

```
buck = 2.15 V  ->  COMP1_B4_CTL (0x373) bit 7 = 0
```

`COMP1_B4_CTL` POR is **0x3C**, whose bit 7 is already 0 — so on this board the
write is a **no-op against reset**. It is still performed, for two reasons: the
sequence should be faithful rather than optimised against a particular reset
value, and a board or part where the bit came up set must be corrected rather
than silently inheriting it.

The C2b gate **asserts** bit 7 is clear after the compander enables, rather than
just issuing the write.

## A second buck branch exists, and it is not on our path

`buck_mv` appears exactly **once** in `wcd9xxx-common.c`: inside
`wcd9xxx_clsh_state_lo()`, the LINEOUT state, where a 1.8 V buck takes a
completely different NCP and buck ordering.

The HPHL `PRE_DAC` path implemented in C2a contains no buck-dependent branch, so
**C2a is complete as built** — this was worth confirming rather than assuming,
since a missed conditional there would have meant the proven class-H lifecycle
was only proven for one board configuration.

## Consequence for C2b

The three compander→HPH registers stay **inside** C2b, as mapped:

| register | addr | action |
|---|---|---|
| `RX_HPH_L_GAIN` | 0x1AE | bit 5 ← 0 on compander enable, ← 1 on disable |
| `RX_HPH_R_GAIN` | 0x1B4 | same |
| `COMP1_B4_CTL` | 0x373 | bit 7 ← **0** (buck is 2.15 V) |

Nothing is deferred to the PA milestone.

# The MCLK path: what is mapped, and what is still guesswork

**Status:** mapping only, 2026-08-23. **No code written, no register poked.**
Raised by r165, where both `CDC_CLK_POWER_CTL` (0x314) and
`CDC_CLK_RDAC_CLK_EN_CTL` (0x30d) refused writes while every other register the
DAC branch touches accepted them.

## Why this was asked

r164 found that `0x30d` bit 1 would not latch. r165 tried downstream's
`CDC_CLK_POWER_CTL = 0x03` as the missing prerequisite and discovered that
**0x314 refuses too**, so the hypothesis was never tested. The question became:
is something board-level — a clock — missing for the analog conversion path
that the digital RX path never needed?

The pattern that motivated it, all from chip-verified writes on one boot:

| accepts writes | refuses writes |
|---|---|
| `0x309` `0x310` compander clocks/reset | **`0x30d`** RDAC clock enable |
| `0x370`-`0x373`, `0x377` compander block | **`0x314`** CDC clock power |
| `0x1ae` `0x1b4` HPH gain source | |
| `0x3b0` class-H DSM mux, `0x1a2` RX bias | |
| class-H buck/NCP (C2a, 82/82) | |

## 1. The divider hardware exists, and is running — measured

Read directly from the PMIC's regmap (`/sys/kernel/debug/regmap/0-00`, SPMI
slave 0):

| peripheral | `+04` type | `+05` subtype | `+43` DIV_CTL1 | `+46` EN_CTL |
|---|---|---|---|---|
| `0x5B00` DIV_CLK1 | `06` | `0b` | `00` | **`80` enabled** |
| `0x5C00` DIV_CLK2 | `06` | `0b` | `00` | **`80` enabled** |
| `0x5D00` DIV_CLK3 | `06` | `0b` | `00` | `00` disabled |

Three consecutive peripherals, 0x100 apart, identical type/subtype. That is the
CLKDIV block, at the addresses the driver's `base = start + i * 0x100` expects.

**They are already enabled**, left on by the boot chain — nothing in our kernel
touches them.

### But the rate is wrong

`div_factor_to_div()` treats a `DIV_CTL1` factor of 0 as 1:

```c
static inline unsigned int div_factor_to_div(unsigned int div_factor)
{
        if (!div_factor)
                div_factor = 1;
        return 1 << (div_factor - 1);
}
```

`xo_board` measures **19 200 000 Hz**, and factor 0 divides by 1. So DIV_CLK1
is currently producing **19.2 MHz, not the 9.6 MHz** Taiko's defaults table
calls for ("set MCLk to 9.6"). 9.6 MHz needs `div_factor = 2`.

## 2. The routing: firmware says yes, hardware currently says no

**For.** The Lumia's own ACPI power description for
`\_SB.ADSP.SLM1.ADCM.AUDD` — the codec — contains, in its active `FSTATE`:

```
PMICGPIO       IOCTL_PM_GPIO_CONFIG_DIGITAL_OUTPUT, 0, 0x0E, 0, 0x02, 0x04, 0x03
PMICDIVCLK     PPP_RESOURCE_ID_DIV_CLK_1_A, 0x02, One      <- enabled
PMICVREGVOTE   SMPS2 @ 0x0020CE70 = 2 150 000 uV
PMICVREGVOTE   SMPS3 @ 0x001B7740 = 1 800 000 uV
```

and in its off state, `DIV_CLK_1_A ... Zero, Zero`. The two regulator votes are
exactly this codec's buck and 1.8 V rails, independently established months
ago, which is what identifies the block. So the firmware enables DIV_CLK1 and
configures a PMIC GPIO **as part of powering the codec**, and disables the
divider when the codec powers down.

The GPIO field is **0-based**: values across the table include `Zero` and top
out at `0x23` = 35, and PM8941 has exactly 36 GPIOs. So `0x0E` is
**PM8941 GPIO 15**, not GPIO 14. Its trailing fields are `0x04, 0x03` where
every other `PMICGPIO` entry in the table ends `Zero, Zero` — a non-default
source/strength, consistent with an alternate function.

**Against, or at least not yet.** No PM8941 GPIO is presently in an alternate
function. Confirmed two independent ways:

- pinctrl debugfs reports every one of the 36 pins as function `normal`
- decoding `MODE_CTL` (`base+0x40`) directly from the PMIC regmap agrees:
  with bits [6:4] direction, **[3:1] function**, [0] output value, every pin
  decodes to function 0

(An earlier pass of mine masked `MODE_CTL & 0x0f` and mis-flagged GPIOs 19, 21,
23 and 24 as alternate-function. They are `func=0` with the output-value bit
set. The correct decode agrees with pinctrl.)

**So the firmware describes a route that our running system does not
implement.** That is consistent with the divider going nowhere today.

### This is outcome B, not A

The mapping cannot promote this to "RM-940 routes DIV_CLK1 to the WCD9320 MCLK
pin". What is established is that the codec's own firmware power state enables
that divider and configures a specific PMIC GPIO alongside it. What is not
established is the physical trace from PM8941 GPIO 15 to the codec's MCLK pad.
Confirming it needs either a schematic or an instrumented test — configure the
pin to the divider function and observe whether the codec's behaviour changes.

## 3. The DT the provider needs

From `Documentation/devicetree/bindings/clock/qcom,spmi-clkdiv.yaml` and the
driver. Mainline `pm8941.dtsi` has **no** clkdiv node, so this would be new:

```dts
pm8941_clk_divs: clock-controller@5b00 {
        compatible = "qcom,spmi-clkdiv";
        reg = <0x5b00>;
        clocks = <&xo_board>;
        clock-names = "xo";
        #clock-cells = <1>;
        qcom,num-clkdivs = <3>;

        assigned-clocks = <&pm8941_clk_divs 1>;
        assigned-clock-rates = <9600000>;
};
```

Provider index is **1-based** — `spmi_pmic_div_clk_hw_get()` does
`idx = clkspec->args[0] - 1` and rejects 0.

`CONFIG_SPMI_PMIC_CLKDIV` is **not set** in our config and must be enabled.

## 4. A pinctrl state is also required

The binding says it outright: *"These clocks are typically wired through
alternate functions on GPIO pins."* The clkdiv driver only programs the
divider — `DIV_CTL1` and `EN_CTL` — and knows nothing about pads. Exposing
DIV_CLK1 on PM8941 GPIO 15 needs a `pinctrl-spmi-gpio` state selecting one of
`func1`…`func4` on that pin, and which one is not established.

## 5. There is a second half nobody has mentioned: the codec must be told

Adding `clocks = <...>` to the codec node does nothing on its own. Two things
have to happen beyond the provider:

1. **The driver must take the clock.** `devm_clk_get()` plus
   `clk_prepare_enable()`, refcounted, because HPHR and EAR will want the same
   reference later. Nothing in `wcd9320-core.c` touches the clock framework
   today.

2. **The codec must switch to it.** `CLK_BUFF_EN1` (0x108) currently reads
   `0x0d` — bit 3 set — which selects **RCO**. Downstream switches with
   `wcd9xxx_enable_clock_block(resmgr, config_mode = 0)`:

   ```
   CLK_BUFF_EN1  0x08 <- 0x00      stop selecting RCO
   if (RC_OSC_FREQ & 0x80) { CLK_BUFF_EN2 <- 0x02; config_mode(0); }
   CLK_BUFF_EN1  0x0C <- 0x04      source = external, ref = VBG
   CLK_BUFF_EN1  0x01 <- 0x01      then 1 ms
   CLK_BUFF_EN2  0x02 <- 0x00
   CLK_BUFF_EN2  0x04 <- 0x04
   CDC_CLK_MCLK_CTL 0x01 <- 0x01
   ```

   This is a **codec-side register sequence**, needing no board change. It also
   carries a real hazard: if no MCLK is actually arriving, switching away from
   RCO removes the CDC core's clock. Register access over SLIMbus should
   survive, since that is the interface function's own clock, but the digital
   core would stop. Recoverable by switching back or rebooting — and worth
   saying out loud before anyone runs it.

## 6. The inverse

Mirror of the above: switch back to RCO first, then `clk_disable_unprepare()`,
then release the divider. Refcounted at the codec-driver level so that adding
HPHR or EAR later cannot drop a clock another path still holds — the same
discipline `wcd9320_rx_bias()` already uses for `RX_COM_BIAS`.

## Outcome, stated plainly

**B — the divider exists in software and firmware; the physical routing is not
established.**

The pieces that are now facts: the CLKDIV hardware exists at known addresses
and is enabled; the XO is 19.2 MHz and the current divider setting yields
19.2 MHz rather than 9.6; the codec's firmware power state ties DIV_CLK1 and a
specific PMIC GPIO to the codec; no PMIC GPIO is currently in an alternate
function; the codec is currently selecting RCO; and the provider driver is not
built.

The piece that is not: that PM8941 GPIO 15 physically reaches the codec's MCLK
pad on RM-940.

**What this does NOT establish** is that MCLK is why `0x314` and `0x30d`
refuse. That remains a hypothesis. It is now a *well-formed* one, with a
concrete construction path and a concrete falsification, which it was not
before.

## Deliberately not done

- No `CHIP_CTL` (0x001) write. Still observe-only, still unmapped.
- No divider reprogramming, no pinmux change, no clock switch.
- No promotion of `taiko_reg_defaults[]` into codec init.

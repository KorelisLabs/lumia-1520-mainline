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

## 2b. THE FIRST PROVIDER DESIGN IS DISPROVEN, BY BOOT

**r166 was a BOOT REGRESSION. It yields no MCLK or RDAC conclusion.**

The design below in section 3 -- a `qcom,spmi-clkdiv` provider at `0x5b00` --
was built, verified 63/0 by the artefact gate, flashed, and **broke the boot**:

```
[2.725605] qcom-clk-smd-rpm ...clock-controller: error -EEXIST:
           failed to register clk 'div_clk1'
[4.377581] sdhci_msm f9824900.mmc: no support for card's volts
[4.377667] mmc0: error -22 whilst initialising MMC card
[22.10765] [pmOS-rd]: ERROR: failed to mount subpartitions!
```

`spmi_pmic_clkdiv_probe()` names its outputs `div_clk1`, `div_clk2`,
`div_clk3`. Clock names are a GLOBAL namespace, and **MSM8974's RPM already
provides `div_clk1`**. The duplicate registration failed with `-EEXIST`, which
took down the RPM clock controller and cascaded into the eMMC losing regulator
support. No rootfs, initramfs debug shell.

Note what this was NOT: not the pin mux (the codec module lives on the rootfs
and never probed, so `pinctrl-0` was never applied -- and the mmc failure at
4.379 s precedes the SLIMbus controller registering at 4.458 s anyway), and not
the divider rate.

### The ownership finding, which is the real content

```c
/* drivers/clk/qcom/clk-smd-rpm.c */
DEFINE_CLK_SMD_RPM_XO_BUFFER(div_clk1, 11, 19200000);
[RPM_SMD_DIV_CLK1]   = &clk_smd_rpm_div_clk1,
[RPM_SMD_DIV_A_CLK1] = &clk_smd_rpm_div_clk1_a,
```

DIV_CLK1 is **RPM resource 11**, and `rpmcc` is already in
`qcom-msm8974.dtsi`. The DSDT string that started this --
`PPP_RESOURCE_ID_DIV_CLK_1_A` -- is an *RPM resource id*, and its `_A` suffix
is RPM's active-only convention. That was readable from the beginning and was
misread as generic firmware nomenclature.

Instantiating a second CCF provider for hardware whose ownership already
belongs to RPM is the actual mistake, and the SPMI block physically containing
the divider registers is what makes it a tempting one.

### And the obvious repair does not work either

`clocks = <&rpmcc RPM_SMD_DIV_A_CLK1>` with `assigned-clock-rates = <9600000>`
would NOT produce 9.6 MHz. `DEFINE_CLK_SMD_RPM_XO_BUFFER` expands through
`__DEFINE_CLK_SMD_RPM_BRANCH` to `clk_smd_rpm_branch_ops`:

```c
static const struct clk_ops clk_smd_rpm_branch_ops = {
        .prepare = ..., .unprepare = ..., .recalc_rate = ...,
};
```

No `.set_rate`, no `.round_rate`, no `.determine_rate` -- only the non-branch
`clk_smd_rpm_ops` carries those. `RPM_SMD_DIV_A_CLK1` is an **enable-only
gate**, not a Linux-programmable divide-by-2.

### So the open question has changed

Not "how do we add DIV_CLK1" -- that is answered. It is:

> **Who programs the PM8941 DIV_CLK1 divide factor, while RPM owns the
> enable vote?**

Two layers that appear separable:

```
RPM resource 11 / DIV_CLK_1_A   ->  ownership + active-only enable
PM8941 CLKDIV1 @ 0x5b00         ->  DIV_CTL1 @ 0x5b43, the actual factor
GPIO15 alternate function       ->  routing
WCD9320 MCLK                    ->  consumer
```

and the measured state says the boot chain enabled the resource without
configuring or routing it for audio:

| | |
|---|---|
| `0x5b46` | `0x80` -- enabled |
| `0x5b43` | `0` -- divide by 1, so 19.2 MHz |
| gpio15 | function `normal`, nothing routed |
| codec | RCO selected |

### The three ownership questions, answered

**1. Does the Windows `PMICDIVCLK` request carry a rate or factor? NO.**

```
on :  "PPP_RESOURCE_ID_DIV_CLK_1_A", 0x02, One
off:  "PPP_RESOURCE_ID_DIV_CLK_1_A", Zero, Zero
```

`0x02` is not a divide-by-2. It is the same value in the same slot that
`PMICVREGVOTE` uses (6 instances), i.e. a parameter common to resource votes,
and the off state zeroes it alongside the enable -- consistent with releasing a
vote, not with clearing a divider. Corroborated independently by RPM's own
protocol: `DEFINE_CLK_SMD_RPM_XO_BUFFER` passes
`QCOM_RPM_KEY_SOFTWARE_ENABLE`, and the CLK_BUF_A resource has no rate key at
all. The ACPI tables also never touch `0x5b43`/`0x5b46` directly.

So Windows votes the resource on and off. It does not set the factor here.

**2. What did Qualcomm downstream do? CANNOT BE ANSWERED FROM WHAT WE HOLD.**

The cache is the codec plus resmgr plus wcd9xxx-common -- no MSM8974 machine
driver and no downstream clock table. Stating that plainly rather than
inferring. The one thing the cache does settle: the downstream **codec** driver
never touches the PMIC or any divider register, so wherever that programming
lives downstream, it is not in the codec.

**3. Who owns `DIV_CTL1`? Constrained hard, but not proven.**

The constraint that makes this tractable is in the codec, not the PMIC:

```c
if (wcd9xxx->mclk_rate == TAIKO_MCLK_CLK_12P288MHZ)
        snd_soc_update_bits(codec, TAIKO_A_CHIP_CTL, 0x06, 0x0);
else if (wcd9xxx->mclk_rate == TAIKO_MCLK_CLK_9P6MHZ)
        snd_soc_update_bits(codec, TAIKO_A_CHIP_CTL, 0x06, 0x2);
```

`CHIP_CTL[2:1]` is the codec's MCLK **rate selector** and has exactly two legal
values: 12.288 MHz or 9.6 MHz. **There is no 19.2 MHz setting.** The XO is
19.2 MHz and 19.2 / 2 = 9.6 exactly, so for this part the divider must be at
/2. The codec cannot consume the XO directly.

Putting the measurements beside that:

| | measured | meaning |
|---|---|---|
| `0x5b46` | `80` | buffer enabled by the boot chain |
| `0x5b43` | `00` | divide by 1, so 19.2 MHz at the pad |
| `0x001` CHIP_CTL | `00` | codec expecting 12.288 MHz -- the POR, unset for this board |
| gpio15 | `normal` | nothing routed |
| RPM votes | `enable_count 0` | Linux holds no vote; `deviceless` |

So on this boot path nothing programs the factor, and **nothing in the clock
framework can** -- RPM's branch ops have no `set_rate`, and the resource
protocol has no rate key. That leaves two possibilities, and the evidence does
not yet separate them:

- the AP is expected to program `0x5b43` over SPMI, alongside an RPM enable
  vote and the pin mux; or
- RPM firmware programs it from a board configuration we cannot see, and does
  so only in a boot path ours is not taking.

**A hazard that must be designed for either way.** RPM owns the resource. If
RPM firmware touches the peripheral when it processes an enable or disable
vote, a factor written by the AP could be silently clobbered. Any experiment
that writes `0x5b43` therefore has to re-read it *after* the vote transition,
not just after the write -- otherwise a clobbered divider looks exactly like a
successful one.

**A second trap, worth stating because it would have gone into a gate.**
`clk_get_rate()` on `div_clk1` returns 19 200 000 unconditionally: it is a
branch clock whose `recalc_rate` reports the fixed nominal value and never
reads `DIV_CTL1`. The CCF rate is nominal, not measured. Only the PMIC register
can say what the pad is actually carrying.

### RESOLVED: AP kernel software owns the divide factor

Answered from a shipping MSM8974 + WCD9320 board -- LineageOS
`android_kernel_lge_hammerhead`, `cm-11.0`, the Nexus 5. Same SoC, same codec.
Source stays in `~/.cache/wcd9320-downstream/hammerhead/` and is never checked
in; only these derived facts are recorded.

**The divide factor is set in device tree and programmed by an AP-side kernel
driver.**

```dts
/* arch/arm/boot/dts/msm8974-clock.dtsi */
&spmi_bus {
        qcom,pm8941@0 {
                pm8941_clkdiv1: clkdiv@5b00 {
                        qcom,cxo-div = <2>;      /* 19.2 MHz / 2 = 9.6 MHz */
                };
```

consumed through a private kernel API, not the clock framework:

```c
/* include/linux/qpnp/clkdiv.h */
enum q_clkdiv_cfg {
        Q_CLKDIV_NO_CLK = 0,
        Q_CLKDIV_XO_DIV_1,      /* 1 */
        Q_CLKDIV_XO_DIV_2,      /* 2 */
        Q_CLKDIV_XO_DIV_4,      /* 3 */
        ...
};
int qpnp_clkdiv_config(struct q_clkdiv *, enum q_clkdiv_cfg cfg);
```

and the board wires the codec to exactly that node:

```dts
/* msm8974-hammerhead.dtsi */
qcom,cdc-mclk-gpios      = <&pm8941_gpios 15 0>;
taiko-mclk-clk           = <&pm8941_clkdiv1>;
qcom,taiko-mclk-clk-freq = <9600000>;
```

**RPM owns only the enable vote, in downstream too.**

```c
DEFINE_CLK_RPM_SMD_XO_BUFFER(div_clk1, div_a_clk1, DIV_CLK1_ID);
        /* -> RPM_CLK_BUFFER_A_REQ, RPM_KEY_SOFTWARE_ENABLE */

static int rpm_branch_clk_set_rate(struct clk *clk, unsigned long rate)
{
        if (rate == clk->rate)
                return 0;
        return -EPERM;
}

CLK_LOOKUP("osr_clk", div_clk1.c, "msm-dai-q6-dev.16384");
```

So RPM ownership is Qualcomm's own model and not a mainline artefact, and the
downstream branch `set_rate` refuses any change exactly as mainline's does by
having none at all.

**The audio machine driver programs nothing.** It resolves `osr_clk` from the
QDSP6 AFE DAI device, calls `clk_prepare_enable()` on it, and `gpio_request()`s
the MCLK pin under the name `TAIKO_CODEC_PMIC_MCLK` -- and never sets that
pin's direction or value, and never issues a `clk_set_rate`. It only
*validates* the frequency, erroring out if `qcom,taiko-mclk-clk-freq` is
anything but 9 600 000.

### Two independent derivations of the /2 encoding agree

| source | value for divide-by-2 |
|---|---|
| downstream `Q_CLKDIV_XO_DIV_2` | **2** |
| mainline `div_to_div_factor(2) = ilog2(2) + 1` | **2** |

So `DIV_CTL1` (`0x5b43`) = **2** means XO/2 = 9.6 MHz, corroborated across two
independently written implementations.

### GPIO 15 is confirmed by a second, independent board

`qcom,cdc-mclk-gpios = <&pm8941_gpios 15 0>` on the Nexus 5, and
`gpio@ce00 { qcom,pin-num = <15>; }` in the PM8941 dtsi -- the same address this
project read directly from the PMIC. That is independent agreement with the
0-based decode of the Lumia's own ACPI GPIO index `0x0E`, from a completely
different source.

### Why r166 failed, stated precisely

Mainline's equivalent of `qpnp-clkdiv` **is**
`drivers/clk/qcom/clk-spmi-pmic-div.c` -- the driver r166 used. The
architecture was right. The defect is narrower and worth recording upstream:

- downstream's `qpnp-clkdiv` exposed a **private API** (`qpnp_clkdiv_get`,
  `_enable`, `_config`) and registered **no CCF clocks**, so it had no
  namespace to collide with;
- mainline's `clk-spmi-pmic-div` registers CCF clocks named `div_clk1..N`,
  which on MSM8974 collide with the ones `rpmcc` already exports.

On this SoC those two drivers **cannot coexist**, and nothing in the binding
says so.

### What is still NOT established

Which pinctrl function routes the divider onto the pad. The hammerhead board DT
reserves gpio15 for audio but sets no `qcom,src-sel` for it in the files
fetched, the machine driver never configures the pin, and `qpnp-clkdiv.c`
itself could not be located (four candidate paths tried, all 404). So **func1
versus func2 remains open** -- still a two-way choice, still runtime-testable
via pinctrl debugfs `pinmux-select` without a rebuild.

### What r167 may and may not do

May: take an RPM enable vote via `<&rpmcc RPM_SMD_DIV_A_CLK1>`, set the pin
mux, and read `0x5b43` back after every state change.

Must not: resurrect the SPMI CCF provider, or write `0x5b43` before the
ownership question above is settled by evidence rather than by the fact that
nothing else in our stack does it.

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

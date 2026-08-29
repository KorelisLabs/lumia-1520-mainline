# C3 design map: HPHL DAC → the left headphone PA → the physical output

**Status:** research only, 2026-08-29. **No code written, no register poked, no
build staged.** Everything is transcribed from downstream `wcd9320.c`,
`wcd9xxx-common.c` and `wcd9xxx-mbhc.c`, cached externally and never checked in.

**Starts from D1**, frozen at `8239a20`: the HPHL DAC widget powers,
`0x1b1 = 0xC0` chip-verified, twice, reversibly, with the PA off. See section 19
of [wcd9320-refused-registers-audit.md](wcd9320-refused-registers-audit.md).

**This milestone is not audible sound.** It is an *electrical* proof at the HPHL
output with a controlled PA enable, measured on a scope.

---

## 1. The HPHL PA register, widget and event

```c
SND_SOC_DAPM_PGA_E("HPHL", TAIKO_A_RX_HPH_CNP_EN, 5, 0, NULL, 0,
	taiko_hph_pa_event, SND_SOC_DAPM_PRE_PMU |
	SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_POST_PMD),
```

| | |
|---|---|
| register | `TAIKO_A_RX_HPH_CNP_EN` = **`0x1ab`**, POR `0x80` |
| bit | **5** (HPHL). Bit 4 is HPHR and stays clear. |
| written by | the **DAPM PGA widget itself**, not by the event handler |
| events | `PRE_PMU`, `POST_PMU`, `POST_PMD` — **there is no `PRE_PMD`** |

This is the register our PA guard has been asserting `& 0x30 == 0x00` against
since C2a. Our board reads `0x80` at baseline, matching POR exactly.

## 2. The complete ordering

`taiko_hph_pa_event()`, in full, for `w->shift == 5`:

| # | phase | what happens |
|---|---|---|
| 1 | **PRE_PMU** | `wcd9xxx_resmgr_notifier_call(PRE_HPHL_PA_ON)` — **no codec register write** |
| 2 | *(widget)* | `0x1ab` bit 5 ← 1 |
| 3 | **POST_PMU** | `usleep(pa_settle_time)`, then `wcd9xxx_clsh_fsm(HPHL, ENABLE, POST_PA)` |
| — | | *…run…* |
| 4 | *(widget)* | `0x1ab` bit 5 ← 0 |
| 5 | **POST_PMD** | `usleep(pa_settle_time)`, `notifier(POST_HPHL_PA_OFF)`, `wcd9xxx_clsh_fsm(HPHL, DISABLE, POST_PA)` |

**The settle comes *after* the enable and *after* the disable, not before
either.** And the disable has no pre-event: the bit drops first, then the codec
waits and only then unwinds class-H.

## 3. Every gain register, and the safest configuration

```c
SOC_SINGLE_TLV("HPHL Volume", TAIKO_A_RX_HPH_L_GAIN, 0, 20, 1, line_gain)
                                                     ^shift ^max ^INVERT
static const DECLARE_TLV_DB_SCALE(line_gain, 0, 7, 1);
```

| register | addr | POR | role |
|---|---|---|---|
| `RX_HPH_L_GAIN` | `0x1ae` | `0x00` | bits **[4:0]** gain (max 20), bit **5** gain source |
| `RX_HPH_L_PA_CTL` | `0x1b0` | `0x40` | PA control |
| `RX_HPH_L_TEST` | `0x1af` | `0x00` | init sets bit 0 |
| `RX_HPH_BIAS_PA` | `0x1a6` | `0xaa` | PA bias |
| `RX_HPH_BIAS_WG_OCP` | `0x1a9` | `0x2a` | wavegen / OCP bias, **paired with the compander state** |
| `RX_HPH_CHOP_CTL` | `0x1a5` | `0xb4` | chopper, **paired with the compander state** |

> ### ⚠ THE CONTROL IS INVERTED, SO THE POR IS MAXIMUM GAIN
>
> `SOC_SINGLE_TLV(..., max = 20, invert = 1)` means the register field holds
> `20 − user_volume`. The POR of `0x1ae` is `0x00`, so **the default register
> state is user-maximum output level.**
>
> **The safest gain is `0x1ae[4:0] = 20 (0x14)`**, which is user-*minimum*.
> C3a must write it explicitly before the PA is ever enabled. Leaving the
> register at its reset value is the loudest possible setting, not the quietest.

## 4. The gain-source handoff, and where it is *not*

`taiko_config_gain_compander(COMPANDER_1, enable)`:

```c
snd_soc_update_bits(codec, TAIKO_A_RX_HPH_L_GAIN, 1 << 5, !enable << 5);
```

- bit 5 **clear** → gain comes from the **compander**
- bit 5 **set** → gain comes from the **register field**

`taiko_codec_reg_init_val[]` sets `{RX_HPH_L_GAIN, 0x20, 0x20}` at probe —
register-controlled by default.

**There is no gain handoff associated with PA activation.** It belongs to the
compander widget's `PRE_PMU`/`PRE_PMD`, which C2b already implements and D1
already exercised. Nothing new is required at PA time.

**But it collides with "minimum gain" — see section 12.**

## 5. Class-H, charge pump, buck and NCP at PA enable

`WCD9XXX_CLSH_EVENT_POST_PA` is the **second stage** of class-H — the one C2a
deliberately did not perform, and the only part of class-H C2b left unproven.

**Enable** (`req_type == ENABLE`, state ≠ LO) → `wcd9xxx_clsh_enable_post_pa()`:

```
BUCK_MODE_5   mask 0x02 <- 0x00
NCP_STATIC    mask 0x20 <- 0x00
BUCK_MODE_3   mask 0x04 <- 0x04
BUCK_MODE_3   mask 0x08 <- 0x08
```

**Disable** (`req_type == DISABLE`) → `new_state = old_state & ~HPHL`, then the
state function for the resulting state. With HPHL the only active state that is
`state_idle`, **which is exactly the transition C2a proved reversible on
hardware, 82/82.**

No separate charge-pump or bias step is triggered by the PA: the buck and NCP
moves above are the whole of it.

## 6. Required delays

```c
#define TAIKO_HPH_PA_SETTLE_COMP_ON  3000    /* us */
#define TAIKO_HPH_PA_SETTLE_COMP_OFF 13000   /* us */
```

Selected by `taiko->comp_enabled[COMPANDER_1]`. Applied **after** the enable and
**after** the disable, in both cases before the class-H transition.

## 7. Pop and click suppression, and its pairing rule

The wavegen and chopper settings are **not fixed** — downstream reconfigures
them with the compander, in `taiko_set_compander()`:

| | compander 1 **ON** | compander 1 **OFF** |
|---|---|---|
| `CNP_WG_CTL` `0x1ac` | `0xDA` | `0xDB` |
| `CNP_WG_TIME` `0x1ad` | `0x15` (5 ms) | `0x58` (20 ms) |
| `BIAS_WG_OCP` `0x1a9` | `0x2A` | `0x1A` |
| `CHOP_CTL` `0x1a5` bit 7 | set | clear |
| `NCP_DTEST` | `0x20` | — |
| **PA settle** | **3 ms** | **13 ms** |

`taiko_codec_reg_init_val[]` establishes the compander-OFF set at probe
(`0xDB`, `0x58`, `0x1A`, `CHOP_CTL 0x24`), and the comment says so explicitly:
*"Setup wavegen timer to 20msec and disable chopper as default. This
corresponds to Compander OFF."*

> **The pairing is a rule, not a preference.** Wavegen timing, chopper, OCP bias
> and PA settle time must all match the compander state. Our C2b enables
> compander 1 but has never applied the compander-ON half of this pairing,
> because it never enabled the PA. **C3a must apply whichever half matches the
> compander state it runs in.**

## 8. The real teardown path

Sink to source, from the events themselves rather than by reversing the enable:

1. `0x1ab` bit 5 ← 0 *(the widget; there is no PRE_PMD)*
2. `usleep(pa_settle_time)`
3. notifier `POST_HPHL_PA_OFF`
4. `wcd9xxx_clsh_fsm(HPHL, DISABLE, POST_PA)` → `state_idle`, the C2a-proven transition
5. …then the existing D1 teardown, unchanged: DAC power and switch off, forced `0x30d` clear, class-H `PRE_DAC` unwind, DSM mux, RX bias, compander gain handoff, forced `0x314` clear

## 9. Status that becomes meaningful only with the PA active

**Over-current protection is the real one**, and it is an interrupt, not a
register poll:

| | |
|---|---|
| `WCD9XXX_IRQ_HPH_PA_OCPL_FAULT` | HPHL over-current fault |
| `RX_HPH_OCP_CTL` `0x1aa` | POR `0x68`; init `{0xE1, 0x61}`; **bit 4 (`0x10`) is the re-arm toggle** |
| `RX_COM_OCP_COUNT` | init `0xFF` |
| OCP current limit | `hph_ocp_limit << 5` into mask `0xE0`, from board data we do not have |

Downstream's handler retries `OCP_ATTEMPT` times by toggling `OCP_CTL` bit 4
low then high, and after that **disables the IRQ and reports
`SND_JACK_OC_HPHL`**.

`RX_HPH_L_STATUS` (`0x1b3`) is **not** a PA status — r172 established it is an
MBHC plug-detection comparator, meaningful only with `MBHC_HPH` bit 1 asserted.
Do not press it into service here.

## 10. Expected idle state at the output

`CNP_EN` POR is `0x80`: bit 7 set, bits 5 and 4 (the two PA enables) clear. Our
board reads exactly `0x80` at baseline and has throughout every run since C2a.

So with the DAC powered and the PA off — the D1 state — **the HPHL pin is not
being driven by the PA.** The DC measurement in section 13 exists to confirm
that before any tone is allowed.

## 11. Does downstream assume a load?

**No.** Nothing in the codec driver, the class-H code or the PA path tests for
a load, an impedance or a plug before enabling the PA. The only load-related
mechanism is **OCP, which protects against over-current** — that is, against an
impedance that is too *low*, or a short.

A high-impedance scope probe is the **low-current** case, which is the safe
direction with respect to every protection downstream implements.

Two honest caveats:

- MBHC's `PRE_HPHL_PA_ON` handler switches the mic bias to VDDIO if micbias is
  off. That is jack-detection housekeeping, not a PA prerequisite, and our port
  has no resmgr notifier chain to run it. **C3a will not run it, and must say
  so** — the cost is that MBHC state is not informed, which matters for plug
  detection and not for driving the pin.
- Because the OCP limit comes from board data we do not have, `OCP_CTL` should
  be left at the value the codec already holds rather than programmed from a
  guess.

---

## 12. THE ONE OPEN DECISION: compander on or off for C3a

These two requirements pull against each other:

- **D1 was proven with compander 1 ON.** Reusing that state keeps C3a one step
  from a proven baseline.
- **"Minimum mapped gain" needs the register field to apply**, which requires
  `0x1ae` bit 5 **set** — and the compander's `PRE_PMU` **clears** it, handing
  gain to the compander instead.

With the compander on, the output level is compander-controlled and *not*
deterministically minimum. For a first electrical measurement that is the wrong
trade.

**Recommendation: run C3a with compander 1 OFF.**

- gain is then register-controlled and can be pinned at the minimum, `0x1ae[4:0] = 0x14`
- the pairing set is the probe default already in `reg_init_val` — `CNP_WG_CTL 0xDB`,
  `CNP_WG_TIME 0x58` (20 ms), `BIAS_WG_OCP 0x1A`, chopper off
- the PA settle becomes **13 ms**, the longer and gentler of the two
- the cost: it departs from the exact D1 state, so C3a must re-establish and
  re-verify the DAC path without the compander before enabling the PA

**DECIDED: COMP1 OFF.** C3a optimises for deterministic minimum analog
output rather than preserving D1's compander-on state. Sections 16 to 19 make
that concrete.

---

## 13. C3a, as it would be built

### Enable sequence

```
 0. pristine baseline; PA guard armed; 0x1ab & 0x30 == 00
 1. QDSP6 + SLIMbus up, RX1 digital chain, (compander per section 12)
 2. gain:      0x1ae[5]   <- 1        register-controlled
               0x1ae[4:0] <- 0x14     MINIMUM, chip-verified
 3. pop/click: CNP_WG_CTL, CNP_WG_TIME, BIAS_WG_OCP, CHOP_CTL
               to the set matching the compander state
 4. DSM mux 0x3b0 <- 0x14; RX bias 0x1a2[7]; class-H PRE_DAC
 5. FORCED 0x314 <- 0x03                     (unverifiable, journalled)
 6. FORCED 0x30d[1] <- 1                     (unverifiable, journalled)
 7. DAC:  0x1b1[6] <- 1, then 0x1b1[7] <- 1  chip-verified 0xC0
 8. ---- MEASURE DC AT THE HPHL PIN, PA STILL OFF ----
 9. PA:   0x1ab[5] <- 1                      chip-verified
10. usleep(pa_settle_time)
11. class-H POST_PA enable:
        BUCK_MODE_5 0x02<-00, NCP_STATIC 0x20<-00,
        BUCK_MODE_3 0x04<-04, BUCK_MODE_3 0x08<-08
12. ---- MEASURE DC AGAIN, THEN ALLOW THE TONE ----
13. bounded PCM run: 1 channel, 48 kHz S16_LE, low-amplitude sine
```

### Teardown sequence

```
14. stop PCM
15. PA:   0x1ab[5] <- 0                      chip-verified
16. usleep(pa_settle_time)
17. class-H POST_PA disable -> state_idle    (C2a-proven)
18. DAC:  0x1b1[7] <- 0, then 0x1b1[6] <- 0  chip-verified 0x00
19. FORCED 0x30d[1] <- 0                     mandatory inverse
20. class-H PRE_DAC unwind; DSM mux; RX bias release
21. FORCED 0x314 <- 0x00                     mandatory inverse
22. gain restored to its measured baseline
23. pop/click registers restored
24. RX1 / compander teardown; PA guard re-armed
```

### Safest initial gain

**`0x1ae[4:0] = 0x14` (decimal 20) with bit 5 set** — user-minimum, because the
control is inverted and the reset value is user-*maximum*.

### What constitutes PASS

**Electrical, on a scope, before any headphone is connected:**

1. **DC at the HPHL pin with the PA off** — recorded, and the reference for (2).
2. **DC with the PA on and no tone** — must be stable and within a small,
   pre-declared band of the codec's common-mode. A large or drifting DC offset
   is an **abort**, not a result.
3. **With the tone: a 1 kHz sine at the HPHL pin**, at the programmed frequency,
   amplitude consistent with minimum gain, and **disappearing when the tone
   stops while the PA stays on**.
4. Reproducible across two cycles.
5. `0x1ab & 0x30` returns to `0x00`; the full teardown verifies as in D1.

Point 3 is the milestone: a signal that follows the *digital* content proves
end-to-end conversion, which no register readback in this branch has been able
to establish.

### Stop and abort conditions

Any of these → immediate teardown, tone never enabled:

- `WCD9XXX_IRQ_HPH_PA_OCPL_FAULT` fires, **at any point**
- DC offset outside the declared band, or drifting
- `0x1ab` reads anything other than the expected value after the enable
- `0x1b1` is not `0xC0` before the PA step
- any HPHR, EAR, lineout or speaker register moves
- any new kernel `WARNING`/`BUG`
- the QDSP6 loop or SLIMbus stream faults
- the forced-write journal does not show its expected operations

### What each outcome would justify

| observed | justified claim | tag |
|---|---|---|
| PA register sequence completes, reverses, PA guard clean, **no waveform captured** | the PA control path is correct and reversible | **none** — a register result, same class as D1 |
| stable DC with PA on, no tone yet | the output stage powers without fault | **none** |
| **a sine at the HPHL pin tracking the digital content, twice** | end-to-end D/A conversion and analog output on this port | **`wcd9320-hphl-electrical-proven`** |
| audible in headphones | *not this milestone* | deferred |

> **Merely sequencing the PA registers correctly earns no tag.** That is the
> same kind of evidence D1 already provides, one stage further along. Only an
> observed waveform that follows the digital content changes the class of
> result — and even that is an *electrical* proof, not an audible one.

---

## 14. Boundaries carried forward from D1, unchanged

- `0x314` and `0x30d` remain **write-effect-unverifiable**. Forced forward
  **and** forced inverse writes, journalled. **No readback expectations are
  reintroduced for them, ever.**
- The PA guard stays armed through all mapping and build work, and is relaxed
  **only** at step 9, the one mapped PA-enable, and re-armed at step 24.
- HPHR, EAR, speaker and lineout remain off-limits and stay in the guarded set.
- `wcd9320-hphl-dac-path-proven` is **not** awarded and is not revisited here.

## 15. Deliberately not done

No code. No register written. No build staged. The decision in section 12 is
open and belongs to the operator, and nothing should be written until it is
made.


---

## 16. THE COMP1-OFF D1 PREREQUISITE SEQUENCE, EXPLICITLY

D1 was run with COMP1 on. C3a runs the same DAC path with COMP1 **off**, so
what changes has to be stated register by register rather than assumed to be
"the same minus the compander".

### What the driver requires, checked rather than assumed

`wcd9320_hphl_dac_path()` has **no `comp1_on` dependency**. The compander check
lives only inside `wcd9320_comp1_enable()`. Running the DAC path with COMP1 off
therefore needs **no driver surgery** — it is a gate sequencing change.

### What COMP1 was doing that now must be done explicitly

| what | with COMP1 on (D1) | with COMP1 off (C3a) |
|---|---|---|
| gain source `0x1ae[5]` | compander PRE_PMU **clears** it → compander-controlled | **must be set to 1 explicitly** |
| gain field `0x1ae[4:0]` | irrelevant, compander drives the level | **must be set to `0x14`, the minimum** |
| pop/click set | compander-ON half (`0xDA`/`0x15`/`0x2A`, chopper on) | **compander-OFF half** (`0xDB`/`0x58`/`0x1A`, chopper off) |
| PA settle | 3 ms | **13 ms** |
| `0x373` bit 7 | compander static gain offset | untouched |

> ### ⚠ AT A COLD-BOOT BASELINE, `0x1ae` READS `0x00`
>
> Bit 5 **clear** means the gain source is the **compander** — which will not be
> running. And the field reads `0`, which the inverted control makes
> **maximum**. So a pristine part is in the worst of both states for C3a.
>
> Downstream avoids this with `taiko_codec_reg_init_val[]`:
> `{TAIKO_A_RX_HPH_L_GAIN, 0x20, 0x20}` — *"Initialize gain registers to use
> register gain"*. **Our port has never applied that table.** C3a must do it
> itself, and must do it before the PA is enabled.

### The prerequisite sequence, in order

```
 P1  pristine baseline, PA guard armed, 0x1ab & 0x30 == 00
 P2  QDSP6 + SLIMbus up
 P3  RX1 digital chain on                       (unchanged from D1)
 P4  COMP1 deliberately NOT enabled             (the change)
 P5  gain source:  0x1ae mask 0x20 <- 0x20      chip-verified
 P6  gain field:   0x1ae mask 0x1f <- 0x14      chip-verified  MINIMUM
 P7  pop/click, compander-OFF half:
         CNP_WG_CTL   0x1ac <- 0xDB
         CNP_WG_TIME  0x1ad <- 0x58   (20 ms wavegen)
         BIAS_WG_OCP  0x1a9 <- 0x1A
         CHOP_CTL     0x1a5 mask 0x80 <- 0x00   (chopper off)
     each chip-verified; all four are ordinary verifiable registers
 P8  DSM mux 0x3b0 <- 0x14                      chip-verified
 P9  RX bias 0x1a2[7]                           refcounted
P10  class-H PRE_DAC                            C2a, unchanged
P11  FORCED 0x314 <- 0x03                       unverifiable, journalled
P12  FORCED 0x30d[1] <- 1                       unverifiable, journalled
P13  DAC 0x1b1[6] then [7]                      chip-verified == 0xC0
```

### The abort gate, before the PA is touched at all

**All of these must hold, or C3a aborts into teardown without ever writing
`0x1ab`:**

| | required |
|---|---|
| `0x1ae & 0x3f` | `0x34` — bit 5 set **and** field `0x14` |
| `0x1b1` | `0xC0` |
| `0x3b0` | `0x14` |
| `0x1a2[7]` | set |
| `0x320` class-H | `0xa7`, the C2a live value |
| `0x1ac`/`0x1ad`/`0x1a9` | `0xDB`/`0x58`/`0x1A` |
| `0x1a5[7]` | clear |
| QDSP6 / SLIMbus | stream running, no faults |
| `0x1ab & 0x30` | `0x00` |
| forced journal | `0x314` set and `0x30d` set both present |

The gain check is the one that matters most, and it is checked as a **field**,
not a whole register: `0x1ae` also carries bits this run does not own.

---

## 17. CLASS-H POST_PA: THE ENABLE, AND WHAT ITS INVERSE ACTUALLY IS

### The enable — four writes, baseline-relative

`wcd9xxx_clsh_enable_post_pa()`:

| # | register | addr | mask | value |
|---|---|---|---|---|
| 1 | `BUCK_MODE_5` | `0x185` | `0x02` | `0x00` |
| 2 | `NCP_STATIC` | `0x194` | `0x20` | `0x00` |
| 3 | `BUCK_MODE_3` | `0x183` | `0x04` | `0x04` |
| 4 | `BUCK_MODE_3` | `0x183` | `0x08` | `0x08` |

All four are inside the **fuse-loaded `0x180`–`0x1e4` range**, so expectations
must be **baseline-relative per bit** — measure each register before the PA
step and predict `(baseline & ~mask) | value`. Predicting whole-register values
here is the exact mistake C2a was caught by.

### The inverse — and it is NOT a reversal of those four writes

> **`wcd9xxx_clsh_turnoff_postpa()` does not touch any of them.**

```c
static void wcd9xxx_clsh_turnoff_postpa(struct snd_soc_codec *codec)
{
	const struct wcd9xxx_reg_mask_val reg_set[] = {
		{WCD9XXX_A_NCP_EN,          0x01, 0x00},
		{WCD9XXX_A_BUCK_MODE_1,     0x80, 0x00},
		{WCD9XXX_A_CDC_CLSH_B1_CTL, 0x10, 0x00},
	};
	wcd9xxx_chargepump_request(codec, false);
	for (...) snd_soc_update_bits(...);
	wcd9xxx_enable_clsh_block(codec, false);
}
```

Different registers entirely. So on the disable side,
`clsh_fsm(HPHL, DISABLE, POST_PA)` computes `state & ~HPHL` → `state_idle`,
which runs `comp_req(HPH_L, false)` then `turnoff_postpa()` — and
**`BUCK_MODE_5[1]`, `NCP_STATIC[5]` and `BUCK_MODE_3[2:3]` keep their post-PA
values.**

**They are PROGRAMMED state, not RESTORED state**, in exactly the sense the C2b
expectation model already uses for the compander configuration. C3a's gate must
classify them that way. **Reversing them would be inventing an inverse
downstream does not have**, which this branch does not do.

### Our C2a already implements the whole inverse

Checked line by line rather than assumed:

| downstream `state_idle(HPHL)` | our `wcd9320_clsh_hphl(false)` |
|---|---|
| `comp_req(HPH_L, false)` → `B1_CTL 0x08 <- 0` | ✅ `"comp req off"` |
| `chargepump_request(false)` → `CLK_OTHR_CTL 0x01 <- 0` | ✅ refcounted `"charge pump off"` |
| `NCP_EN 0x01 <- 0` | ✅ `wcd9320_clsh_off[0]` |
| `BUCK_MODE_1 0x80 <- 0` | ✅ `wcd9320_clsh_off[1]` |
| `CDC_CLSH_B1_CTL 0x10 <- 0` | ✅ `wcd9320_clsh_off[2]` |
| `enable_clsh_block(false)` → `B1_CTL 0x01 <- 0` | ✅ `"clsh block off"` |

**Complete, and in downstream's order.** It was proven 82/82 at C2a.

**But one thing about that proof changes in C3a, and it must be said.** C2a ran
`turnoff_postpa()` in a state where `enable_post_pa()` had never run. C3a is
the first time the NCP and buck are actually brought up by the post-PA writes
before it executes. The registers do not overlap, so the sequences are
independent — but the **expected post-teardown values differ from C2a's**,
because `BUCK_MODE_3`, `BUCK_MODE_5` and `NCP_STATIC` will hold their post-PA
values rather than their pre-PA ones. A gate reusing C2a's expectations
verbatim would fail a correct run.

---

## 18. THE PA GUARD BECOMES AN ALLOWED-STATE GUARD

It is **not removed** at any point. It changes from a constant to a
phase-dependent assertion on `0x1ab & 0x30`:

| phase | allowed | on violation |
|---|---|---|
| everything before the deliberate enable | `0x00` | abort into teardown |
| while HPHL is intentionally enabled | `0x20` **exactly** — bit 5 set, **bit 4 clear** | abort into teardown |
| after teardown | `0x00` | fail the run |

The middle phase is the new part and it is strict: **HPHR bit 4 must remain
clear**, so a mask that accidentally enabled both channels is caught rather
than passed. Sampled before and after every analog-affecting stage, read
bypassed, as it has been since C2a.

The guard's own "once tripped, stays tripped" behaviour is kept: a violation
disables the path for the rest of the boot.

---

## 19. WHAT REMAINS BEFORE CODE

Both prerequisites the operator named are now explicit:

- **the COMP1-off D1 prerequisite sequence** — section 16, P1–P13 with its
  abort gate;
- **the exact class-H POST_PA inverse** — section 17, including the finding
  that it is *not* a reversal of the four enable writes, and the confirmation
  that our C2a implements the real inverse completely.

Still to be settled by measurement, not by code:

1. The **DC band** that counts as acceptable at the HPHL pin. It has to be
   declared before the run, from the first PA-off measurement, so that
   "large or drifting" is a number rather than a judgement.
2. The **scope setup** — probe, ground reference and the pin itself. Nothing in
   software can check this, and an unverified probe point would make a null
   result meaningless.

Neither is a coding question, and C3a should not be written until the DC band
is agreed.


---

## 20. THE POST_PA PERSISTENT-CONFIG EXPECTATIONS, CONCRETE

All four POST_PA registers live inside the **fuse-loaded `0x180`–`0x1e4`
range**, so the header PORs are not trustworthy and are not used. The baselines
below are read from the recorded cold-boot map
([wcd9320-fullmap-20260815T154307Z.txt](wcd9320-fullmap-20260815T154307Z.txt),
`low_before`, taken after reset release and before any driver write).

| # | register | addr | **baseline** | mask | value | **PROGRAMMED** | changes? |
|---|---|---|---|---|---|---|---|
| 1 | `BUCK_MODE_5` | `0x185` | `00` | `0x02` | `0x00` | `00` | **no** |
| 2 | `NCP_STATIC` | `0x194` | `28` | `0x20` | `0x00` | **`08`** | **YES** |
| 3 | `BUCK_MODE_3` | `0x183` | `ce` | `0x04` | `0x04` | `ce` | **no** |
| 4 | `BUCK_MODE_3` | `0x183` | `ce` | `0x08` | `0x08` | `ce` | **no** |

> ### THREE OF THE FOUR POST_PA WRITES ARE NO-OPS ON THIS SILICON
>
> `BUCK_MODE_5` bit 1 is already clear, and `BUCK_MODE_3` bits 2 and 3 are
> already set, at cold boot. Only **`NCP_STATIC` `0x28 → 0x08`** actually
> changes anything.
>
> This matters twice over. First, the gate must predict `ce` and `00` for the
> unchanged ones — a gate expecting movement would fail a correct run, which is
> the C2a lesson exactly. Second, `regmap_update_bits()` **elides a write whose
> value is unchanged**, so three of these four transactions may never reach the
> bus at all. That is correct behaviour for configuration bits and must not be
> mistaken for a skipped step.

### These four stay PROGRAMMED through teardown

`wcd9xxx_clsh_turnoff_postpa()` touches `NCP_EN`, `BUCK_MODE_1[7]` and
`B1_CTL[4]` — **none of the four above**. So after the full C3a teardown:

| register | expected after teardown | why |
|---|---|---|
| `BUCK_MODE_5` `0x185` | `00` | unchanged throughout |
| `NCP_STATIC` `0x194` | **`08`, not `28`** | PROGRAMMED by POST_PA, never restored |
| `BUCK_MODE_3` `0x183` | `ce` | unchanged throughout |

**`NCP_STATIC` not returning to `0x28` is a PASS, not a failure.** Inventing an
inverse for it would depart from downstream, and this branch does not invent
inverses. It is the same classification the C2b model already applies to
compander configuration.

### The other C3a registers, baseline-relative

| register | addr | baseline | target | note |
|---|---|---|---|---|
| `RX_HPH_L_GAIN` | `0x1ae` | `00` | **`34`** | bit 5 set + field `0x14`; baseline is the worst case, see §16 |
| `RX_HPH_CNP_EN` | `0x1ab` | `80` | **`a0`** while on, `80` after | mask `0x30` is the guard |
| `CNP_WG_CTL` | `0x1ac` | **`da`** | `db` | |
| `CNP_WG_TIME` | `0x1ad` | **`15`** | `58` | |
| `BIAS_WG_OCP` | `0x1a9` | **`2a`** | `1a` | |
| `CHOP_CTL` | `0x1a5` | **`a4`** | `24` | bit 7 clear |
| `RX_HPH_OCP_CTL` | `0x1aa` | `69` | *left as found* | the limit is board data we do not have |

> ### THE PART COMES UP IN THE COMPANDER-**ON** POP/CLICK CONFIGURATION
>
> Measured `0x1ac`/`0x1ad`/`0x1a9` = `da`/`15`/`2a` and `0x1a5` bit 7 **set** —
> which is exactly `taiko_set_compander(COMPANDER_1, 1)`'s set: 5 ms wavegen,
> chopper on. These four are all fuse-loaded, so this is the silicon's own
> reset state and not something a driver did.
>
> Running COMP1 **off** against a compander-**on** pop/click configuration would
> be the mismatched pairing §7 warns about. **C3a must write all four**, and
> they are ordinary verifiable registers, so each one is chip-verified.

---

## 21. THE FROZEN PHYSICAL SETUP

**Probe — a TRRS breakout, never a bare probe inside the jack.**

| | |
|---|---|
| signal | HPHL / left-audio contact (**Tip**) |
| reference | the jack's **actual audio-ground contact** |
| verification | confirm the ground contact **on the breakout with a meter** before the run — do not rely on generic CTIA pinout assumptions |
| probe | **10×**, high impedance |
| load | **none** — no headphones |
| coupling | **DC-coupled** for the offset measurements |

**Ground safety.** If the scope is earth-referenced, the Lumia must be
**disconnected from USB and from its charger** before scope ground is attached.
An isolated or battery-powered scope, or a differential probe, is preferred.

> This has a consequence the gate must accommodate: with USB disconnected there
> is **no ssh**. C3a therefore cannot be driven interactively over the link
> while the probe is attached. The run must be startable and then complete on
> its own, with its evidence written to the phone and collected afterwards.

## 22. THE FROZEN DC CONTRACT

Measured at HPHL, DC-coupled, against the jack ground contact.

### Stage 1 — PA still OFF, full upstream and DAC path established

```
Voff = mean HPHL DC over 250 ms
precondition:  abs(Voff) <= 100 mV
```

Failing this **aborts before the PA is enabled**.

### Stage 2 — PA enabled by the mapped sequence, after the mapped 13 ms settle

```
Von = mean HPHL DC over 250 ms
require:  abs(Von - Voff)                  <= 50 mV
require:  DC drift across the 250 ms window <= 10 mV
```

### Hard abort, at any point in the run

```
abs(HPHL DC) >= 250 mV
```

> These are **conservative experimental safety limits, not claimed WCD9320
> datasheet limits.** The load-bearing comparison is `Von` **relative to the
> measured `Voff` baseline**, not either value against an absolute.

**Only after stage 2 passes may the tone run.**

## 23. THE FROZEN TONE PLAN

| | |
|---|---|
| channel | **HPHL only** |
| waveform | 1 kHz sine, deterministic |
| format | 48 kHz, **S16_LE**, 1 channel |
| duration | bounded ~1 second burst |
| start | **−40 dBFS** |
| ladder | if below the useful measurement floor, **−30 dBFS**, then **−20 dBFS maximum for C3a** |
| never | full scale |

Each amplitude step is a **declared** step: recorded in the evidence before it
is used, not chosen ad hoc while looking at the scope.

## 24. C3a PASS, RESTATED AGAINST THE FROZEN CONTRACT

All of the following, or it is not a pass:

1. A **repeatable waveform at HPHL whose frequency tracks the 1 kHz digital
   stimulus** — present during playback, **absent afterwards while the PA
   remains on**.
2. Across **two clean cycles**.
3. DC inside the declared band at every stage.
4. `0x1ab & 0x30`: `00` → `20` → `00`, with HPHR bit 4 clear throughout.
5. Complete teardown, with `NCP_STATIC` **expected at `08`** and the other three
   POST_PA registers unchanged.
6. Forced journal complete, both directions, both cycles.

**Correct PA register sequencing without a measured waveform earns no tag.**
Point 1 is the milestone; everything else is a precondition for believing it.

| observed | tag |
|---|---|
| PA sequences and reverses cleanly, no waveform | **none** |
| stable DC with the PA on, no tone yet | **none** |
| waveform tracking the stimulus, twice, DC in band | **`wcd9320-hphl-electrical-proven`** |
| audible in headphones | *not this milestone* |

---

## 25. STILL NOT DONE

No code. The mapping is complete and the contract is frozen; what remains
before C3a can be written is the one operational question §21 raises — how the
run is driven with USB disconnected — and that is a harness design point, not a
measurement or a mapping one.

> **§25 is answered by §26 and §27.** The harness question is settled and r175 is
> built. Nothing above this line changed.

---

## 26. THE HARNESS FACTS, ESTABLISHED ON HARDWARE

Five facts, measured on the device rather than assumed, that the C3a runner is
built on. They are written down here because code now depends on every one of
them and none is derivable from the source.

### 26.1 Detachment: `systemd-run`, not `nohup`

PID 1 is systemd, and logind kills the user session cgroup on logout.
**`nohup` and `setsid` both die with the ssh session** — tested, not assumed.
A transient unit survives:

```
sudo systemd-run --unit=wcd9320-c3a --collect sh <runner> detached
```

Being transient it also satisfies “explicitly armed, never a boot service”: it
exists only because someone armed it, and `--collect` makes it vanish when it
exits. Nothing is installed on disk and nothing runs at the next boot.

### 26.2 The input nodes move between boots

`eventN` numbering is **not stable** — the Synaptics touchscreen has already
re-ordered it once. Both devices are resolved **by NAME** from
`/proc/bus/input/devices` at arm time, on every arm, and the resolution is then
confirmed against the open descriptor with `EVIOCGNAME`. If either device is
missing the run **refuses to arm at all**.

An approve button that works alongside an abort button that does not is worse
than neither, because it looks armed.

### 26.3 Approve and abort are on DIFFERENT devices

| | device | key | code |
|---|---|---|---|
| approve | `gpio-keys` | `KEY_VOLUMEUP` | 115 |
| abort | `pm8941_resin` | `KEY_VOLUMEDOWN` | 114 |

Confirmed by real presses. That they are separate devices is not a detail: it
is what lets the abort watcher hold its own descriptor open for the whole run
while the approve gates open and close theirs.

### 26.4 `input_event` is 16 bytes here

`sec(4) usec(4) type(2) code(2) value(4)`, little endian. Presses are
`value == 1`; releases (0) and autorepeat (2) are ignored, so holding a button
is one decision rather than a stream of them.

> **`struct input_event` from the headers is NOT used.** On a build with a
> 64-bit `time_t` that struct is 24 bytes, and a reader using it would find
> `type` where `usec` is and conclude nothing was ever pressed — an interlock
> that silently never fires. Events are parsed from a byte buffer at fixed
> offsets, and a read that is not a whole number of 16-byte records is an error
> rather than something to resynchronise past.

### 26.5 The abort path is proven before anything arms

The runner **requires a live Volume-Down press at arm time**, read through the
same device, stride and key code the watcher will use. Until that press
happens nothing arms and no register is written. An interlock nobody has
pressed is an assumption, and it is the one assumption this run cannot carry.

---

## 27. r175 AS BUILT: `pa-rc1`

**Status: STAGED at pkgrel 175, `pa-rc1`. NOT YET BUILT, NOT YET RUN.**

### The order the work was done in

Artefact fences first, then the driver, then the helpers and their selftests,
then the runner. The fence for a capability has to exist before the capability
does, or the first thing it fences is a decision already taken.

### The driver

| | |
|---|---|
| `wcd9320_pa_guard_expect()` | the guard, with the expected value as an argument |
| `wcd9320_pa_guard()` | now a one-line wrapper passing `0` — every pre-r175 call site unchanged in meaning |
| `wcd9320_pa_prep()` | P5–P7: gain source, minimum mapped gain, the compander-OFF pop/click pairing, with the measured baseline recorded for the restore |
| `wcd9320_hphl_pa_path()` | steps 9–11 up, §8's real teardown down |
| `wcd9320_c3_abort()` | the whole mapped teardown as ONE idempotent operation |
| `enum wcd9320_gain_src` | `COMPANDER` (D1) and `REGISTER` (C3a) |
| `wcd->c3_lock` | serialises every C3 sysfs entry point |
| `hphl_pa_test` | `prep`, `pa-on`, `pa-off`, `unprep`, `abort` |
| `hphl_pa_state` | the C3a register set plus `INTR_STATUS2`, all read bypassed |

### D1's contract is intact, and that was a constraint not an accident

The COMP1 mode still requires `comp1_on`, and `dac-on` still selects it. C3a
adds a second mode rather than redefining the first, because r174's evidence
describes the COMPANDER path and swapping the prerequisite would have made a
proven result stop describing the shipping driver.

> **§16 said this needed no driver surgery. That was true of downstream and
> false of our port.** `wcd9320_hphl_dac_path()` opened with
> `if (!wcd->comp1_on || !wcd->rx1_digital_on) return -EAGAIN;` — our check,
> not `taiko`'s. The replacement is stronger than what it replaces: in register
> mode the path reads `0x1ae` back **from the chip** and refuses unless
> `& 0x3f == 0x34`, which verifies the hardware rather than a driver flag.

### Two observables the mapping did not have

`INTR_STATUS2` at `0x09a` carries `HPH_PA_OCPL_FAULT` (bit 0) and
**`HPH_L_PA_STARTUP` (bit 3)**. §9 reached for `0x1b3`, which r172 ruled out;
these are pollable directly, and bit 3 is the analog block reporting that the
left PA started rather than a readback of the bit we wrote.

**Sampled at every stage boundary, with the boundary stated in advance the way
r172's was:** a channel-specific startup indication is useful positive
corroboration; **no indication is not evidence of failure** — these sources are
masked and whether the status bits assert while masked is not established; an
OCP fault is a hard abort. The IRQ mask configuration is **not changed** to
find out, because `wcd9320-irq-parent-idle-validated` certifies it.

### The PA fence, section 5d of the artefact gate

`0x1ab` goes from **0 write sites to exactly 2**, and the relaxation is bounded
five ways:

1. exactly two write sites, by count;
2. both masked to `WCD9320_HPH_PA_HPHL` alone — `0x30` may never appear as a
   write mask, and `WCD9320_HPH_PA_HPHR` in no write at all;
3. both inside `wcd9320_hphl_pa_path()`;
4. the guard compares for **equality**, so the allowed set is exactly
   `{00, 20}` — a subset test would accept `0x30` while expecting `0x20`;
5. D1's contract asserted unchanged.

Plus: the four POST_PA writes present with their exact masks and values, **no
inverse for any of them**, the abort composing the mapped steps in order with
no early return, the C3 lock balanced and taken by all three stores, and the
IRQ mask untouched.

**Dry-run against the staged patch: every check in 5d passes.**

### The helpers

| | |
|---|---|
| `input-gate` | resolves by name, confirms with `EVIOCGNAME`, proves the abort path at arm time, runs the independent watcher. **Every ambiguous outcome returns non-approve**: timeout, setup error, busy, unknown code. |
| `pcm-tone` | 1 kHz, 48 kHz S16_LE mono, 250 ms tone/silence/tone/silence in **one uninterrupted stream**, −40 dBFS, with a **compiled −20 dBFS ceiling** checked before the device is opened. It cannot emit a ramp or full scale at all. |

`pcm-run-measured` is **not** used: it writes `(i * 37) & 0x7fff`, a full-scale
sawtooth with no declared frequency, which is the one thing §23 says never.

> **Why tone/silence/tone/silence in one stream rather than PCM start/stop.**
> An output that appeared and disappeared with the stream could be explained by
> the stream machinery, the SLIMbus port, the DSP or the codec's own clock
> gating — none of which is conversion. Here the stream, the routing, the PA
> and every register stay unchanged for the whole second, and only the sample
> values change. At 48 kHz a 250 ms segment is exactly 250 whole cycles of
> 1 kHz, so every burst begins and ends on a rising zero crossing and the
> segment boundaries contribute no step of their own.

### Four independent things make the run safe

1. an **independent abort watcher**, started before the first hardware change
   and alive until the final teardown — the approve gates are blind between
   calls and it is not;
2. a **transient systemd fail-safe timer**, armed at the PA-enable boundary,
   re-armed at each hold taken with the PA live, and cancelled **only** on a
   chip-verified reading of both PA bits clear;
3. the driver's teardown is **one idempotent operation under a state lock**, so
   a normal teardown and an emergency abort cannot interleave;
4. the PA guard is **never disabled**, only made phase-dependent.

The hold limits are deliberately not one number: **10 minutes** with the PA off
(scope setup takes as long as it takes), **120 seconds** for each hold taken
with the PA live, and every expiry is a teardown.

### Offline verification, all passing before any hardware

| | |
|---|---|
| `wcd9320-hphl-pa-selftest.sh` | **96 passed, 0 failed** |
| `c3a-helper-audit.py --selftest` | **19 cases, 16 of which must be rejected, 0 wrong** |
| `wcd9320-sh-scope-lint.py` | clean on all five new shell files |
| artefact gate section 5d | every check passes against the staged patch |

The selftest covers the derivation against the measured cold-boot baseline and
against a hostile one with every fuse-loaded register inverted; the §20 no-op
predictions; the forced-write journal with a missing inverse, an inverse issued
as a set, a wrong register, a masked `0x314` and a truncated cycle all caught;
**every input-gate exit code resolving to abort except 0**; the ssh-detachment
form; and, against the real binary, key renumbering across two boots, a missing
abort device, a prefix name that must not match, and a refused double arm.

### Two defects found offline, both in checkers

1. The scope lint caught `pa_derive()` and `pa_apply()` both assigning `_b`. It
   works today only because every call is inside `$( )`, which runs in a
   subshell — correctness by accident of the call site, the exact shape of the
   `_n` bug that cost this project a hardware run.
2. The helper audit rejected a correct `input-gate`, twice, because it checked
   for things that are **string literals** in source it had already stripped
   literals from. Fixed with a third view of the source — comments removed,
   literals kept — and a selftest case in each direction.

Both were verified by hand before being acted on. Neither was in the code under
test, which is the fourth and fifth time on this project.

### One standing mystery retired

The artefact gate carried a note about a “constant offset of 2 between source
call sites and artefact relocations”, stable since r167 and unexplained. It is
the **two places the comments name `regmap_read_bypassed()` in prose**, which a
bare `grep -c` counted as calls. Counting calls instead of mentions:
`83` real sites, `2` prose, `85` bare. The expectation is now `83 + 7 = 90` and
the subtraction is gone.

### What is still NOT done

**No build, no flash, no run.** No register has been written on hardware. The
DC band still has to be measured before the tone is ever allowed, and the probe
point still has to be confirmed with a meter, both per §21 and §22.

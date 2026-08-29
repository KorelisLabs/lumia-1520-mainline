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

# WCD9320 audio bring-up — handoff

State as of 2026-08-15. Everything is on GitHub unless marked otherwise.

## Where things are

| | |
|---|---|
| public repo | `KorelisLabs/lumia-1520-mainline` |
| `main` | `fabe7e2` — the audio foundation is merged and published |
| working branch | `research/audio-wcd9320-core-init`, pushed; latest tag **`wcd9320-coldboot-autoload-proven`** |
| pmaports | `~/.local/var/pmbootstrap/cache_git/pmaports`, same branch under `device/testing/linux-postmarketos-qcom-msm8974` — **local only**, origin is upstream postmarketOS and is not writable |
| driver patch | `patches/0002-slimbus-wcd9320-codec-core.patch` — the durable copy |
| driver source | `~/corepatch/new/drivers/slimbus/wcd9320-core.c` (WSL, not in git) |
| pkgrel | **142 built, verified, and run on hardware** |
| last built module | `fullmap-rc7` (r142) |
| running on the phone | `fullmap-rc7` (r142), autoloaded from `/lib/modules` |

**The scratchpad does not survive a session.** Only `~/corepatch`, pmaports
and this repo do. Regenerate build scripts from the patterns below.

## Proven on hardware

Tags, each with an evidence log in this directory:

- `wcd9320-regmap-readonly-proven`
- `wcd9320-core-bringup-proven`
- `wcd9320-dual-function-proven`
- `wcd9320-irq-parent-idle-validated` — TLMM 72 edge-rising, idle
- `wcd9320-cdc-rco-wake-proven` — CDC core accessible, **no external MCLK**
- `wcd9320-core-init-proven` (`1b18fe7`) — automatic idempotent init:
  cold boot 24/24, adoption 26/26
- **`wcd9320-irq-proven`** — one physical headset insertion through the
  whole chain: MBHC_JACK_SWITCH → GPIO 72 → regmap-irq → nested handler →
  ack → status clear → quiescence. 27/27, three writes to `0x14a`.
- **`wcd9320-coldboot-autoload-proven`** — the driver autoloads from
  `/lib/modules` on a cold restart with no manual insertion available,
  31/31, and the IRQ chain re-proven from that boot, 27/27.

Untagged but validated:

- `core-init-rc1` regression — stage split is behaviour-neutral
- **nested IRQ idle proof, 16/16** (`9544c1d`) — chip registers 29 sources all
  masked on parent irq 87, `/proc/interrupts` shows **0** assertions against
  `msmgpio 72 Edge`, masks `ff ff 3f 7f`, codec health untouched

## The two findings that matter

**1. The dark `0x200`–`0x3bf` region was never an MCLK problem.** The digital
core was held in reset because this port never ran `wcd9xxx_bring_up()` — four
writes downstream performs at `wcd9xxx-core.c:468`, before it even reads the
chip id. It survived every earlier milestone because identity, revision,
regmap and dual-function were all **read-only**.

**2. The core release does the work, not the clock.** Three-stage snapshots:
`0 → 94 → 95` non-zero. The RCO sequence changes **exactly one register in
448** — `0x311`, the gate bit it writes itself. All 16 registers differing
from `__POR` are already at final values after the core release, so they are
reset-state values for this die (consistent with revision-dependent defaults
for minor `0x0001`). See `wcd9320-core-release-vs-clock.md`.

Consequence: `reg_defaults` can be built from the **measured** stage-2 dump —
but only for `0x200`–`0x3bf`, which is what the sentinel covers. **Updated
2026-08-15:** volatility is no longer unmeasured, and that is no longer the
reason `REGCACHE_NONE` stays. It is measured for the MBHC path only, the
analog-region reset state is unattributed, and both reasons are set out in
`wcd9320-volatility-and-defaults.md` below.

## Full-map capture closes the defaults gap — `wcd9320-reg-defaults.md`

**2026-08-15, `wcd9320-fullmap-20260815T154307Z.txt`, 16/16, fresh path.**
`fullmap-rc7` snapshots `0x000`-`0x1ff` at the same three moments as the
sentinel, giving the complete 1024-register map at each stage of core init.

| class | count |
|---|---|
| `matches-por` | 424 |
| `volatile` | 379 |
| `unresolved` (undocumented holes, all zero) | 163 |
| `reset-default` | 50 |
| `driver-write` | 7 |
| `hw-side-effect` | 1 |

**The 27 analog mismatches are attributable.** Each reads identically at
pre-init, after core release and after RCO — stable from reset, never written
by us, differing from `__POR`. Revision-dependent defaults for this die.

**`0x1fd RC_OSC_TUNER` resolved, and not as predicted.** It was already `14` at
reset, so the RCO sequence did not populate it from nothing; but it moved
`14 → 15` with no write from us. Hardware side effect — excluded from defaults
and **must be added to `volatile_reg`**. It is the one place this hardware
contradicts `taiko_volatile()`.

**Eligible for `reg_defaults`: 474**, of which **229 non-zero**. Nothing
hardware-populated, volatile or unresolved is in that set. The 7 driver-write
registers all read their documented `__POR` at pre-init, so they could be
included at that value — a judgement call, not a gap.

**Remaining before `cache_type` changes** — implementation, not evidence: add
`0x1fd` to `volatile_reg`; add `readable_reg` limited to the 673 documented
addresses so the 163 holes are never touched; build the 229-entry table; decide
on the 7.

## Volatility measured; the cache stays off — `wcd9320-volatility-and-defaults.md`

**2026-08-15, `wcd9320-volatility-20260815T150932Z.txt`.** Six full
1024-register snapshots across idle, detection enable, a physical insertion, a
removal, and detection disable. Four writes, all to `0x14a`, all logged.

| bucket | count |
|---|---|
| observed volatile, downstream agrees | **1** (`0x14b`) |
| observed volatile, downstream does **not** mark | **0** |
| downstream volatile, never exercised by this test | **378** |

`taiko_volatile()` marks 379 of 1024 volatile (37%); 645 cacheable, 237 of
those non-zero, 57 differing from documented `__POR` — of which 6 are this
driver's own rco-wake writes.

**Hardware finding: a masked source does not latch.** `INTR_STATUS`
(`0x098`–`0x09b`) read `00 00 00 00` in all six snapshots across a real
insertion and removal with all 29 sources masked. Masking gates the status
latch itself, not just the interrupt output — which also explains why the first
IRQ acceptance attempt saw `INTR_STATUS` flat while `0x14b` moved. It equally
means this test never exercised those registers; they stay volatile on
downstream's `reg < 0x100` and on regmap-irq having demonstrably dispatched,
not on measurement.

**`REGCACHE_NONE` stays.** Not caution — three specific reasons: the volatile
predicate is verified on 1 register of 379; 28 candidate defaults in the analog
region are unattributed because no snapshot exists between reset release and
core init; and with no ASoC or DAI yet the cache would optimise an access
pattern that does not exist while adding a stale-read failure mode to a stack
whose interrupt path depends on uncached reads below `0x100`.

**What would settle it:** extend `sentinel_before` from 448 registers to all
1024. The driver already captures it between reset release and core init, so
one change attributes all 28 analog differences, shows whether `0x1fd`
`RC_OSC_TUNER` is hardware-populated by the RCO sequence, and yields defensible
defaults for the whole cacheable set.

## STEP 4/5 COMPLETE — `wcd9320-irq-proven`

**2026-08-13, `wcd9320-irq-acceptance-20260813T220429Z.txt`, PASS 27/0.**

One physical headset insertion, minimum configuration, whole chain:

| stage | `0x14a` | present | mask | status | parent | child |
|---|---|---|---|---|---|---|
| S0 baseline | `00` | 1 | `ff ff 3f 7f` | `00 00 00 00` | 4 | 0 |
| S1 detection on | `6f` | 1 | `ff ff 3f 7f` | `00 00 00 00` | 4 | 0 |
| S2 armed | `6f` | 1 | **`ff ff 3f 6f`** | `00 00 00 00` | 4 | 4 |
| **S3 inserted** | `6f` | **0** | `ff ff 3f 6f` | `00 00 00 00` | **5** | **5** |
| S4 +5 s | `6f` | - | `ff ff 3f 6f` | `00 00 00 00` | 5 | 5 |
| S5 disarmed | `6f` | - | `ff ff 3f 7f` | - | - | - |
| S6 detection off | `00` | - | `ff ff 3f 7f` | `00 00 00 00` | - | - |

Exactly **+1** parent edge, **+1** nested dispatch, post-ack status
`00 00 00 00`, zero quiescence drift, all 29 sources masked again, `0x14a`
back to reset, no manual recovery. No WARNING, BUG, `nobody cared`, spurious
or regulator complaint. Codec health identical to every prior run.

**The source is `MBHC_JACK_SWITCH` (26), not `MBHC_INSERTION`.** The first
acceptance attempt armed INSERTION and got a clean physical transition with
`INTR_STATUS` still `00 00 00 00` - insert detection does not feed that
source. Downstream's `insert_detect` branch requests
`WCD9320_IRQ_MBHC_JACK_SWITCH`, handled by `wcd9xxx_mech_plug_detect_irq`;
INSERTION belongs to the headset-type state machine that runs afterwards and
is disabled immediately after being requested.

**Total configuration: three writes to one register** (`0x14a`), every value
sourced. No micbias, no `MBHC_EN_CTL`, no MBHC clock, no `HPHL_10K_SW`.

One artifact in that evidence file, corrected here rather than edited out of
it: the `assertions before the event 4` line is not a measurement.
`/proc/interrupts` has no child line until the source is armed, so S1 always
reads 0 and S1->S2 records the counter appearing rather than assertions. The
counter is cumulative for the boot; this run's own delta is the `+1` the gate
used. The script no longer prints that line.

### What this tag does NOT cover

The module was **hand-inserted from `/tmp`**, because
`/lib/modules/.../wcd9320.ko` was **zero bytes** (`e3b0c442...`, the SHA-256 of
an empty file). An empty ELF is rejected early enough to log nothing, which is
the silent `EINVAL`, and it explains why loading from `/tmp` always worked.

**RESOLVED 2026-08-14** — see `wcd9320-coldboot-autoload-proven` below and
`wcd9320-zero-byte-module.md`. Two guesses written here at the time were wrong:
rootfs truncation was **not** the cause (the filesystem measured `clean`, and
the `mounting unchecked fs` warning is about `/boot`, a journal-less ext2
filesystem where it is routine), and neither was zstd decompression. It was a
single zero-length write at install time; the mechanism remains unproven and is
recorded as such.

This tag's scope is unchanged and remains accurate: it asserts the interrupt
chain from a hand-inserted module, and nothing about cold boot.

## COLD BOOT + AUTOLOAD COMPLETE — `wcd9320-coldboot-autoload-proven`

**2026-08-14, `wcd9320-coldboot-autoload-20260814T225740Z.txt`, PASS 31/0**, and
the IRQ chain re-proven from that boot in
`wcd9320-irq-acceptance-20260814T230022Z.txt`, **PASS 27/0**.

This is what `wcd9320-irq-proven` deferred. That tag was earned with the module
hand-inserted from `/tmp`; this one shows the driver comes up on its own.

| gate | measured |
|---|---|
| autoload | `mbhc-switch-rc6`, first driver line **48 s into the boot** |
| no fallback | **no `wcd9320.ko` anywhere outside `/lib/modules`** |
| module integrity | 53264 bytes, sha `c4c772fb…` = the built artefact |
| cold codec | `path=fresh`, `adopted=0`, `power_owned=1`, `nonzero_before=0` |
| core init | ran once, `0 → 94 → 95`, canary `e4`, `core_ready=1` |
| identity | major `0x0102` minor `0x0001`, 0 failures, no stale bus state |
| nested chip | registered, `msmgpio 72`, parent count 0 |
| masks | `ff ff 3f 7f`, nothing asserted |
| errors | `WARNING:`/`BUG:` 0, `_regulator_put` 0, nobody-cared 0, SLIMbus 0 |

Then, from that same autoloaded module, one physical insertion: `0x14b` bit 2
`1 → 0`, parent **+1**, child **+1**, `irq_count=1`, post-ack `00 00 00 00`, no
quiescence drift, everything re-masked and `0x14a` restored. Counters started at
zero for that boot, so the deltas are unambiguous.

### What "cold boot" means here, precisely

There is no state where this SoC is unpowered and reachable — powering off
lands at the Windows boot screen. And the port is **RAM-boot by design**:
`fastboot boot` each time, nothing Android-bootable flashed, so the Windows
chain stays intact (`docs/boot-chain.md`). A cold start is therefore: power off,
restart into the bootloader, `fastboot boot` the matching image.

That exercises the entire autoload path — initramfs, root mount, systemd, udev,
`modprobe`, `/lib/modules` — and skips only fetching the kernel from flash,
which this port never does. **The tag does not claim a flash boot.** Rather than
argue about how cold the restart was, the run measures it: `path=fresh` with
`nonzero_before=0` is the codec's own report that it came up dark.

### The zero-byte module

Root cause written up in `wcd9320-zero-byte-module.md`. In short: the module in
`/lib/modules` was zero bytes, an empty file is not an ELF, and the loader
rejects it early enough to log nothing — hence a silent `EINVAL` that hand-
loading from `/tmp` always sidestepped. The rootfs was **clean**; no repair was
needed or run. Two earlier explanations in this handoff (a zstd decompression
problem, and "autoload is fixed") were wrong and are corrected there.

The mechanism of the single zero-length write is **unproven** and recorded as
such. The durable fix is that install is now verified by size and sha256 against
the built artefact, and the cold-boot gate additionally requires that no module
exists outside `/lib/modules` to mask the fault.

## Superseded: the road to step 4

### What two hardware runs established

**rc1 (r136): FAIL 13/18, inconclusive.** MBHC_INSERTION armed on child virq
88, headset inserted, nothing fired. But with no interrupt there was no handler
line, and every live fact about the mask came from that line — so the run could
not separate "the codec never asserted" from "the unmask never reached the
chip", and the second would have made the whole test vacuous.

**rc2 (r137): FAIL 17/21, and the ambiguity is gone.** `irq_live` reads
INTR_STATUS and INTR_MASK off the chip on demand, so the arming half is
measured before the event window opens:

| check | measured |
|---|---|
| masks quiet before arming | `ff ff 3f 7f` |
| nothing asserted before arming | `00 00 00 00` |
| armed mask (live) | **`bf ff 3f 7f`** — INTR_REG0 bit 6 clear, 28 still set |
| re-masked after disarm (live) | `ff ff 3f 7f` |

So regmap-irq's unmask **does** reach the chip and `free_irq` re-masks it. The
arm/disarm mechanism is proven at the register level.

**And that makes the negative a result:** with the source verifiably unmasked,
live status stayed `00 00 00 00` across an insertion. The WCD9320 does not
assert MBHC_INSERTION with the MBHC block unconfigured — measured, not
inferred. The four remaining FAILs are all the same fact, that no event
occurred.

Evidence files, both **FAIL verdicts** and both worth keeping:
`wcd9320-mbhc-irq-20260812T212820Z.txt` (rc1) and
`...T222527Z.txt` (rc2). The one line that separates them is
`armed mask (live)`: `got=` empty in rc1, `bf ff 3f 7f` in rc2.

### Where the proof stands

- Chain proven: enumeration → regmap → nested chip → mask/unmask → parent idle
- Stimulus proven: three writes to `0x14a` make a physical event visible
- Chain unproven: **dispatch**. Nothing has yet travelled codec → parent → ack.
- Nothing now blocks the acceptance run.

### rc3 (r138) RESULT: NO STIMULUS — conclusive negative, 13/13 valid

**2026-08-12, `wcd9320-mbhc-group-20260812T230939Z.txt`.** All seven MBHC
sources armed and verified unmasked (`81 ff 3f 6f` read live off the chip),
seven named children in `/proc/interrupts`, a physical insertion **and** a
removal, 20 s each. Every counter stayed at 0. Live status never left
`00 00 00 00`. Masks restored to `ff ff 3f 7f` on disarm. Codec healthy
throughout, no warnings, no spurious.

**The WCD9320 raises no MBHC interrupt at all until the MBHC block is
configured.** Every run-validity check passed, so this is a measurement, not a
failed experiment.

Per the settled bar, the answer is **minimal MBHC programming**, not a
driver-triggered source.

### Autoload: NOT fixed — that claim was wrong

r138 probed at t=47.8 s, boot time, and this was written up as autoload having
been restored by installing a plain `.ko`.

**r139 disproved it.** Identical arrangement — uncompressed `.ko` in
`/lib/modules`, sha-verified on the phone, `depmod -a` run — and it did not
autoload. Four minutes up, both SLIMbus functions enumerated, no module. A
manual `modprobe` then failed with the same silent `EINVAL`.

So r138's boot-time load was not proof of a fix; it was one success in a
pattern nobody has explained yet. See the `EINVAL` trap below. Nothing may
claim cold-boot behaviour until this is understood.

### rc5 (r140) RESULT: **PASS 17/17** — minimal insert detection works

**2026-08-13, `wcd9320-mbhc-detect-20260813T205339Z.txt`.** The step's
acceptance — *physical insertion/removal → reproducible status transition* — is
met.

| state | `0x14b` | present bit |
|---|---|---|
| detection off | `0e` | 1 |
| detection on, no jack | `04` | 1 |
| **headset inserted** | `0b` | **0** |
| **headset removed** | `04` | **1** |

Removal returned it to exactly the pre-insertion value. Polled every second, so
the sequence `1 0` then `0 1` is the measured transition, not two endpoints.

**What was written: three writes, one register, nothing else.**

```
write 1  0x14a mask=01 old=00 want=00 -> 00   disable first ("avoid glitch")
write 2  0x14a mask=ff old=00 want=6e -> 6e   0x6C | BIT(1), set up for insertion
write 3  0x14a mask=01 old=6e want=6f -> 6f   re-enable
restore  0x14a mask=ff old=6f want=00 -> 00   back to reset
```

Every value sourced from downstream `wcd9xxx_insert_detect_setup()`; bit 2 of
`0x14b` as the presence bit from `wcd9xxx_swch_level_remove()`. **No micbias, no
`MBHC_EN_CTL`, no MBHC clock** — none of it was needed, which is why measuring
first was worth the extra build.

**Side effects: none in `0x3c0`–`0x3ff`.** Zero bytes changed across all four
transitions, so nothing in the MBHC block moved that we did not write. The only
register that moved at all is `0x14b`, which is the status register and the
point of the exercise.

All 29 interrupt sources stayed masked at `ff ff 3f 7f` before, during and
after. Nothing was armed.

**The stimulus question is now answered, and IRQ arming is unblocked.**

### rc4 (r139) RESULT: NO SIGNAL — detection is off, 12/12 valid

**2026-08-12, `wcd9320-mbhc-probe-20260812T234415Z.txt`.** Read-only. Nothing
written.

| register | baseline | inserted | removed |
|---|---|---|---|
| `0x14b` MBHC_INSERT_DET_STATUS | `0e` | `0e` | `0e` |
| `0x1b3` RX_HPH_L_STATUS | `04` | `04` | `04` |
| `0x1b9` RX_HPH_R_STATUS | `04` | `04` | `04` |
| `0x3c0`–`0x3ff`, 64 registers | 15 non-zero | 15 non-zero | 15 non-zero |

Zero bytes changed in either direction. `insert_det` was polled every second
through both windows, so a transient that settled back would have been caught;
only `0e` was ever seen. RC oscillator alive at `0x18`, so detection's clock
was running and the probe was measuring the right thing.

**Detection is off, not merely ungated.** Micbias and the comparator have to be
brought up before any physical event can be detected at all. That is the larger
of the two possible writes, and this run is why it is necessary rather than
assumed.

### The MBHC block baseline — first read on this hardware

The CDC sentinel stops at `0x3bf`, so `0x3c0`–`0x3ff` had never been read.
15 of 64 non-zero, in five clusters:

| run | registers | values |
|---|---|---|
| `0x3c2`–`0x3c8` | 7 | `06 03 09 1e 45 04 78` |
| `0x3ce`–`0x3cf` | 2 | `c0 5d` |
| `0x3d6`–`0x3d9` | 4 | `ff 07 ff 7f` |
| `0x3db` | 1 | `80` |
| `0x3eb` | 1 | `40` |

This is the state any minimal MBHC configuration starts from, and the baseline
every future MBHC diff is against. It is also consistent with the count of
non-zero-`__POR` registers `wcd9320-register-map.md` predicted for this range.

### rc4 design notes — measure before writing

`wcd9320-register-map.md` already carries the lead, from the 2026-07-31 dump:

| addr | register | `__POR` | read |
|---|---|---|---|
| `0x14b` | `MBHC_INSERT_DET_STATUS` | `00` | **`0e`** |

That register is in the **readable analog** region, outside the dark block, and
was recorded then as reflecting real analog state. The same doc notes MBHC at
`0x3c0`–`0x3ff` reads its defaults correctly *because headset detection is
designed to run off the RC oscillator* — which core init already starts.

So the question "what is the minimum configuration necessary" has a cheaper
prior question, answerable **without writing a single register**:

> Does `MBHC_INSERT_DET_STATUS` (and the MBHC block at `0x3c0`–`0x3ff`) change
> when a headset is physically inserted?

- **If it tracks the jack**, the comparator already works unconfigured and only
  the detection→interrupt path is missing. The minimum configuration is then
  whichever enable gates that path — a small, well-targeted write.
- **If nothing moves**, detection itself is off, and micbias plus the comparator
  have to come up first.

Those are materially different amounts of writing to an analog block this port
has never touched, so measure first. rc4 should be a **read-only** poll of
`0x14b` plus a dump of `0x3c0`–`0x3ff` across an insertion and a removal —
neither is in the sentinel range (`0x200`–`0x3bf`), so neither has ever been
read on this hardware.

### rc3 design notes — `476d468`, pkgrel 138

`arm-group` arms all seven MBHC sources at once, to find out whether the codec
raises *anything* unconfigured. `MBHC_JACK_SWITCH` is the candidate worth the
run: on this family it reflects a mechanical contact in the jack rather than
the detection block, so it may assert with no setup at all.

A correctly armed group reads back **`81 ff 3f 6f`** and the script asserts it.
Each source gets its own dev_id and irqname, so the handler names which source
fired and `/proc/interrupts` shows seven named child lines.

`tools/wcd9320-mbhc-group-evidence.sh` is a **diagnostic, not the gate** — the
acceptance script stays single-source. Its exits: 0 a stimulus exists, 1 valid
run and nothing fired (a conclusive negative, not a driver fault), 2 the run
did not hold up.

If nothing fires, the remaining routes are to program MBHC insert detection, or
to use a driver-triggerable source such as MICBIAS precharge — which
reinterprets what "one physical event" means and should be decided deliberately.

Build script: `~/build-mbhc-irq-rc3.sh` (WSL, survives sessions).

### Exact next actions

1. Commit `wcd9320-mbhc-detect-20260813T205339Z.txt`.
2. **The acceptance run.** Enable insert detection (`echo on >
   mbhc_detect`), arm MBHC_INSERTION alone, then one physical insertion.
   Both halves now exist: a source that asserts, and an arm/disarm
   mechanism proven at the register level.
3. If it passes the bar — finite sequence, status cleared after ack,
   quiescence on both parent and child, no manual recovery — tag
   `wcd9320-irq-proven`.
4. Then the cold-boot regression and the silent-EINVAL investigation,
   before anything builds on the module path.

### The acceptance bar — settled 2026-08-12

> One literal physical headset event, using the minimum hardware configuration
> necessary, causes one known WCD9320 MBHC interrupt source to assert,
> propagate through GPIO 72 and regmap-irq, execute its nested Linux handler,
> ACK successfully, clear its status, and return to a quiescent masked/idle
> state without warnings or repeated assertions.

A source that fires and stays asserted is a FAIL, not a partial pass. The
single-source acceptance script splits this into: status cleared after ack
(live, from the handler's own post-ack line), quiescence resampled 5 s later on
both parent and child, and ≤20 assertions.

**A driver-triggered source is explicitly ruled out.** MICBIAS precharge and
friends would demonstrate the internal IRQ machinery, but the whole point of
this milestone is that a real external event enters *through the codec*.
Proving it synthetically would weaken what `wcd9320-irq-proven` means. If the
group diagnostic comes back empty, the answer is minimal MBHC programming —
the least configuration that makes a physical event detectable — not an easier
stimulus.

"Minimum hardware configuration necessary" is load-bearing in both directions:
enough to make the event detectable, and no more, so that what is proven stays
the interrupt path rather than a pile of setup.

Only after that passes: tag `wcd9320-irq-proven`. **The group diagnostic cannot
earn the tag** — it only finds a stimulus for the run that can. If it does find
one, go straight back to single-source and run the real proof.

## Superseded: step 4 rc1 build details

`ab12c71` adds `mbhc-irq-rc1`: a research hook arming exactly one source,
`WCD9320_IRQ_MBHC_INSERTION`, plus `tools/wcd9320-mbhc-irq-evidence.sh`.

Requesting the child IRQ is the whole mechanism — regmap-irq unmasks on
request, re-masks on free — so no mask register is touched by hand.

### Build: DONE, verified by artifact

r136 is built and staged. Verified, not assumed:

- `linux-postmarketos-qcom-msm8974-6.16.12-r136.apk` exists, and the
  `wcd9320.ko.zst` inside it reports `version=mbhc-irq-rc1`, with `strings`
  finding both `mbhc test: ARMED` and `nested irq chip registered`.
- `check-modpost.sh` clean.
- pmaports patch is byte-identical to `patches/0002-...`, and its sha512
  matches the APKBUILD entry **in position** (`source=` order is config,
  dtsi, rm940.dts, 0001, 0003, 0002).
- `boot-1520-mbhc-irq-rc1.img` carries the known-good cmdline UUIDs and is
  byte-identical to the built `boot.img` apart from the cmdline field.

### The harness bug found before the run was spent — `aa6feac`

Two of the gate's checks could not fail. Both read `irq_observe`, and neither
field is live: `last_status` is written only by the bounded sampler, which
finished during probe with everything masked, and `mask_readback` is written
exactly once at IRQ setup, right after the driver masks everything. They are
frozen at `00 00 00 00` and `ff ff 3f 7f`.

So "status cleared after ack" and "re-masked after disarm" — the two checks
carrying the acceptance bar — would have passed a stuck source, which is
precisely the failure a separate write-1-to-clear register produces.

Both now come from the handler's own live post-ack log line, and the run
gained a real check for "exactly one source armed": the live mask while armed
must read `bf ff 3f 7f`. The evidence file was also never actually written;
it is now, the cold-boot way.

## Build and test loop

Scripts in `tools/`: `wcd9320-coldboot-evidence.sh`,
`wcd9320-adoption-evidence.sh`, `wcd9320-nested-idle-evidence.sh`,
`wcd9320-mbhc-irq-evidence.sh`, `wcd9320-evidence-lib.sh`,
`wcd9320-evidence-selftest.sh` (offline, 12 cases),
`wcd9320-attribute-stages.py`, `check-modpost.sh`, `patch-cmdline.py`.

Every run gates on `/sys/module/wcd9320/version` and writes **no evidence file
at all** on mismatch. Exit 0 PASS, 1 FAIL, 2 INVALID.

1. `pmbootstrap build --force linux-postmarketos-qcom-msm8974` — **the agent
   cannot run this**, it needs interactive sudo (`sudo -n` fails). Verify by
   artifact, never by exit code.
2. `install --no-sparse` then `export`, then overwrite the cmdline via
   `tools/patch-cmdline.py`:
   `pmos_boot_uuid=a9d9c6cd-eda8-4246-8a5d-2ff04682aa95`
   `pmos_root_uuid=de214b3a-0811-4b22-a5f7-095ac1f8d676`
   The installer mints fresh ones; using them gives "failed to mount
   subpartitions" on `mmcblk0p28`.
3. **Push the `.ko` to `/lib/modules` separately** and `depmod -a`. This has
   voided two runs. Always check `/sys/module/wcd9320/version`.
4. `fastboot.exe` is Windows-side only, not on PATH:
   `C:\Users\Admin\AppData\Local\Android\Sdk\platform-tools\fastboot.exe`,
   and PowerShell needs the `&` call operator.

Recovery images, untouched: `boot-1520.img` (pre-audio),
`boot-1520-core-init-rc2.img`, `boot-1520-nested-irq-rc1.img`.

## Traps

- **Never generate shell scripts through a PowerShell pipe.** It adds a BOM and
  CRLF and the script dies with `$'\r': command not found`. Use the Write tool
  or a WSL heredoc. This has bitten twice.
- `abuild` pairs `source=` and `sha512sums=` **by position**; a filename-keyed
  check gives a false pass. A pmaports pre-commit hook validates it and will
  reject a commit after a patch is regenerated.
- `uname -r` build number is a per-chroot counter, **not** `pkgrel`. Identify a
  running build by `MODULE_VERSION`.
- The parent virtual IRQ number **varies per boot** (83 and 87 both seen).
  Assert on `msmgpio 72` and trigger `0x1`, never the number.
- `irq_count`/`irq_spurious`/`irq_acked` in `irq_observe` are **vestigial**
  since regmap-irq took the parent. They read 0 regardless. Use
  `/proc/interrupts`.
- **Module inserts sometimes fail with a silent `EINVAL`, cause unknown.**
  `modprobe` says "Invalid argument" and dmesg says *nothing at all*. When it
  happens, insert from `/tmp` by hand and carry on; it has always worked on a
  later attempt.

  **CORRECTION (2026-08-12):** this was first recorded as a `.ko.zst`
  decompression problem. **That was wrong.** The same silent `EINVAL` then
  happened with an uncompressed `.ko` at r139, so compression is not the
  variable. What was actually observed:

  | build | file | when | result |
  |---|---|---|---|
  | r137 | `.ko.zst` in `/lib/modules` | t≈190 s | EINVAL |
  | r137 | `.ko` in `/tmp` | t≈1052 s | loaded |
  | r138 | `.ko` in `/lib/modules` | boot, t≈47 s | autoloaded |
  | r139 | `.ko` in `/lib/modules` | t≈240 s | EINVAL |
  | r139 | `.ko` in `/tmp` | t≈503 s | loaded |

  Neither compression nor path explains all five. The one pattern that nearly
  fits is **time since boot** — every failure was an early attempt, every
  manual success a later one — and r138's boot-time autoload is the case that
  breaks it.

  The strongest untested lead: a silent `EINVAL` with no kernel log is exactly
  what a module's `init` function returning `-EINVAL` produces. That would
  point at `slim_driver_register()` failing early rather than at the module
  loader, which fits the timing pattern and fits this port's history of late,
  racy NGD registration (see `0001-slimbus-ngd-late-registration-recovery.patch`).
  Not investigated. Do not record a cause until one is measured.
- `last_status` and `mask_readback` in `irq_observe` are **frozen**, not live.
  `last_status` is written only by the bounded sampler, `mask_readback` only
  once at IRQ setup. Anything asserted against them is self-confirming. Read
  interrupt state from the handler's own post-ack log line instead.
- Parent and child both appear in `/proc/interrupts` as `wcd9320*`. Exclude
  `wcd9320-mbhc` by name when counting the parent; do not rely on ordering.
- Editing `~/corepatch/new/...c` does **not** change the repo — only the
  regenerated patch does. `git status` will happily say clean.
- Kconfig dependency errors are invisible to source checks. `CONFIG_REGMAP_IRQ`
  was missing and the build died at modpost with the symbol undefined; run
  `check-modpost.sh`.
- Confirm pushes by `git ls-remote`. Backgrounded git commands have reported a
  commit while leaving the push undone.

## Sequence from here

1. ~~Minimal MBHC configuration~~ — done
2. ~~Single-source physical-event acceptance~~ — `wcd9320-irq-proven`
3. ~~Module integrity and cold boot~~ — `wcd9320-coldboot-autoload-proven`
4. ~~Merge the research branch to `main`~~ — done, `fabe7e2`
5. ~~Measure volatility~~ — done; **cache stays off**, see
   `wcd9320-volatility-and-defaults.md`
6. ~~Full-map post-reset snapshot~~ — done, `fullmap-rc7`/r142; defaults
   gap closed, see `wcd9320-reg-defaults.md`
7. Provoked runs per volatile family — digital gain, clip-detect, VBAT, IIR
   and ANC windows are all still unexercised
8. Minimal ASoC component
9. RX DAI and IFD port programming
10. Machine driver
11. External MCLK / AFE clock work
12. First 48 kHz playback route

The pmaports recipe is now mirrored at pkgrel 141 under `pmaports/`, checksums
rebuilt positionally against the repo's own files, so the build no longer
exists on one machine only.

## Standing constraints

- Public repo: **no RegenX branding, no private substrate content.** Ordinary
  upstream-style kernel work only.
- Never redistribute Nokia/Microsoft firmware blobs or ACPI dumps — extraction
  instructions and hashes only.
- No downstream GPL source checked in; `wcd9320-regmap-derive.py` fetches its
  own headers.
- Evidence discipline: do not tag on evidence that needs explaining, and
  correct published docs when a hypothesis is disproven. Several docs here
  carry correction headers for that reason.

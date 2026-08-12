# WCD9320 audio bring-up — handoff

State as of 2026-08-12. Everything is on GitHub unless marked otherwise.

## Where things are

| | |
|---|---|
| public repo | `KorelisLabs/lumia-1520-mainline` |
| `main` | `17db442` |
| working branch | `research/audio-wcd9320-core-init` at **`2c234b6`**, pushed |
| pmaports | `~/.local/var/pmbootstrap/cache_git/pmaports`, same branch under `device/testing/linux-postmarketos-qcom-msm8974` — **local only**, origin is upstream postmarketOS and is not writable |
| driver patch | `patches/0002-slimbus-wcd9320-codec-core.patch` — the durable copy |
| driver source | `~/corepatch/new/drivers/slimbus/wcd9320-core.c` (WSL, not in git) |
| pkgrel | **139 built, verified, and run on hardware** |
| last built module | `mbhc-probe-rc4` (r139) |
| running on the phone | `mbhc-probe-rc4` (r139), inserted by hand from `/tmp` |

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

Consequence: `reg_defaults` can be built from the **measured** stage-2 dump.
`REGCACHE_NONE` still stays, but now for one reason only — **volatility is
unmeasured**, and `taiko_volatile()` has never been checked against this part.

## IN FLIGHT — step 4: arming proven; MBHC detection is off until configured

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
- Chain unproven: **dispatch**. Nothing has yet travelled codec → parent → ack.
- The blocker is stimulus, not mechanism.

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

1. Commit `wcd9320-mbhc-probe-20260812T234415Z.txt` — the evidence that
   detection is off, and the MBHC baseline everything diffs against.
2. **Minimal MBHC configuration.** Bring up micbias and the insert-detect
   comparator: the least that makes a physical insertion observable at
   `0x14b` or in `0x3c0`-`0x3ff`. Re-run the rc4 probe to confirm the
   comparator now tracks the jack — still read-only afterwards, so it stays
   falsifiable.
3. Then arm the matching source and run the single-source acceptance proof →
   `wcd9320-irq-proven`.
4. Cold-boot regression, and the silent-EINVAL investigation.

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

1. ~~r138 seven-source MBHC diagnostic~~ — **done, conclusive negative.**
2. ~~Identify a natural source, or establish none exists~~ — **none exists.**
3. **rc4: read-only MBHC probe** — poll `0x14b` and dump `0x3c0`–`0x3ff`
   across an insertion and a removal. Write nothing. This decides how much
   configuration "minimum necessary" actually means.
4. **Minimal MBHC configuration**, scoped by what step 3 measures
5. **Single-source physical-event acceptance run** → `wcd9320-irq-proven`
6. Cold-boot regression. Autoload now works with an uncompressed `.ko`, but
   that has not been deliberately regression-tested, and the `.ko.zst`
   rejection is still unexplained. Both belong here, before anything builds on
   the module path.
7. Measure volatility, then `reg_defaults` from the stage-2 dump, then cache
8. Minimal ASoC component
9. RX DAI and IFD port programming
10. Machine driver
11. External MCLK / AFE clock work
12. First 48 kHz playback route

The `.ko.zst` rejection stays parked until step 6. The uncompressed module is a
controlled test path, the milestone does not depend on the packaging question,
and step 6's cold-boot regression is the first thing that does.

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

# WCD9320 audio bring-up — handoff

State as of 2026-08-11. Everything is on GitHub unless marked otherwise.

## Where things are

| | |
|---|---|
| public repo | `KorelisLabs/lumia-1520-mainline` |
| `main` | `17db442` |
| working branch | `research/audio-wcd9320-core-init` at **`ab12c71`**, pushed |
| pmaports | `~/.local/var/pmbootstrap/cache_git/pmaports`, same branch — **local only**, origin is upstream postmarketOS and is not writable |
| driver patch | `patches/0002-slimbus-wcd9320-codec-core.patch` — the durable copy |
| driver source | `~/corepatch/new/drivers/slimbus/wcd9320-core.c` (WSL, not in git) |
| pkgrel | 135 built; the build script bumps to 136 |
| last built module | `nested-irq-rc1` (r135), currently on the phone |

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

## IN FLIGHT — step 4, committed but NOT built or booted

`ab12c71` adds `mbhc-irq-rc1`: a research hook arming exactly one source,
`WCD9320_IRQ_MBHC_INSERTION`, plus `tools/wcd9320-mbhc-irq-evidence.sh`.

Requesting the child IRQ is the whole mechanism — regmap-irq unmasks on
request, re-masks on free — so no mask register is touched by hand.

### Exact next actions

1. Build: bump pkgrel, regen patch from `~/corepatch` (`diff -uprN orig new`),
   fix checksums **positionally** (`source=` is ordered 0001, 0003, 0002),
   build, verify by artifact, make `boot-1520-mbhc-irq-rc1.img` with the
   known-good cmdline UUIDs. Guards: module reports `mbhc-irq-rc1`, and
   `strings` finds both `mbhc test: ARMED` and `nested irq chip registered`.
2. Push the `.ko` to `/lib/modules` — `fastboot boot` does **not** update it.
3. Reboot, boot the image.
4. Run `wcd9320-mbhc-irq-evidence.sh`. **Interactive — needs a headset.**

### The acceptance bar

One physical event must produce a **finite, explainable interrupt sequence and
return to quiescence with no manual recovery**. A source that fires and stays
asserted is a FAIL, not a partial pass. The script splits this into: status
cleared after ack, quiescence resampled 5 s later (parent and child), and
≤20 assertions.

Only after that passes: tag `wcd9320-irq-proven`.

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
- Editing `~/corepatch/new/...c` does **not** change the repo — only the
  regenerated patch does. `git status` will happily say clean.
- Kconfig dependency errors are invisible to source checks. `CONFIG_REGMAP_IRQ`
  was missing and the build died at modpost with the symbol undefined; run
  `check-modpost.sh`.
- Confirm pushes by `git ls-remote`. Backgrounded git commands have reported a
  commit while leaving the push undone.

## Sequence from here

1. **Step 4/5** — one MBHC source end-to-end → `wcd9320-irq-proven`
2. Measure volatility, then `reg_defaults` from the stage-2 dump, then cache
3. Minimal ASoC component
4. RX DAI and IFD port programming
5. Machine driver
6. External MCLK / AFE clock work
7. First 48 kHz playback route

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

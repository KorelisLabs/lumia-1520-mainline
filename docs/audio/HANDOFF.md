# WCD9320 audio bring-up — handoff

State as of 2026-08-01. Everything below is on GitHub unless marked otherwise.

## Where things are

| | |
|---|---|
| public repo | `KorelisLabs/lumia-1520-mainline` |
| `main` | `17db442` — all proven milestones and tags |
| working branch | `research/audio-wcd9320-core-init` at `8372807` |
| pmaports | `~/.local/var/pmbootstrap/cache_git/pmaports`, same branch, `164b6d6446` — **local only**, its origin is upstream postmarketOS and is not writable |
| driver patch | `patches/0002-slimbus-wcd9320-codec-core.patch` in this repo is the durable copy |
| pkgrel | 129 — **bump before the next build** |

The kernel driver lives only as a patch. There is no checked-in `.c` file;
`patches/` in this repo is the authoritative archive, since pmaports cannot
be pushed.

## What is proven on hardware

Tags, each with an evidence log in this directory:

- `wcd9320-regmap-readonly-proven` — regmap over the `0x800` offset
- `wcd9320-core-bringup-proven` — fresh and adoption power paths
- `wcd9320-dual-function-proven` — PGD `0xcb` and IFD `0xca`
- `wcd9320-irq-parent-idle-validated` — TLMM 72, edge-rising, electrically
  idle across 45 direct pad samples and two s2idle cycles
- `wcd9320-cdc-rco-wake-proven` — CDC digital core made accessible, 87/87
  sentinel registers, on the on-die RC oscillator with **no external MCLK**

Plus, untagged but validated: `core-init-rc1` regression showing the
core-release/RCO stage split is behaviour-neutral
(`wcd9320-core-init-rc1-regression.log`).

## The single most important finding

The `0x200`–`0x3bf` region reading all-zero was **never an MCLK problem**. The
digital core was held in reset because this port had never run
`wcd9xxx_bring_up()` — four writes downstream performs at
`wcd9xxx-core.c:468`, before it even reads the chip id.

It survived every earlier milestone because identity, revision, regmap and
dual-function were all **read-only**. The first write outside the top-level
block exposed it immediately.

`wcd9320-mclk-investigation.md` and `wcd9320-register-map.md` both carry
correction headers saying so. External MCLK remains unresolved but is **not**
a blocker; it matters again only when a stream needs a frequency-accurate
reference.

## What is implemented but NOT validated

`core-init-rc2` (commit `8372807`) converts the manual wake into automatic,
idempotent initialisation. Nothing has been built or booted.

- `wcd9320_core_init()` — idempotent, serialised on `wake_lock`, no-op for
  the IFD; `core_init_calls` vs `core_init_runs` distinguishes a no-op entry
  from one that wrote
- fresh vs adoption decided by **reading the sentinel**, not driver state
- `wcd9320_verify_core_accessible()` — ≥48 of 448 non-zero, and `0x320`
  reading its documented `0xe4`
- three-stage snapshots: as-found, after core release, after clocking
- manual trigger refuses to wake an already-initialised core
- `core_ready` deliberately survives teardown (the documented inverse leaves
  the CDC gate set; `core_ready` describes accessibility, not intent)

### The two proofs still required

**1. Cold-boot automatic init.** Full power-off first. Expect
`core_ready=1 core_adopted=0 init_runs=1`, `nonzero_after=95`, bring-up
before RCO, bandgap canary succeeding first try, and **no `wake` written**.

**2. Adoption, zero writes.** From that already-initialised state, reboot
*without* power-off. Expect `core_adopted=1 init_runs=0`, and `bringup`
showing zero reset transitions and zero supply operations.

Only after both: tag `wcd9320-core-init-proven`.

## Build and test loop

Scripts live in a session scratchpad and do **not** survive. Rebuild them
from `patches/` and the notes below.

1. `pmbootstrap build --force linux-postmarketos-qcom-msm8974` — **the agent
   cannot run this**; it needs interactive sudo. Verify by artifact, never by
   exit code.
2. `pmbootstrap install --no-sparse` then `export`, then overwrite the
   cmdline with the known-good UUIDs via `tools/patch-cmdline.py`:
   `pmos_boot_uuid=a9d9c6cd-eda8-4246-8a5d-2ff04682aa95`
   `pmos_root_uuid=de214b3a-0811-4b22-a5f7-095ac1f8d676`
   The installer mints fresh ones every time; using them gives
   "failed to mount subpartitions" on `mmcblk0p28`.
3. **Push the module to `/lib/modules` separately.** `fastboot boot` only
   RAM-loads the kernel; the rootfs on eMMC is untouched, so a driver change
   needs the `.ko` extracted from the `.apk`, copied to
   `/lib/modules/$(uname -r)/kernel/...`, and `depmod -a`. This costs an
   extra boot and has caused two void runs. Always check
   `/sys/module/wcd9320/version` before trusting a result.
4. `fastboot.exe` is Windows-side only, not on PATH:
   `C:\Users\Admin\AppData\Local\Android\Sdk\platform-tools\fastboot.exe`,
   and PowerShell needs the `&` call operator.

Recovery images, both untouched: `boot-1520.img` (pre-audio) and
`boot-1520-rco-wake.img` (rc3, last fully validated).

## Traps worth knowing

- `abuild` pairs `source=` and `sha512sums=` **by position**, and this
  package's `source=` is ordered 0001, 0003, 0002. A filename-keyed check
  gives a false pass. A pmaports pre-commit hook validates this.
- `uname -r` build number (`#129`) is a per-chroot counter, **not** `pkgrel`.
  Identify a running build by the module's `MODULE_VERSION`.
- The parent IRQ number varies per boot (83 and 87 both seen). It is a
  dynamically allocated Linux virtual IRQ. Assert on pin `msmgpio 72` and
  trigger type `0x1`, never the number.
- `pmbootstrap`'s exit code is non-zero when a post-run umount fails despite
  a good build.
- The phone currently has the core woken and torn down, so it is **not** a
  clean state. The fresh-path test needs a full power-off.

## Open questions

- **The 16 non-POR registers.** Three coherent families with identical deltas:
  `TX1..TX10_MUX_CTL` `08→48`, `COMP0..2_B4_CTL` `3c→37`,
  `COMP0..2_B5_CTL` `1f→7f`. Likely revision-dependent for minor `0x0001`,
  but could equally be state set by the core release or the RCO sequence, or
  inherited firmware configuration. The three-stage snapshots exist to settle
  this. **Do not build `reg_defaults` until it is settled**, and keep
  `REGCACHE_NONE`.
- **External MCLK route** — unresolved, deferred, not blocking.
- **RCU expedited stalls** at ~t+29 s, pre-existing and unrelated to audio
  (they appear with drivers that have no interrupt code). One full record is
  preserved in `rcu-stall-2026-08-01.log`.

## Sequence from here

1. Validate `core-init-rc2` with the two proofs above → `wcd9320-core-init-proven`
2. Attribute the 16 non-POR registers from the three-stage snapshots
3. Nested codec IRQ controller, all sources masked
4. Unmask one MBHC source (reachable without MCLK) and prove a real
   insertion/removal through status → parent edge → threaded handler →
   nested dispatch → write-1-to-clear → line low → `wcd9320-irq-proven`
5. Minimal ASoC component
6. RX DAI and IFD port programming
7. Machine driver
8. External MCLK / AFE clock work
9. First 48 kHz playback route

## Standing constraints

- Public repo: **no RegenX branding, no private substrate content**. This is
  ordinary upstream-style kernel work and stays that way.
- Never redistribute Nokia/Microsoft firmware blobs or ACPI dumps. Publish
  extraction instructions and hashes only.
- No downstream GPL source is checked in; `tools/wcd9320-regmap-derive.py`
  fetches its own headers.
- Evidence discipline: do not tag on evidence that needs explaining, and
  correct published docs when a hypothesis is disproven. Several docs here
  carry correction headers for exactly that reason.

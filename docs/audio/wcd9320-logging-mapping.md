# WCD9320 driver logging: mapping for a quiet normal path

Status: mapping, 2026-11-14. Nothing is built yet. This follows the duplex work (`wcd9320-duplex-mapping.md`, section 10). The quiet console took playback start from 2.76 s to 0.2 s, but the driver still floods the kernel log.

## 1. The evidence: one short duplex run

r201quiet ran capture for 8 s while the headphones played two 1.1 s stimuli. Its window holds **402 kernel-log lines in about 10 s, 398 of them from wcd9320**, all at info level.

| kind | lines |
|---|---|
| `c2b:` chip-verified register writes | 133 |
| RX digital path steps (`rx1-digital:`, `rx2-digital:`) | 48 |
| RX port programming (`rx-port 16/17:`) | 24 |
| clock-source steps (`clk-src ...`) | 35 |
| `forced:` writes | 10 |
| HPH / class-H internals (`hphr:`, `clsh:`, `c3a:`) | 26 |
| stage transitions (`dapm:`, `capture:`, `mclk:`, `slim-stream:`, `tx-stream:`) | ~70 |

At that rate a phone playing notification sounds writes thousands of lines a day. That buries real warnings and wraps the ring buffer. Each printk also costs time under `c3_lock`, even with the console quiet.

## 2. The driver's info calls, all 190

A call graph from the normal-path roots (the DAPM and capture events, the RX/TX DAI ops, the SLIMbus stream helpers, the HPF work, the ALSA control puts, `set_jack`) splits them into:

| group | functions | `dev_info` |
|---|---|---|
| **reached from the normal audio paths** | 51 | 102 |
| of which the jack (`jack_enable`, `jack_disable`, `jack_report`, `insert_detect_set`): boot and plug events | 4 | 6 |
| of which the C3 abort's IRQ sample (`pa_irq_sample`): an anomaly path | 1 | 1 |
| **not reached** (probe and remove, IRQ setup, research sysfs tools, MBHC research threads) | 41 | 88 |

The normal-path functions with the most calls:
- `hphl_dac_path`, `clk_source_switch`: 6 each;
- `cdc_clk_prereq`, `rx_port_program`: 5 each;
- `clsh_lo`, `dapm_event`: 4 each;
- `clsh_mode`, `rx_trigger`, `rx_digital_path`, `cap_event`, `hphr_dac_path`, `__slim_start`, `__slim_stop`, `hphl_pa_path`, `hphr_pa_path`: 3 each.

Most of these are shared with the research tools, which call the same mapped functions.

## 3. What depends on the text

- **Almost every evidence script** (38 of them, the routine gates included) collects the `wcd9320` lines from `dmesg` (`snap_dmesg`, `dmesg_since`, `DMESG_FILE`) and checks message text in places.
  - A plain `dmesg` prints debug-level lines too. So the checks keep working **if the codec's debug output is enabled during the run**. The message text does not change, only its level.
- **The verifier** never mentions `dev_info` or `dev_dbg`. No fence pins a log level.
- **The artefact gate** looks for required strings in the built module. With `CONFIG_DYNAMIC_DEBUG=y` the format strings of `dev_dbg` stay in the module (`__dyndbg` descriptors), so those checks are unaffected.
- **The phone's kernel** has `CONFIG_DYNAMIC_DEBUG=y` and `/sys/kernel/debug/dynamic_debug/control`. The driver already has 3 `dev_dbg` sites.
- **Errors and warnings** (`dev_err` 180, `dev_warn` 12) stay as they are. The tools' failure scans (`WARNING:`, `failed`, `REFUSED`, `PA GUARD TRIPPED`) look for those.

## 4. Proposed: r202

**Driver.**
- In the 51 normal-path functions, `dev_info` becomes `dev_dbg`. Excluded: the jack's 6 (one line per boot or plug, worth keeping) and the abort-path sample.
- Probe, remove, IRQ setup and the research sysfs tools keep `dev_info`: they run once, or when someone invokes them. Errors and warnings are unchanged.
- **Expected:** a normal playback or capture logs nothing at default levels.

**Tools.**
- `wcd9320-evidence-lib.sh`: `find_devices()` (every lib runner's setup) switches the module's debug output on (`module wcd9320 +p`), noting whether it already was, and `emit_verdict()` puts it back.
- `wcd9320-capture.sh` and `wcd9320-duplex-probe.sh` don't source the lib, so they do the same themselves.
- A new `tools/wcd9320-trace.sh on|off|status` flips it by hand.

**Verifier.** A fence that the listed normal-path functions contain no `dev_info` and the jack keeps its, plus mutations.

**Test.**
- The gates with debug output on (their evidence intact).
- A duplex run.
- A quiet check: a playback-and-capture run with debug output off must add **no** wcd9320 lines to the log.

## 5. r202 (`quietlog-rc1`, pkgrel 202): staged 2026-11-14

**Driver.**
- In 47 functions, 96 `dev_info` became `dev_dbg`: the 46 normal-path functions of section 2 that are neither the jack nor the abort sample, plus `cap_dmic_store`, which the capture runner writes every run.
- **Kept at info:** the jack's 6 and the abort-path sample. Probe, remove, IRQ setup and the research tools are untouched, and so are errors and warnings.
- **Counts:** `dev_info` 190 → 94 calls, `dev_dbg` 3 → 99.
- **Proof that only the levels changed:** with every `dev_dbg(` read back as `dev_info(`, r202's source is identical to r201's except for `MODULE_VERSION` (97 changed lines: 96 conversions and the version).

**Tools.**
- **`tools/wcd9320-trace-lib.sh`** is the one implementation:
  - `wcd_trace_on` enables `module wcd9320 +p` once per run and notes the prior state;
  - `wcd_trace_restore` disables again only if this run enabled it;
  - `wcd_trace_state` reports on, off, partial or unavailable;
  - `WCD_TRACE=0` skips enabling, and child runners inherit it.
- **Who uses it:**
  - `wcd9320-evidence-lib.sh` switches on in `find_devices()` and restores in `emit_verdict()` and `emit_invalid_setup()`, which covers every lib runner;
  - `wcd9320-capture.sh` and `wcd9320-duplex-probe.sh` use it directly;
  - `tools/wcd9320-trace.sh on|off|status` flips it by hand.
- **The duplex probe** reports the codec lines it added to the kernel log. With `WCD_TRACE=0` it checks that the number is **0** (the quiet check).

**Verifier.**
- **New fences:** the 47 functions contain no `dev_info`; the jack and the abort sample keep theirs; the counts.
- **The r169 switch-body hash** is now taken with `dev_dbg(` read back as `dev_info(`. The same pin still proves the proven sequence is untouched, and a logic change inside it is caught (mutation).

**Results.**

| check | result |
|---|---|
| Compile | `W=1` clean; no new baseline reads (pin stays 146) |
| Verifier | 741 checks pass; the only failure is the old r201 module's version |
| Mutation | 23/23 |
| Selftest | 131/0 |

**Test plan:**
1. The gates. Their evidence needs the debug output on, which the library now does.
2. A headphones + DMIC1 duplex run.
3. The same with `WCD_TRACE=0`, which must add no codec lines.

**Not in scope:** the card driver (`wcd9320-lumia-q6`) still logs about 3 info lines per stream (`BE hw_params`). That is a card change, for later.

## 6. r202 result (2026-11-14): the normal path is silent

**Boot.**
- The build's quiet console took effect: `console=tty0 loglevel=4`, no `ignore_loglevel`.
- The codec debug messages were `off`. The codec wrote **0** lines to the kernel log in the first 87 s.

**Gates.** Digital 83/0, MCLK ownership 90/0, vm 57/0, cache 0 mismatches. Each switched the debug output on in `find_devices()`, and it was `off` again after.

**Headphones + DMIC1, cap-first, 341 ms buffer:**

| run | debug output | codec lines in the run | result |
|---|---|---|---|
| r202trace2 | on (the probe enabled it; the capture runner found it on and left it) | 461 (406 in the 8 s window) | PASS 50/50 + 17/17 |
| r202quiet3 | off (`WCD_TRACE=0`) | **0** (the card: 3, `BE hw_params`) | PASS 50/50 + **18/18**, the quiet check included |

**On the way there:**
- **The install script** had re-sent r197's `pcm-capture`, which has no `-p`/`-n`, so the first run refused at setup. The script now sends r201b's, as do the old install scripts it was copied from.
- **The PC helper** did not pass `WCD_TRACE` to the phone, so one "quiet" run was a debug-on run. Fixed.
- **The probe's first quiet count read −4.** The ring buffer was full after the debug-on runs, so a line-count delta went negative. It now counts lines newer than its start timestamp (r187's lesson, 51693ed). The raw log for that run held 0 codec lines.

**Open:** the card driver's per-stream info lines (3 per duplex run: one per stream start). That is a card change (`lumia1520-q6.c`, patch 0005), for later.

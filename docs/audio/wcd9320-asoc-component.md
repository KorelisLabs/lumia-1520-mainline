# The minimal ASoC component

The first piece of this driver that enters the sound subsystem. It registers a
component with **zero DAIs**, no controls, no DAPM widgets and no routes — so
it cannot be bound into a card and no audio path exists. That is the milestone,
and the limit of it.

Evidence, all from one cold boot of `asoc-component-rc1` (pkgrel 145) on
2026-08-15:

| run | verdict |
|---|---|
| `wcd9320-coldboot-autoload-20260815T185125Z.txt` | PASS 31/0 |
| `wcd9320-asoc-component-20260815T185924Z.txt` | PASS 29/0 |
| `wcd9320-irq-acceptance-20260815T185937Z.txt` | PASS 27/0 |
| `wcd9320-irq-acceptance-20260815T190003Z.txt` | PASS 27/0, repeat |

## What was added

```c
static const struct snd_soc_component_driver wcd9320_soc_component = {
	.name = "wcd9320-codec",
	.endianness = 1,
};
```

registered once with `devm_snd_soc_register_component(dev, &..., NULL, 0)`.

**Where it sits in probe matters.** It goes after the regmap and the
power-release devres action but *before* the adoption/fresh branch, so it
happens on every path out of probe rather than one of them. The interface
function returns earlier, so only the control function ever reaches it —
giving the IFD a component would put a second, mute codec into any card that
later binds this one.

Registration touches no register, so it is safe before enumeration completes
and does not wait for `core_ready`. `devm_` means teardown is the exact reverse
without `wcd9320_remove()` gaining a responsibility it could forget.

`CONFIG_SND_SOC=y` in the device config already, so a module can reference the
exported symbols; the Kconfig entry now declares `depends on SND_SOC`
explicitly. A missing `SND_SOC` would surface only at modpost — the same class
of failure `CONFIG_REGMAP_IRQ` produced once already.

## ASoC names components after the device, not after the driver

This cost a failed run and is worth recording, because it is not obvious and
the wrong assumption produces a confident false negative.

`snd_soc_component_initialize()` sets

```c
component->name = fmt_single_name(dev, &component->id);
```

so what appears in `/sys/kernel/debug/asoc/components` is the **slim_device's**
name, `217:a0:1:0`. The `.name` field in `snd_soc_component_driver` —
`wcd9320-codec` — appears in this driver's own log line and **nowhere in that
file**.

The first version of the gate matched on `wcd9320-codec` and reported the
component missing while it was registered perfectly well. Measured output:

```
registered components:
  217:a0:1:0
  snd-soc-dummy
  snd-soc-dummy

registered DAIs:
  snd-soc-dummy-dai
```

The two `snd-soc-dummy` entries are ASoC's own built-ins and are present on any
system with `SND_SOC`.

**The correction bought a better check than the original.** Because components
are named by device, the interface function `217:a0:0:0` has a name of its own —
and requiring it to be *absent* is direct evidence that the control function
registered and the interface function did not. Matching on the driver's `.name`
could not have distinguished those cases at all.

## What the gate asserts

`tools/wcd9320-asoc-component-evidence.sh`, against ASoC's own list rather than
this driver's dmesg:

| check | measured |
|---|---|
| `217:a0:1:0` in `components` | present, exactly once |
| `217:a0:0:0` in `components` | **absent** — the IFD did not register |
| DAIs belonging to it | **0** |
| sound cards | **0** |

The driver's own "ASoC component registered" line is collected as
corroboration and is never the assertion — it proves the call returned zero,
not that ASoC kept the component.

Zero DAIs and zero cards are **requirements at this stage, not omissions**.
Either appearing would mean the scope grew without anyone deciding it should,
so the gate fails on them. The artefact verifier enforces the same thing before
the module ever reaches the phone: no DAI table in the ELF, and
`devm_snd_soc_register_component` relocated from exactly one call site.

## Nothing underneath moved

From the same boot: `path=fresh`, core init `0 → 94 → 95` with canary `e4`,
identity `0x0102`/`0x0001`, **460 cacheable registers still agreeing with the
chip**, all 29 interrupt sources masked and nothing asserted.

The interrupt chain was re-proven twice with physical insertions — parent +1,
child +1, post-ack status `00 00 00 00`, quiescence, `0x14a` restored — the
second time from a non-zero counter baseline, which shows the deltas are
measured rather than assumed.

## What this does NOT cover

DAI routing, PCM, DAPM, controls, and any audio path whatsoever. A component
with no DAIs cannot be bound into a card, so none of that is reachable from
here and none of it is claimed. The next step is the RX DAI and IFD port
programming, which is where register access from ASoC callbacks starts and
where the component will need to care about `core_ready`.

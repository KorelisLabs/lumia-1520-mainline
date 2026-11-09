# Phase 0: mapping what is left of audio (in progress)

**Goal:** a daily-usable phone, at the same quality bar as r184-r186. The
remaining features are:
- the loudspeaker;
- the earpiece;
- the microphones (built-in and headset);
- headset buttons and headset typing;
- other sample rates and formats;
- the userspace setup (UCM, PipeWire);
- finally, the consolidated production driver.

Plan, agreed 2026-11-08: map everything first, then build in batches:
1. outputs;
2. capture;
3. headset and formats;
4. userspace;
5. consolidation.

## 1. The loudspeaker: what drives it

**Sources:**
- the phone's ACPI tables (`~/dsdt.dsl`);
- its own Windows Phone install (`MainOS`, mounted **read-only** with
  `ntfs3`, and unmounted afterwards);
- public teardowns.

The Windows files were copied to `~/winaudio` (WSL) for analysis only. They
are proprietary and are not committed.

**Established:**
- **The ACPI audio device** (`\_SB.ADSP.SLM1.ADCM.AUDD`) has exactly one
  GPIO, TLMM 63. That is the WCD9320's reset line (the same pin the MSM8974
  reference uses), not an amplifier enable. Its GPIO-config method (`GPNF`)
  is empty.
- **The whole DSDT declares only four I2C peripherals,** and none is audio.
  Every other Nokia device is declared (`NOKIA_TOUCH`, `NOKIA_VIBRA_PMIC`,
  `NOKIA_PANEL`…), with no amplifier among them.
- **Windows Phone drivers get their hardware resources from ACPI.** A speaker
  amplifier that needed I2C control, or an enable line, would have to appear
  there, and none does.
- **The Windows audio stack is Qualcomm's:**
  - `qcaud8974.sys` and `qcauddev8974.sys`;
  - `Codec_cal_8974.acdb`: `CDCNAME WCD9320`, `OEMINFO "1.0 sysdef"`, dated
    2012-06-21. This is Qualcomm's generic codec database. It names every
    profile (`LINEOUT_1_DIFFERENTIAL`, `EAROUT_SPEAKER`, `DMIC_1`…
    `DMIC_1_2_3_4_QUAD`), not which ones this phone uses.
  - Nokia's registry adds only effects, for example a Dolby EQ for
    `_DeviceLoudspeaker`. The routing is compiled into `qcauddev8974.sys`.
- **Public teardowns** (iFixit, the IHS summary, the Nokia service manual) do
  not name an audio amplifier.

> **Superseded (2026-11-09).** r187 and r188 found every WCD9320 analog
> output silent. The power-framework (PEP) entry for this audio device, which
> this section never read, switches a 5 V / 1.5 A rail and the SoC's
> Secondary MI2S pins. The loudspeaker is behind a control-less I2S
> amplifier. See [r189-sec-mi2s-speaker-mapping.md](r189-sec-mi2s-speaker-mapping.md).

**Working hypothesis:** the loudspeaker is driven directly by the WCD9320's
own class-D speaker driver (`SPKR`, fed from RX7). It is not proven.
- **The case for it:** nothing else exists for Windows to control.
- **What cannot yet be excluded:** a line output into an amplifier that
  hardware keeps always on.
- **How Phase 1 settles it:** map `SPKR` from downstream, and make its first
  hardware test a minimum-gain probe with the mic at a fixed position. If it
  is silent, `LINEOUT` is next.

## 2. Still to map

- **The earpiece:** the WCD9320 `EAR` PA (`0x1bc`, fed from RX1 through the
  EAR DAC), from downstream.
- **The microphones:**
  - The Lumia 1520 has four ("Rich Recording").
  - Which codec inputs do they use, digital (DMIC) or analog (ADC), and with
    which mic bias?
  - The database's `DMIC_1_2_3_4_QUAD` profile is a hint, not proof.
- **Capture:**
  - the codec TX ports and decimators;
  - the SLIMbus TX stream;
  - QDSP6 AFE `SLIMBUS_0_TX` and ASM capture.
- **The headset mic and buttons:** MBHC headset typing and button detection,
  on top of the engine the r178/r179 voltmeter and zdet already exercise.
- **Rates and formats:** 44.1 kHz and 24-bit on the RX path.

## Sources

- [iFixit teardown](https://www.ifixit.com/Teardown/Nokia+Lumia+1520+Teardown/23924)
- [IHS teardown via GlobalSpec](https://electronics360.globalspec.com/article/4239/exclusive-video-teardown-nokia-lumia-1520)
- [Nokia Lumia 1520 service manual (RM-937…940)](https://manualslib.com/manual/1157407/Nokia-Lumia-1520.html?page=30)

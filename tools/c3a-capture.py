#!/usr/bin/env python3
"""C3a acoustic instrument: record the phone's headphone output and decide,
from the recording alone, whether it followed the digital stimulus.

WHY THIS EXISTS

C3a was frozen as a scope measurement at the HPHL pin, through a TRRS breakout,
with the ground contact meter-verified. None of those three tools is available.
What IS available is a pair of wired 3.5 mm headphones and a USB microphone on
the PC. An earbud pressed against that microphone turns the HPHL output into a
recording, and a recording can be analysed objectively, saved as evidence, and
re-analysed by anyone later -- which a scope trace read by eye cannot.

The phone is never electrically connected to anything but the earbud, so the
earth-reference hazard that dictated the whole offline-button design does not
arise: USB stays connected and ssh stays live for the entire run.

WHAT THE ANALYSIS DECIDES, AND HOW

The stimulus is pcm-tone's: 1 kHz, 250 ms tone, 250 ms digital silence, 250 ms
tone, 250 ms silence, in one uninterrupted stream. So the question is not "is
there a 1 kHz tone in the room" but "is there a 1 kHz tone that is PRESENT in
exactly the two tone segments and ABSENT in exactly the two silent ones".

For every 10 ms hop the recording is reduced to the amplitude at exactly
1000 Hz and at two reference frequencies (600, 1400 Hz). The four-segment
template is slid across the whole recording, and at every offset

    contrast = min(tone1, tone2) - max(silence1, silence2)        [dB]

A tone that did not stop for the digital silence fails, because the silent
segments are loud. A single burst fails, because the second tone segment is
quiet. Anything broadband -- a thump, a click, room noise gated by chance --
fails the narrowband test, because it lifts the reference frequencies as much
as 1 kHz. And a tone at the wrong frequency fails the frequency test, which
measures the peak inside each tone segment to well under 1 Hz.

Classes, per detected event:

    PASS    contrast >= 20 dB, narrowband, frequency 1000 +/- 5 Hz
    WEAK    10 dB <= contrast < 20 dB, narrowband, frequency OK
    REJECT  contrast >= 10 dB but broadband or at the wrong frequency

WEAK exists so that a tone near the floor is reported as near the floor, rather
than silently becoming a null.

A NULL IS ONLY MEANINGFUL IF THE INSTRUMENT IS PROVEN FIRST

`calibrate` plays the IDENTICAL stimulus from the PC through the same
headphones, at the same placement, into the same microphone, and runs the same
analysis. If that does not PASS, a phone run that shows nothing says nothing.
If it does, a phone run that shows nothing means the phone produced nothing.

Commands (record, play and calibrate need Windows; analyse and selftest do not):

    c3a-capture.py list
    c3a-capture.py record    --in N --seconds S --out F.wav [--stop-file P]
    c3a-capture.py play      --out-dev M [--dbfs -40]
    c3a-capture.py calibrate --in N --out-dev M --wav F.wav [--dbfs -40]
    c3a-capture.py analyse   F.wav [--expect K]
    c3a-capture.py selftest

Exit: 0 pass / done, 1 fail, 2 usage or setup error.
"""
import argparse
import ctypes
import math
import os
import sys
import time
import wave

import numpy as np

# ---- the stimulus, identical to pcm-tone's frozen plan ---------------------
RATE = 48000
TONE_HZ = 1000.0
SEG_S = 0.250
N_SEG = 4
DBFS_DEFAULT = -40.0
DBFS_CEILING = -20.0

# ---- analysis ---------------------------------------------------------------
FRAME_S = 0.020
HOP_S = 0.010
TRIM_FRAMES = 3          # 30 ms either side of a segment edge is not judged
REF_HZ = (600.0, 1400.0)
PASS_DB = 20.0
WEAK_DB = 10.0
NARROW_DB = 6.0          # a gated broadband burst sits near 0 dB here
FREQ_TOL_HZ = 5.0
GROUP_S = 1.0            # offsets closer than this are the same event


def stimulus(dbfs, rate=RATE):
    """The C3a stimulus as int16 samples, built the way pcm-tone builds it.

    One exact period of the sine in a table, 250 whole cycles per segment, so
    every burst starts and ends on a rising zero crossing.
    """
    if not dbfs <= DBFS_CEILING:
        raise ValueError("refusing %.1f dBFS -- the ceiling is %.1f dBFS"
                         % (dbfs, DBFS_CEILING))
    period = int(round(rate / TONE_HZ))
    if period * TONE_HZ != rate:
        raise ValueError("rate %d is not a whole number of 1 kHz periods" % rate)
    peak = int(round(32767.0 * 10.0 ** (dbfs / 20.0)))
    table = np.round(peak * np.sin(2.0 * np.pi * np.arange(period) / period))
    seg = int(round(rate * SEG_S))
    idx = np.arange(seg * N_SEG)
    out = table[(idx - (idx // seg) * seg) % period]
    out[(idx // seg) % 2 == 1] = 0.0
    return out.astype(np.int16)


# ============================================================== analysis ===

def load_wav(path):
    with wave.open(path, "rb") as w:
        ch, sw, fs, n = (w.getnchannels(), w.getsampwidth(),
                         w.getframerate(), w.getnframes())
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    elif sw == 1:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) / 128
    else:
        raise ValueError("unsupported sample width %d" % sw)
    return x.reshape(-1, ch).mean(axis=1), fs


def frame_amplitudes(x, fs, freqs):
    """Amplitude (dBFS) at each frequency for every hop, Hann-windowed.

    Processed in chunks over a strided VIEW, so a 20-minute recording does not
    materialise a gigabyte of overlapping frames.
    """
    n = int(round(FRAME_S * fs))
    h = int(round(HOP_S * fs))
    if len(x) < n:
        return np.zeros((0, len(freqs)))
    nfr = 1 + (len(x) - n) // h
    win = np.hanning(n)
    t = np.arange(n) / fs
    basis = win[:, None] * np.exp(-2j * np.pi * np.outer(t, freqs))
    norm = 2.0 / win.sum()
    frames = np.lib.stride_tricks.as_strided(
        x, shape=(nfr, n), strides=(x.strides[0] * h, x.strides[0]),
        writeable=False)
    out = np.empty((nfr, len(freqs)))
    step = 4096
    for i in range(0, nfr, step):
        amp = np.abs(np.ascontiguousarray(frames[i:i + step]) @ basis) * norm
        out[i:i + step] = 20.0 * np.log10(amp + 1e-12)
    return out


def peak_frequency(seg, fs, quiet):
    """The tone's frequency, and whether it is the stimulus's own component.

    Returns (frequency of the peak in the 900-1100 Hz window, to well under
    1 Hz; whether the strongest component that APPEARS in this tone segment
    relative to the silent segment `quiet` sits at that same frequency).

    THE SECOND TEST WAS WRONG IN ITS FIRST FORM, and the calibration caught it.
    It used to require the 1 kHz peak to be the strongest thing in the whole
    100 Hz - 8 kHz range. Behind a noise gate that holds, because the gate
    removes everything else. With the gate off, in a real room, fan rumble and
    mains hum are louder than a quiet tone and present ALL the time, so a
    genuine -50 dBFS calibration tone -- measured at 1000.10 Hz, 21 dB of
    contrast -- was rejected, and reported misleadingly as a "frequency"
    failure.

    What the test exists for is a stimulus whose DOMINANT effect is at some
    other frequency, with only leakage landing at 1 kHz. That is a question
    about what the stimulus CHANGED, so it is asked of the tone segment
    against the silence beside it.

    AND IT IS ASKED IN RELATIVE TERMS -- the second correction, also from
    calibration. Comparing ABSOLUTE added power still failed a known-good
    -50 dBFS tone: 1 kHz rose 37 dB over its silence (-113 -> -76 dBFS), while
    112-190 Hz hum rose only 10-14 dB but from a louder starting point, so it
    out-added the tone in raw power. That hum gates WITH the stimulus because
    the PC headset's USB DAC mutes itself during all-zero digital silence --
    an artefact of the playback device, not of anything under test.

    So: among the components loud enough to matter (within 20 dB of the 1 kHz
    level in the tone segment), 1 kHz must show the LARGEST RISE over its own
    silence level. A real tone rises by tens of dB; hum that merely fluctuates
    or un-mutes rises by a few to a dozen; a stimulus whose real effect is at
    2.5 kHz rises most at 2.5 kHz and is refused.
    """
    w = np.hanning(len(seg))
    nfft = 1 << int(math.ceil(math.log2(len(seg) * 16)))
    spec = np.abs(np.fft.rfft(seg * w, nfft))
    calm = np.abs(np.fft.rfft(quiet[:len(seg)] * w[:len(quiet)], nfft))
    f = np.fft.rfftfreq(nfft, 1.0 / fs)
    band = (f >= 900) & (f <= 1100)
    wide = (f >= 100) & (f <= 8000)
    if not band.any() or len(quiet) < len(seg):
        return float("nan"), False
    k = np.flatnonzero(band)[np.argmax(spec[band])]
    if 0 < k < len(spec) - 1:               # parabolic interpolation
        a, b, c = np.log(spec[k - 1:k + 2] + 1e-20)
        d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
    else:
        d = 0.0
    fk = f[k] + d * (f[1] - f[0])
    #
    # Power is smoothed over +/-10 Hz before any comparison. Single
    # zero-padded bins are noisy, and taking the MAXIMUM of a noisy quantity
    # over thousands of bins guarantees that some bin wins by chance -- which
    # is exactly how the first relative version rejected a clean synthetic
    # tone. And the tone's own main lobe (a 200 ms Hann window spreads it over
    # about +/-10 Hz) is excluded whole, out to +/-30 Hz, so the tone is never
    # compared against its own shoulders.
    #
    half = max(1, int(round(10.0 / (f[1] - f[0]))))
    box = np.ones(2 * half + 1)
    pt = np.convolve(spec ** 2, box, mode="same")
    pq = np.convolve(calm ** 2, box, mode="same")
    lt = 10.0 * np.log10(pt + 1e-30)
    rise = lt - 10.0 * np.log10(pq + 1e-30)
    own = np.abs(f - fk) <= 30.0
    loud = wide & (lt >= lt[k] - 20.0) & ~own
    strongest = (not loud.any()) or rise[k] > rise[loud].max()
    return float(fk), bool(strongest)


def analyse(x, fs):
    """Find every occurrence of the tone/silence/tone/silence pattern."""
    amps = frame_amplitudes(x, fs, [TONE_HZ] + list(REF_HZ))
    if len(amps) == 0:
        return [], float("nan")
    tone_db = amps[:, 0]
    ref_db = amps[:, 1:].max(axis=1)
    floor_db = float(np.median(tone_db))

    seg_fr = int(round(SEG_S / HOP_S))
    win = seg_fr - 2 * TRIM_FRAMES
    if len(tone_db) < N_SEG * seg_fr + 1:
        return [], floor_db
    lin = 10.0 ** (tone_db / 20.0)
    med = np.median(np.lib.stride_tricks.sliding_window_view(lin, win), axis=1)
    med_db = 20.0 * np.log10(med + 1e-12)
    span = len(tone_db) - N_SEG * seg_fr
    s = np.arange(span)
    seg = [med_db[s + k * seg_fr + TRIM_FRAMES] for k in range(N_SEG)]
    contrast = np.minimum(seg[0], seg[2]) - np.maximum(seg[1], seg[3])

    events = []
    cand = np.flatnonzero(contrast >= WEAK_DB)
    group = int(round(GROUP_S / HOP_S))
    i = 0
    while i < len(cand):
        j = i
        while j + 1 < len(cand) and cand[j + 1] - cand[j] <= group:
            j += 1
        best = cand[i + np.argmax(contrast[cand[i:j + 1]])]
        events.append(best)
        i = j + 1

    hop = int(round(HOP_S * fs))
    seg_samp = int(round(SEG_S * fs))
    out = []
    for b in events:
        start = b * hop + int(round(FRAME_S * fs / 2))
        narrow = []
        freqs = []
        strongest = []
        for k in (0, 2):
            a = b + k * seg_fr + TRIM_FRAMES
            narrow.append(float(np.median(tone_db[a:a + win] - ref_db[a:a + win])))
            s0 = start + k * seg_samp + int(0.025 * fs)
            s1 = s0 + int(0.200 * fs)
            q0 = s0 + seg_samp              # the silent segment after it
            fk, st = peak_frequency(x[s0:s1], fs, x[q0:q0 + (s1 - s0)])
            freqs.append(fk)
            strongest.append(st)
        c = float(contrast[b])
        is_narrow = min(narrow) >= NARROW_DB
        on_freq = all(abs(fk - TONE_HZ) <= FREQ_TOL_HZ for fk in freqs)
        own = all(strongest)
        freq_ok = on_freq and own
        if is_narrow and freq_ok:
            cls = "PASS" if c >= PASS_DB else "WEAK"
        else:
            cls = "REJECT"
        why = []
        if not is_narrow:
            why.append("broadband (narrow %.1f dB)" % min(narrow))
        if not on_freq:
            why.append("frequency %s" % ",".join("%.2f" % f for f in freqs))
        if on_freq and not own:
            why.append("another component rose more than 1 kHz did")
        out.append({
            "t": start / fs,
            "contrast": c,
            "segments": [float(seg[k][b]) for k in range(N_SEG)],
            "narrow": narrow,
            "freqs": freqs,
            "class": cls,
            "why": "; ".join(why),
        })
    return out, floor_db


def report(events, floor_db, expect):
    print("floor at 1 kHz      : %.1f dBFS (median over the recording)" % floor_db)
    print("events found        : %d" % len(events))
    for n, e in enumerate(events):
        s = e["segments"]
        print("  [%d] t=%8.3f s  %-6s  contrast %5.1f dB" % (n, e["t"], e["class"],
                                                        e["contrast"]))
        print("       tone %6.1f  silence %6.1f  tone %6.1f  silence %6.1f  dBFS"
              % (s[0], s[1], s[2], s[3]))
        print("       peak %.2f / %.2f Hz   narrowband %.1f / %.1f dB%s"
              % (e["freqs"][0], e["freqs"][1], e["narrow"][0], e["narrow"][1],
                 ("   -- " + e["why"]) if e["why"] else ""))
    npass = sum(1 for e in events if e["class"] == "PASS")
    nweak = sum(1 for e in events if e["class"] == "WEAK")
    nrej = sum(1 for e in events if e["class"] == "REJECT")
    print("events_pass=%d events_weak=%d events_reject=%d" % (npass, nweak, nrej))
    if expect is None:
        print("VERDICT: NONE (no --expect given)")
        return 0
    if expect == 0:
        ok = npass == 0 and nweak == 0
        print("VERDICT: %s (control: expected no tracking tone)"
              % ("PASS" if ok else "FAIL"))
    else:
        ok = npass == expect and nweak == 0
        if not ok and nweak:
            print("NOTE: %d WEAK event(s) -- a tone near the floor, not a null" % nweak)
        print("VERDICT: %s (expected %d tracking event(s), found %d)"
              % ("PASS" if ok else "FAIL", expect, npass))
    return 0 if ok else 1


# ================================================================ WinMM ===
#
# Plain winmm through ctypes. No PortAudio, no pip: every Windows install has
# it, which is the whole point -- the instrument must not depend on a download.

class WAVEFORMATEX(ctypes.Structure):
    _pack_ = 1                     # sizeof == 18, as in mmeapi.h
    _fields_ = [("wFormatTag", ctypes.c_uint16),
                ("nChannels", ctypes.c_uint16),
                ("nSamplesPerSec", ctypes.c_uint32),
                ("nAvgBytesPerSec", ctypes.c_uint32),
                ("nBlockAlign", ctypes.c_uint16),
                ("wBitsPerSample", ctypes.c_uint16),
                ("cbSize", ctypes.c_uint16)]


class WAVEHDR(ctypes.Structure):
    _fields_ = [("lpData", ctypes.c_void_p),
                ("dwBufferLength", ctypes.c_uint32),
                ("dwBytesRecorded", ctypes.c_uint32),
                ("dwUser", ctypes.c_size_t),
                ("dwFlags", ctypes.c_uint32),
                ("dwLoops", ctypes.c_uint32),
                ("lpNext", ctypes.c_void_p),
                ("reserved", ctypes.c_size_t)]


class WAVECAPSW(ctypes.Structure):
    _fields_ = [("wMid", ctypes.c_uint16),
                ("wPid", ctypes.c_uint16),
                ("vDriverVersion", ctypes.c_uint32),
                ("szPname", ctypes.c_wchar * 32),
                ("dwFormats", ctypes.c_uint32),
                ("wChannels", ctypes.c_uint16),
                ("wReserved1", ctypes.c_uint16),
                ("dwSupport", ctypes.c_uint32)]   # waveOut only; harmless for In


WHDR_DONE = 0x1
WAVE_FORMAT_PCM = 1


def _mm():
    if os.name != "nt":
        raise SystemExit("record/play/calibrate need Windows (winmm)")
    w = ctypes.WinDLL("winmm")
    H = ctypes.c_void_p
    for pre in ("waveIn", "waveOut"):
        getattr(w, pre + "Open").argtypes = [ctypes.POINTER(H), ctypes.c_uint,
                                             ctypes.POINTER(WAVEFORMATEX),
                                             ctypes.c_size_t, ctypes.c_size_t,
                                             ctypes.c_uint32]
        for fn in ("PrepareHeader", "UnprepareHeader"):
            getattr(w, pre + fn).argtypes = [H, ctypes.POINTER(WAVEHDR),
                                             ctypes.c_uint]
        for fn in ("Reset", "Close"):
            getattr(w, pre + fn).argtypes = [H]
        getattr(w, pre + "GetDevCapsW").argtypes = [ctypes.c_size_t,
                                                    ctypes.POINTER(WAVECAPSW),
                                                    ctypes.c_uint]
    w.waveInAddBuffer.argtypes = [H, ctypes.POINTER(WAVEHDR), ctypes.c_uint]
    w.waveOutWrite.argtypes = [H, ctypes.POINTER(WAVEHDR), ctypes.c_uint]
    w.waveInStart.argtypes = [H]
    w.waveInStop.argtypes = [H]
    return w


def _fmt(rate, ch):
    return WAVEFORMATEX(WAVE_FORMAT_PCM, ch, rate, rate * ch * 2, ch * 2, 16, 0)


def _check(rc, what):
    if rc != 0:
        raise SystemExit("%s failed: MMSYSERR %d" % (what, rc))


def list_devices():
    w = _mm()
    for pre, label in (("waveIn", "record (--in)"), ("waveOut", "play (--out-dev)")):
        n = getattr(w, pre + "GetNumDevs")()
        print("%s devices: %d" % (label, n))
        for i in range(n):
            caps = WAVECAPSW()
            getattr(w, pre + "GetDevCapsW")(i, ctypes.byref(caps),
                                           ctypes.sizeof(caps))
            print("  [%d] %s" % (i, caps.szPname))
    return 0


class Player:
    """Asynchronous one-shot playback of an int16 buffer on a waveOut device."""

    def __init__(self, w, dev, samples, rate=RATE):
        self.w = w
        self.h = ctypes.c_void_p()
        fmt = _fmt(rate, 1)
        _check(w.waveOutOpen(ctypes.byref(self.h), dev, ctypes.byref(fmt), 0, 0, 0),
               "waveOutOpen")
        self.data = ctypes.create_string_buffer(samples.tobytes())
        self.hdr = WAVEHDR(ctypes.cast(self.data, ctypes.c_void_p), len(samples) * 2,
                           0, 0, 0, 0, None, 0)
        _check(w.waveOutPrepareHeader(self.h, ctypes.byref(self.hdr),
                                      ctypes.sizeof(self.hdr)), "waveOutPrepareHeader")

    def start(self):
        _check(self.w.waveOutWrite(self.h, ctypes.byref(self.hdr),
                                   ctypes.sizeof(self.hdr)), "waveOutWrite")

    def done(self):
        return bool(self.hdr.dwFlags & WHDR_DONE)

    def close(self):
        deadline = time.monotonic() + 5.0
        while not self.done() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.w.waveOutReset(self.h)
        self.w.waveOutUnprepareHeader(self.h, ctypes.byref(self.hdr),
                                      ctypes.sizeof(self.hdr))
        self.w.waveOutClose(self.h)


def record(dev, seconds, out_path, stop_file=None, play=None, play_at=1.0,
           rate=RATE):
    """Record mono 16-bit from a waveIn device straight to a WAV file.

    Buffers are serviced strictly in queue order, so a burst of completions
    can never be written out of sequence -- an analysis that slides a template
    across the file depends on the samples being in the order they arrived.
    """
    w = _mm()
    h = ctypes.c_void_p()
    fmt = _fmt(rate, 1)
    _check(w.waveInOpen(ctypes.byref(h), dev, ctypes.byref(fmt), 0, 0, 0),
           "waveInOpen")
    nbuf, buf_bytes = 16, rate * 2 // 20            # 16 x 50 ms
    bufs = [ctypes.create_string_buffer(buf_bytes) for _ in range(nbuf)]
    hdrs = [WAVEHDR(ctypes.cast(b, ctypes.c_void_p), buf_bytes, 0, 0, 0, 0, None, 0)
            for b in bufs]
    for hd in hdrs:
        _check(w.waveInPrepareHeader(h, ctypes.byref(hd), ctypes.sizeof(hd)),
               "waveInPrepareHeader")
        _check(w.waveInAddBuffer(h, ctypes.byref(hd), ctypes.sizeof(hd)),
               "waveInAddBuffer")
    out = wave.open(out_path, "wb")
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    target = int(seconds * rate) * 2
    got = 0
    order = list(range(nbuf))
    _check(w.waveInStart(h), "waveInStart")
    t0 = time.monotonic()
    started = False
    print("recording: device %d, %.0f s, %s" % (dev, seconds, out_path), flush=True)
    try:
        while got < target:
            if play is not None and not started and time.monotonic() - t0 >= play_at:
                play.start()
                started = True
            if stop_file and os.path.exists(stop_file):
                print("stop file seen, ending early", flush=True)
                break
            hd = hdrs[order[0]]
            if not hd.dwFlags & WHDR_DONE:
                time.sleep(0.005)
                continue
            n = hd.dwBytesRecorded
            if n:
                out.writeframes(ctypes.string_at(hd.lpData, n))
                got += n
            hd.dwFlags &= ~WHDR_DONE
            hd.dwBytesRecorded = 0
            _check(w.waveInAddBuffer(h, ctypes.byref(hd), ctypes.sizeof(hd)),
                   "waveInAddBuffer")
            order.append(order.pop(0))
    finally:
        w.waveInStop(h)
        w.waveInReset(h)
        for hd in hdrs:
            w.waveInUnprepareHeader(h, ctypes.byref(hd), ctypes.sizeof(hd))
        w.waveInClose(h)
        out.close()
    print("recorded %.1f s" % (got / 2 / rate), flush=True)
    return got / 2 / rate


# ============================================================== selftest ===

def selftest():
    """Synthetic recordings chosen to break the analysis, not to flatter it."""
    rng = np.random.default_rng(1520)
    fs = RATE
    total = 0
    fails = 0

    def canvas(seconds, noise_dbfs=-60.0, fs_=fs):
        return rng.normal(0.0, 10 ** (noise_dbfs / 20.0), int(seconds * fs_))

    def place(buf, at, sig, fs_=fs):
        i = int(at * fs_)
        buf[i:i + len(sig)] += sig
        return buf

    def pattern(dbfs, hz=TONE_HZ, fs_=fs):
        amp = 10 ** (dbfs / 20.0)
        seg = int(SEG_S * fs_)
        t = np.arange(seg * N_SEG) / fs_
        s = amp * np.sin(2 * np.pi * hz * t)
        s[(np.arange(len(s)) // seg) % 2 == 1] = 0.0
        return s

    def gated_noise(dbfs, fs_=fs):
        seg = int(SEG_S * fs_)
        s = rng.normal(0.0, 10 ** (dbfs / 20.0), seg * N_SEG)
        s[(np.arange(len(s)) // seg) % 2 == 1] = 0.0
        return s

    def case(name, x, want, fs_=fs):
        nonlocal total, fails
        ev, _ = analyse(x, fs_)
        got = [e["class"] for e in ev]
        ok = got == want
        total += 1
        if not ok:
            fails += 1
        print("  %s %-58s got=%s" % ("ok  " if ok else "FAIL", name, got or "[]"))

    print("== the stimulus generator matches pcm-tone ==")
    st = stimulus(-40.0)
    for label, got, want in (("peak sample at -40 dBFS", int(st.max()), 328),
                             ("first four samples", list(st[:4]), [0, 43, 85, 126]),
                             ("quarter-period sample", int(st[12]), 328),
                             ("one second long", len(st), 48000),
                             ("second segment is silent",
                              int(np.abs(st[12000:24000]).max()), 0)):
        total += 1
        ok = got == want
        fails += 0 if ok else 1
        print("  %s %-58s %s" % ("ok  " if ok else "FAIL", label, got))
    try:
        stimulus(-10.0)
        refused = False
    except ValueError:
        refused = True
    total += 1
    fails += 0 if refused else 1
    print("  %s %-58s %s" % ("ok  " if refused else "FAIL",
                             "the -20 dBFS ceiling refuses -10", refused))

    print("== what must be found ==")
    case("one clean pattern", place(canvas(4), 1.234, pattern(-30)), ["PASS"])
    case("two patterns, two cycles",
         place(place(canvas(9), 1.0, pattern(-30)), 6.5, pattern(-30)),
         ["PASS", "PASS"])
    case("the real stimulus, int16-scaled",
         place(canvas(4), 1.0, stimulus(-40.0) / 32768.0), ["PASS"])
    case("1003 Hz is within tolerance", place(canvas(4), 1.0, pattern(-30, 1003.0)),
         ["PASS"])
    case("44.1 kHz recording", place(canvas(4, fs_=44100), 1.0,
                                     pattern(-30, fs_=44100), 44100),
         ["PASS"], 44100)
    case("a tone near the floor is WEAK, not a null",
         place(canvas(4), 1.0, pattern(-70)), ["WEAK"])

    print("== what must NOT pass ==")
    case("noise only", canvas(4), [])
    case("a tone that ignores the digital silence",
         place(canvas(4), 1.0, 0.03 * np.sin(2 * np.pi * TONE_HZ
                                             * np.arange(fs) / fs)), [])
    case("only the first burst", place(canvas(4), 1.0,
                                       pattern(-30)[:int(SEG_S * fs)]), [])
    case("the right timing at 1500 Hz", place(canvas(4), 1.0, pattern(-30, 1500.0)),
         [])
    case("the right timing at 1010 Hz", place(canvas(4), 1.0, pattern(-30, 1010.0)),
         ["REJECT"])
    case("broadband noise gated by the pattern", place(canvas(4), 1.0,
                                                       gated_noise(-30)),
         ["REJECT"])
    case("loud steady room rumble does not hide a real tone",
         place(canvas(4) + 10 ** (-40 / 20.0) * np.sin(2 * np.pi * 150 * np.arange(4 * fs) / fs),
               1.0, pattern(-55)), ["PASS"])
    hum = canvas(4)
    gate = np.zeros(len(hum))
    seg = int(SEG_S * fs)
    for k_ in (0, 2):                 # a USB DAC un-muting during the tones
        gate[int(1.0 * fs) + k_ * seg:int(1.0 * fs) + (k_ + 1) * seg] = 1.0
    hum += gate * 10 ** (-48 / 20.0) * np.sin(2 * np.pi * 112 * np.arange(len(hum)) / fs)
    hum += 10 ** (-58 / 20.0) * np.sin(2 * np.pi * 112 * np.arange(len(hum)) / fs)
    case("playback-device hum that un-mutes with the tones",
         place(hum, 1.0, pattern(-50)), ["PASS"])
    case("a dominant 2500 Hz effect with 1 kHz only as leakage",
         place(place(canvas(4), 1.0, pattern(-30, 2500.0)), 1.0, pattern(-50)),
         ["REJECT"])
    thump = canvas(4)
    thump[int(1.5 * fs):int(1.5 * fs) + 200] += 0.5
    case("a thump at PA enable", thump, [])

    print("== the verdict logic ==")
    ev, fl = analyse(place(place(canvas(9), 1.0, pattern(-30)), 6.5, pattern(-30)), fs)
    for label, expect, want in (("two events expected two: PASS", 2, 0),
                                ("two events expected one: FAIL", 1, 1),
                                ("two events as a control: FAIL", 0, 1)):
        devnull = open(os.devnull, "w")
        old, sys.stdout = sys.stdout, devnull
        try:
            rc = report(ev, fl, expect)
        finally:
            sys.stdout = old
            devnull.close()
        total += 1
        ok = rc == want
        fails += 0 if ok else 1
        print("  %s %-58s rc=%d" % ("ok  " if ok else "FAIL", label, rc))

    print("\n%d passed, %d failed" % (total - fails, fails))
    return 1 if fails else 0


# ================================================================== main ===

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    r = sub.add_parser("record")
    r.add_argument("--in", dest="dev", type=int, required=True)
    r.add_argument("--seconds", type=float, required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--stop-file")
    p = sub.add_parser("play")
    p.add_argument("--out-dev", type=int, required=True)
    p.add_argument("--dbfs", type=float, default=DBFS_DEFAULT)
    c = sub.add_parser("calibrate")
    c.add_argument("--in", dest="dev", type=int, required=True)
    c.add_argument("--out-dev", type=int, required=True)
    c.add_argument("--wav", required=True)
    c.add_argument("--dbfs", type=float, default=DBFS_DEFAULT)
    a = sub.add_parser("analyse")
    a.add_argument("wav")
    a.add_argument("--expect", type=int)
    sub.add_parser("selftest")
    args = ap.parse_args()

    if args.cmd == "list":
        return list_devices()
    if args.cmd == "selftest":
        return selftest()
    if args.cmd == "analyse":
        x, fs = load_wav(args.wav)
        print("file                : %s (%.1f s at %d Hz)" % (args.wav, len(x) / fs, fs))
        ev, fl = analyse(x, fs)
        return report(ev, fl, args.expect)
    if args.cmd == "record":
        record(args.dev, args.seconds, args.out, args.stop_file)
        return 0
    if args.cmd == "play":
        w = _mm()
        pl = Player(w, args.out_dev, stimulus(args.dbfs))
        print("playing the C3a stimulus at %.1f dBFS on device %d"
              % (args.dbfs, args.out_dev))
        pl.start()
        pl.close()
        return 0
    if args.cmd == "calibrate":
        w = _mm()
        pl = Player(w, args.out_dev, stimulus(args.dbfs))
        print("calibration: the C3a stimulus at %.1f dBFS from the PC, device %d"
              % (args.dbfs, args.out_dev))
        try:
            record(args.dev, 3.5, args.wav, play=pl, play_at=1.0)
        finally:
            pl.close()
        x, fs = load_wav(args.wav)
        ev, fl = analyse(x, fs)
        return report(ev, fl, 1)
    return 2


if __name__ == "__main__":
    sys.exit(main())

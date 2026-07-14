#!/usr/bin/env python3
"""Synthesize the call tone assets (no external files / licensing).

  python3 tools/gen_sounds.py

Writes:
  assets/sounds/ringback.wav  — RU ringback (425 Hz, 1s on / 4s off), loopable
  assets/sounds/call_end.wav  — soft descending two-tone played when a call ends
"""
import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds")


def _samples_tone(freq, ms, amp=0.5, fade_ms=8):
    n = int(RATE * ms / 1000)
    fade = int(RATE * fade_ms / 1000)
    out = []
    for i in range(n):
        v = math.sin(2 * math.pi * freq * (i / RATE)) * amp
        if i < fade:  # linear fade-in/out to avoid clicks
            v *= i / fade
        elif i > n - fade:
            v *= (n - i) / fade
        out.append(v)
    return out


def _silence(ms):
    return [0.0] * int(RATE * ms / 1000)


def _write(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        )
        w.writeframes(frames)
    print(f"wrote {path} ({len(samples) / RATE:.2f}s)")


# RU ringback (КПВ): 425 Hz, 1s on, 4s off — loops seamlessly.
_write(os.path.join(OUT, "ringback.wav"),
       _samples_tone(425, 1000, amp=0.5) + _silence(4000))

# Call-ended cue: three short 425 Hz beeps — same tone family as the ringback.
_beep = _samples_tone(425, 220, amp=0.9)
_write(os.path.join(OUT, "call_end.wav"),
       _beep + _silence(110) + _beep + _silence(110) + _beep)

#!/usr/bin/env python3
"""Generate the satellite's listening/finished tones.

wyoming-satellite ships no sounds when installed from PyPI, and plays nothing
unless given WAV files — leaving you talking into silence with no idea whether
the wake word registered. These are deliberately short and quiet so they don't
talk over the music.

    python3 make_satellite_sounds.py ~/wyoming-satellite/sounds
"""

import math
import os
import struct
import sys
import wave

RATE = 22050


def tone(path, notes, volume=0.35):
    """notes: [(frequency_hz, milliseconds)]. Short fades avoid clicks."""
    frames = []
    for freq, ms in notes:
        n = int(RATE * ms / 1000)
        fade = max(1, int(RATE * 0.008))
        for i in range(n):
            env = min(1.0, i / fade, (n - i) / fade)
            frames.append(
                int(32767 * volume * env * math.sin(2 * math.pi * freq * i / RATE))
            )
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", s) for s in frames))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    # Rising pair for "listening", falling pair for "finished".
    tone(os.path.join(out, "awake.wav"), [(880, 90), (1320, 110)])
    tone(os.path.join(out, "done.wav"), [(1320, 80), (660, 120)])
    print("wrote awake.wav and done.wav to", out)

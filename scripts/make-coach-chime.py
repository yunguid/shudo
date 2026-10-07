#!/usr/bin/env python3
"""Synthesizes Shudo's text tone: a soft, two-note glass chime.

Writes a mono 16-bit WAV, then converts it to the bundled
`shudo/Sounds/coach_text.caf` with `afconvert` (macOS). Pure standard
library so it runs anywhere Python 3 does.

    python3 scripts/make-coach-chime.py

The tone is deliberately quiet and short (under a second, peak about
-7 dBFS): a perfect fifth up, G5 then D6, each a sine with a faint octave
and a quickly fading bell partial, so it reads as "a text from someone"
rather than an alarm.
"""

import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 44_100
DURATION = 0.92
PEAK = 0.44  # about -7 dBFS

# (start seconds, frequency Hz, gain, decay time constant seconds)
NOTES = [
    (0.000, 783.99, 0.80, 0.16),   # G5
    (0.115, 1174.66, 1.00, 0.24),  # D6
]
# (frequency ratio, relative gain, decay multiplier) layered on each note.
PARTIALS = [
    (1.0, 1.00, 1.00),
    (2.0, 0.22, 0.45),
    (2.76, 0.07, 0.20),  # inharmonic "glass" shimmer, gone in a blink
]
ATTACK = 0.004
TAIL_FADE = 0.12


def sample(t: float) -> float:
    value = 0.0
    for start, freq, gain, tau in NOTES:
        local = t - start
        if local < 0:
            continue
        attack = 0.5 - 0.5 * math.cos(math.pi * min(1.0, local / ATTACK))
        for ratio, partial_gain, decay_mult in PARTIALS:
            envelope = math.exp(-local / (tau * decay_mult))
            value += gain * partial_gain * attack * envelope * math.sin(
                2 * math.pi * freq * ratio * local
            )
    # Fade the last stretch to true silence so there is no click.
    remaining = DURATION - t
    if remaining < TAIL_FADE:
        value *= 0.5 - 0.5 * math.cos(math.pi * max(0.0, remaining) / TAIL_FADE)
    return value


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output = os.path.join(root, "shudo", "Sounds", "coach_text.caf")
    count = int(RATE * DURATION)
    raw = [sample(i / RATE) for i in range(count)]
    scale = PEAK / max(abs(v) for v in raw)
    frames = b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, v * scale)) * 32767)) for v in raw
    )
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "coach_text.wav")
        with wave.open(wav_path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(frames)
        subprocess.run(
            ["afconvert", "-f", "caff", "-d", "LEI16@44100", "-c", "1", wav_path, output],
            check=True,
        )
    print(f"wrote {output} ({DURATION:.2f}s, peak {20 * math.log10(PEAK):.1f} dBFS)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

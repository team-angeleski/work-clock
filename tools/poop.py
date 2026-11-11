"""Synthesises a short, silly 'pfffrrt' for the poop prank. No samples, pure maths.

Usage: python3 poop.py out.wav
"""
import math
import random
import struct
import sys
import wave

RATE = 22050
DURATION = 0.85
random.seed(7)

frames = []
phase = 0.0
noise = 0.0
for i in range(int(RATE * DURATION)):
    t = i / RATE
    # Pitch sags from ~120Hz to ~60Hz with a wobble: the classic deflating sound.
    freq = 120 - 60 * (t / DURATION) + 8 * math.sin(2 * math.pi * 3 * t)
    freq *= 1 + random.uniform(-0.04, 0.04)
    phase += freq / RATE
    saw = 2 * (phase % 1) - 1
    # Fast flutter gives the 'brrr' texture.
    flutter = 0.55 + 0.45 * math.sin(2 * math.pi * 28 * t)
    noise = 0.7 * noise + 0.3 * random.uniform(-1, 1)
    # Envelope: quick puff in, long trail off, a little splutter at the end.
    env = min(t / 0.03, 1) * (1 - t / DURATION) ** 0.6
    if t > DURATION * 0.75:
        env *= 0.6 + 0.4 * (random.random() > 0.5)
    sample = (0.75 * saw * flutter + 0.35 * noise) * env
    frames.append(struct.pack("<h", int(max(-1, min(1, sample)) * 22000)))

with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(b"".join(frames))

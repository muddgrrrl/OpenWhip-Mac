"""Synthesize a short whip crack from filtered noise and a decaying swish."""

import math
import random
import struct
import sys
import wave

sample_rate = 44100
rng = random.Random(11)
previous = 0.0
samples = bytearray()

for index in range(int(sample_rate * 0.19)):
    t = index / sample_rate
    noise = rng.uniform(-1.0, 1.0)
    previous += 0.3 * (noise - previous)
    swish = 0.16 * previous * math.exp(-((t - 0.024) / 0.012) ** 2)
    crack_time = t - 0.039
    crack = 0.0
    if crack_time >= 0:
        crack = 0.74 * (noise - previous) * math.exp(-crack_time / 0.011)
        crack += 0.17 * math.sin(2 * math.pi * 290 * crack_time) * math.exp(-crack_time / 0.022)
    samples.extend(struct.pack("<h", int(32767 * max(-1.0, min(1.0, swish + crack)))))

with wave.open(sys.argv[1], "wb") as output:
    output.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
    output.writeframes(samples)

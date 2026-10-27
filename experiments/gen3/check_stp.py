#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent polynomial-division oracle for Gen3 STP protection."""
from itertools import combinations
from pathlib import Path
import random
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = root / "experiments/gen3"
(root / "build").mkdir(exist_ok=True)
out = Path(tempfile.mkdtemp(prefix="gen3_stp_", dir=root / "build"))
rng = random.Random(0x130)


def encode(length, sequence):
    remainder = sum(((length >> b) & 1) << (14-b) for b in range(11))
    for power in range(14, 3, -1):
        if remainder & (1 << power):
            remainder ^= 0x13 << (power-4)
    parity = (length.bit_count()+remainder.bit_count()) & 1
    return ((length & 15) << 4 | 15 | (length >> 4) << 8 | parity << 15 |
            (sequence >> 8) << 16 | remainder << 20 | (sequence & 255) << 24)


rows = []


def vector(length, sequence, incoming, valid, eds=False):
    expected = encode(length, sequence) | int(valid) << 32 | int(eds) << 33
    stimulus = incoming | sequence << 32 | length << 44
    rows.append((expected << 55) | stimulus)


for length in range(2048):
    sequence = rng.randrange(4096)
    incoming = encode(length, sequence)
    vector(length, sequence, incoming, 2 <= length < 1152)
assert encode(1, 0) == 0x0090801f
vector(1, 0, encode(1, 0), False, True)
protected = list(range(4, 16)) + list(range(20, 24))
for length in (5, 36, 1151):
    for weight in (1, 2, 3):
        for flips in combinations(protected, weight):
            token = encode(length, 0xabc)
            for bit in flips:
                token ^= 1 << bit
            vector(length, 0xabc, token, False)
for bit in range(32):
    vector(1, 0, encode(1, 0) ^ (1 << bit), False)
(out/"vectors.hex").write_text("".join(f"{v:023x}\n" for v in rows))
subprocess.run(["iverilog", "-g2012", "-s", "test_stp", "-o", str(out/"test"),
                str(src/"gen3_stp.sv"), str(src/"test_stp.sv")], check=True)
subprocess.run(["vvp", str(out/"test"), f"+vectors={out/'vectors.hex'}", f"+count={len(rows)}"], check=True)
subprocess.run(["verilator", "--lint-only", "--Wall", str(src/"gen3_stp.sv")], check=True)
print(f"STP results: {out}")

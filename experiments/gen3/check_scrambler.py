#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test against Appendix C.2 tables in the user's local draft; do not vendor it."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("spec", type=Path, help="PCIe Base 4.0 v0.3, February 19 2014 PDF")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
(root / "build").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="gen3_scrambler_", dir=root / "build"))
subprocess.run(["pdftotext", "-f", "998", "-l", "998", "-layout",
                str(args.spec.resolve()), str(work / "vectors.txt")], check=True)
page = (work / "vectors.txt").read_text()


def read_table(digits, columns):
    values = []
    for line in page.splitlines():
        match = re.fullmatch(r"\s*([0-9A-F]{2})\s+((?:[0-9A-F]{%d}\s+){%d}[0-9A-F]{%d})\s*"
                             % (digits, columns - 1, digits), line)
        if match:
            if int(match[1], 16) != len(values):
                raise ValueError("Unexpected table ordering; inspect local PDF")
            values.extend(match[2].split())
    if len(values) != 128:
        raise ValueError("Expected 128 independent values; inspect local PDF")
    return values


states, masks = read_table(6, 8), read_table(2, 16)
if states[0] != "1DBFBC" or masks[0] != "6C":
    raise ValueError("Unexpected lane/table identity")
for name, values in (("states", states), ("masks", masks)):
    (work / f"{name}.hex").write_text("\n".join(values) + "\n")
source = root / "experiments/gen3"
subprocess.run(["iverilog", "-g2012", "-s", "test_scrambler", "-o", str(work / "test.vvp"),
                str(source / "gen3_scrambler.sv"), str(source / "test_scrambler.sv")], check=True)
subprocess.run(["vvp", str(work / "test.vvp"), f"+masks={work / 'masks.hex'}",
                f"+states={work / 'states.hex'}"], check=True)
subprocess.run(["verilator", "--lint-only", "--Wall", str(source / "gen3_scrambler.sv")], check=True)
print(f"Reference-derived vectors and simulation outputs remain local: {work}")

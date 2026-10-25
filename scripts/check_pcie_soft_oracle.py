#!/usr/bin/env python3
"""Check original RTL against hash-pinned, external test-only PCIe arithmetic.

Upstream pcievhost is GPL-3.0-or-later. Its unmodified sources and license stay
in an ignored reference cache; none enter the hardware build or tracked RTL.
This checks arithmetic only, not LTSSM, packet framing or PCIe compliance.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def reverse(value, bits):
    return int(f'{value & ((1 << bits)-1):0{bits}b}'[::-1], 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch', action='store_true', help='Download the locked external test sources')
    parser.add_argument('--reference', type=Path, default=ROOT / 'build/pcie_soft_reference')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reference, output = args.reference.resolve(), args.output.resolve()
    # Never download GPL reference code into the tracked source tree.
    for directory in (reference, output):
        if not directory.is_relative_to(ROOT / 'build'):
            raise ValueError('Reference cache and results must be below ignored build/')
    lock = json.loads((ROOT / 'tests/pcie_soft/reference.lock.json').read_text())
    for name, expected in lock['files'].items():
        path = reference / name
        if not path.exists():
            if not args.fetch:
                raise FileNotFoundError(f'{path}: rerun with --fetch to obtain locked test-only sources')
            url = f"https://raw.githubusercontent.com/wyvernSemi/pcievhost/{lock['commit']}/{name}"
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f'Download hash mismatch: {name}')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Cached reference hash mismatch: {name}')
    output.mkdir(parents=True, exist_ok=True)
    library = output / 'crc_oracle.so'
    run(['cc', '-shared', '-fPIC', '-DVPROC_SV', reference / 'src/pcicrc32.c', '-o', library])
    oracle = ctypes.CDLL(str(library))
    oracle.PciCrc32.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_uint), ctypes.c_int]
    oracle.PciCrc16.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_uint)]
    rows = []
    rng = random.Random(0x15e6)
    words = [0, 0xffffffff, 0x01234567, 0x89abcdef] + [1 << i for i in range(32)]
    words += [rng.getrandbits(32) for _ in range(4096)]
    for word in words:
        crc32, crc16 = ctypes.c_uint(0xffffffff), ctypes.c_uint(0xffff)
        oracle.PciCrc32(word, ctypes.byref(crc32), 32)
        oracle.PciCrc16(word, ctypes.byref(crc16))
        rows.append(f'{word:08x} {reverse(crc32.value, 32)^0xffffffff:08x} '
                    f'{reverse(crc16.value, 16)^0xffff:04x}')
    vectors = output / 'crc_vectors.txt'
    vectors.write_text('\n'.join(rows) + '\n')
    messages = []
    for top, sources, options, plusargs in [
        ('tb_external_crc', [ROOT / 'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_crc.sv'], [], [f'+VECTORS={vectors}']),
        ('tb_external_scrambler', [ROOT / 'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_scrambler.sv',
                                 reference / 'verilog/lib/ScrambleCodec.v'],
         ['-DWsTimeScale=', '-DRegDel=0'], [])
    ]:
        executable = output / (top + '.vvp')
        run(['iverilog', '-g2012', '-s', top, '-o', executable] + options + sources +
            [ROOT / 'tests/pcie_soft' / (top + '.sv')])
        message = run(['vvp', executable] + plusargs)
        if 'PASS' not in message:
            raise RuntimeError(message)
        messages.append(message)
        print(message, end='')
    (output / 'validation.json').write_text(json.dumps({
        'status': 'ARITHMETIC_PASS_ONLY', 'reference': lock,
        'crc_dwords': len(words), 'scrambler_states': 65536,
        'messages': messages, 'hardware_programmed': False
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()

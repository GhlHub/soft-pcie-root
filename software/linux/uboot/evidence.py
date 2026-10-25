#!/usr/bin/env python3
"""Record/check the exact FMC sources and U-Boot outputs from a successful build."""
import argparse
import hashlib
import json
from pathlib import Path


def snapshot(build):
    local = Path(__file__).resolve().parent
    files = {str(p.relative_to(local)): p for p in sorted(local.iterdir())
             if p.suffix in ('.c', '.h', '.py')}
    result = {'local': {}, 'build': {}}
    for name, path in files.items():
        result['local'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        if path.suffix in ('.c', '.h'):
            installed = build / 'board/xilinx/zynqmp' / name
            if installed.read_bytes() != path.read_bytes():
                raise ValueError(f'Stale installed FMC source: {name}')
    for name in ('u-boot', 'u-boot.itb', 'spl/boot.bin', '.config',
                 'board/xilinx/zynqmp/zynqmp.c', 'board/xilinx/zynqmp/Makefile'):
        result['build'][name] = hashlib.sha256((build / name).read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['record', 'check'])
    parser.add_argument('build', type=Path)
    args = parser.parse_args()
    evidence = args.build / 'fmc-build.json'
    actual = snapshot(args.build)
    if args.action == 'record':
        evidence.write_text(json.dumps(actual, indent=2) + '\n')
    elif json.loads(evidence.read_text()) != actual:
        raise SystemExit('FMC/U-Boot inputs or outputs changed since build')


if __name__ == '__main__':
    main()

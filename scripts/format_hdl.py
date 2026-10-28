#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Format tracked HDL, requiring convergence and whitespace-token equivalence."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def group_ports(text):
    """Keep inherited-type port names with their declaration, not at column 4."""
    lines = []
    in_group = False
    for line in text.splitlines():
        line = line.rstrip()
        if re.match(r'^\s*(input|output|inout)\s', line):
            in_group = True
        elif in_group and re.fullmatch(r'\s*[A-Za-z_][A-Za-z_0-9]*,?\s*', line):
            if lines[-1].rstrip().endswith(','):
                if len(lines[-1]) + 1 + len(line.strip()) <= 100:
                    lines[-1] += ' ' + line.strip()
                    continue
                line = '        ' + line.strip()
            else:
                in_group = False
        else:
            in_group = False
        lines.append(line)
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='apply changes; default is check only')
    parser.add_argument('--bin-dir', default=os.environ.get('VERIBLE_BIN'))
    args = parser.parse_args()
    def tool(name):
        path = str(Path(args.bin_dir) / name) if args.bin_dir else shutil.which(name)
        if not path:
            parser.error(f'{name} not found; set VERIBLE_BIN or --bin-dir')
        return path
    formatter, diff = tool('verible-verilog-format'), tool('verible-verilog-diff')
    files = subprocess.check_output(
        ['git', 'ls-files', '-z', '*.sv', '*.v', '*.svh', '*.vh'], cwd=ROOT,
    ).decode().strip('\0').split('\0')
    changes = {}
    with tempfile.TemporaryDirectory(prefix='soft-pcie-format-') as tmp:
        before, after = Path(tmp) / 'before.sv', Path(tmp) / 'after.sv'
        for name in files:
            source = (ROOT / name).read_bytes()
            current = source
            flags = ['--flagfile=' + str(ROOT / '.verible-format'),
                     '--failsafe_success=false', '--verify_convergence=false']
            # Verible's line-wrap search explodes on the large diagnostic XOR.
            # Preserve its manual wrapping, while still checking all tokens.
            if name == 'experiments/gen3/gen3_eq_bringup.sv':
                flags += ['--try_wrap_long_lines=false']
            for _ in range(6):
                result = subprocess.run([formatter, *flags, '-'], input=current,
                                        capture_output=True, check=True)
                candidate = group_ports(result.stdout.decode()).encode()
                if candidate == current:
                    break
                current = candidate
            else:
                raise RuntimeError(f'Formatting did not converge: {name}')
            before.write_bytes(source)
            after.write_bytes(current)
            subprocess.run([diff, str(before), str(after)], check=True, capture_output=True)
            if current != source:
                changes[name] = current
        # Validate every file before applying any changes.
        if args.write:
            for name, content in changes.items():
                (ROOT / name).write_bytes(content)
    print(f'{len(files)} HDL files checked; {len(changes)} '
          + ('formatted' if args.write else 'need formatting')
          + '; token equivalence passed')
    if changes and not args.write:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

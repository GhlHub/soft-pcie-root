#!/usr/bin/env python3
"""Capture passive Linux bring-up evidence without probing or changing hardware.

Run manually on the target. No PCI config/resource mappings, NVMe commands,
module loading, network operations, or disk discovery are performed.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

ENDPOINT = '0001:01:00.0'
FILES = {
    'kernel-version': 'proc/version',
    'command-line': 'proc/cmdline',
    'memory': 'proc/meminfo',
    'interrupts': 'proc/interrupts',
    'modules': 'proc/modules',
    'mounts': 'proc/mounts',
    'device-tree-model': 'sys/firmware/devicetree/base/model',
    'device-tree-compatible': 'sys/firmware/devicetree/base/compatible',
}
# Deliberately omit current_link_speed/width: Linux may read PCI config
# space to implement those sysfs attributes. These fields are cached metadata.
PCI_FIELDS = ('vendor', 'device', 'class', 'enable', 'irq', 'resource')


def snapshot(root, output):
    """Read only named kernel metadata; missing files remain explicit evidence."""
    results = {}
    paths = dict(FILES)
    base = f'sys/bus/pci/devices/{ENDPOINT}'
    for name in PCI_FIELDS:
        paths[f'pci-{name}'] = f'{base}/{name}'
    for label, relative in paths.items():
        try:
            data = (root / relative).read_bytes()
            (output / f'{label}.txt').write_bytes(data)
            results[label] = {'status': 'captured', 'bytes': len(data)}
        except OSError as exc:
            results[label] = {'status': 'unavailable', 'error': str(exc)}
    endpoint = root / base
    try:
        results['pci-driver'] = {'status': 'captured',
                                 'target': os.readlink(endpoint / 'driver')}
    except OSError as exc:
        results['pci-driver'] = {'status': 'unavailable', 'error': str(exc)}
    try:
        vectors = sorted(p.name for p in (endpoint / 'msi_irqs').iterdir())
        results['pci-msi-vectors'] = {'status': 'captured', 'vectors': vectors}
    except OSError as exc:
        results['pci-msi-vectors'] = {'status': 'unavailable', 'error': str(exc)}
    return results


def hash_artifact(path):
    # Refuse devices/FIFOs, including paths which resolve to a block device.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('artifact must be a regular file')
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def collect(output, artifacts, board_note):
    output.mkdir(parents=True, exist_ok=False)
    report = {
        'schema': 1,
        'captured_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'endpoint': ENDPOINT,
        'operator_board_note': board_note,
        'qualification': 'Evidence capture only; no probe, MSI delivery, DMA or SSD I/O test.',
        'files': snapshot(Path('/'), output),
        'artifacts': [],
    }
    try:
        result = subprocess.run(['dmesg'], capture_output=True, timeout=10, check=False)
        (output / 'dmesg.txt').write_bytes(result.stdout)
        (output / 'dmesg-stderr.txt').write_bytes(result.stderr)
        report['dmesg'] = {'status': 'captured' if result.returncode == 0 else 'failed',
                           'returncode': result.returncode}
    except (OSError, subprocess.TimeoutExpired) as exc:
        report['dmesg'] = {'status': 'unavailable', 'error': str(exc)}
    for path in artifacts:
        entry = {'path': str(path)}
        try:
            # Precheck before opening to avoid blocking on a FIFO.
            if not path.is_file():
                raise ValueError('artifact must be a regular file')
            entry.update(status='hashed', sha256=hash_artifact(path))
        except (OSError, ValueError) as exc:
            entry.update(status='unavailable', error=str(exc))
        report['artifacts'].append(entry)
    report['capture_sha256'] = {
        p.name: hash_artifact(p) for p in sorted(output.iterdir()) if p.is_file()
    }
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path,
                        help='fresh directory for local evidence files')
    parser.add_argument('--artifact', action='append', default=[], type=Path,
                        help='explicit regular boot/image file to hash; repeatable')
    parser.add_argument('--board-note', default='',
                        help='operator-observed revision, adapter, VADJ and SSD identity')
    args = parser.parse_args()
    report = collect(args.output, args.artifact, args.board_note)
    missing = sum(v['status'] != 'captured' for v in report['files'].values())
    print(f'Evidence saved to {args.output}; {missing} metadata items unavailable.')
    print('Review manifest.json; capture completion does not mean hardware passed.')


if __name__ == '__main__':
    main()

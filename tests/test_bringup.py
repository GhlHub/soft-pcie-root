"""Passive evidence collection must tolerate baseline boots and avoid devices."""
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest

spec = importlib.util.spec_from_file_location(
    'collect_bringup', Path(__file__).resolve().parents[1] / 'scripts/collect_bringup.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def test_snapshot_missing_endpoint_and_allowed_metadata(tmp_path):
    root = tmp_path / 'root'
    output = tmp_path / 'output'
    output.mkdir()
    (root / 'proc').mkdir(parents=True)
    (root / 'proc/version').write_text('fixture kernel\n')
    result = collector.snapshot(root, output)
    assert result['kernel-version']['status'] == 'captured'
    assert result['pci-resource']['status'] == 'unavailable'
    assert (output / 'kernel-version.txt').read_text() == 'fixture kernel\n'
    endpoint = root / f'sys/bus/pci/devices/{collector.ENDPOINT}'
    (endpoint / 'msi_irqs').mkdir(parents=True)
    (endpoint / 'msi_irqs/47').touch()
    (endpoint / 'resource').write_text('00000000a3000000 00000000a3003fff 00000200\n')
    (endpoint / 'driver').symlink_to('../../../drivers/nvme')
    # These must never be opened/copied, even if present.
    (endpoint / 'config').write_bytes(b'not passive metadata')
    (endpoint / 'resource0').write_bytes(b'BAR mapping')
    result = collector.snapshot(root, output)
    assert result['pci-msi-vectors']['vectors'] == ['47']
    assert result['pci-driver']['target'].endswith('/nvme')
    assert not (output / 'pci-config.txt').exists()
    assert not (output / 'pci-resource0.txt').exists()


def test_collection_records_failures_and_preserves_previous_output(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, 'snapshot', lambda root, output: {})
    calls = []
    def denied(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 1, b'', b'permission denied')
    monkeypatch.setattr(collector.subprocess, 'run', denied)
    artifact = tmp_path / 'Image'
    artifact.write_bytes(b'kernel')
    fifo = tmp_path / 'fifo'
    collector.os.mkfifo(fifo)
    output = tmp_path / 'capture'
    report = collector.collect(output, [artifact, fifo, Path('/dev/null')], 'fixture only')
    assert calls == [['dmesg']]
    assert report['dmesg']['status'] == 'failed'
    assert report['artifacts'][0]['sha256'] == collector.hash_artifact(artifact)
    assert all(a['status'] == 'unavailable' for a in report['artifacts'][1:])
    assert json.loads((output / 'manifest.json').read_text()) == report
    with pytest.raises(FileExistsError):
        collector.collect(output, [], '')
    assert len(calls) == 1

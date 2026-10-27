# SPDX-License-Identifier: Apache-2.0
"""Experimental native startup, including a peer that independently enters idle."""
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_bench(tmp_path, top, **parameters):
    sources = sorted((ROOT / 'ip/soft_pcie_root/rtl').rglob('*.sv'))
    sources += sorted((ROOT / 'experiments/gen3').glob('gen3_*.sv'))
    sources += [ROOT / 'experiments/gen3' / (top + '.sv')]
    exe = tmp_path / top
    compile_result = subprocess.run(
        ['iverilog', '-g2012', '-s', top, '-o', str(exe),
         *[f'-P{top}.{key}={value}' for key, value in parameters.items()],
         *map(str, sources)], capture_output=True, text=True, timeout=60)
    assert compile_result.returncode == 0, compile_result.stderr
    result = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS:' in result.stdout, result.stdout


@pytest.mark.parametrize('count', [7, 8, 16, 24])
def test_finite_ts2_then_idle(tmp_path, count):
    run_bench(tmp_path, 'test_eq_bringup', FINITE_TS2=count)


@pytest.mark.parametrize('fault', range(12))
def test_startup_and_equalization_faults(tmp_path, fault):
    run_bench(tmp_path, 'test_eq_bringup', FAULT=fault)


@pytest.mark.parametrize('datalink', [0, 1])
def test_recovery_bringup(tmp_path, datalink):
    run_bench(tmp_path, 'test_recovery_bringup', DATALINK=datalink)


@pytest.mark.parametrize('case', range(7))
def test_receive_qualification_guards(tmp_path, case):
    run_bench(tmp_path, 'test_startup_qualification', CASE=case)


@pytest.mark.parametrize('gaps', [0, 1])
def test_native_ordered_set_validation(tmp_path, gaps):
    run_bench(tmp_path, 'test_native_ordered_sets', GAPS=gaps)

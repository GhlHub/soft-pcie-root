# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess
import pytest
ROOT=Path(__file__).resolve().parents[1]
@pytest.mark.parametrize('case', range(18))
def test_adaptation(tmp_path,case):
    exe=tmp_path/'eq'
    subprocess.run(['iverilog','-g2012','-s','test_eq_adapt',f'-Ptest_eq_adapt.CASE={case}','-o',str(exe),
        str(ROOT/'experiments/gen3/gen3_eq_adapt.sv'),str(ROOT/'experiments/gen3/test_eq_adapt.sv')],check=True,capture_output=True)
    result=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=20)
    assert result.returncode==0, result.stdout+result.stderr
    assert 'PASS:' in result.stdout

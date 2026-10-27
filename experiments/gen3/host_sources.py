#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze experimental host inputs and generate an otherwise unchanged host shell."""
import argparse,hashlib,json,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def inputs():
    paths=list((ROOT/'ip/soft_pcie_root').rglob('*.sv'))+list((ROOT/'ip/soft_pcie_root').rglob('*.tcl'))
    paths+=list((ROOT/'examples/zcu104').rglob('*.tcl'))+list((ROOT/'examples/zcu104').rglob('*.xdc'))
    paths += [p for p in (ROOT/'experiments/gen3').iterdir() if p.suffix in ('.sv','.tcl','.py') and not p.name.startswith('test_')]
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
p=argparse.ArgumentParser();p.add_argument('mode',choices=('capture','check','shell'));p.add_argument('path',type=Path);a=p.parse_args()
if a.mode=='shell':
    src=(ROOT/'ip/soft_pcie_root/rtl/management/soft_pcie_root.sv').read_text()
    assert src.count('module soft_pcie_root(')==1 and src.count('pcie_soft_root_port root_port(')==1
    for token in ('PACKET_DWORDS=1','READ_PREFETCH_SLOTS=2','NUM_READ_OUTSTANDING 2'):
        assert src.count(token)==1, token
    a.path.write_text(src.replace('module soft_pcie_root(', 'module gen3_soft_pcie_root(').replace('pcie_soft_root_port root_port(', 'gen3_native_root root_port(').replace('PACKET_DWORDS=1', 'PACKET_DWORDS=2').replace('READ_PREFETCH_SLOTS=2', 'READ_PREFETCH_SLOTS=8').replace('NUM_READ_OUTSTANDING 2', 'NUM_READ_OUTSTANDING 8'))
elif a.mode=='capture':
    if a.path.exists():raise SystemExit('Manifest must be fresh')
    hashes=inputs();a.path.write_text(json.dumps(hashes,indent=2)+'\n')
    for name in hashes:
        target=a.path.parent/'input_snapshot'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
else:
    if json.loads(a.path.read_text())!=inputs():raise SystemExit('Experimental host sources changed')
    print('PASS: frozen experimental host sources')

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Snapshot/check unified package inputs for the experimental board recipe."""
import argparse,json,shutil,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from host_sources import hashes
p=argparse.ArgumentParser();p.add_argument('mode',choices=('capture','check'));p.add_argument('path',type=Path);a=p.parse_args()
if a.mode=='capture':
    if a.path.exists():raise SystemExit('Manifest must be fresh')
    values=hashes();a.path.write_text(json.dumps(values,indent=2)+'\n')
    for name in values:
        target=a.path.parent/'input_snapshot'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
else:
    if json.loads(a.path.read_text())!=hashes():raise SystemExit('Unified host sources changed')
    print('PASS: frozen unified host sources')

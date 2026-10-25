#!/usr/bin/env python3
"""Bind build evidence to reusable RTL, packaging and example constraints."""
import argparse, hashlib, json
from pathlib import Path
R=Path(__file__).resolve().parents[1]
def hashes():
 paths=sorted((R/'ip').rglob('*.sv'))+sorted((R/'ip').rglob('*.tcl'))
 paths+=sorted((R/'examples/zcu104').rglob('*.tcl'))+sorted((R/'examples/zcu104').rglob('*.xdc'))
 paths+=[R/'scripts/host_sources.py']
 return {str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=('capture','check'));p.add_argument('manifest',type=Path);a=p.parse_args()
 if a.action=='capture':
  if a.manifest.exists():raise SystemExit('Refusing to replace source manifest')
  a.manifest.write_text(json.dumps(hashes(),indent=2)+'\n')
 else:
  old=json.loads(a.manifest.read_text());now=hashes()
  changed=sorted(k for k in old.keys()|now.keys() if old.get(k)!=now.get(k))
  if changed:raise SystemExit('Hardware source mismatch: '+', '.join(changed))
 print('HOST_HARDWARE_SOURCE_HASHES_PASS')

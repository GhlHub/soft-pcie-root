#!/usr/bin/env python3
"""Check frozen RTL provenance and public source-tree hygiene (Apache-2.0)."""
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
ignored = {'build', '.git', '.venv', '__pycache__', '.pytest_cache', '.Xil'}
files = [p for p in root.rglob('*') if p.is_file() and not any(x in ignored for x in p.relative_to(root).parts)]
errors = []
manifest = json.loads((root / 'docs/baseline-rtl.json').read_text())
updates = json.loads((root / 'docs/rtl-updates.json').read_text())
if not set(updates).issubset(manifest):
    errors.append('RTL update names are not in the original baseline')
for name, record in manifest.items():
    data = (root / name).read_bytes()
    if name in updates:
        update = updates[name]
        implementation = json.loads((root / update['implementation']).read_text())
        completion = json.loads((root / update['completion']).read_text())
        digest = hashlib.sha256(data).hexdigest()
        if update['previous_release_sha256'] != record['release_sha256']:
            errors.append(f'RTL update baseline mismatch: {name}')
        if digest != update['release_sha256'] or digest != implementation['sources'].get(name):
            errors.append(f'Changed qualified RTL update: {name}')
        if (completion['status'] != 'physically_verified' or
                completion['bitstream_sha256'] != implementation['files']['system.bit']):
            errors.append(f'RTL update physical evidence mismatch: {name}')
        continue
    if hashlib.sha256(data).hexdigest() != record['release_sha256']:
        errors.append(f'Changed baseline RTL: {name}')
    if name.endswith('/soft_pcie_root.sv'):
        data = data.replace(b'module soft_pcie_root(', b'module zcu104_pcie_top(', 1)
    if hashlib.sha256(data).hexdigest() != record['baseline_sha256']:
        errors.append(f'Baseline normalization mismatch: {name}')
actual = {str(p.relative_to(root)) for p in (root / 'ip/soft_pcie_root/rtl').rglob('*.sv')}
if actual != set(manifest):
    errors.append('RTL inventory differs from baseline manifest')
for p in files:
    name = str(p.relative_to(root))
    if p.suffix.lower() in {'.pdf', '.bit', '.xsa', '.dcp', '.ko', '.o', '.xci'}:
        errors.append(f'Generated/vendor artifact: {name}')
    if p.stat().st_size > 5_000_000:
        errors.append(f'Unexpected large file: {name}')
    if p.suffix == '.png':
        continue
    try:
        content = p.read_text()
    except UnicodeDecodeError:
        errors.append(f'Unexpected binary: {name}')
        continue
    for pattern in [r'/' + r'raid/work/', r'10\.' + r'0\.1\.\d+', r'-----BEGIN [A-Z ]*PRIVATE KEY-----']:
        if re.search(pattern, content):
            errors.append(f'Private deployment content: {name}')
    if p.suffix == '.md':
        for link in re.findall(r'\]\(([^)]+)\)', content):
            if '://' in link or link.startswith('#'):
                continue
            target = link.split('#')[0]
            if target and not (p.parent / target).exists():
                errors.append(f'Broken documentation link: {name}: {link}')
assert 'Apache License' in (root / 'LICENSE').read_text()
assert 'GPL-2.0-only' in (root / 'software/driver/zcu104-soft-pcie.c').read_text()
if errors:
    raise SystemExit('\n'.join(errors))
print(f'RELEASE_CHECK_PASS {len(files)} files; {len(manifest)} RTL files verified, '
      f'{len(updates)} qualified updates to the historical baseline')

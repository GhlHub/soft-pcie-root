"""Reject ABI-compatible but stale host drivers and stale packaged rootfs copies."""
import hashlib
import importlib.util
import io
from pathlib import Path
import struct
import tarfile
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_verify', ROOT/'software/linux/verify.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

def test_host_module_source_and_archive_identity(tmp_path):
    rel = Path('lib/modules/6.6.70/updates/zcu104-soft-pcie.ko')
    module = tmp_path/rel
    module.parent.mkdir(parents=True)
    elf = bytearray(64)
    elf[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', elf, 16, 1, 183)
    abi = bytes(elf)+b'vermagic=6.6.70 SMP\0ngt,zcu104-soft-pcie-1.0\0'
    module.write_bytes(abi)
    with pytest.raises(ValueError, match='Stale host module'):
        verify.verify_host_module(tmp_path)
    digest = hashlib.sha256((ROOT/'software/driver/zcu104-soft-pcie.c').read_bytes()).hexdigest()
    good = abi+b'source_sha256='+digest.encode()+b'\0'
    module.write_bytes(good)
    archive = tmp_path/'rootfs.tar'
    def pack(data):
        with tarfile.open(archive, 'w') as tar:
            info = tarfile.TarInfo('./'+str(rel))
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    pack(abi)
    with pytest.raises(ValueError, match='Archived rootfs'):
        verify.verify_host_module(tmp_path, archive)
    pack(good)
    assert verify.verify_host_module(tmp_path, archive)['source_sha256'] == digest

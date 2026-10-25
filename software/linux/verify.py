#!/usr/bin/env python3
"""Validate resolved NAS config and installed target tools, not selected flags alone."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import struct
import subprocess

ROOT=Path(__file__).resolve().parent

def config(path):
    values={}
    for line in Path(path).read_text().splitlines():
        if line.startswith(('BR2_','CONFIG_')) and '=' in line:
            key,value=line.split('=',1);values[key]=value
        else:
            match=re.fullmatch(r'# ((?:CONFIG_|BR2_)\w+) is not set',line)
            if match:values[match.group(1)]='n'
    return values

def require_fragment(actual, fragment):
    expected=config(fragment)
    missing=[f'{key}={value}' for key,value in expected.items()
             if actual.get(key,'n')!=value]
    if missing:raise ValueError('Required options dropped: '+', '.join(missing))

def target_path(root, path):
    """Resolve target symlinks in the target namespace, never the host's /."""
    root=Path(root).resolve();path=Path(path)
    for _ in range(32):
        relative=path.relative_to(root);current=root;changed=False
        for part in relative.parts:
            current=current/part
            if current.is_symlink():
                target=Path(os.readlink(current))
                rest=path.relative_to(current)
                path=(root/str(target).lstrip('/') if target.is_absolute() else current.parent/target)/rest
                path=Path(os.path.normpath(path));path.relative_to(root)
                changed=True;break
        if not changed:return path
    raise ValueError('Target symlink loop')

def verify_rootfs(root):
    root=Path(root).resolve();found={}
    for group,names in json.loads((ROOT/'required-tools.json').read_text()).items():
        for name in names:
            candidates=[target_path(root,root/base/name) for base in ('usr/sbin','usr/bin','sbin','bin','usr/libexec')]
            file=next((p for p in candidates if p.is_file()),None)
            if file is None:raise ValueError(f'Missing {group} executable: {name}')
            if not file.stat().st_mode & 0o111:raise ValueError(f'{name}: not executable')
            head=file.read_bytes()[:20]
            if name=='nfsdclddb' and file.read_bytes().startswith(b'#!/usr/bin/python3\n'):
                # This upstream admin helper is a script; python3 is itself
                # checked as an AArch64 ELF and its SQLite module is VM-tested.
                found[name]=str(file.relative_to(root));continue
            if head[:6]!=b'\x7fELF\x02\x01' or struct.unpack_from('<H',head,18)[0]!=183:
                raise ValueError(f'{name}: not little-endian AArch64 ELF')
            found[name]=str(file.relative_to(root))
    if list((root/'etc/ssh').glob('ssh_host_*_key')) or (root/'root/.ssh/authorized_keys').exists():
        raise ValueError('Test/device SSH credentials leaked into image')
    if any(line.strip() and not line.lstrip().startswith('#') for line in (root/'etc/exports').read_text().splitlines()):
        raise ValueError('Unprovisioned NFS export in image')
    mdadm=(root/'etc/mdadm.conf').read_text()
    if 'AUTO -all' not in mdadm:raise ValueError('Bring-up image must not auto-assemble unknown arrays')
    for service in ('S30rpcbind','S60nfs','S50sshd','S80dnsmasq','S91smb'):
        if (root/'etc/init.d'/service).exists():
            raise ValueError('Unprovisioned server enabled at boot: '+service)
        if not (root/'usr/lib/zcu104/services'/service).is_file():
            raise ValueError('Missing opt-in server script: '+service)
    ssh=(root/'etc/ssh/sshd_config').read_text()
    if 'PasswordAuthentication no' not in ssh or 'PermitEmptyPasswords no' not in ssh:
        raise ValueError('SSH provisioning policy missing')
    return found

def verify_host_module(root, rootfs_tar=None):
    modules=list((Path(root)/'lib/modules').glob('*/updates/zcu104-soft-pcie.ko'))
    if len(modules)!=1:raise ValueError('Expected exactly one installed soft PCI host module')
    file=modules[0];data=file.read_bytes()
    if data[:6]!=b'\x7fELF\x02\x01' or struct.unpack_from('<HH',data,16)!=(1,183):
        raise ValueError('Host module is not AArch64 ELF relocatable')
    release=file.parent.parent.name
    if ('vermagic='+release+' ').encode() not in data:
        raise ValueError('Host module vermagic mismatch')
    if b'ngt,zcu104-soft-pcie-1.0' not in data:raise ValueError('Missing host OF alias')
    source_hash=hashlib.sha256((ROOT.parent/'driver/zcu104-soft-pcie.c').read_bytes()).hexdigest()
    if ('source_sha256='+source_hash).encode()+b'\0' not in data:
        raise ValueError('Stale host module source identity; rebuild zcu104-pcie-host')
    if rootfs_tar is not None:
        import tarfile
        with tarfile.open(rootfs_tar) as archive:
            candidates=[m for m in archive.getmembers() if m.name.lstrip('./')==str(file.relative_to(root))]
            if len(candidates)!=1 or archive.extractfile(candidates[0]).read()!=data:
                raise ValueError('Archived rootfs host module differs from validated target')
    return {'path':str(file.relative_to(root)), 'sha256':hashlib.sha256(data).hexdigest(),
            'source_sha256':source_hash,
            'kernel_release':release,'physical_host_tested':False}

def probe_versions(root, tools, qemu):
    # Version-only commands: no device discovery, assembly, mount or writes.
    # mount.cifs needs root, ssh needs a target UID, and nft opens Netlink.
    # Exercise these inside the isolated system VM, not host user emulation.
    versions={}
    for name, flag in (('mdadm','--version'),('btrfs','--version'),
                       ('mkfs.btrfs','--version'),('smartctl','-V'),
                       ('nvme','version'),('cryptsetup','--version'),
                       ('rsync','--version'),('mount.nfs','-V'),('smbd','--version'),('smbclient','--version'),
                       ('sshd','-V'),('openssl','version'),('dnsmasq','--version'),('ip','-V'),
                       ('ss','-V'),('ethtool','--version'),
                       ('tcpdump','--version'),('iperf3','--version'),('curl','--version')):
        result=subprocess.run([str(qemu),'-U','LD_LIBRARY_PATH','-L',str(root),
                               str(Path(root)/tools[name]),flag],
                              check=True,text=True,stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT,timeout=30)
        versions[name]=result.stdout.splitlines()[0]
    return versions

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--target',type=Path);p.add_argument('--kernel-config',type=Path)
    p.add_argument('--buildroot-config',type=Path);p.add_argument('--qemu',type=Path)
    p.add_argument('--rootfs-tar',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    result={'status':'ZCU104_SERVER_CONTENT_VALIDATED','hardware_tested':False,'board_boot_tested':False,'sd_image_validation':'separate archive/partition check'}
    if a.kernel_config:
        values=config(a.kernel_config);require_fragment(values,ROOT/'kernel/server.config')
        for option in ('CONFIG_MD_AUTODETECT','CONFIG_XLNX_R5_REMOTEPROC'):
            if values.get(option) in ('y','m'):raise ValueError('Ownership/autodetection option enabled: '+option)
        result['kernel_config_sha256']=hashlib.sha256(a.kernel_config.read_bytes()).hexdigest()
    if a.buildroot_config:
        require_fragment(config(a.buildroot_config),ROOT/'buildroot/configs/zcu104_server_defconfig')
    if a.target:
        result['tools']=verify_rootfs(a.target)
        result['host_module']=verify_host_module(a.target,a.rootfs_tar)
        if a.qemu:result['qemu_versions']=probe_versions(a.target.resolve(),result['tools'],a.qemu)
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

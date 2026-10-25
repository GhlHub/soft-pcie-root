#!/usr/bin/env python3
"""Reproducible ZCU104 server build; never writes media or programs hardware."""
import argparse,hashlib,json,os,shutil,subprocess,tarfile,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
VERSION='2025.02.18'
SHA='e38ad1df6ea0479fff6419a87a64535d02131674d463be154a763ef725b55321'
def digest(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for chunk in iter(lambda:f.read(1<<20),b''):h.update(chunk)
 return h.hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('action',choices=['fetch','configure','build','verify','archive','legal-info'])
 p.add_argument('--work',type=Path,default=ROOT/'build/linux-cache')
 p.add_argument('--output',type=Path,default=ROOT/'build/linux_v1')
 p.add_argument('--jobs',type=int,default=min(os.cpu_count() or 1,12))
 a=p.parse_args();work=a.work.resolve();work.mkdir(parents=True,exist_ok=True)
 source=work/f'buildroot-{VERSION}';out=work/'output'
 marker=source/'.zcu104-source.json'
 if not marker.exists():
  archive=work/f'buildroot-{VERSION}.tar.xz'
  if not archive.exists():urllib.request.urlretrieve(f'https://buildroot.org/downloads/{archive.name}',archive)
  if digest(archive)!=SHA:raise SystemExit('Buildroot archive SHA256 mismatch')
  with tarfile.open(archive) as archive_file:
   if not source.is_dir():archive_file.extractall(work,filter='data')
   else:
    # Verify a reused source against every regular upstream archive member;
    # downloads/output/cache files outside the archive do not affect this check.
    for member in archive_file.getmembers():
     if member.isfile():
      path=work/member.name
      if not path.is_file() or digest(path)!=hashlib.sha256(archive_file.extractfile(member).read()).hexdigest():
       raise SystemExit(f'Existing Buildroot source differs: {member.name}')
  marker.write_text(json.dumps({'sha256':SHA,'version':VERSION})+'\n')
 if json.loads(marker.read_text()).get('sha256')!=SHA:
  raise SystemExit('Wrong Buildroot source stamp')
 if a.action=='fetch':
  print(json.dumps({'source':str(source),'sha256':SHA,'upstream_files_verified':True}));return
 make=['make','-C',str(source),'O='+str(out),'BR2_EXTERNAL='+str(ROOT/'software/linux/buildroot')]
 def run(cmd):subprocess.run(cmd,check=True)
 if a.action=='configure':run(make+['zcu104_server_defconfig'])
 elif a.action in ('build','legal-info'):
  if not (out/'.config').exists():run(make+['zcu104_server_defconfig'])
  run(make+[f'-j{a.jobs}']+(['legal-info'] if a.action=='legal-info' else []))
 elif a.action=='verify':
  run(['python3',str(ROOT/'software/linux/uboot/evidence.py'),'check',str(out/'build/uboot-custom')])
  kernels=list((out/'build').glob('linux-*/.config'))
  if len(kernels)!=1:raise SystemExit('Expected exactly one resolved kernel configuration')
  run(['python3',str(ROOT/'software/linux/verify.py'),'--target',str(out/'target'),'--rootfs-tar',str(out/'images/rootfs.tar'),'--buildroot-config',str(out/'.config'),'--kernel-config',str(kernels[0]),'--output',str(work/'validation.json')])
 else:
  run(['python3',str(ROOT/'software/linux/uboot/evidence.py'),'check',str(out/'build/uboot-custom')])
  from verify import verify_host_module
  verify_host_module(out/'target',out/'images/rootfs.tar')
  if a.output.exists() and any(a.output.iterdir()):raise SystemExit('Use a fresh archive directory; existing images are preserved')
  a.output.mkdir(parents=True,exist_ok=True);hashes={}
  names=['sdcard.img','boot.bin','u-boot.itb','bl31.bin','Image','system.dtb','rootfs.ext4','rootfs.cpio.gz','rootfs.tar','extlinux.conf']
  for name in names:
   src=out/'images'/name
   if not src.is_file():raise SystemExit(f'Missing image: {src}')
   dst=a.output/name;shutil.copyfile(src,dst);hashes[name]=digest(dst)
  for name,src in [('buildroot.config',out/'.config'),('linux-validation.json',work/'validation.json')]:
   if src.exists():shutil.copyfile(src,a.output/name)
  shutil.copyfile(out/'build/uboot-custom/fmc-build.json',a.output/'fmc-build.json')
  hashes['fmc-build.json']=digest(a.output/'fmc-build.json')
  metadata={'buildroot':VERSION,'buildroot_archive_sha256':SHA,'artifacts':hashes,'hardware_tested':False,'pl_in_default_sd_image':False,'soft_pcie_linux_host_driver':True,'soft_pcie_host_profile_required':True,'physical_pcie_tested':False}
  (a.output/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
  (a.output/'SHA256SUMS').write_text(''.join(f'{sha}  {name}\n' for name,sha in hashes.items()))
if __name__=='__main__':main()

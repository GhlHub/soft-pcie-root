#!/usr/bin/env python3
"""Boot Linux and exercise NFSv3/v4, SSH and SMB over VM loopback only."""
import argparse,gzip,hashlib,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def cpio_entry(name,data,mode=0o100755):
 n=name.encode()+b'\0';v=[1,mode,0,0,1,0,len(data),0,0,0,0,len(n),0]
 h=b'070701'+b''.join(f'{x:08x}'.encode() for x in v)+n
 return h+b'\0'*(-len(h)%4)+data+b'\0'*(-len(data)%4)
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--kernel',type=Path,required=True);p.add_argument('--initramfs',type=Path,required=True)
 p.add_argument('--qemu',type=Path,required=True);p.add_argument('--work',type=Path,required=True)
 a=p.parse_args();a.work.mkdir(parents=True,exist_ok=False)
 init=a.work/'test.cpio.gz'
 script=(ROOT/'tests/linux/server_init.sh').read_bytes()
 init.write_bytes(a.initramfs.read_bytes()+gzip.compress(cpio_entry('zcu104-server-test',script)+cpio_entry('TRAILER!!!',b'',0),mtime=0))
 cmd=[str(a.qemu),'-M','virt','-cpu','cortex-a53','-smp','4','-m','1024','-nographic','-monitor','none','-nic','none','-no-reboot','-kernel',str(a.kernel),'-initrd',str(init),'-append','console=ttyAMA0 rdinit=/zcu104-server-test zcu104_server_smoke=1 panic=-1']
 start=time.monotonic()
 with (a.work/'console.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=240)
 text=(a.work/'console.log').read_text(errors='replace')
 markers=['ZCU104_HOST_MODULE_PASS','ZCU104_NFS3_PASS','ZCU104_NFS4_PASS','ZCU104_SSH_PASS','ZCU104_SMB_PASS','ZCU104_SERVER_SMOKE_PASS']
 if r.returncode or not all(x in text for x in markers) or 'ZCU104_SERVER_SMOKE_FAIL' in text:raise SystemExit('Server smoke test failed; inspect '+str(a.work/'console.log'))
 result={'status':'SERVER_VM_VALIDATED','markers':markers,'elapsed_seconds':round(time.monotonic()-start,2),'kernel_sha256':hashlib.sha256(a.kernel.read_bytes()).hexdigest(),'initramfs_sha256':hashlib.sha256(a.initramfs.read_bytes()).hexdigest(),'scope':'generic ARM64 virt machine; loopback only, no disks/external network; not physical ZCU104 boot, GEM or PCIe validation'}
 (a.work/'validation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()

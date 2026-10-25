#!/usr/bin/env python3
"""Produce an optional PL-first boot profile; no board or media access."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True);p.add_argument('--hardware',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
if not (a.hardware/'sources.json').is_file():raise SystemExit('Host hardware source manifest required; command-only images are incompatible')
subprocess.run(['python3',str(ROOT/'scripts/validate_hardware.py'),str(a.hardware),'--output',str(a.output/'hardware-validation.json')],check=True)
out=a.work/'output';kernels=list((out/'build').glob('linux-*'))
subprocess.run(['python3',str(ROOT/'software/linux/uboot/evidence.py'),'check',str(out/'build/uboot-custom')],check=True)
if len(kernels)!=1:raise SystemExit('Expected one kernel source')
k=kernels[0];host=out/'host/bin';dt=k/'arch/arm64/boot/dts/xilinx'
pp=a.output/'zcu104-soft-pcie.pp.dts'
subprocess.run([str(host/'aarch64-linux-gcc'),'-E','-P','-x','assembler-with-cpp','-nostdinc','-undef','-D__DTS__','-I',str(dt),'-I',str(k/'include'),str(ROOT/'software/linux/zcu104-soft-pcie.dts'),'-o',str(pp)],check=True)
subprocess.run([str(host/'dtc'),'-I','dts','-O','dtb','-o',str(a.output/'zcu104-soft-pcie.dtb'),str(pp)],check=True)
mkimage=host/'mkimage'
if not mkimage.is_file():mkimage=next((out/'build').glob('uboot-*/tools/mkimage'))
subprocess.run([str(mkimage),'-A','arm64','-T','script','-C','none','-n','ZCU104 experimental soft PCIe host','-d',str(ROOT/'software/linux/boot-soft-pcie.cmd'),str(a.output/'boot-soft-pcie.scr')],check=True)
if (out/'images/Image').stat().st_size >= 0x04000000-0x00200000:
 raise SystemExit('Kernel overlaps the boot-script DTB address')
shutil.copyfile(a.hardware/'system.bit',a.output/'system.bit')
modules=list((out/'target/lib/modules').glob('*/updates/zcu104-soft-pcie.ko'))
if len(modules)!=1:raise SystemExit('Expected one installed PCI host driver')
# Check module architecture/vermagic and all NAS image policies separately.
subprocess.run(['python3',str(ROOT/'software/linux/verify.py'),'--target',str(out/'target'),'--rootfs-tar',str(out/'images/rootfs.tar'),'--kernel-config',str(k/'.config'),'--buildroot-config',str(out/'.config'),'--output',str(a.output/'linux-validation.json')],check=True)
files={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in a.output.iterdir() if f.is_file()}
(a.output/'manifest.json').write_text(json.dumps({'artifacts':files,'hardware_tested':False,'automatic_boot':False,'fmc_vadj_ready_required':True,'uboot_itb_sha256':hashlib.sha256((out/'images/u-boot.itb').read_bytes()).hexdigest(),'kernel_sha256':hashlib.sha256((out/'images/Image').read_bytes()).hexdigest(),'initramfs_sha256':hashlib.sha256((out/'images/rootfs.cpio.gz').read_bytes()).hexdigest(),'host_driver_source_sha256':hashlib.sha256((ROOT/'software/driver/zcu104-soft-pcie.c').read_bytes()).hexdigest(),'note':'Requires matching FMC-capable U-Boot and physical VADJ measurement. Copy files alongside baseline boot partition after review; manually run the script from U-Boot. Experimental soft PCI host and DDR DMA. Load zcu104-soft-pcie.ko after PL-first boot; no physical validation.'},indent=2)+'\n')

#!/usr/bin/env python3
"""Read-only structural validation of a generated SD image and its boot files."""
import argparse,hashlib,json,struct,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('images',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=a.images;image=root/'sdcard.img'
with image.open('rb') as f:mbr=f.read(512)
if mbr[510:512]!=b'\x55\xaa':raise SystemExit('Missing MBR signature')
sig=struct.unpack_from('<I',mbr,440)[0]
if sig!=0x1045a7a0:raise SystemExit('Wrong PARTUUID disk signature')
parts=[]
for n in range(2):
 base=446+n*16;start,sectors=struct.unpack_from('<II',mbr,base+8)
 parts.append({'type':mbr[base+4],'start_sector':start,'sectors':sectors})
 if not start or not sectors or (start+sectors)*512>image.stat().st_size:raise SystemExit('Partition outside image')
if parts[0]['type']!=12 or parts[1]['type']!=131:raise SystemExit('Wrong FAT/ext4 partition types')
if parts[0]['start_sector']+parts[0]['sectors']>parts[1]['start_sector']:raise SystemExit('Overlapping partitions')
with image.open('rb') as f:
 f.seek(parts[1]['start_sector']*512+1024+56)
 if f.read(2)!=b'\x53\xef':raise SystemExit('Missing ext4 superblock')
conf=(root/'extlinux.conf').read_text()
if 'root=PARTUUID=1045a7a0-02' not in conf:raise SystemExit('Wrong root partition selection')
for name in ['boot.bin','u-boot.itb','Image','system.dtb']:
 if not (root/name).is_file() or (root/name).stat().st_size==0:raise SystemExit('Missing boot file '+name)
# Check actual FAT contents using the image builder's own mtools utility.
host=root.parent/'host/bin';offset=parts[0]['start_sector']*512
listing=subprocess.check_output([str(host/'mdir'),'-i',str(image)+'@@'+str(offset),'::/'],text=True)
for word in ['boot','u-boot','Image','system','extlinux']:
 if word.lower() not in listing.lower():raise SystemExit('Missing FAT member '+word)
result={'status':'SD_IMAGE_STRUCTURE_VALIDATED','disk_signature':hex(sig),'root_partuuid':'1045a7a0-02','partitions':parts,'bytes':image.stat().st_size,'hardware_boot_tested':False,'fat_listing':listing}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

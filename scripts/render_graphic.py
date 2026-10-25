#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from html import escape
out=Path(__file__).resolve().parents[1] / 'docs/media'
im=Image.new('RGB',(1600,900),'#071827'); d=ImageDraw.Draw(im)
svg=['<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900" viewBox="0 0 1600 900"><rect width="1600" height="900" fill="#071827"/>']
def text(x,y,s,size=30,color='#ffffff',bold=False):
 f=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf',size)
 d.text((x,y),s,font=f,fill=color,anchor='lt')
 svg.append(f'<text x="{x}" y="{y+size*.82}" font-family="DejaVu Sans,sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}">{escape(s)}</text>')
def rect(x,y,w,h,fill):
 d.rounded_rectangle((x,y,x+w,y+h),radius=16,fill=fill)
 svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}"/>')
text(80,55,'SOFT PCIe ROOT PORT',24,'#59dfda',True)
text(80,115,'PCIe, built in logic.',76,bold=True)
text(80,220,'Transceiver-based. Verified with NVMe under Linux.',34,'#c8dae8')
rect(80,290,1440,70,'#103747')
text(110,311,'NO HARD PCIe BLOCK  /  NO VENDOR PCIe CONTROLLER IP',30,'#59dfda',True)
for x,w,title,sub in [(80,310,'Linux + DDR','Custom PCI host driver'),(450,360,'Soft PCIe RTL','Gen1 / Gen2 · x1'),(870,230,'GTH','One transceiver'),(1160,360,'NVMe SSD','Standard Linux NVMe')]:
 rect(x,415,w,130,'#142d40');text(x+22,439,title,32,bold=True);text(x+22,493,sub,20,'#c8dae8')
for x in [404,824,1114]: text(x,454,'→',32,'#59dfda')
text(80,600,'428.6 MB/s',56,'#59dfda',True);text(80,671,'SEQUENTIAL READ',23,'#c8dae8')
text(760,600,'260.1 MB/s',56,'#59dfda',True);text(760,671,'SEQUENTIAL WRITE',23,'#c8dae8')
text(80,748,'ZCU104  ·  OP047 Rev D  ·  Samsung 990 EVO  ·  Linux 6.6',25,bold=True)
text(80,798,'Measured Gen2 x1 baseline · 1 MiB direct I/O · QD8 · 30 seconds · decimal MB/s',21,'#a5bacb')
text(80,839,'Experimental release · Gen3+ and wider links: future research · Original RTL: Apache-2.0',20,'#a5bacb')
svg.append('</svg>');(out/'linkedin-soft-pcie.svg').write_text('\n'.join(svg));im.save(out/'linkedin-soft-pcie.png')

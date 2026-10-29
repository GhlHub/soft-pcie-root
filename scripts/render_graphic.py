#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from html import escape
import json
out=Path(__file__).resolve().parents[1] / 'docs/media'
evidence=json.loads((out.parent/'evidence/requester_fix_v1/completion.json').read_text())
read=evidence['benchmark']['MB_s']['read8']
write=evidence['benchmark']['MB_s']['write8']
im=Image.new('RGB',(1600,900),'#071827'); d=ImageDraw.Draw(im)
svg=['<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900" viewBox="0 0 1600 900"><rect width="1600" height="900" fill="#071827"/>']
def text(x,y,s,size=30,color='#ffffff',bold=False):
 f=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf',size)
 d.text((x,y),s,font=f,fill=color,anchor='lt')
 svg.append(f'<text x="{x}" y="{y+size*.82}" font-family="DejaVu Sans,sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}">{escape(s)}</text>')
def rect(x,y,w,h,fill):
 d.rounded_rectangle((x,y,x+w,y+h),radius=16,fill=fill)
 svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}"/>')
text(80,48,'SOFT PCIe ROOT PORT  /  CURRENT HARDWARE RESULTS',23,'#59dfda',True)
text(80,102,'Gen3 x1. Built in logic.',72,bold=True)
text(80,197,'NVMe under Linux. One GTH. Custom PCIe RTL.',31,'#c8dae8')
rect(80,265,700,200,'#103747');rect(800,265,720,200,'#103747')
text(110,290,'SEQUENTIAL READ',22,'#c8dae8',True)
text(110,337,f'{read:.2f}',78,'#59dfda',True);text(495,382,'MB/s',32,'#c8dae8')
text(830,290,'SEQUENTIAL WRITE',22,'#c8dae8',True)
text(830,337,f'{write:.2f}',78,'#59dfda',True);text(1215,382,'MB/s',32,'#c8dae8')
text(80,498,'NO HARD PCIe CONTROLLER  /  NO VENDOR PCIe CONTROLLER IP',27,'#59dfda',True)
for x,w,title,sub in [(80,310,'Linux + DDR','Custom PCI host driver'),(450,360,'Soft PCIe RTL','Gen3 x1 · 8 GT/s'),(870,230,'GTH','One transceiver'),(1160,360,'NVMe SSD','Standard Linux NVMe')]:
 rect(x,557,w,120,'#142d40');text(x+22,578,title,30,bold=True);text(x+22,630,sub,20,'#c8dae8')
for x in [399,819,1109]: text(x,598,'↔',32,'#59dfda')
text(80,713,'ZCU104 · OP047 Rev D · Samsung 990 EVO 1 TB · Linux 6.6.70',24,bold=True)
text(80,757,'1 MiB · QD8 · direct/libaio · one job · 30 s per workload · decimal MB/s',22,'#a5bacb')
text(80,800,'Experimental Gen3 · Full Recovery and broader qualification remain open',21,'#e8c783')
text(80,845,'github.com/GhlHub/soft-pcie-root',21,'#c8dae8')
text(1090,845,'Measured '+evidence['date'],21,'#c8dae8')
svg.append('</svg>');(out/'linkedin-soft-pcie.svg').write_text('\n'.join(svg)+'\n');im.save(out/'linkedin-soft-pcie.png')

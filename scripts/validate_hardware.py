#!/usr/bin/env python3
"""Check saved ZCU104 route evidence; does not program hardware."""
import argparse,hashlib,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();d=a.directory
if (d/'sources.json').exists():
 import subprocess
 subprocess.run(['python3',str(Path(__file__).resolve().parent/'host_sources.py'),'check',str(d/'sources.json')],check=True)
needed=['timing.rpt','utilization.rpt','cdc.rpt','drc.rpt','route.rpt','bus_skew.rpt','check_timing.rpt','routed.dcp','system.bit','system.xsa']
for f in needed:
 if not (d/f).is_file():raise SystemExit('Missing hardware artifact '+f)
t=(d/'timing.rpt').read_text();m=re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$',t,re.M)
if not m:raise SystemExit('Missing full timing summary')
v=m.groups();slack={'wns_ns':float(v[0]),'whs_ns':float(v[4]),'wpws_ns':float(v[8])}
if any(x<0 for x in slack.values()) or any(int(v[i]) for i in (2,6,10)):raise SystemExit('Timing failure')
drc=(d/'drc.rpt').read_text()
if re.search(r'^\|[^\n]+\|\s*(Error|Critical Warning)\s*\|',drc,re.M):raise SystemExit('DRC failure')
skew=(d/'bus_skew.rpt').read_text()
if 'Slack (VIOLATED)' in skew:raise SystemExit('Bus-skew failure')
route=(d/'route.rpt').read_text()
if not re.search(r'# of nets with routing errors\.*\s*:\s*0',route,re.I):raise SystemExit('Routing errors or missing route summary')
cdc=(d/'cdc.rpt').read_text()
if re.search(r'^CDC-\d+\s+Critical\s+[1-9]',cdc,re.M):raise SystemExit('Unwaived critical CDC')
checks=(d/'check_timing.rpt').read_text()
for label in ['no_clock','unconstrained_internal_endpoints','no_input_delay']:
 if not re.search(r'checking '+label+r' \(0\)',checks):raise SystemExit('Timing coverage failed: '+label)
resources={}
for line in (d/'utilization.rpt').read_text().splitlines():
 fields=[x.strip() for x in line.split('|')]
 if len(fields)>5 and fields[1] in ['CLB LUTs','CLB Registers','CLB','Block RAM Tile','URAM','DSPs','GTHE4_CHANNEL','MMCM','PLL']:
  resources[fields[1]]={'used':fields[2],'percent':fields[-2]}
result={'status':'ZCU104_ROUTE_EVIDENCE_VALIDATED','slack':slack,'resources':resources,'hardware_tested':False,'files':{f:hashlib.sha256((d/f).read_bytes()).hexdigest() for f in needed},'limitations':['No physical board boot or serial PCIe link test','Experimental direct-endpoint PCI host/DDR bridge; no physical NVMe I/O, hotplug or live recovery qualification','Review scoped CDC waivers and remaining informational/enable warnings','Dedicated serial output has no conventional parallel output-delay contract']}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

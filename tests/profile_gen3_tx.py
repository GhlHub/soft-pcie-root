#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Synthetic sustained Gen3 TX scheduling experiment, not hardware evidence."""
import argparse,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--pcs',type=int,choices=(0,1),nargs='+',default=[0,1])
p.add_argument('--ack-delay',type=int,nargs='+',default=[0,16,64,128,256])
p.add_argument('--ack-every',type=int,choices=(1,2,4,8),nargs='+',default=[1])
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
s=ROOT/'experiments/gen3';c=ROOT/'ip/soft_pcie_root/rtl/pcie_soft'
files=[s/(x+'.sv') for x in ('gen3_tx_window','gen3_tlp_source','gen3_stp','gen3_recovery_tx','test_tx_throughput')]+[c/(x+'.sv') for x in ('pcie_soft_replay','pcie_soft_ack_capture')]
rows=[]
for pcs in a.pcs:
 for delay in a.ack_delay:
  assert 0<=delay<=256
  for every in a.ack_every:
   name=f'pcs{pcs}-delay{delay}-every{every}';binary=a.output/name
   subprocess.run(['iverilog','-g2012','-s','test_tx_throughput',f'-Ptest_tx_throughput.PCS={pcs}',f'-Ptest_tx_throughput.ACK_DELAY={delay}',f'-Ptest_tx_throughput.ACK_EVERY={every}','-o',str(binary),*map(str,files)],check=True)
   raw=subprocess.check_output(['vvp',str(binary)],text=True,timeout=120)
   (a.output/(name+'.txt')).write_text(raw)
   line=next(x for x in raw.splitlines() if x.startswith('RESULT '))
   row={k:int(v) for k,v in (x.split('=') for x in line.split()[1:])}
   # All packets have 21 framed DWORDs, of which 16 carry payload.
   row['payload_equivalent_MB_s']=(row['cycles']-row['out_empty']-row['out_stall'])/row['cycles']*250e6/21*64/1e6
   rows.append(row);print(json.dumps(row),flush=True)
(a.output/'results.json').write_text(json.dumps({'scope':'Synthetic saturated transmitter; 64-byte payload, extended replay timeout 4096 cycles, no peer-credit/DDR/RX model. ACK delay starts at formatter-to-PCS acceptance, not wire reception. Warm-up excluded; partial boundary frames contribute pro rata.','source_sha256':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},'results':rows},indent=2)+'\n')

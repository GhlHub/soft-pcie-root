#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""On-target LPR1/LPR2 capture; exclusive administrative use of SRP1 is required.
Uses existing command ownership/CDC, never PCI configuration/reset/remove.
Write mode overwrites the previously authorized SSD range [8 GiB,12 GiB).
Requires SOFT_PCIE_TEST_SSD_SERIAL. The named FPGA image must include LPR1 or LPR2.
"""
import argparse,json,mmap,os,struct,subprocess,time
from pathlib import Path
from profile_completion_path import guard
NAMES='''cycles active app_valid app_accept app_credit_stall app_replay_stall
replay_full ack_pending ack_wait_copy ack_wait_staged ack_blocks_new_copy
ack_retire nak_retire timeout replaying copy_accept copy_formatter_stall
formatter_valid formatter_blocked pcs_tlp_accept tlp_submitted dllp_accept
dllp_blocked pcs_idle pcs_block_boundary_wait pcs_cadence_wait pcs_skp_wait
pcs_skp_due_wait replay_nonempty sent_nonempty fault app_command_stall'''.split()
class Mailbox:
    def __init__(self,mm):self.mm=mm
    def rd(self,off):return struct.unpack_from('<I',self.mm,off)[0]
    def wr(self,off,value):struct.pack_into('<I',self.mm,off,value)
    def command(self,address,data=0):
        assert self.rd(0)==0x53525031 and self.rd(0x10)&1
        assert self.rd(0x34)&5==0, 'Mailbox busy or quarantined'
        assert self.rd(8)&7==3, 'Link/DL inactive or error'
        self.wr(0x20,address);self.wr(0x24,0);self.wr(0x28,data)
        self.wr(0x2c,0xf7);self.wr(0x30,1)
        deadline=time.monotonic()+.2
        while True:
            status=self.rd(0x34)
            if status&1==0 and status&2:break
            assert time.monotonic()<deadline,'Mailbox did not complete; do not retry/reset'
        assert status&0x704==0, 'Local command failed: '+hex(status)
        return self.rd(0x38)
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mode',choices=('idle','write'),required=True)
    ap.add_argument('--qd',type=int,choices=(1,8),default=8)
    ap.add_argument('--seconds',type=int,choices=range(1,11),default=5)
    a=ap.parse_args();before=guard()
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split()==['0','0']
    assert Path('/sys/class/nvme/nvme0/device/current_link_speed').read_text().strip()=='8.0 GT/s PCIe'
    assert Path('/sys/class/nvme/nvme0/device/current_link_width').read_text().strip()=='1'
    fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
    with mmap.mmap(fd,4096,offset=0xa2000000) as dbr:
        assert struct.unpack_from('<I',dbr,0x14)[0]==12
        assert struct.unpack_from('<I',dbr,0x90)[0]==0x802
    result=None;command=None
    with mmap.mmap(fd,4096,offset=0xa0000000) as mm:
        mb=Mailbox(mm);saved=[mb.rd(x) for x in (0x20,0x24,0x28,0x2c)]
        magic=mb.command(0);assert magic in (0x4c505231,0x4c505232)
        hz=mb.command(8);assert hz==250000000
        assert mb.command(4)==0,'Profiler already running'
        mb.command(0x10,1)
        try:
            if a.mode=='idle':time.sleep(a.seconds)
            else:
                command=['fio','--name=link_profile','--filename=/dev/nvme0n1','--rw=write',
                         '--direct=1','--ioengine=libaio','--numjobs=1','--bs=1M','--iodepth='+str(a.qd),
                         '--offset=8G','--size=4G','--time_based=1','--runtime='+str(a.seconds),
                         '--end_fsync=1','--refill_buffers=1','--randseed=19047','--output-format=json']
                run=subprocess.run(command,check=True,capture_output=True,text=True,timeout=14)
                result=json.loads(run.stdout);assert all(j['error']==0 for j in result['jobs'])
        finally:mb.command(0x10,0)
        assert mb.command(4)==0
        overflow=mb.command(0xc)
        counters=dict(zip(NAMES,[mb.command(0x100+4*i) for i in range(32)]))
        # Restore staging fields only after all command responses have drained.
        for offset,value in zip((0x20,0x24,0x28,0x2c),saved):mb.wr(offset,value)
    os.close(fd)
    after=guard();written=(after[6]-before[6])*512
    payload={'profile_magic':hex(magic),'mode':a.mode,'qd':a.qd,'clock_hz':hz,'command':command,'overflow':overflow,
             'counters':counters,'fio':result,'written_bytes':written,
             'capture_seconds':counters['cycles']/hz,
             'cycle_percent':{k:100*v/max(counters['cycles'],1) for k,v in counters.items()}}
    Path('/tmp/link-profile-last.json').write_text(json.dumps(payload,indent=2)+'\n')
    assert overflow==0 and counters['fault']==0
    assert written==(sum(j['write']['io_bytes'] for j in result['jobs']) if result else 0)
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split()==['0','0']
    print(json.dumps(payload,indent=2))
if __name__=='__main__':main()

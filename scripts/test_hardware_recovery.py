#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read-only on-board single-Recovery test for the isolated HWT1 overlay.

Requires explicit hardware fault-test authorization and exclusive SRP1 access.
Never run on a production image. Does not reset/reprogram PL or remove a device.
The trigger records packet ownership, not proof of an outstanding DDR AXI burst.
"""
import argparse
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess
import time
from profile_completion_path import guard
from profile_gen3_link import Mailbox


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    before = guard()
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split() == ['0', '0']
    args.output.mkdir(exist_ok=False)
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    def smart():
        return json.loads(subprocess.check_output(['nvme', 'smart-log', '/dev/nvme0', '-o', 'json'], text=True))
    initial_smart = smart()
    with mmap.mmap(fd, 4096, offset=0xa0000000) as mm:
        mb = Mailbox(mm)
        def status():
            return {hex(off): hex(mb.rd(off)) for off in (8, 0x34, 0x40, 0x44, 0x48, 0x4c, 0x50)}
        initial = status()
        assert mb.rd(0x40) == 0x48575431, 'Requires HWT1 diagnostic image'
        assert mb.rd(0x44) == 0 and mb.rd(0x48) == 0, 'Expected fresh diagnostic boot'
        saved = [mb.rd(x) for x in (0x20, 0x24, 0x28, 0x2c)]
        cmd = ['fio', '--name=recovery_crc', '--filename=/dev/nvme0n1',
               '--readonly', '--rw=read', '--direct=1', '--ioengine=libaio',
               '--numjobs=1', '--bs=1M', '--iodepth=8', '--offset=16G',
               '--size=256M', '--verify=crc32c', '--verify_interval=4096',
               '--verify_fatal=1', '--time_based=1', '--runtime=10',
               '--output-format=json', '--output='+str(args.output/'fio.json')]
        with (args.output/'fio-console.txt').open('w') as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
            time.sleep(1)
            assert proc.poll() is None, 'Read workload ended before trigger'
            # Existing local command completes through the normal CDC. Its
            # diagnostic-only arm is consumed at the next active received TLP.
            mb.command(0x10, 1)
            rc = proc.wait(timeout=180)
        time.sleep(.1)
        final = status()
        if mb.rd(8) & 7 == 3 and mb.rd(0x34) & 5 == 0:
            mb.command(0x10, 0)
            for off, value in zip((0x20, 0x24, 0x28, 0x2c), saved):
                mb.wr(off, value)
    os.close(fd)
    data = json.loads((args.output/'fio.json').read_text())
    final_smart = smart()
    after = [int(v) for v in Path('/sys/class/block/nvme0n1/stat').read_text().split()]
    result = {'initial': initial, 'final': final, 'fio_returncode': rc, 'fio': data,
              'written_bytes': (after[6]-before[6])*512,
              'before_smart': initial_smart, 'after_smart': final_smart}
    (args.output/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    assert rc == 0 and all(j['error'] == 0 for j in data['jobs'])
    assert int(final['0x44'], 16) == 1, 'Trigger not observed exactly once'
    assert int(final['0x48'], 16) == 0x00010001, 'Recovery entry/return not observed exactly once'
    assert int(final['0x4c'], 16) & 6 == 6, 'Trigger missed active packet/DL ownership'
    assert int(final['0x8'], 16) == 0x93 and int(final['0x34'], 16) & 5 == 0
    assert result['written_bytes'] == 0
    for key in ('critical_warning', 'media_errors', 'num_err_log_entries', 'unsafe_shutdowns', 'data_units_written'):
        assert initial_smart[key] == final_smart[key], key
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split() == ['0', '0']
    print('PASS: one packet-active Recovery entry/return, read CRC, zero writes, stable SMART')

if __name__ == '__main__':
    main()

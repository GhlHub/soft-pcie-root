#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Guarded on-board CRC matrix; overwrites only [8 GiB, 8 GiB + 128 MiB + 512 B).

Explicit hardware-write authorization and SOFT_PCIE_TEST_SSD_SERIAL required.
Uses a random permutation (LFSR) to avoid same-block concurrent-write races.
Not a throughput benchmark or endurance test. No formatting, reset or removal.
"""
import argparse
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess
from profile_completion_path import guard


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    before = guard()
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split() == ['0', '0']
    args.output.mkdir(exist_ok=False)
    def health():
        fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
        try:
            with mmap.mmap(fd, 4096, offset=0xa2000000, access=mmap.ACCESS_READ) as mm:
                assert struct.unpack_from('<I', mm, 0x14)[0] == 12, 'DDR bridge not healthy/idle'
                assert struct.unpack_from('<I', mm, 0x90)[0] == 0x802, 'Expected wide/eight-slot host'
        finally:
            os.close(fd)
    def smart():
        return json.loads(subprocess.check_output(['nvme', 'smart-log', '/dev/nvme0', '-o', 'json'], text=True))
    health()
    initial_smart = smart()
    results = []
    base = 8 * 1024**3
    size = 128 * 1024**2
    def job(name, bs, qd, offset, rw, extra=()):
        assert base <= offset and offset + size <= base + size + 512
        command = ['fio', '--name='+name, '--filename=/dev/nvme0n1',
                   '--direct=1', '--ioengine=libaio', '--numjobs=1',
                   '--bs='+str(bs), '--iodepth='+str(qd), '--offset='+str(offset),
                   '--size='+str(size), '--rw='+rw, '--verify=crc32c',
                   '--verify_fatal=1', '--verify_write_sequence=0', '--do_verify=1',
                   '--verify_pattern=0x'+format(0x5a170000 ^ bs ^ qd, 'x')+'%o',
                   '--random_generator=lfsr', '--randseed=20261103',
                   '--refill_buffers=1', '--output-format=json',
                   '--output='+str(args.output/(name+'.json')), *extra]
        print('RUN '+name, flush=True)
        subprocess.run(command, check=True, timeout=180)
        data = json.loads((args.output/(name+'.json')).read_text())
        assert all(j['error'] == 0 and j['read']['io_bytes'] > 0 for j in data['jobs'])
        if rw == 'randwrite':
            assert sum(j['write']['io_bytes'] for j in data['jobs']) == size
            assert sum(j['read']['io_bytes'] for j in data['jobs']) == size
        results.append({'name': name, 'command': command, 'fio': data})
        health()
        print('PASS '+name, flush=True)
    def flush():
        subprocess.run(['nvme', 'flush', '/dev/nvme0n1', '-n', '1'], check=True)
    for bs in (4096, 8192, 131072, 1048576):
        for qd in (1, 8, 32):
            name = f'random_{bs}_qd{qd}'
            job(name, bs, qd, base+512, 'randwrite', ['--end_fsync=1'])
            flush()
            job(name+'_postflush', bs, qd, base+512, 'read', ['--readonly'])
    for qd in (1, 8, 32):
        name = f'mixed_4k_qd{qd}'
        job(name+'_seed', 4096, qd, base, 'randwrite', ['--end_fsync=1'])
        job(name, 4096, qd, base, 'randrw', ['--rwmixread=70', '--end_fsync=1'])
        flush()
        job(name+'_postflush', 4096, qd, base, 'read', ['--readonly'])
    after = guard()
    final_smart = smart()
    written = sum(j['write']['io_bytes'] for result in results for j in result['fio']['jobs'])
    assert (after[6]-before[6])*512 == written, 'Unexpected writes'
    for key in ('critical_warning', 'media_errors', 'num_err_log_entries', 'unsafe_shutdowns'):
        assert initial_smart[key] == final_smart[key], key
    assert Path('/sys/class/block/nvme0n1/inflight').read_text().split() == ['0', '0']
    result = {'jobs_passed': len(results), 'written_bytes': written,
              'before_smart': initial_smart, 'after_smart': final_smart,
              'before_stat': before, 'after_stat': after, 'results': results}
    (args.output/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'PASS: {len(results)} jobs; {written} written bytes exactly accounted', flush=True)

if __name__ == '__main__':
    main()

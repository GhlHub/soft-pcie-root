#!/usr/bin/env python3
"""On-target PRF1 counters around guarded raw SSD writes in the authorized 8–12GiB range.
Requires the completion-profile FPGA image; never run against an older DBR1.
Outputs one JSON object. No driver control/reset or PCI configuration changes.
"""
import argparse
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess
import time

NAMES = '''cycles read_active slot_empty_wait slot_ready tx_stall tx_dwords
payload_dwords completions ar_bursts ar_stall r_beats r_bursts r_wait
r_first_wait pending_one pending_two slots_full issue_slots_full rx_empty
rx_copy check_fence read_requests drain r_first queued_blocked rx_backpressure
writer_busy write_outstanding fault link_active check msi'''.split()


def guard():
    p = Path('/sys/class/block/nvme0n1')
    assert Path('/sys/class/nvme/nvme0/model').read_text().strip() == 'Samsung SSD 990 EVO 1TB'
    expected = os.environ.get('SOFT_PCIE_TEST_SSD_SERIAL')
    assert expected, 'Set SOFT_PCIE_TEST_SSD_SERIAL to the intended expendable SSD serial'
    assert Path('/sys/class/nvme/nvme0/serial').read_text().strip() == expected
    assert Path('/sys/class/nvme/nvme0/state').read_text().strip() == 'live'
    assert int((p / 'size').read_text()) * 512 == 1000204886016
    devices = [p] + [x for x in p.iterdir() if (x / 'partition').exists()]
    numbers = {(x / 'dev').read_text().strip() for x in devices}
    assert not any(line.split()[2] in numbers for line in Path('/proc/self/mountinfo').read_text().splitlines()), 'Mounted SSD'
    assert all(not list((x / 'holders').iterdir()) for x in devices), 'SSD has holders'
    return [int(x) for x in (p / 'stat').read_text().split()]


def summarize(c, hz):
    cycles = c['cycles']
    return {
        'capture_seconds': cycles / hz,
        'cycle_percent': {k: 100 * c[k] / cycles for k in (
            'read_active', 'slot_empty_wait', 'slot_ready', 'tx_stall', 'tx_dwords',
            'ar_stall', 'r_wait', 'r_first_wait', 'slots_full', 'issue_slots_full',
            'rx_empty', 'rx_copy', 'check_fence', 'read_requests', 'drain', 'queued_blocked')},
        'completion_payload_MB_s': c['payload_dwords'] * 4 * hz / cycles / 1e6,
        'mean_completion_payload_bytes': c['payload_dwords'] * 4 / max(c['completions'], 1),
        'mean_read_request_payload_bytes': c['payload_dwords'] * 4 / max(c['read_requests'], 1),
        # Occupancy integral / burst count: AR-to-RLAST inclusive cycles.
        # Approximate if the capture starts/ends with an outstanding burst.
        'mean_axi_burst_residence_ns': (c['pending_one'] + 2 * c['pending_two']) / max(c['r_bursts'], 1) * 1e9 / hz,
        'slot_empty_cycles_per_completion': c['slot_empty_wait'] / max(c['completions'], 1),
        'tx_stall_cycles_per_completion': c['tx_stall'] / max(c['completions'], 1),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mode', choices=['idle', 'write'], required=True)
    ap.add_argument('--qd', type=int, choices=[1, 8], default=8)
    ap.add_argument('--seconds', type=int, choices=range(1, 21), default=10)
    a = ap.parse_args()
    before = guard()
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    with mmap.mmap(fd, 4096, offset=0xa2000000) as mm:
        def rd(off): return struct.unpack_from('<I', mm, off)[0]
        def wr(off, value): struct.pack_into('<I', mm, off, value)
        assert rd(0) == 0x44425231 and rd(0x88) == 0x50524631
        def wait_idle():
            samples = []
            deadline = time.monotonic() + 1
            while True:
                status = rd(0x14)
                samples.append(status)
                assert status & 0xb == 8, 'DMA/PIO fault or inactive link: ' + hex(status)
                if status & 4:
                    return samples
                assert time.monotonic() < deadline, 'DMA did not become idle'
                time.sleep(.001)
        hz = rd(0x8c)
        assert hz == 125000000
        before_status = wait_idle()
        wr(0x80, 3)
        result = None
        command = None
        try:
            if a.mode == 'idle':
                time.sleep(a.seconds)
            else:
                command = ['fio', '--name=completion_profile', '--filename=/dev/nvme0n1',
                           '--rw=write', '--direct=1', '--ioengine=libaio', '--numjobs=1',
                           '--bs=1M', '--iodepth=' + str(a.qd), '--offset=8G', '--size=4G',
                           '--time_based=1', '--runtime=' + str(a.seconds), '--end_fsync=1',
                           '--refill_buffers=1', '--randseed=19047', '--output-format=json']
                run = subprocess.run(command, check=True, capture_output=True, text=True, timeout=28)
                result = json.loads(run.stdout)
                assert all(j['error'] == 0 for j in result['jobs'])
        finally:
            wr(0x80, 0)
        assert rd(0x80) == 0
        overflow = rd(0x84)
        counts = dict(zip(NAMES, [rd(0x100 + 4 * i) for i in range(32)]))
        Path('/tmp/completion-profile-last.json').write_text(json.dumps({
            'counters': counts, 'overflow': overflow, 'fio': result, 'command': command}))
        assert overflow == 0, 'Capture wrapped; shorten the interval'
        assert counts['fault'] == 0
        after_status = wait_idle()
    os.close(fd)
    after = guard()
    written = (after[6] - before[6]) * 512
    assert written == (sum(j['write']['io_bytes'] for j in result['jobs']) if result else 0)
    print(json.dumps({'mode': a.mode, 'qd': a.qd, 'command': command, 'clock_hz': hz,
                      'before_status': before_status, 'after_status': after_status,
                      'overflow': overflow, 'counters': counts, 'summary': summarize(counts, hz),
                      'written_bytes': written, 'fio': result}, indent=2))


if __name__ == '__main__':
    main()

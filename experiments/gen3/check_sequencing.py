#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rate/clock control and independent transmitted-word scheduling checks."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'experiments/gen3'
OUT = Path(tempfile.mkdtemp(prefix='gen3_sequencing_', dir=ROOT / 'build'))


def run(name, extras=(), interval=None):
    sources = [SRC / f'gen3_{name}.sv', SRC / f'test_{name}.sv']
    sources += [SRC / f'{extra}.sv' for extra in extras]
    binary = OUT / (name + (str(interval) if interval else ''))
    command = ['iverilog', '-g2012', '-s', f'test_{name}', '-o', str(binary)]
    if interval:
        command += [f'-Ptest_tx_schedule.SKP_INTERVAL={interval}']
    subprocess.run(command + list(map(str, sources)), check=True)
    trace = binary.with_suffix('.txt')
    subprocess.run(['vvp', str(binary), f'+OUT={trace}'], check=True)
    subprocess.run(['verilator', '--lint-only', '--Wall', '--top-module',
                    f'gen3_{name}', str(sources[0]), *map(str, sources[2:])], check=True)
    return trace


def check_trace(path, interval):
    # Decode captured scrambled PCS words without instantiating the custom RX.
    # Byte order, OS contents, LFSR/parity and legal block transitions are
    # checked from a serial bit recurrence and independent scheduling counters.
    lfsr = 0x1dbfbc
    parity = 0
    state = 'off'
    block = []
    cycle_counter = None
    blocks = 0
    debt = 0
    packets = []
    in_packet = False
    skps = 0
    markers = 0
    last_eds = False
    for line in path.read_text().splitlines():
        fields = line.split()
        cycle, valid = map(int, fields[:2])
        if not valid:
            continue
        word = int(fields[2], 16)
        header, start, marker = map(int, fields[3:])
        if start and state == 'off':
            cycle_counter = cycle
        assert cycle_counter is not None
        # Within an active run: 64 words, bubble, repeat. Exit can end a run.
        offset = cycle - cycle_counter
        assert offset % 65 != 64, ('unexpected cadence slot', cycle)
        assert start == (len(block) == 0), ('block start', cycle)
        block.append(word)
        markers += marker
        if len(block) < 4:
            continue
        payload = b''.join(w.to_bytes(4, 'little') for w in block)
        block = []
        blocks += 1
        due = blocks % interval == 0
        if header == 1:
            if payload == b'\xe1' + b'\x55' * 15:
                assert state == 'off'
                state = 'data'
                last_eds = False
                parity = 0
                advance = 16
            elif payload[:12] == b'\xaa' * 12:
                assert state == 'data' and last_eds and not in_packet
                assert debt > 0, 'SKP sent before scheduled'
                assert payload[12] == 0xe1
                assert payload[13] == ((parity << 7) | (lfsr >> 16))
                assert payload[14:] == (lfsr & 65535).to_bytes(2, 'big')
                parity = 0
                debt -= 1
                advance = 0
                skps += 1
                last_eds = False
                state = 'after_skp'
            else:
                assert payload == b'\x00\xff' * 8
                assert state == 'data' and last_eds and not in_packet
                state = 'off'
                lfsr = 0x1dbfbc
                blocks = 0
                debt = 0
                advance = 0
                due = False
        else:
            assert header == 2 and state in ('data', 'after_skp')
            assert not (state == 'data' and last_eds), 'EDS not followed by OS'
            state = 'data'
            parity ^= sum(b.bit_count() for b in payload) & 1
            decoded = bytearray()
            for octet in payload:
                value = 0
                for bit in range(8):
                    top = lfsr >> 22
                    value |= (((octet >> bit) & 1) ^ top) << bit
                    lfsr = ((lfsr << 1) & 0x7fffff) ^ (0x210125 if top else 0)
                decoded.append(value)
            advance = 0
            values = [int.from_bytes(decoded[i:i+4], 'little') for i in range(0, 16, 4)]
            last_eds = values[-1] == 0x0090801f
            for i, value in enumerate(values):
                if value == 0x81000000:
                    assert not packets and not in_packet
                    in_packet = True
                if in_packet:
                    assert value == 0x81000000 + len(packets), 'packet interrupted/corrupted'
                    packets.append(value)
                    if len(packets) == 20:
                        in_packet = False
                else:
                    assert value == 0 or (i == 3 and value == 0x0090801f)
        for _ in range(advance * 8):
            top = lfsr >> 22
            lfsr = ((lfsr << 1) & 0x7fffff) ^ (0x210125 if top else 0)
        debt += due
    assert state == 'off' and not block
    assert len(packets) == 20 and markers == 1 and skps >= 2
    print(f'PASS: independent TX decode, EDS/SKP, LFSR/parity and cadence (interval {interval}, {skps} SKPs)')


run('phy_rate')
run('clock_watch')
run('phy_control', ('gen3_phy_rate', 'gen3_clock_watch'))
for interval in (4, 372):
    check_trace(run('tx_schedule', ('gen3_tx_cadence', 'gen3_scrambler'), interval), interval)
print(f'Sequencing results: {OUT}')

fault_test = OUT / 'tx_fault'
subprocess.run(['iverilog', '-g2012', '-s', 'test_tx_schedule_fault', '-o', str(fault_test),
                *map(str, [SRC/'gen3_tx_schedule.sv', SRC/'gen3_tx_cadence.sv',
                           SRC/'gen3_scrambler.sv', SRC/'test_tx_schedule_fault.sv'])], check=True)
subprocess.run(['vvp', str(fault_test)], check=True)

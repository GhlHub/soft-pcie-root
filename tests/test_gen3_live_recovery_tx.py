# SPDX-License-Identifier: Apache-2.0
"""Independently decode the PCS output across a mid-packet Recovery request."""
from pathlib import Path
import subprocess
import pytest
from test_gen3_packet_peer import tlp

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('phase', [1, 2, 3, 4, 10, 19, 20])
def test_atomic_recovery_exit(tmp_path, phase):
    payload = bytes.fromhex('100000400f00000100100000') + bytes(range(64))
    frame = tlp(0, payload)
    assert len(frame) == 84
    vectors, trace, exe = (tmp_path / n for n in ('frame.hex', 'trace.txt', 'sim'))
    vectors.write_text(''.join(f'{int.from_bytes(frame[i:i+4], "little"):08x}\n' for i in range(0, 84, 4)))
    subprocess.run(['iverilog', '-g2012', '-s', 'test_live_recovery_tx',
                    f'-Ptest_live_recovery_tx.PHASE={phase}', '-o', str(exe),
                    str(ROOT/'experiments/gen3/gen3_recovery_tx.sv'),
                    str(ROOT/'experiments/gen3/test_live_recovery_tx.sv')], check=True)
    subprocess.run(['vvp', str(exe), f'+VECTORS={vectors}', f'+TRACE={trace}'], check=True, timeout=20)
    state, block, streams, stream, closed = 0x1dbfbc, [], [], False, False
    first, headers, training = None, [], 0
    for line in trace.read_text().splitlines():
        cycle, valid, start, header, word = line.split()
        if not int(valid):
            continue
        cycle, header = int(cycle), int(header)
        if first is None:
            first = cycle
        assert (cycle-first) % 65 != 64
        assert bool(int(start)) == (not block)
        if not block:
            block_header = header
        assert header == block_header
        block.extend(int(word, 16).to_bytes(4, 'little'))
        if len(block) != 16:
            continue
        raw, block = bytes(block), []
        decoded = []
        for value in raw:
            mask = 0
            for bit in range(8):
                feedback = state >> 22
                mask |= feedback << bit
                state = ((state << 1) & 0x7fffff) ^ (0x210125 if feedback else 0)
            decoded.append(value ^ mask)
        if header == 2:
            assert stream and not closed
            if decoded[-4:] == [0x1f, 0x80, 0x90, 0]:
                closed = True
                streams[-1].extend(decoded[:-4])
            else:
                streams[-1].extend(decoded)
        elif raw == bytes([0, 255])*8:
            assert not stream or closed
            stream, closed, state = False, False, 0x1dbfbc
            headers.append('EIEOS')
        elif raw == b'\xe1'+b'\x55'*15:
            assert not stream
            streams.append(bytearray())
            stream, closed = True, False
            headers.append('SDS')
        elif raw == b'\x66'*16:
            assert stream and closed
            stream = False
            headers.append('EIOS')
        else:
            assert header == 1 and raw[0] == 0x1e and not stream
            training += 1
    assert not block and training >= 16
    assert len(streams) == 2 and streams[0].count(frame) == 1
    position = streams[0].index(frame)
    assert not any(streams[0][:position]) and not any(streams[0][position+len(frame):])
    assert not any(streams[1])
    assert headers == ['EIEOS', 'SDS', 'EIEOS', 'SDS', 'EIOS']

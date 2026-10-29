# SPDX-License-Identifier: Apache-2.0
"""NVMe-scope Gen1/Gen2 fault injection and implementation boundary tests."""
import zlib

import pytest

from test_pcie_soft import crc16_packet, run_bench


@pytest.mark.parametrize('half_period', [4, 2], ids=['gen1', 'gen2'])
@pytest.mark.parametrize('case', range(28), ids=[
    'byte-enables', 'timeout-ticks', 'traffic-class', 'digest', 'poison',
    'relaxed-order', 'no-snoop', 'bcm', 'length', 'byte-count', 'lower-address',
    'format', 'format-reserved', 'wrong-tag', 'wrong-requester', 'non-completion',
    'extra-data', 'missing-data', 'ur', 'ca', 'memory-crs', 'before-deadline',
    'at-deadline', 'malformed-at-deadline', 'write-at-deadline',
    'ur-at-deadline', 'wrong-tag-at-deadline', 'link-loss-at-deadline',
])
def test_requester_completion_matrix(tmp_path, half_period, case):
    run_bench(tmp_path, 'tb_requester_coverage', ['pcie_soft_requester.sv'],
              parameters=[('HALF_PERIOD', half_period), ('CASE', case)])


# These are decoded-symbol tests. They do not qualify the serial GTH codec.

def tlp_frame(sequence, words, *, nullified=False):
    body = sequence.to_bytes(2, 'big') + b''.join(w.to_bytes(4, 'little') for w in words)
    checksum = zlib.crc32(body) ^ (0xffffffff if nullified else 0)
    return [0x1fb, *body, *checksum.to_bytes(4, 'little'), 0x1fe if nullified else 0x1fd]


def rx_vectors(frames, tail):
    rows = []
    for frame, error_beat in frames:
        # PAD is harmless outside a packet and aligns odd-length fault cases.
        frame = frame + ([0x1f7] if len(frame) % 2 else [])
        for i in range(0, len(frame), 2):
            lo, hi = frame[i:i + 2]
            rows.append((0, (lo & 255) | ((hi & 255) << 8),
                         (lo >> 8) | ((hi >> 8) << 1), int(i // 2 == error_beat), 0))
        rows.append((1, 4, 0, 0, 0))
    rows.extend(tail)
    return rows


def drain(words):
    return [(3, word, int(i == len(words) - 1), 0, 1) for i, word in enumerate(words)]


FAULTS = ([f'bit-{bit}' for bit in range(22 * 8)] +
          [f'truncate-{n}' for n in range(1, 23)] +
          ['bad-end', 'control-in-body', 'phy-error', 'length-mismatch',
           'oversize', 'future-sequence', 'duplicate', 'nullified'])


@pytest.mark.parametrize('half_period', [4, 2], ids=['gen1', 'gen2'])
@pytest.mark.parametrize('fault', FAULTS)
def test_receive_fault_matrix(tmp_path, half_period, fault):
    sentinel = [0x01000040, 0x11111111, 0x22222222, 0x12345678]
    retry = [0x01000040, 0x33333333, 0x44444444, 0xabcdef01]
    frame = tlp_frame(1, retry)
    error_beat = -1
    if fault.startswith('bit-'):
        bit = int(fault[4:])
        frame[1 + bit // 8] ^= 1 << (bit % 8)
    elif fault.startswith('truncate-'):
        frame = frame[:int(fault[9:])] + [0x1fd]
    elif fault == 'bad-end':
        frame[-1] = 0x1fe  # EDB without nullified CRC
    elif fault == 'control-in-body':
        frame[7] = 0x1bc
    elif fault == 'phy-error':
        error_beat = 4
    elif fault == 'length-mismatch':
        frame = tlp_frame(1, [0x02000040, *retry[1:]])
    elif fault == 'oversize':
        frame = tlp_frame(1, [0x21000040, 0, 0, *range(33)])
    elif fault == 'future-sequence':
        frame = tlp_frame(2, retry)
    elif fault == 'duplicate':
        frame = tlp_frame(0, retry)
    elif fault == 'nullified':
        frame = tlp_frame(1, retry, nullified=True)
    acks = 2 if fault == 'duplicate' else 1
    naks = 0 if fault in ('duplicate', 'nullified') else 1
    rows = rx_vectors([(tlp_frame(0, sentinel), -1), (frame, error_beat)],
                      [(5, acks, naks, 0, 0)] + drain(sentinel) + [(2, 0, 0, 0, 0)])
    rows += rx_vectors([(tlp_frame(1, retry), -1)],
                       [(5, acks + 1, naks, 1, 0)] + drain(retry) + [(2, 0, 0, 0, 0)])
    path = tmp_path / 'rx.txt'
    path.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n' for op, a, b, c, d in rows))
    run_bench(tmp_path, 'tb_rx_fault_matrix', ['pcie_soft_packet_rx.sv'], path,
              parameters=[('HALF_PERIOD', half_period)])


@pytest.mark.parametrize('half_period', [4, 2], ids=['gen1', 'gen2'])
@pytest.mark.parametrize('bit', range(48))
def test_dllp_crc_rejection(tmp_path, half_period, bit):
    body = bytes([0x90, 0x12, 0x34, 0x56])
    good = [0x15c, *body, *crc16_packet(body).to_bytes(2, 'little'), 0x1fd]
    bad = good.copy()
    bad[1 + bit // 8] ^= 1 << (bit % 8)
    rows = rx_vectors([(bad, -1)], [(4, 0, 0, 0, 0), (2, 0, 0, 0, 0)])
    rows += rx_vectors([(good, -1)],
                       [(4, 1, int.from_bytes(body, 'little'), 0, 0), (2, 0, 0, 0, 0)])
    path = tmp_path / 'dllp.txt'
    path.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n' for op, a, b, c, d in rows))
    run_bench(tmp_path, 'tb_rx_fault_matrix', ['pcie_soft_packet_rx.sv'], path,
              parameters=[('HALF_PERIOD', half_period)])


@pytest.mark.parametrize('half_period', [4, 2], ids=['gen1', 'gen2'])
@pytest.mark.parametrize('update_cycles', [3, 16, 1024, 4000])
def test_updatefc_timer_boundary(tmp_path, half_period, update_cycles):
    run_bench(tmp_path, 'tb_fc_timer_coverage', ['pcie_soft_flow_control.sv'],
              parameters=[('HALF_PERIOD', half_period), ('UPDATE_CYCLES', update_cycles)])


@pytest.mark.parametrize('half_period', [4, 2], ids=['gen1', 'gen2'])
@pytest.mark.parametrize('timeout', [16, 512])
@pytest.mark.parametrize('ack_edge', [0, 1, 2], ids=['expire', 'ack-at-expiry', 'ack-at-service'])
def test_replay_timer_boundary(tmp_path, half_period, timeout, ack_edge):
    run_bench(tmp_path, 'tb_replay_timer_coverage', ['pcie_soft_replay.sv'],
              parameters=[('HALF_PERIOD', half_period), ('TIMEOUT', timeout), ('ACK_EDGE', ack_edge)])

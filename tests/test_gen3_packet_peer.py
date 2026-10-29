# SPDX-License-Identifier: Apache-2.0
"""Independent encoded ingress peer and framed egress scoreboard.

The boundary is native 32-bit Gen3 blocks on ingress and framed DWORDs on
link-layer egress, before the physical TX scheduler/scrambler. No DUT state
or production transmitter is used to construct peer traffic.
"""
from pathlib import Path
import subprocess
import zlib

import pytest
from test_pcie_soft import crc16_packet

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'experiments/gen3'
CORE = ROOT / 'ip/soft_pcie_root/rtl/pcie_soft'


def stp(length, sequence):
    remainder = sum(((length >> bit) & 1) << (14-bit) for bit in range(11))
    for bit in range(14, 3, -1):
        if remainder & (1 << bit):
            remainder ^= 0x13 << (bit-4)
    parity = (length.bit_count() + remainder.bit_count()) & 1
    return bytes([(length & 15) << 4 | 15, length >> 4 | parity << 7,
                  remainder << 4 | sequence >> 8, sequence & 255])


def tlp(sequence, payload):
    return (stp(len(payload)//4 + 2, sequence) + payload +
            zlib.crc32(sequence.to_bytes(2, 'big') + payload).to_bytes(4, 'little'))


def dllp(body):
    return b'\xf0\xac' + body + crc16_packet(body).to_bytes(2, 'little')


def fc(kind, headers=1, data=1):
    return bytes([kind, headers >> 2, (headers & 3) << 6 | data >> 8, data & 255])


def ack(sequence, nak=False):
    return bytes([0x10 if nak else 0, 0, sequence >> 8, sequence & 255])


class PacketPeer:
    def __init__(self, gap=0):
        self.rows = []
        self.state = 0x1dbfbc
        self.gap = gap
        self.block(bytes([0, 255])*8, 1)
        self.state = 0x1dbfbc
        self.block(b'\xe1' + b'\x55'*15, 1)  # SDS

    def wait(self, cycles):
        self.rows.append((1, cycles, 0, 0))

    def block(self, plain, header=2):
        wire = bytearray()
        for value in plain:
            mask = 0
            for bit in range(8):
                feedback = self.state >> 22
                mask |= feedback << bit
                self.state = ((self.state << 1) & 0x7fffff) ^ (0x210125 if feedback else 0)
            wire.append(value ^ mask if header == 2 else value)
        for offset in range(0, 16, 4):
            self.rows.append((0, int.from_bytes(wire[offset:offset+4], 'little'),
                              8 | (4 if offset == 0 else 0) | header, 0))
            if self.gap:
                self.wait(self.gap)

    def stream(self, data, offset=0):
        data = bytes(offset) + data
        # IDL padding closes the current token/packet and fills complete blocks.
        data += bytes((-len(data)) % 16 + 16)
        for i in range(0, len(data), 16):
            self.block(data[i:i+16])
        self.wait(20)

    def initialize(self):
        self.stream(b''.join(dllp(fc(t)) for t in (0x40, 0x50, 0x60)))
        self.wait(60)
        self.stream(b''.join(dllp(fc(t)) for t in (0xc0, 0xd0, 0xe0)))
        self.wait(60)
        self.rows.append((3, 5, 0, 0))  # active, no pending, one posted credit

    def send_app(self, payload):
        for i in range(0, len(payload), 4):
            self.rows.append((2, int.from_bytes(payload[i:i+4], 'little'), int(i+4 == len(payload)), 0))
        self.wait(50)

    def drain(self, payload):
        for i in range(0, len(payload), 4):
            self.rows.append((4, int.from_bytes(payload[i:i+4], 'little'), int(i+4 == len(payload)), 0))
        self.rows.append((5, 0, 0, 0))


@pytest.fixture(scope='module')
def packet_peer_executable(tmp_path_factory):
    path = tmp_path_factory.mktemp('gen3_packet_peer') / 'sim'
    modules = ['gen3_native_rx', 'gen3_data_rx', 'gen3_stream_rx', 'gen3_stream_buffered_rx',
               'gen3_packet_gate', 'gen3_link_layer', 'gen3_link_profile', 'gen3_dllp_source',
               'gen3_tx_window', 'gen3_tlp_source', 'gen3_stp']
    common = ['pcie_soft_flow_control', 'pcie_soft_requester', 'pcie_soft_replay', 'pcie_soft_ack_capture']
    result = subprocess.run(['iverilog', '-g2012', '-s', 'test_gen3_packet_peer', '-o', str(path),
                             *[str(SRC/f'{n}.sv') for n in modules],
                             *[str(CORE/f'{n}.sv') for n in common],
                             str(SRC/'test_gen3_packet_peer.sv')],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    return path


def run_peer(peer, tmp_path, executable):
    vectors, trace = tmp_path/'vectors.txt', tmp_path/'trace.txt'
    vectors.write_text(''.join(f'{op} {a:x} {b:x} {c:x}\n' for op,a,b,c in peer.rows))
    result = subprocess.run(['vvp', str(executable), f'+VECTORS={vectors}', f'+TRACE={trace}'],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    packets, control, frame = [], [], bytearray()
    for line in trace.read_text().splitlines():
        word, last = line.split()
        frame.extend(int(word, 16).to_bytes(4, 'little'))
        if last == '1':
            if frame[:2] == b'\xf0\xac':
                assert len(frame) == 8
                assert int.from_bytes(frame[6:], 'little') == crc16_packet(frame[2:6])
                control.append(bytes(frame[2:6]))
            else:
                length = frame[0] >> 4 | (frame[1] & 0x7f) << 4
                sequence = (frame[2] & 15) << 8 | frame[3]
                assert frame[:4] == stp(length, sequence)
                assert len(frame) == length * 4
                payload = bytes(frame[4:-4])
                assert int.from_bytes(frame[-4:], 'little') == zlib.crc32(sequence.to_bytes(2, 'big') + payload)
                packets.append((sequence, payload))
            frame.clear()
    assert not frame, 'Partial outgoing packet'
    return packets, control


PAYLOAD = bytes.fromhex('400000017856341200000000efbeadde')


@pytest.mark.parametrize('scenario', ['ack', 'corrupt-ack', 'nak', 'timeout', 'credit', 'pause'])
@pytest.mark.parametrize('gap', [0, 1])
def test_native_replay_and_credit(tmp_path, packet_peer_executable, scenario, gap):
    peer = PacketPeer(gap)
    peer.initialize()
    peer.send_app(PAYLOAD)
    peer.rows.append((3, 6, 0, 0))  # pending, no remaining posted credit
    if scenario == 'corrupt-ack':
        frame = bytearray(dllp(ack(0)))
        frame[-1] ^= 1
        peer.stream(frame)
        peer.rows.append((3, 6, 0, 0))
    if scenario == 'nak':
        peer.stream(dllp(ack(0xfff, True)))
        peer.wait(50)
    if scenario == 'timeout':
        peer.wait(400)
    if scenario == 'pause':
        peer.rows.append((7, 0, 0, 0))
        peer.wait(500)
        peer.rows.append((3, 6, 0, 0))
        peer.rows.append((7, 1, 0, 0))
    peer.stream(dllp(ack(0)))
    peer.wait(30)
    peer.rows.append((3, 4, 0, 0))  # ACK frees replay but does not return credit
    if scenario == 'credit':
        bad = bytearray(dllp(fc(0x80, 2, 2)))
        bad[-1] ^= 1
        peer.stream(bad)
        peer.rows.append((3, 4, 0, 0))
        peer.stream(dllp(fc(0x80, 2, 2)))
        peer.rows.append((3, 5, 0, 0))
        peer.send_app(PAYLOAD)
        peer.stream(dllp(ack(1)))
        peer.wait(30)
        peer.rows.append((3, 4, 0, 0))
    packets, _ = run_peer(peer, tmp_path, packet_peer_executable)
    expected = [(0, PAYLOAD)] * (2 if scenario in ('nak', 'timeout') else 1)
    if scenario == 'credit':
        expected.append((1, PAYLOAD))
    assert packets == expected


@pytest.mark.parametrize('offset', range(16))
@pytest.mark.parametrize('bit', range(32))
def test_native_lcrc_fault_retry(tmp_path, packet_peer_executable, offset, bit):
    peer = PacketPeer()
    peer.initialize()
    peer.stream(tlp(0, PAYLOAD), offset)
    corrupted = bytearray(tlp(1, PAYLOAD))
    corrupted[-4 + bit//8] ^= 1 << (bit % 8)
    peer.stream(corrupted, offset)
    peer.rows.append((6, 1, 1, 0))
    peer.drain(PAYLOAD)
    peer.stream(tlp(1, PAYLOAD), offset)
    peer.rows.append((6, 2, 1, 0))
    peer.drain(PAYLOAD)
    peer.wait(20)
    packets, control = run_peer(peer, tmp_path, packet_peer_executable)
    assert not packets
    responses = [body for body in control if body[0] in (0, 0x10)]
    assert responses == [ack(0), ack(0, True), ack(1)]


@pytest.mark.parametrize('bit', range(48))
@pytest.mark.parametrize('kind', ['ack', 'updatefc'])
def test_native_dllp_corruption(tmp_path, packet_peer_executable, bit, kind):
    peer = PacketPeer()
    peer.initialize()
    peer.send_app(PAYLOAD)
    if kind == 'updatefc':
        peer.stream(dllp(ack(0)))
        peer.wait(20)
    body = ack(0) if kind == 'ack' else fc(0x80, 2, 2)
    corrupted = bytearray(dllp(body))
    corrupted[2 + bit//8] ^= 1 << (bit % 8)
    peer.stream(corrupted)
    peer.rows.append((3, 6 if kind == 'ack' else 4, 0, 0))
    peer.stream(dllp(body))
    peer.wait(20)
    peer.rows.append((3, 4 if kind == 'ack' else 5, 0, 0))
    packets, _ = run_peer(peer, tmp_path, packet_peer_executable)
    assert packets == [(0, PAYLOAD)]


@pytest.mark.parametrize('offset', range(16))
@pytest.mark.parametrize('fault', [False, True], ids=['ordered-exit', 'bad-sync-header'])
def test_native_reacquire_preserves_packets(tmp_path, packet_peer_executable, offset, fault):
    peer = PacketPeer()
    peer.initialize()
    peer.stream(tlp(0, PAYLOAD), offset)
    if fault:
        peer.block(bytes(16), 0)
        peer.wait(20)
        peer.rows.append((8, 1, 0, 0))
    else:
        # EDS occupies the final DWORD; next block must be an ordered set.
        peer.block(bytes(12) + bytes.fromhex('1f809000'))
    peer.block(bytes([0, 255])*8, 1)
    peer.state = 0x1dbfbc
    peer.block(b'\xe1' + b'\x55'*15, 1)
    peer.wait(20)
    peer.drain(PAYLOAD)
    peer.stream(tlp(1, PAYLOAD), offset)
    peer.drain(PAYLOAD)
    peer.wait(20)
    packets, control = run_peer(peer, tmp_path, packet_peer_executable)
    assert not packets
    assert [body for body in control if body[0] in (0, 0x10)] == [ack(0), ack(1)]

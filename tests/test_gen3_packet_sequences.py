# SPDX-License-Identifier: Apache-2.0
"""Native Gen3 sequence/ownership checks using independently encoded traffic."""
import pytest
from test_gen3_packet_peer import (
    PacketPeer, ack, dllp, fc, tlp, run_peer, packet_peer_executable,
)


def payload(words, marker):
    # 3DW MWr with distinct data and legal contiguous byte enables.
    header = (0x40000000 | words).to_bytes(4, 'big')
    return header + bytes.fromhex('7856341200000000') + b''.join(
        ((marker << 16) | n).to_bytes(4, 'little') for n in range(words))


@pytest.mark.parametrize('offset', range(16))
@pytest.mark.parametrize('words', [1, 2, 7, 32])
@pytest.mark.parametrize('scenario', ['duplicate', 'future', 'corrupt-duplicate'])
def test_native_receive_sequence(tmp_path, packet_peer_executable, offset, words, scenario):
    peer = PacketPeer()
    peer.initialize()
    first, second = payload(words, 1), payload(words, 2)
    peer.stream(tlp(0, first), offset)
    frame = bytearray(tlp(2 if scenario == 'future' else 0, first))
    if scenario == 'corrupt-duplicate':
        frame[-1] ^= 0x80
    peer.stream(frame, offset)
    # The original remains intact while the duplicate/future packet is rejected.
    peer.drain(first)
    peer.stream(tlp(1, second), offset)
    peer.drain(second)
    peer.wait(20)
    packets, control = run_peer(peer, tmp_path, packet_peer_executable)
    assert not packets
    assert [b for b in control if b[0] in (0, 0x10)] == [
        ack(0), ack(0, scenario != 'duplicate'), ack(1)]


@pytest.mark.parametrize('retire', [0, 1, 2])
@pytest.mark.parametrize('offset', [0, 3, 15])
def test_native_cumulative_retirement(tmp_path, packet_peer_executable, retire, offset):
    peer = PacketPeer()
    peer.initialize()
    peer.stream(dllp(fc(0x80, 3, 3)))
    bodies = [payload(1, n + 1) for n in range(3)]
    for body in bodies:
        peer.send_app(body)
    peer.stream(dllp(ack(retire)), offset)
    peer.wait(20)
    peer.rows.append((3, 4 if retire == 2 else 6, 0, 0))
    # Duplicate cumulative ACK must neither retire later packets nor replay them.
    peer.stream(dllp(ack(retire)), offset)
    peer.rows.append((3, 4 if retire == 2 else 6, 0, 0))
    if retire < 2:
        peer.stream(dllp(ack(retire, True)), offset)
        peer.wait(70)
        peer.stream(dllp(ack(2)), offset)
        peer.wait(20)
    peer.rows.append((3, 4, 0, 0))
    packets, _ = run_peer(peer, tmp_path, packet_peer_executable)
    assert packets == list(enumerate(bodies)) + list(enumerate(bodies))[retire+1:]


def test_native_rx_sequence_rollover(tmp_path, packet_peer_executable):
    peer = PacketPeer()
    peer.initialize()
    expected = []
    for ordinal in range(4098):
        sequence = ordinal & 0xfff
        body = payload(1, ordinal)
        peer.stream(tlp(sequence, body), ordinal % 16)
        peer.drain(body)
        expected.append(ack(sequence))
        if ordinal in (4095, 4096):
            # A duplicate on either side of rollover must not be delivered twice.
            peer.stream(tlp(sequence, body), ordinal % 16)
            peer.rows.append((5, 0, 0, 0))
            expected.append(ack(sequence))
    peer.wait(20)
    packets, control = run_peer(peer, tmp_path, packet_peer_executable)
    assert not packets
    assert [b for b in control if b[0] in (0, 0x10)] == expected

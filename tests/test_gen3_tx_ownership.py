# SPDX-License-Identifier: Apache-2.0
"""Native Gen3 TX rollover and full replay-window ownership checks."""
import pytest
from test_gen3_packet_peer import PacketPeer, ack, dllp, fc, run_peer, packet_peer_executable
from test_gen3_packet_sequences import payload


def enqueue(peer, body):
    for index in range(0, len(body), 4):
        peer.rows.append((2, int.from_bytes(body[index:index+4], 'little'),
                          int(index + 4 == len(body)), 0))


@pytest.mark.parametrize('retire', range(8))
@pytest.mark.parametrize('offset', [0, 15])
def test_native_full_replay_window(tmp_path, packet_peer_executable, retire, offset):
    peer = PacketPeer()
    peer.initialize()
    # Spare credits distinguish replay-store capacity from credit backpressure.
    peer.stream(dllp(fc(0x80, 32, 32)))
    originals = [payload(1, n) for n in range(8)]
    for body in originals:
        enqueue(peer, body)
    peer.wait(120)
    peer.rows.append((3, 6, 0, 0))  # Eight owners; ninth cannot be admitted.
    peer.stream(dllp(ack(retire)), offset)
    peer.rows.append((3, 5 if retire == 7 else 7, 0, 0))
    replacements = [payload(1, n + 8) for n in range(retire + 1)]
    for body in replacements:
        enqueue(peer, body)
    peer.wait(100)
    peer.rows.append((3, 6, 0, 0))  # Freed slots reused, window full again.
    peer.stream(dllp(ack(retire, True)), offset)
    peer.wait(180)
    peer.stream(dllp(ack(8 + retire)), offset)
    peer.wait(20)
    peer.rows.append((3, 5, 0, 0))
    packets, _ = run_peer(peer, tmp_path, packet_peer_executable)
    sent = list(enumerate(originals + replacements))
    assert packets == sent + sent[retire+1:]


def test_native_tx_sequence_and_credit_rollover(tmp_path, packet_peer_executable):
    peer = PacketPeer()
    peer.initialize()
    expected = []
    for ordinal in range(4098):
        sequence = ordinal & 0xfff
        body = payload(1, ordinal)
        peer.send_app(body)
        peer.rows.append((3, 6, 0, 0))
        expected.append((sequence, body))
        if ordinal in (4095, 4096):
            # NAK at rollover replays the same owner and sequence without credits.
            peer.stream(dllp(ack((sequence - 1) & 0xfff, True)))
            peer.wait(50)
            expected.append((sequence, body))
        peer.stream(dllp(ack(sequence)), ordinal % 16)
        peer.wait(10)
        peer.rows.append((3, 4, 0, 0))
        # One cumulative credit returned per original packet, never per replay.
        peer.stream(dllp(fc(0x80, (ordinal + 2) & 255, (ordinal + 2) & 4095)))
        peer.rows.append((3, 5, 0, 0))
    packets, _ = run_peer(peer, tmp_path, packet_peer_executable)
    assert packets == expected

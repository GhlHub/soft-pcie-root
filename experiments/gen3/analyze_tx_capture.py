#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independently decode native TX words exported by the diagnostic ILA.

This checks the fabric-to-PHY interface, not the serial lane. Acquisition needs
one complete EIEOS in the capture. Incomplete edge blocks are ignored.
"""
import argparse
import collections
import csv
import json
import zlib
from pathlib import Path


def analyze(path, data_column, initfc1=False, packets=False):
    with path.open() as f:
        reader = csv.DictReader(f)
        next(reader)  # Vivado radix row.
        rows = list(reader)
    event_key = next(k for k in rows[0] if k.endswith('diag_tx_events[31:0]'))
    cycle_key = next(k for k in rows[0] if k.endswith('diag_state_cycles[31:0]'))
    counts = collections.Counter()
    nonidle = collections.Counter()
    errors = []
    fc_packets = []
    stream_bytes = bytearray()
    decoded_packets = []
    # Independently checked against the pinned cocotbext-pcie encoder.
    fc_expected = [bytes.fromhex(x) for x in ("40004008eaee", "50004001a84f", "60000000d892")]
    state = None
    parity = 0
    stream = False
    closed = False
    block = []
    header = None
    first_data = None
    last_data = None
    sds_sample = None
    ts2_sample = None
    valid_cycles = []
    for i, row in enumerate(rows):
        event = int(row[event_key], 16)
        if not event & 1 or (event >> 11) & 3 != 2:
            continue
        valid_cycles.append(i)
        start = bool(event & 2)
        h = (event >> 2) & 3
        word = int(row[data_column], 16)
        if start:
            if block:
                errors.append(f'premature block start at sample {i}')
            block = []
            header = h
        elif header is None:
            continue
        if h != header:
            errors.append(f'header changed within block at sample {i}')
        block.extend(word.to_bytes(4, 'little'))
        if len(block) < 16:
            continue
        raw = bytes(block)
        block = []
        header = None
        if h == 1 and raw == bytes([0, 255]) * 8:
            state = 0x1dbfbc
            counts['eieos'] += 1
            continue
        if state is None:
            counts['blocks_before_acquisition'] += 1
            continue
        if h == 1 and raw[0] == 0xaa:
            expected = bytes([0xaa]) * 12 + bytes([
                0xe1, ((parity if stream else 1 - (state >> 22)) << 7) | (state >> 16),
                (state >> 8) & 255, state & 255])
            if raw != expected or (stream and not closed):
                errors.append(f'SKP state/parity/EDS mismatch at sample {i}')
            parity = 0
            closed = False
            counts['skp'] += 1
            continue
        decoded = []
        for j, value in enumerate(raw):
            mask = 0
            for bit in range(8):
                feedback = state >> 22
                mask |= feedback << bit
                state = ((state << 1) & 0x7fffff) ^ (0x210125 if feedback else 0)
            decoded.append(value ^ mask if h == 2 or (raw[0] in (0x1e, 0x2d) and j) else value)
        decoded = bytes(decoded)
        if h == 2:
            if not stream or closed:
                errors.append(f'Data Block outside open stream at sample {i}')
            stream_bytes.extend(decoded)
            for j in range(0, 16, 4):
                dword = int.from_bytes(decoded[j:j+4], 'little')
                if dword:
                    nonidle[f'{dword:08x}'] += 1
            if initfc1 and decoded[:2] == bytes.fromhex('f0ac'):
                packet = decoded[2:8]
                if packet != fc_expected[len(fc_packets) % 3] or decoded[8:] != bytes(8):
                    errors.append(f'InitFC1 order/credit/CRC/padding mismatch at sample {i}: {decoded.hex()}')
                if fc_packets and not 1024 <= i - fc_packets[-1]['sample'] <= 1040:
                    errors.append(f'InitFC1 spacing mismatch at sample {i}')
                fc_packets.append(dict(sample=i, packet=packet.hex()))
                counts['initfc1'] += 1
            elif not packets and decoded not in (bytes(16), bytes(12) + bytes.fromhex('1f809000')):
                errors.append(f'non-idle TX Data Block at sample {i}: {decoded.hex()}')
            closed = decoded[-4:] == bytes.fromhex('1f809000')
            parity ^= sum(v.bit_count() for v in raw) & 1
            counts['data'] += 1
            first_data = i if first_data is None else first_data
            last_data = i
        elif h == 1 and raw[0] in (0x1e, 0x2d):
            if stream:
                errors.append(f'training inside stream at sample {i}')
            if raw[0] == 0x2d:
                if decoded[:14] != bytes.fromhex('2d0000200e000045454545454545'):
                    errors.append(f'TS2 fields/IDs mismatch at sample {i}: {decoded.hex()}')
                counts['ts2'] += 1
                ts2_sample = i
            else:
                counts['ts1'] += 1
        elif h == 1 and raw == bytes([0xe1]) + bytes([0x55]) * 15:
            if stream:
                errors.append(f'duplicate SDS at sample {i}')
            stream = True
            parity = 0
            closed = False
            sds_sample = i
            counts['sds'] += 1
        elif h == 1 and raw == bytes([0x66]) * 16:
            if stream and not closed:
                errors.append(f'EIOS without EDS at sample {i}')
            stream = False
            counts['eios'] += 1
        else:
            errors.append(f'unknown TX block at sample {i}: header={h} raw={raw.hex()}')
    if packets:
        offset = 0
        while offset < len(stream_bytes):
            if stream_bytes[offset] == 0:
                offset += 1
                continue
            if stream_bytes[offset:offset+4] == bytes.fromhex('1f809000'):
                offset += 4
                continue
            if stream_bytes[offset:offset+2] == bytes.fromhex('f0ac'):
                if offset+8 > len(stream_bytes): break
                payload = stream_bytes[offset+2:offset+8]
                crc = 0xffff
                for byte in payload[:4]:
                    for bit in range(8):
                        crc = (crc >> 1) ^ (0xd008 if (crc ^ (byte >> bit)) & 1 else 0)
                if ((~crc) & 0xffff) != int.from_bytes(payload[4:], 'little'):
                    errors.append(f'DLLP CRC mismatch at stream byte {offset}')
                decoded_packets.append(dict(kind='DLLP', bytes=payload.hex()))
                offset += 8
                continue
            if stream_bytes[offset] & 15 == 15:
                if offset+4 > len(stream_bytes): break
                token = int.from_bytes(stream_bytes[offset:offset+4], 'little')
                length = ((token >> 8) & 127) * 16 + ((token >> 4) & 15)
                fcrc = sum(((length & mask).bit_count() & 1) << bit
                           for bit, mask in enumerate((0x4d7, 0x6bc, 0x35e, 0x1af)))
                if length < 5 or fcrc != (token >> 20) & 15 or ((token >> 15) & 1) != ((length.bit_count()+fcrc.bit_count()) & 1):
                    errors.append(f'Invalid STP at stream byte {offset}')
                    break
                if offset+length*4 > len(stream_bytes): break
                frame = stream_bytes[offset:offset+length*4]
                sequence = ((token >> 16) & 15) * 256 + (token >> 24)
                if zlib.crc32(sequence.to_bytes(2, 'big')+frame[4:-4]) != int.from_bytes(frame[-4:], 'little'):
                    errors.append(f'TLP LCRC mismatch at stream byte {offset}')
                decoded_packets.append(dict(kind='TLP', sequence=sequence, bytes=frame.hex()))
                offset += length*4
                continue
            errors.append(f'Unknown Data Stream token at byte {offset}: {stream_bytes[offset]:02x}')
            break
    gaps = collections.Counter(b - a for a, b in zip(valid_cycles, valid_cycles[1:]))
    if any(gap not in (1, 2) for gap in gaps):
        errors.append(f'unexpected TX cadence gaps: {dict(gaps)}')
    if initfc1 and not fc_packets:
        errors.append("No InitFC1 packet captured")
    return dict(packets=decoded_packets, initfc1_packets=fc_packets, samples=len(rows), acquired=state is not None, blocks=dict(counts),
                nonzero_data_dwords=dict(nonidle), valid_cycle_gaps=dict(gaps),
                last_ts2_sample=ts2_sample, sds_sample=sds_sample,
                first_data_block_end=first_data, last_data_block_end=last_data,
                final_local_state_cycles=int(rows[-1][cycle_key], 16), errors=errors)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=Path)
    parser.add_argument('--data-column', required=True)
    parser.add_argument('--initfc1', action='store_true')
    parser.add_argument('--packets', action='store_true')
    args = parser.parse_args()
    result = analyze(args.csv, args.data_column, args.initfc1, args.packets)
    print(json.dumps(result, indent=2))
    if not result['acquired'] or result['errors']:
        raise SystemExit(1)

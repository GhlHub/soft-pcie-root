"""Experimental PCIe arithmetic and packet ownership, before PHY integration."""
from pathlib import Path
import random
import subprocess
import zlib

import pytest

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'ip/soft_pcie_root/rtl/pcie_soft'
BENCH = ROOT / 'tests/pcie_soft'


def run_bench(tmp_path, top, sources, vectors=None, parameters=()):
    executable = tmp_path / (top + '.vvp')
    cmd = ['iverilog', '-g2012', '-s', top, '-o', str(executable)]
    cmd += [f'-P{top}.{key}={value}' for key, value in parameters]
    cmd += [str(RTL / s) for s in sources] + [str(BENCH / (top + '.sv'))]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(['vvp', str(executable)] +
                            ([f'+VECTORS={vectors}'] if vectors else []),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS' in result.stdout, result.stdout
    print(result.stdout.strip())


def reverse(value, bits):
    return int(f'{value:0{bits}b}'[::-1], 2)


def crc16_packet(data):
    """GF(2) polynomial division, not the RTL's reflected bit recurrence."""
    remainder = 0xffff
    for octet in data:
        dividend = (remainder ^ (reverse(octet, 8) << 8)) << 8
        while dividend.bit_length() > 16:
            dividend ^= 0x1100b << (dividend.bit_length() - 17)
        remainder = dividend
    return reverse(remainder, 16) ^ 0xffff


@pytest.mark.parametrize('seed', [17, 8923])
def test_crc_stream(tmp_path, seed):
    rng = random.Random(seed)
    message = bytearray()
    rows = []
    # Includes reset with valid asserted, clear-and-data in the same cycle,
    # sparse enables, empty enables and paused packets.
    for cycle in range(4000):
        reset = int(cycle not in (0, 451, 452, 2198))
        clear = int(cycle % 53 == 1 or rng.randrange(60) == 0)
        valid = int(rng.randrange(5) != 0)
        data, keep = rng.randrange(65536), rng.randrange(4)
        if not reset or clear:
            message.clear()
        if reset and valid:
            message.extend((data >> (8*i)) & 255 for i in range(2) if keep & (1 << i))
        rows.append(f'{reset} {clear} {valid} {data:04x} {keep:x} '
                    f'{zlib.crc32(message):08x} {crc16_packet(message):04x}')
    path = tmp_path / 'crc.txt'
    path.write_text('\n'.join(rows) + '\n')
    run_bench(tmp_path, 'tb_crc', ['pcie_soft_crc.sv'], path)


def scramble_octets(state, data, ctrl, keep, scramble):
    """Byte-parallel polynomial expansion, independent of RTL bit stepping."""
    output = data
    for lane in range(2):
        if not keep & (1 << lane):
            continue
        octet = (data >> (8*lane)) & 255
        is_control = bool(ctrl & (1 << lane))
        if not is_control and scramble & (1 << lane):
            output ^= reverse(state >> 8, 8) << (8*lane)
        if is_control and octet == 0xbc:
            state = 0xffff
        elif not (is_control and octet == 0x1c):
            upper = state >> 8
            state = (((state & 255) << 8) | upper) ^ (upper << 3) ^ (upper << 4) ^ (upper << 5)
    return state, output


@pytest.mark.parametrize('seed', [41, 2053])
def test_scrambler_stalls_and_symbols(tmp_path, seed):
    rng = random.Random(seed)
    state, occupied, held = 0xffff, False, (0, 0, 0)
    pending, offered = None, False
    rows = []
    for cycle in range(6000):
        reset = int(cycle not in (0, 1517, 2999, 3000))
        ready = int(rng.randrange(4) != 0 and cycle % 173 not in range(15))
        if pending is None:
            data, ctrl = rng.randrange(65536), rng.randrange(4)
            if cycle % 7 == 0:
                data = (data & 0xff00) | 0xbc; ctrl |= 1
            if cycle % 11 == 0:
                data = (data & 255) | 0x1c00; ctrl |= 2
            if cycle % 13 == 0:
                data = 0xbc1c; ctrl = 3
            pending = (data, ctrl, rng.randrange(4), rng.randrange(4))
        data, ctrl, keep, scramble = pending
        # Once VALID is offered, hold it and its payload until acceptance.
        valid = int(offered or rng.randrange(6) != 0)
        offered = bool(valid)
        if not reset:
            state, occupied, pending, offered = 0xffff, False, None, False
        elif not occupied or ready:
            occupied = bool(valid)
            if valid:
                state, transformed = scramble_octets(state, data, ctrl, keep, scramble)
                held, pending, offered = (transformed, ctrl, keep), None, False
        rows.append(f'{reset} {valid} {ready} {data:04x} {ctrl:x} {keep:x} {scramble:x} '
                    f'{int(occupied)} {held[0]:04x} {held[1]:x} {held[2]:x} {state:04x}')
    path = tmp_path / 'scrambler.txt'
    path.write_text('\n'.join(rows) + '\n')
    run_bench(tmp_path, 'tb_scrambler', ['pcie_soft_scrambler.sv'], path)


def test_scrambler_roundtrip(tmp_path):
    run_bench(tmp_path, 'tb_scrambler_roundtrip', ['pcie_soft_scrambler.sv'])


@pytest.mark.parametrize('seed', [0x631ba421, 0x318a56cf])
@pytest.mark.parametrize('words', [8,64])
def test_replay_ownership(tmp_path, seed, words):
    run_bench(tmp_path, 'tb_replay', ['pcie_soft_replay.sv'], parameters=[('SEED', seed), ('WORDS', words)])


def test_vc0_flow_control(tmp_path):
    run_bench(tmp_path, 'tb_flow_control', ['pcie_soft_flow_control.sv'])


def test_root_requester(tmp_path):
    run_bench(tmp_path, 'tb_requester', ['pcie_soft_requester.sv'])


def test_link_training(tmp_path):
    run_bench(tmp_path, 'tb_link_training', ['pcie_soft_training.sv', 'pcie_soft_ltssm.sv'])


@pytest.mark.parametrize("gen2", [0, 1])
def test_integrated_root_link(tmp_path, gen2):
    sources = ['pcie_soft_link.sv', 'pcie_soft_ltssm.sv', 'pcie_soft_training.sv',
               'pcie_soft_scrambler.sv', 'pcie_soft_packet_tx.sv', 'pcie_soft_packet_rx.sv',
               'pcie_soft_requester.sv', 'pcie_soft_flow_control.sv',
               'pcie_soft_replay.sv', 'pcie_soft_ack_capture.sv']
    run_bench(tmp_path, 'tb_root_link', sources, parameters=[('GEN2_TEST',gen2)])


def test_ack_capture(tmp_path):
    run_bench(tmp_path, 'tb_ack_capture', ['pcie_soft_ack_capture.sv'])


def test_root_reset_sequence(tmp_path):
    sources = [p.name for p in sorted(RTL.glob('*.sv')) if p.name != 'pcie_soft_gth.sv']
    run_bench(tmp_path, 'tb_root_reset', sources)


def test_receive_capacity(tmp_path):
    run_bench(tmp_path, 'tb_receive_capacity', ['pcie_soft_packet_rx.sv'])


def test_gen2_training(tmp_path):
    run_bench(tmp_path, 'tb_gen2_training', ['pcie_soft_ltssm.sv'])


def test_rate_control(tmp_path):
    run_bench(tmp_path, 'tb_rate_control', ['pcie_soft_rate_control.sv'])


def test_tx_overlap(tmp_path):
    run_bench(tmp_path, "tb_tx_overlap", ["pcie_soft_replay.sv", "pcie_soft_packet_tx.sv"])


def test_packet_tx_banks(tmp_path):
    run_bench(tmp_path, 'tb_packet_tx_banks', ['pcie_soft_packet_tx.sv'])

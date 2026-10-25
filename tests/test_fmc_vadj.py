"""Exercise the compiled power policy with an independent PMBus model."""
import ctypes as C
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
READ = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_ubyte, C.POINTER(C.c_ubyte), C.c_int)
WRITE = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_ubyte, C.POINTER(C.c_ubyte), C.c_int)
DELAY = C.CFUNCTYPE(None, C.c_uint)


class IO(C.Structure):
    _fields_ = [('ctx', C.c_void_p), ('read', READ), ('write', WRITE), ('delay', DELAY)]


def fru(part=b'OP047', low=171, high=199):
    board = bytearray([1, 0, 0, 0, 0, 0])
    for field in (b'Opsero', b'FPGA Drive FMC', b'test', part, b'v1.0'):
        board += bytes([0xc0 | len(field)]) + field
    board += b'\xc1'
    board += bytes((-len(board) - 1) % 8) + b'\0'
    board[1] = len(board) // 8
    board[-1] = -sum(board) & 255
    data = bytes([0]) + b'\xb4\0' + low.to_bytes(2, 'little') + high.to_bytes(2, 'little') + bytes(6)
    record = bytearray([2, 0x82, 13, -sum(data) & 255, 0])
    record[-1] = -sum(record) & 255
    header = bytearray([1, 0, 0, 1, 0, 1 + len(board) // 8, 0, 0])
    header[-1] = -sum(header) & 255
    result = header + board + record + data
    return bytes(result + bytes(256 - len(result)))


@pytest.fixture(scope='module')
def policy(tmp_path_factory):
    output = tmp_path_factory.mktemp('fmc') / 'policy.so'
    subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC',
                    str(ROOT / 'software/linux/uboot/fmc_vadj.c'), '-o', str(output)], check=True)
    lib = C.CDLL(str(output))
    lib.fmc_fru_valid.argtypes = [C.c_char_p, C.c_size_t]
    lib.fmc_vadj_init.argtypes = [C.POINTER(IO), C.c_char_p, C.c_size_t, C.POINTER(C.c_uint)]
    return lib


class PMBus:
    def __init__(self, mode=0x18, fail=0, bad_page=False, live=False, output_mv=None, status=0):
        self.reg = {0: 0, 1: 0x80 if live else 0, 2: 0x1a, 0x10: 0, 0x20: mode,
                    0x21: round(1.8 * (1 << (32 - mode)))}
        self.fail, self.bad_page = fail, bad_page
        self.calls, self.writes, self.delays = 0, [], 0
        self.output_mv, self.status = output_mv, status
        self.callbacks = (READ(self.read), WRITE(self.write), DELAY(self.delay))
        self.io = IO(None, *self.callbacks)

    def failed(self):
        self.calls += 1
        return self.calls == self.fail

    def read(self, _, reg, data, length):
        if self.failed():
            return -1
        value = self.reg.get(reg, 0)
        if reg == 0x8b:
            mv = self.output_mv if self.output_mv is not None else (1800 if self.reg[1] == 0x80 else 150)
            value = round(mv / 1000 * (1 << (32 - self.reg[0x20])))
        if reg == 0x79:
            value = self.status
        for i in range(length):
            data[i] = value >> (8 * i) & 255
        return 0

    def write(self, _, reg, data, length):
        if self.failed():
            return -1
        value = sum(data[i] << (8 * i) for i in range(length))
        self.writes.append((self.reg[0], reg, value))
        self.reg[reg] = 0 if reg == 0 and self.bad_page else value
        return 0

    def delay(self, ms):
        self.delays += ms

    def run(self, policy, data=None):
        data = fru() if data is None else data
        mv = C.c_uint()
        result = policy.fmc_vadj_init(C.byref(self.io), data, len(data), C.byref(mv))
        return result, mv.value


def test_fru_rejects_corruption_and_incompatible_voltage(policy):
    data = fru()
    assert policy.fmc_fru_valid(data, len(data)) == 0
    end = data[5] * 8 + 18
    for i in range(end):
        bad = bytearray(data)
        bad[i] ^= 1
        assert policy.fmc_fru_valid(bytes(bad), len(bad)) != 0, i
    for size in range(end):
        assert policy.fmc_fru_valid(data[:size], size) != 0
    for bad in (fru(part=b'OP063'), fru(low=181), fru(high=179), fru(low=200, high=190)):
        bus = PMBus()
        assert bus.run(policy, bad)[0] != 0
        assert bus.calls == 0


def test_enable_and_warm_boot(policy):
    for mode in (0x18, 0x17, 0x14):
        bus = PMBus(mode=mode)
        result, mv = bus.run(policy)
        assert result == 0 and 1790 <= mv <= 1810
        assert bus.writes[-1] == (3, 1, 0x80)
        assert all(page == 3 for page, reg, value in bus.writes if reg != 0)
        assert all(reg in (0, 1, 0x21, 0x24, 0x40, 0x42, 0x43, 0x44, 0x5e, 0x5f)
                   for _, reg, _ in bus.writes)
        assert bus.reg[0x44] < bus.reg[0x43] < bus.reg[0x21] < bus.reg[0x42] < bus.reg[0x40]
        bus.writes.clear()
        assert bus.run(policy)[0] == 0
        assert bus.writes == [(3, 0, 3)]  # Never power-cycle on warm boot.


def test_every_transfer_failure_and_wrong_page(policy):
    normal = PMBus()
    assert normal.run(policy)[0] == 0
    for fail in range(1, normal.calls + 1):
        bus = PMBus(fail=fail)
        assert bus.run(policy)[0] != 0, fail
        assert bus.reg[1] == 0, fail
        assert all(page == 3 for page, reg, _ in bus.writes if reg != 0)
    bus = PMBus(bad_page=True)
    assert bus.run(policy)[0] != 0
    assert bus.writes == [(0, 0, 3)]


def test_refuses_unsafe_initial_state_and_power_faults(policy):
    for reg, value in ((0x20, 0x13), (2, 0x17), (0x10, 0x80), (1, 0x98)):
        bus = PMBus()
        bus.reg[reg] = value
        assert bus.run(policy)[0] != 0
        assert bus.writes == [(0, 0, 3)]
    bus = PMBus(live=True, output_mv=2500)
    assert bus.run(policy)[0] != 0
    assert bus.writes == [(0, 0, 3)]
    # Fault injection after enable, while preserving a valid initial low rail.
    for fault in ('high', 'low', 'status'):
        bus = PMBus()
        def delay(ms, bus=bus, fault=fault):
            bus.delays += ms
            bus.output_mv = 2100 if fault == 'high' else (1000 if fault == 'low' else 1800)
            bus.status = 0x8000 if fault == 'status' else 0
        bus.callbacks = (bus.callbacks[0], bus.callbacks[1], DELAY(delay))
        bus.io = IO(None, *bus.callbacks)
        assert bus.run(policy)[0] != 0
        assert bus.reg[1] == 0
        assert bus.delays <= 1000

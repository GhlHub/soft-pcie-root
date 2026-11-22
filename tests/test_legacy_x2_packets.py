# SPDX-License-Identifier: Apache-2.0
"""Gen1/Gen2 packet framing and ownership at four striped symbols per beat."""
import zlib

import pytest

from test_gen12_coverage import drain, tlp_frame
from test_multilane import RTL, simulate
from test_pcie_soft import crc16_packet, run_bench


def pack_symbols(symbols):
    data = sum((symbol & 255) << (8 * index) for index, symbol in enumerate(symbols))
    control = sum((symbol >> 8) << index for index, symbol in enumerate(symbols))
    return data, control


def beats(symbols):
    padded = symbols + [0] * (-len(symbols) % 4)
    return [pack_symbols(padded[i:i + 4]) for i in range(0, len(padded), 4)]


def dllp_frame(body):
    octets = body.to_bytes(4, 'little')
    return [0x15c, *octets, *crc16_packet(octets).to_bytes(2, 'little'), 0x1fd]


@pytest.mark.parametrize('position', range(4))
@pytest.mark.parametrize('pipelined', [0, 1], ids=['legacy', 'pipelined'])
def test_legacy_x2_contiguous_frames_at_capacity(tmp_path, position, pipelined):
    first = [0x01000040, 0x11223344, 0x55667788, 0xdeadbeef]
    second = [0x01000040, 0xa1b2c3d4, 0xe5f65768, 0x9ab0cd1e]
    retry = [0x01000040, 0x15243241, 0x20314859, 0x77889900]
    dllp = 0xaf555540
    # At offset two, the next STP shares a beat with the preceding END.
    # The second commit consumes the final slot. Its last DWORD must survive
    # the third candidate's admission failure.
    stream = [0] * position + dllp_frame(dllp)
    stream += tlp_frame(0, first) + tlp_frame(1, second) + tlp_frame(2, retry)
    rows = [(0, data, control, 0, 0) for data, control in beats(stream)]
    rows += [(4, 1, dllp, 0, 0), (5, 2, 1, 1, 0), *drain(first), *drain(second), (2, 0, 0, 0, 0)]
    rows += [(0, data, control, 0, 0) for data, control in beats(tlp_frame(2, retry))]
    rows += [(1, 4, 0, 0, 0), (5, 3, 1, 2, 0), *drain(retry), (2, 0, 0, 0, 0)]
    vectors = tmp_path / 'rx.txt'
    vectors.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n' for op, a, b, c, d in rows))
    receiver = 'pcie_legacy_x2_packet_rx.sv' if pipelined else 'pcie_soft_packet_rx.sv'
    run_bench(tmp_path, 'tb_rx_fault_matrix', [receiver], vectors,
              parameters=[('SYMBOLS', 4), ('DEPTH', 2), ('PIPELINED', pipelined)])


@pytest.mark.parametrize('pipelined', [0, 1], ids=['legacy', 'pipelined'])
@pytest.mark.parametrize('progress', [4, 12])
def test_legacy_x2_abort_keeps_committed_packet_and_sequence(tmp_path, pipelined, progress):
    owned = [0x01000040, 0x11223344, 0x55667788, 0xdeadbeef]
    retry = [0x01000040, 0x15243241, 0x20314859, 0x77889900]
    good_retry = tlp_frame(1, retry)
    rows = [(0, data, control, 0, 0)
            for data, control in beats([0, 0] + tlp_frame(0, owned) + good_retry[:progress - 2])]
    rows += [(6, 0, 0, 0, 0)]
    rows += [(0, data, control, 0, 0) for data, control in beats(good_retry[progress - 2:])]
    rows += [(5, 1, 0, 0, 0), *drain(owned), (2, 0, 0, 0, 0)]
    rows += [(0, data, control, 0, 0) for data, control in beats(good_retry)]
    rows += [(1, 4, 0, 0, 0), (5, 2, 0, 1, 0), *drain(retry), (2, 0, 0, 0, 0)]
    vectors = tmp_path / 'rx.txt'
    vectors.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n' for op, a, b, c, d in rows))
    receiver = 'pcie_legacy_x2_packet_rx.sv' if pipelined else 'pcie_soft_packet_rx.sv'
    run_bench(tmp_path, 'tb_rx_fault_matrix', [receiver], vectors,
              parameters=[('SYMBOLS', 4), ('PIPELINED', pipelined)])


@pytest.mark.parametrize('remainder', [1, 2, 3])
def test_legacy_x2_nullified_short_word(tmp_path, remainder):
    body = bytes(range(10 + remainder))
    inverted = (zlib.crc32(body) ^ 0xffffffff).to_bytes(4, 'little')
    frame = [0x1fb, *body, *inverted, 0x1fe]
    words = [0x01000040, 0x15243241, 0x20314859, 0x77889900]
    rows = [(0, data, control, 0, 0) for data, control in beats(frame + tlp_frame(0, words))]
    rows += [(1, 4, 0, 0, 0), (5, 1, 0, 0, 0), *drain(words), (2, 0, 0, 0, 0)]
    vectors = tmp_path / 'rx.txt'
    vectors.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n' for op, a, b, c, d in rows))
    run_bench(tmp_path, 'tb_rx_fault_matrix', ['pcie_legacy_x2_packet_rx.sv'], vectors,
              parameters=[('SYMBOLS', 4), ('PIPELINED', 1)])


def test_legacy_x2_pipelined_continuous_readout(tmp_path):
    packets = [[0x20000040, 0x10203040, 0x55667788] + list(range(base, base + 32))
               for base in (0x1000, 0x2000)]
    stream = [0, 0] + tlp_frame(0, packets[0]) + tlp_frame(1, packets[1])
    stimulus = '\n'.join(f"put(32'h{data:08x}, 4'h{control:x});" for data, control in beats(stream))
    expected = '\n'.join(f"expected[{i}] = 32'h{word:08x};"
                         for i, word in enumerate(packets[0] + packets[1]))
    simulate(tmp_path, f'''
module tb;
reg clk = 0; always #2 clk = ~clk;
reg rst_n = 0, valid = 0, ready = 0;
reg [31:0] symbols = 0;
reg [3:0] control = 0;
wire [31:0] data;
wire tv, last, response, nak, error;
wire [1:0] packet_class;
wire [8:0] credits;
integer committed = 0;
reg [31:0] expected[0:69];
pcie_legacy_x2_packet_rx #(.DEPTH(2)) dut(
    clk, rst_n, 1'b0, symbols, control, valid, 1'b0, data, tv, last, ready,
    packet_class, credits, response, nak, , , , error, 1'b0);
always @(posedge clk) if (rst_n) begin
    if (nak || error) $fatal(1, "Unexpected rejection");
    if (response) committed = committed + 1;
end
task put(input [31:0] data_word, input [3:0] control_word);
    @(negedge clk); valid = 1; symbols = data_word; control = control_word;
endtask
initial begin
    {expected}
    repeat (3) @(negedge clk);
    rst_n = 1;
    {stimulus}
    @(negedge clk); valid = 0;
    wait (committed == 2);
    @(negedge clk); ready = 1;
    for (integer word_index = 0; word_index < 70; word_index = word_index + 1) begin
        @(posedge clk);
        if (!tv || data !== expected[word_index] || last !== (word_index % 35 == 34) ||
            packet_class != 0 || credits != 8)
            $fatal(1, "Incorrect readout or bubble at DWORD %0d", word_index);
    end
    @(negedge clk);
    if (tv) $fatal(1, "Extra packet data");
    $display("PASS"); $finish;
end
initial begin #8000; $fatal(1, "timeout"); end
endmodule
''', [RTL / 'pcie_legacy_x2_packet_rx.sv'])


@pytest.mark.parametrize('word_count', [3, 4, 35, 36, 64])
def test_legacy_x2_transmit_matches_wire_frames(tmp_path, word_count):
    words = [(0x84cafe0d + i * 0x1020409) & 0xffffffff for i in range(word_count)]
    body = 0xaabbcc40
    sequence = 0x9e2
    expected = beats(dllp_frame(body) + tlp_frame(sequence, words))
    init = '\n'.join(f"tests[{i}] = 36'h{control:x}{data:08x};"
                     for i, (data, control) in enumerate(expected))
    stimulus = '\n'.join(f"put(32'h{word:08x}, 1'b{int(i == len(words) - 1)});"
                         for i, word in enumerate(words))
    simulate(tmp_path, f'''
module tb;
reg clk = 0; always #4 clk = ~clk;
reg rst_n = 0, hold = 0, valid = 0, last = 0, dllp = 0;
reg [31:0] data = 0;
wire ready, dllp_ready, transmitting, done, idle, overflow;
wire [31:0] symbols;
wire [3:0] control;
integer beat = 0, completions = 0;
reg [35:0] tests [0:{len(expected) - 1}];
pcie_soft_packet_tx #(.SYMBOLS(4)) dut(
    clk, rst_n, hold, data, valid, last, ready, 12'h{sequence:x},
    dllp, dllp_ready, 32'h{body:x}, symbols, control, done, idle, transmitting, overflow);
task put(input [31:0] word, input final_word);
    @(negedge clk); data = word; last = final_word; valid = 1;
    do @(posedge clk); while (!ready);
    @(negedge clk); valid = 0;
endtask
always @(posedge clk) if (rst_n) begin
    if (overflow) $fatal(1, "serializer overflow");
    if (transmitting) begin
        if (beat >= {len(expected)} || {{control, symbols}} !== tests[beat])
            $fatal(1, "wrong emitted symbols at beat %0d", beat);
        if (done !== (beat == {len(expected) - 1}))
            $fatal(1, "wrong wire retirement at beat %0d", beat);
        beat = beat + 1;
    end
    if (done) completions = completions + 1;
end
initial begin
    {init}
    repeat (3) @(negedge clk);
    rst_n = 1;
    dllp = 1;
    do @(posedge clk); while (!dllp_ready);
    @(negedge clk); dllp = 0;
    {stimulus}
    wait (idle && beat == {len(expected)});
    if (completions != 1) $fatal(1, "wire did not retire exactly once");
    $display("PASS"); $finish;
end
initial begin #50000; $fatal(1, "timeout"); end
endmodule
''', [RTL / 'pcie_soft_packet_tx.sv'])

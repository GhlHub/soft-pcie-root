# SPDX-License-Identifier: Apache-2.0
"""Independent striped 128b/130b PHY peer for the bonded receiver."""
from itertools import zip_longest

import pytest

from test_gen3_packet_peer import tlp
from test_multilane import GEN3, RTL, simulate
from test_x2_datapath import body


EDS = bytes.fromhex('1f809000')
EIEOS = bytes.fromhex('00ff') * 8
SDS = bytes.fromhex('e1') + bytes.fromhex('55') * 15
EIOS = bytes.fromhex('66') * 16


class Lane:
    def __init__(self, index, delay):
        self.seed = (0x1dbfbc, 0x0607bb)[index]
        self.lfsr = self.seed
        self.parity = 0
        self.rows = [(0, 0, 0, 0)] * delay

    def word(self, encoded, start, header):
        self.rows.append((int.from_bytes(encoded, 'little'), 1, start, header))

    def block(self, data, header=1):
        assert len(data) == 16
        encoded = bytearray()
        for octet in data:
            mask = 0
            for bit in range(8):
                lead = self.lfsr >> 22
                mask |= lead << bit
                self.lfsr = ((self.lfsr << 1) & 0x7fffff) ^ (0x210125 if lead else 0)
            encoded.append(octet ^ mask if header == 2 else octet)
        for offset in range(0, len(encoded), 4):
            self.word(encoded[offset:offset + 4], int(offset == 0), header)
        if header == 2:
            self.parity ^= sum(octet.bit_count() for octet in encoded) & 1
        if data == EIEOS and header == 1:
            self.lfsr = self.seed
        if data == SDS and header == 1:
            self.parity = 0

    def skip(self, words):
        tail = bytes([0xe1, (self.lfsr >> 16) | (self.parity << 7),
                      (self.lfsr >> 8) & 0xff, self.lfsr & 0xff])
        for index in range(words - 1):
            self.word(b'\xaa' * 4, int(index == 0), 1)
        self.word(tail, 0, 1)
        self.parity = 0


def drive(lanes):
    steps = []
    for left, right in zip_longest(lanes[0].rows, lanes[1].rows, fillvalue=(0, 0, 0, 0)):
        packed = (left[0] | right[0] << 32, left[1] | right[1] << 1,
                  left[2] | right[2] << 1, left[3] | right[3] << 2)
        steps.append(f"put(64'h{packed[0]:016x}, 2'b{packed[1]:02b}, 2'b{packed[2]:02b}, 4'h{packed[3]:x});")
    return '\n'.join(steps)


@pytest.mark.parametrize('skew,skip_words,end_idle', [(0, (4, 4), True), (5, (2, 6), False),
                                                    (6, (6, 2), True)])
@pytest.mark.parametrize('corrupt_first', [False, True])
def test_bonded_receive_packets(tmp_path, skew, skip_words, end_idle, corrupt_first):
    lanes = [Lane(0, 0), Lane(1, skew)]
    packets = [body(1, marker) for marker in (0x1234, 0x4321)]
    first = bytearray(tlp(0, packets[0]))
    if corrupt_first:
        first[-1] ^= 0x80
    frames = [bytes(4) + first + EDS, bytes(4) + tlp(int(not corrupt_first), packets[1]) + EDS]
    for index, lane in enumerate(lanes):
        lane.block(EIEOS)
        lane.block(SDS)
        lane.block(frames[0][index::2], 2)
        lane.skip(skip_words[index])
        lane.block(frames[1][index::2], 2)
        lane.block(EIOS if end_idle else EIEOS)
    words = [int.from_bytes(packet[offset:offset + 8], 'little')
             for packet in packets[int(corrupt_first):] for offset in (0, 8)]
    scoreboard = '\n'.join(f"expected[{index}] = 64'h{word:016x};" for index, word in enumerate(words))
    simulate(tmp_path, bench(drive(lanes), f'''
    {scoreboard}
    repeat (45) @(negedge clk);
    if (fault || stream || starts != 1 || ends != 1 || closed_idle !== 1'b{int(end_idle)})
        $fatal(1, "incorrect stream progression start=%0d end=%0d fault=%b", starts, ends, fault);
    if (acks != {len(words)//2} || naks != {int(corrupt_first)} || errors != {int(corrupt_first)})
        $fatal(1, "missing CRC/ACK events ack/nak/error=%0d/%0d/%0d", acks, naks, errors);
    abort_rx = 1;
    @(negedge clk); abort_rx = 0; ready = 1;
    wait (received == {len(words)});
    repeat (4) @(negedge clk);
    if (tlp_valid) $fatal(1,"extra packet");
''', len(words)), sources())


@pytest.mark.parametrize('fault_kind', ['missing-eds', 'data-after-eds', 'different-os', 'missing-lane'])
def test_bonded_receive_rejects_block_transitions(tmp_path, fault_kind):
    lanes = [Lane(0, 0), Lane(1, 3)]
    first = bytes(4) + tlp(0, body(1, 0x7001)) + (bytes(4) if fault_kind == 'missing-eds' else EDS)
    forbidden = bytes(4) + tlp(1, body(1, 0x9002)) + EDS
    for index, lane in enumerate(lanes):
        lane.block(EIEOS)
        lane.block(SDS)
        lane.block(first[index::2], 2)
        if fault_kind == 'missing-lane':
            if index == 0:
                lane.block(EIOS)
            continue
        if fault_kind == 'different-os' and index == 1:
            lane.block(EIOS)
            continue
        if fault_kind != 'data-after-eds':
            lane.skip(4)
        lane.block(forbidden[index::2], 2)
        lane.block(EIOS)
    simulate(tmp_path, bench(drive(lanes), '''
    repeat (50) @(negedge clk);
    if (!fault || stream || ends != 0 || starts != 1 || acks > 1 || naks != 0)
        $fatal(1, "bad boundary escaped: fault=%b ends=%d acks=%d naks=%d", fault, ends, acks, naks);
    abort_rx = 1;
    @(negedge clk); abort_rx = 0;
    repeat (2) @(negedge clk);
    if (fault || stream) $fatal(1, "fault did not clear on Recovery entry");
''', 2), sources())


def sources():
    return [GEN3 / f'{name}.sv' for name in ('gen3_x2_receive', 'gen3_native_rx', 'gen3_data_rx_x2')] + [
        RTL / f'{name}.sv' for name in ('pcie_lane_deskew', 'pcie_lane_stripe')]


def bench(stimulus, checks, word_count):
    return f'''module tb;
reg clk=0; always #2 clk=~clk;
reg reset=1, abort_rx=0, ready=0;
reg [63:0] data=0;
reg [1:0] valid=0, start=0;
reg [3:0] header=0;
wire stream,start_evt,end_evt,closed_idle,fault,tlp_valid,tlp_last,ack,nak,packet_error;
wire [63:0] payload;
wire [1:0] words,packet_class;
wire [8:0] credits;
wire [11:0] seq;
integer acks=0,naks=0,errors=0,starts=0,ends=0,received=0;
reg [63:0] expected[0:{word_count-1}];
gen3_x2_receive dut(.clk(clk),.reset_i(reset),.enable_i(1'b1),.abort_i(abort_rx),
 .lane_data_i(data),.lane_valid_i(valid),.lane_start_i(start),.lane_header_i(header),
 .stream_o(stream),.stream_start_o(start_evt),.stream_end_o(end_evt),
 .end_electrical_idle_o(closed_idle),.framing_fault_o(fault),
 .tlp_data_o(payload),.tlp_words_o(words),.tlp_valid_o(tlp_valid),.tlp_last_o(tlp_last),
 .tlp_ready_i(ready),.tlp_class_o(packet_class),.tlp_credits_o(credits),
 .response_o(ack),.nak_o(nak),.response_sequence_o(seq),.packet_error_o(packet_error));
always @(posedge clk) if (!reset) begin
    if (ack) begin
        if (nak) begin
            if (seq != 12'hfff) $fatal(1,"NAK sequence drift");
            naks <= naks + 1;
        end else begin
            if (seq != 12'(acks)) $fatal(1,"ACK sequence drift");
            acks <= acks + 1;
        end
    end
    if (packet_error) errors <= errors + 1;
    if (start_evt) starts <= starts + 1;
    if (end_evt) ends <= ends + 1;
    if (tlp_valid && ready) begin
        if (received >= {word_count} || payload !== expected[received] || words != 2 ||
            tlp_last !== received[0] || packet_class != 0 || credits != 1)
            $fatal(1,"bad bonded payload/ownership beat %d",received);
        received <= received+1;
    end
end
task put(input [63:0] d, input [1:0] v,s, input [3:0] h);
    @(negedge clk); data=d; valid=v; start=s; header=h;
endtask
initial begin
    repeat (3) @(negedge clk); reset=0;
    {stimulus}
    @(negedge clk); valid=0;
    {checks}
    $display("PASS bonded RX"); $finish;
end
initial begin #25000; $fatal(1,"watchdog"); end
endmodule'''

# SPDX-License-Identifier: Apache-2.0
"""Executable RTL tests for x2 building blocks; not an integrated x2 link test."""
from pathlib import Path
import random
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'ip/soft_pcie_root/rtl/pcie_soft'
GEN3 = ROOT / 'experiments/gen3'


def simulate(tmp_path, source, files):
    bench = tmp_path / 'tb.sv'
    bench.write_text(source)
    exe = tmp_path / 'sim'
    result = subprocess.run(['iverilog', '-g2012', '-s', 'tb', '-o', str(exe),
                             str(bench), *map(str, files)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    result = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS' in result.stdout


@pytest.mark.parametrize('lanes', [1, 2])
@pytest.mark.parametrize('symbols', [2, 4, 16])
def test_byte_striping(tmp_path, lanes, symbols):
    rng = random.Random(4242)
    width = lanes * symbols * 8
    checks = []
    for _ in range(150):
        # Check both directions against a byte-array oracle, not just roundtrip.
        data = rng.randbytes(lanes * symbols)
        striped = b''.join(data[lane::lanes] for lane in range(lanes))
        stream = int.from_bytes(data, 'little')
        lane_words = int.from_bytes(striped, 'little')
        checks.append(f"s={width}'h{stream:x}; li={width}'h{lane_words:x}; #1; "
                      f"if(lo!=={width}'h{lane_words:x} || o!==s) $fatal(1,\"stripe\");")
    simulate(tmp_path, f'''module tb;
reg [{width-1}:0] s,li; wire [{width-1}:0] lo,o;
pcie_lane_stripe #(.LANES({lanes}),.SYMBOLS({symbols})) dut(s,lo,li,o);
initial begin {' '.join(checks)} $display("PASS"); $finish; end
endmodule''', [RTL / 'pcie_lane_stripe.sv'])


@pytest.mark.parametrize('leading', [0, 1])
@pytest.mark.parametrize('skew', [0, 1, 3, 6])
def test_deskew_order_and_stalls(tmp_path, leading, skew):
    simulate(tmp_path, f'''module tb;
reg clk=0; always #2 clk=~clk;
reg rst=1,abort_i=0,ready=0; reg [1:0] v=0,a=0;
reg [63:0] data=0; reg [7:0] tag=0;
wire ov,fault,aligned; wire [63:0] out; wire [3:0] ot;
integer c,got=0,n0,n1;
pcie_lane_deskew #(.DEPTH(16),.ALIGN_CYCLES(24)) dut(
 clk,rst,abort_i,v,a,data,tag,ov,ready,out,ot,fault,aligned);
always @(posedge clk) if(!rst) begin
 if(fault) $fatal(1,"unexpected fault");
 if(ov && ready) begin
  if(out !== {{32'(1000+got),32'(got)}} || ot !== 4'(got%16))
   $fatal(1,"deskew order at %0d got %h tag %h",got,out,ot);
  got=got+1;
 end
end
initial begin
 @(negedge clk); rst=0;
 // Unaligned garbage must not be published or consume FIFO capacity.
 v=3;data='1;repeat(20) @(negedge clk);v=0;
 for(c=0;c<160;c=c+1) begin
  n0=c-({leading}==0?0:{skew}); n1=c-({leading}==1?0:{skew});
  v=0;a=0;
  if(n0>=0 && n0<100) begin v[0]=1;a[0]=(n0==0);data[31:0]=n0;tag[3:0]=4'(n0%16);end
  if(n1>=0 && n1<100) begin v[1]=1;a[1]=(n1==0);data[63:32]=1000+n1;tag[7:4]=4'(n1%16);end
  ready=!(c>=30 && c<34); @(negedge clk);
 end
 if(got!=100) $fatal(1,"lost records %0d",got);
 $display("PASS");$finish;
end
endmodule''', [RTL / 'pcie_lane_deskew.sv'])


@pytest.mark.parametrize('case', ['overflow', 'missing_lane', 'tag', 'repeated_align'])
def test_deskew_quarantine_and_reacquire(tmp_path, case):
    stimulus = {
        'overflow': 'ready=0;v=3;repeat(5) @(negedge clk);v=0;',
        'missing_lane': 'v=0;repeat(10) @(negedge clk);',
        'tag': "v=3;tag=8'h21;@(negedge clk);v=0;repeat(3) @(negedge clk);",
        'repeated_align': 'v=3;a=3;@(negedge clk);v=0;a=0;',
    }[case]
    simulate(tmp_path, f'''module tb;
reg clk=0;always #2 clk=~clk;
reg rst=1,abort_i=0,ready=1;reg [1:0] v=0,a=0;reg [63:0] data=0;reg[7:0] tag=0;
wire ov,fault,aligned;wire[63:0] out;wire[3:0] ot;
pcie_lane_deskew #(.DEPTH(4),.ALIGN_CYCLES(6)) dut(
 clk,rst,abort_i,v,a,data,tag,ov,ready,out,ot,fault,aligned);
initial begin
 @(negedge clk);rst=0;v={'1' if case=='missing_lane' else '3'};a=v;
 @(negedge clk);v=0;a=0;
 {stimulus}
 if(!fault || ov || aligned) $fatal(1,"missing quarantine");
 v=3;a=0;repeat(5) begin @(negedge clk);if(!fault || ov) $fatal(1,"fault not sticky");end
 abort_i=1;v=0;@(negedge clk);abort_i=0;
 if(fault || ov) $fatal(1,"candidate abort failed");
 v=3;a=3;data=64'h123456789abcdef0;tag=8'h55;ready=0;
 @(negedge clk);v=0;a=0;#1;
 if(!ov || out!==64'h123456789abcdef0 || ot!=5) $fatal(1,"reacquire failed");
 repeat(4) begin @(negedge clk);if(!ov || out!==64'h123456789abcdef0) $fatal(1,"stall");end
 ready=1;@(negedge clk);if(ov) $fatal(1,"double delivery");
 $display("PASS");$finish;
end
endmodule''', [RTL / 'pcie_lane_deskew.sv'])


def scramble_word(state, word, advance, xor):
    # Explicit bit-vector polynomial oracle rather than RTL shift/XOR expression.
    result = word
    for byte in range(4):
        bits = [(state >> bit) & 1 for bit in range(23)]
        for bit in range(8):
            feedback = bits[22]
            if xor & (1 << byte):
                result ^= feedback << (byte*8 + bit)
            bits = [0] + bits[:-1]
            for tap in (0, 2, 5, 8, 16, 21):
                bits[tap] ^= feedback
        if advance & (1 << byte):
            state = sum(value << bit for bit, value in enumerate(bits))
    return state, result


@pytest.mark.parametrize('lane,seed', [(0, 0x1dbfbc), (1, 0x0607bb)])
def test_lane_scrambler(tmp_path, lane, seed):
    rng = random.Random(392)
    checks = []
    state = seed
    for i in range(200):
        data, advance, xor = rng.getrandbits(32), rng.randrange(16), rng.randrange(16)
        state, expected = scramble_word(state, data, advance, xor)
        reseed = i % 17 == 0
        if reseed:
            state = seed
        checks.append(f'''d=32'h{data:x}; adv=4'd{advance}; x=4'd{xor};rs=1'b{int(reseed)};v=1;
 @(negedge clk);if(!ov || out!==32'h{expected:x} || st!==23'h{state:x}) $fatal(1,"oracle {i}");
 ready=0;d=~d;rs=1;repeat(3) begin @(negedge clk);
 if(ir || !ov || out!==32'h{expected:x} || st!==23'h{state:x}) $fatal(1,"stall {i}");end
 ready=1;v=0;@(negedge clk);''')
    simulate(tmp_path, f'''module tb;
reg clk=0;always #2 clk=~clk;
reg rst=1,v=0,ready=1,rs=0;reg[31:0] d=0;reg[3:0] adv=0,x=0;
wire ir,ov;wire[31:0]out;wire[22:0]st;
gen3_scrambler #(.LANE_ID({lane})) dut(clk,rst,d,adv,x,rs,v,ir,out,ov,ready,st);
initial begin @(negedge clk);rst=0;
{' '.join(checks)}
$display("PASS");$finish;end
endmodule''', [GEN3 / 'gen3_scrambler.sv'])


@pytest.mark.parametrize('lane', [0, 1])
def test_lane_training_peer(tmp_path, lane):
    # Check the transmitted lane number/seed with both real receive decoders.
    simulate(tmp_path, f'''module tb;
reg clk=0;always #2 clk=~clk;reg rst=1;
wire[31:0] data;wire valid,start;wire[1:0] hdr;
wire good,native_good,wrong_good,err,nerr;wire[127:0] ts;
integer seen=0,nseen=0;
gen3_training_tx #(.LANE_ID({lane})) tx(.clk(clk),.reset_i(rst),.enable_i(1'b1),.stop_i(1'b0),
 .ec_i(2'b0),.preset_i(4'd4),.first_i(6'd0),.second_i(6'd40),.post_i(6'd0),
 .eq_fields_i(32'b0),.reset_interval_i(1'b0),.data_o(data),.valid_o(valid),.start_o(start),.header_o(hdr));
gen3_training_rx #(.LANE_ID({lane})) rx(.clk(clk),.reset_i(rst),.enable_i(1'b1),
 .data_i(data),.valid_i(valid),.start_i(start),.header_i(hdr),.ts1_valid_o(good),.error_o(err),.last_ts_o(ts));
gen3_native_rx #(.LANE_ID({lane})) nrx(.clk(clk),.reset_i(rst),.enable_i(1'b1),
 .data_i(data),.valid_i(valid),.start_i(start),.header_i(hdr),.eds_i(1'b0),.parser_error_i(1'b0),
 .ts1_valid_o(native_good),.error_o(nerr));
gen3_training_rx #(.LANE_ID({1-lane})) wrong(.clk(clk),.reset_i(rst),.enable_i(1'b1),
 .data_i(data),.valid_i(valid),.start_i(start),.header_i(hdr),.ts1_valid_o(wrong_good));
always @(negedge clk) if(!rst) begin
 if(err || nerr || wrong_good) $fatal(1,"training lane identity");
 if(good) begin seen=seen+1;if(ts[23:8]!==16'h{lane<<8:04x}) $fatal(1,"lane field");end
 if(native_good) nseen=nseen+1;
end
initial begin repeat(3) @(negedge clk);rst=0;repeat(3000) @(negedge clk);
 if(seen<200 || nseen<200) $fatal(1,"missing training %0d %0d",seen,nseen);
 $display("PASS");$finish;end
endmodule''', [GEN3 / (name + '.sv') for name in
               ['gen3_training_tx', 'gen3_training_rx', 'gen3_native_rx']])


@pytest.mark.parametrize('phase', [-1, 0, 1, 63, 64])
def test_lane_one_recovery_wire(tmp_path, phase):
    result = subprocess.run(
        ['python3', str(GEN3 / 'check_recovery_tx.py'), '--lane', '1',
         '--initfc1', '--stop-phase', str(phase)], cwd=ROOT,
        capture_output=True, text=True, timeout=90,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS: independent Recovery TX oracle' in result.stdout


@pytest.mark.parametrize('module', [
    'gen3_scrambler', 'gen3_training_tx', 'gen3_training_rx',
    'gen3_native_rx', 'gen3_recovery_tx',
])
def test_lane_one_lint(module):
    result = subprocess.run(
        ['verilator', '--lint-only', '-Wall', '--top-module', module,
         '-GLANE_ID=1', str(GEN3 / (module + '.sv'))],
        capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_deskew_full_pop_push_and_x1(tmp_path):
    simulate(tmp_path, '''module tb;
reg clk=0;always #2 clk=~clk;reg rst=1,abort_i=0,ready=0,v=0,a=0;
reg[31:0] data=0;reg[3:0] tag=0;wire ov,fault,aligned;wire[31:0] out;wire[3:0] ot;
integer i,got=0;
pcie_lane_deskew #(.LANES(1),.DEPTH(4)) dut(
 clk,rst,abort_i,v,a,data,tag,ov,ready,out,ot,fault,aligned);
always @(posedge clk) if(!rst && ov && ready) begin
 if(out!==32'(got) || ot!==4'(got%16)) $fatal(1,"full FIFO order");got=got+1;
end
initial begin
 @(negedge clk);rst=0;
 for(i=0;i<4;i=i+1) begin v=1;a=(i==0);data=i;tag=4'(i);@(negedge clk);end
 a=0;ready=1;
 for(i=4;i<100;i=i+1) begin data=i;tag=4'(i%16);@(negedge clk);if(fault) $fatal(1,"full simultaneous pop/push");end
 v=0;repeat(6) @(negedge clk);
 if(got!=100 || ov || fault) $fatal(1,"drain");
 $display("PASS");$finish;end
endmodule''', [RTL / 'pcie_lane_deskew.sv'])


@pytest.mark.parametrize('lane', [0, 1])
def test_recovery_to_native_lane_stream(tmp_path, lane):
    simulate(tmp_path, f'''module tb;
reg clk=0;always #2 clk=~clk;reg rst=1,ts2=0,stream=0,stop=0;
wire[31:0] data,decoded;wire valid,start,stopped,dv,err,good1,good2;
wire[1:0] hdr;integer n1=0,n2=0,words=0;
gen3_recovery_tx #(.LANE_ID({lane})) tx(.clk(clk),.reset_i(rst),.enable_i(1'b1),.stop_i(stop),
 .ts2_i(ts2),.stream_i(stream),.ec_i(2'b0),.preset_i(4'd4),.first_i(6'd0),.second_i(6'd40),.post_i(6'd0),
 .initfc1_i(1'b0),.packet_data_i(32'b0),.packet_valid_i(1'b0),.packet_last_i(1'b0),
 .eq_fields_i(32'b0),.reset_interval_i(1'b0),.data_o(data),.valid_o(valid),.start_o(start),
 .header_o(hdr),.stopped_o(stopped));
gen3_native_rx #(.LANE_ID({lane})) rx(.clk(clk),.reset_i(rst),.enable_i(1'b1),
 .data_i(data),.valid_i(valid),.start_i(start),.header_i(hdr),
 .eds_i(dv && decoded==32'h0090801f),.parser_error_i(1'b0),.ts1_valid_o(good1),
 .ts2_valid_o(good2),.error_o(err),.data_valid_o(dv),.data_o(decoded));
always @(negedge clk) if(!rst) begin
 if(err) $fatal(1,"native lane stream error");
 if(good1) n1=n1+1;if(good2)n2=n2+1;
 if(dv) begin words=words+1;
 if(decoded!==0 && decoded!==32'h0090801f) $fatal(1,"lane stream descramble");end
end
initial begin
 repeat(3) @(negedge clk);rst=0;
 repeat(400) @(negedge clk);#1;ts2=1;
 repeat(400) @(negedge clk);#1;stream=1;
 repeat(4000) @(negedge clk);#1;stop=1;
 wait(stopped);repeat(10) @(negedge clk);
 if(n1<40 || n2<40 || words<3000) $fatal(1,"lane progression");
 $display("PASS");$finish;end
initial begin #50000;$fatal(1,"timeout");end
endmodule''', [GEN3 / (name + '.sv') for name in ['gen3_recovery_tx', 'gen3_native_rx']])

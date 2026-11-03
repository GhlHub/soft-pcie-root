# SPDX-License-Identifier: Apache-2.0
"""Check diagnostic injection gating independently of board software."""
import importlib.util
from pathlib import Path
import subprocess
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('overlay', ROOT / 'scripts/prepare_hardware_coverage.py')
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)

@pytest.mark.parametrize('mode', [1, 2])
def test_overlay_control(tmp_path, mode):
    bench = '''module test;
    reg clk=0; always #2 clk=~clk;
    localparam RL0=18, RLOCK=19, ADAPT=20;
    localparam HW_MODE=MODE;
    reg reset_i=1;
    reg [4:0] state=0;
    reg cmd_valid_i=0,cmd_ready_o=0,packet_active=0,dl_active_o=0,link_pending=0;
    reg [2:0] cmd_op_i=7;
    reg [63:0] cmd_address_i=16;
    reg [31:0] cmd_data_i=1;
    CONTROL
    task step; begin @(posedge clk); #1; @(negedge clk); end endtask
    initial begin
      step(); reset_i=0;
      if(HW_MODE==1) begin
        state=ADAPT; repeat(4) step();
        if(hw_triggers!=1 || hw_flags!=1 || hw_pulse) $fatal(1,"EQ injection counting");
      end else begin
        state=RL0; dl_active_o=1; cmd_valid_i=1;
        step(); if(hw_armed) $fatal(1,"unaccepted command armed");
        cmd_ready_o=1; cmd_op_i=2; step();
        if(hw_armed) $fatal(1,"configuration access armed");
        cmd_op_i=7; step(); cmd_valid_i=0;
        if(!hw_armed) $fatal(1,"accepted profile start not armed");
        repeat(4) step(); if(hw_triggers || hw_pulse) $fatal(1,"idle injection");
        packet_active=1; link_pending=1; step();
        if(!hw_pulse || hw_armed || hw_triggers!=1 || hw_flags!=14) $fatal(1,"traffic trigger");
        state=RLOCK; repeat(4) step();
        if(hw_pulse || hw_triggers!=1 || hw_entries!=1 || hw_returns) $fatal(1,"one-shot/entry");
        state=16; step(); state=17; step(); state=RL0; step();
        if(hw_returns!=1) $fatal(1,"Recovery return");
        repeat(4) step(); if(hw_returns!=1 || hw_triggers!=1) $fatal(1,"repeat injection");
      end
      reset_i=1; step();
      if(hw_triggers || hw_entries || hw_returns || hw_armed || hw_pulse) $fatal(1,"reset");
      $display("PASS diagnostic gating"); $finish;
    end
    endmodule'''.replace('MODE;', str(mode)+';').replace('    CONTROL', overlay.CONTROL)
    p=tmp_path/'test.sv'; p.write_text(bench)
    exe=tmp_path/'test'
    subprocess.run(['iverilog','-g2012','-s','test','-o',str(exe),str(p)],check=True,capture_output=True)
    r=subprocess.run(['vvp',str(exe)],text=True,capture_output=True,timeout=10)
    assert r.returncode==0,r.stdout+r.stderr

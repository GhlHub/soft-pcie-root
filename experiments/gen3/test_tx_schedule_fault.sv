// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_tx_schedule_fault;
    reg clk=0;always #2 clk=~clk;
    reg reset_i=1,enable_i=1,stop_i=0;
    reg [31:0] packet_data_i=0;reg packet_valid_i=0,packet_last_i=0;
    reg [15:0] packet_id_i=7;
    wire packet_ready_o;reg retire_i=0,wire_drained_i=1;
    wire packet_done_o;wire [15:0] packet_done_id_o;
    wire [31:0] tx_data_o;wire tx_valid_o;wire [1:0] tx_header_o;
    wire tx_start_o,tx_packet_last_o;wire [15:0] tx_packet_id_o;
    wire stopped_o,fault_o;wire [7:0] skp_pending_o;
    gen3_tx_schedule #(.PACKET_WORDS(4),.SKP_INTERVAL(4)) dut(.*);
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    initial begin
        tick;reset_i=0;while(!packet_ready_o)tick;
        packet_valid_i=1;
        repeat(4)begin tick;packet_data_i=packet_data_i+1;end
        packet_valid_i=0;stop_i=1;repeat(50)tick;
        if(!fault_o || packet_ready_o || packet_done_o || stopped_o || tx_packet_last_o)
            $fatal(1,"overflow discarded partial packet");
        if(dut.written!=4 || dut.memory[0]!=0 || dut.memory[3]!=3)
            $fatal(1,"accepted partial bank lost");
        // Even a bogus retirement cannot clear a partial packet.
        retire_i=1;tick;retire_i=0;tick;
        if(packet_done_o || stopped_o || dut.written!=4) $fatal(1,"bogus retire freed bank");
        $display("PASS: scheduler partial-packet quarantine and bogus retirement");$finish;
    end
endmodule

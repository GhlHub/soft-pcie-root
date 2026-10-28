// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_tx_schedule;
    parameter integer SKP_INTERVAL = 4;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset_i = 1, enable_i = 0, stop_i = 0;
    reg [31:0] packet_data_i = 0;
    reg packet_valid_i = 0, packet_last_i = 0;
    reg  [15:0] packet_id_i = 16'h42;
    wire        packet_ready_o;
    reg retire_i = 0, wire_drained_i = 0;
    wire        packet_done_o;
    wire [15:0] packet_done_id_o;
    wire [31:0] tx_data_o;
    wire        tx_valid_o;
    wire [ 1:0] tx_header_o;
    wire tx_start_o, tx_packet_last_o;
    wire [15:0] tx_packet_id_o;
    wire stopped_o, fault_o;
    wire [7:0] skp_pending_o;
    gen3_tx_schedule #(.SKP_INTERVAL(SKP_INTERVAL)) dut (.*);
    integer fd, cycle = 0, marker = 0;
    reg [1023:0] path;
    always @(posedge clk) begin
        if (!reset_i) begin
            $fdisplay(fd, "%0d %0d %08x %0d %0d %0d", cycle, tx_valid_o, tx_data_o, tx_header_o,
                      tx_start_o, tx_packet_last_o);
            cycle = cycle + 1;
            if (tx_packet_last_o && tx_valid_o) marker = marker + 1;
        end
    end
    task tick;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask
    task word(input integer i, input integer last);
        begin
            while (!packet_ready_o) tick;
            packet_data_i  = 32'h81000000 + 32'(i);
            packet_valid_i = 1;
            packet_last_i  = 1'(last);
            tick;
            packet_valid_i = 0;
            packet_last_i  = 0;
        end
    endtask
    initial begin
        if (!$value$plusargs("OUT=%s", path)) $fatal(1, "missing output");
        fd = $fopen(path, "w");
        tick;
        reset_i  = 0;
        enable_i = 1;
        // Input gaps cannot leak into the wire packet; stop halfway through
        // collection still allows accepted ownership to finish.
        for (integer i = 0; i < 20; i = i + 1) begin
            word(i, i == 19);
            if (i == 9) stop_i = 1;
            repeat (i % 3) tick;
        end
        while (marker == 0) tick;
        repeat (12) tick;
        if (packet_done_o || stopped_o || packet_ready_o)
            $fatal(1, "PCS acceptance freed ownership");
        retire_i = 1;
        tick;
        retire_i = 0;
        if (!packet_done_o || packet_done_id_o != 16'h42) $fatal(1, "retirement identity");
        if (stopped_o) $fatal(1, "missing wire drain ack accepted");
        wire_drained_i = 1;
        repeat (5) tick;
        if (!stopped_o || fault_o) $fatal(1, "stop/drain failure");
        // Restart exercises fresh SDS and periodic SKPs with no packet traffic.
        stop_i         = 0;
        wire_drained_i = 0;
        repeat (SKP_INTERVAL * 8 + 128) tick;
        stop_i = 1;
        repeat (15) tick;
        wire_drained_i = 1;
        repeat (5) tick;
        if (!stopped_o || fault_o || marker != 1) $fatal(1, "idle stream stop failure");
        $fclose(fd);
        $display("PASS: buffered scheduler ownership and drain");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "watchdog");
    end
endmodule

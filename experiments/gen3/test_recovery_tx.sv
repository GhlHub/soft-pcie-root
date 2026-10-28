// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_recovery_tx;
    parameter integer INITFC1 = 0, STOP_PHASE = -1;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, enable = 0, stop = 0, ts2 = 0, stream = 0;
    wire [31:0] data;
    wire valid, start, done, stopped, ts2_done, eieos_done, idle_word;
    wire unused_ready, unused_submit, unused_fault;
    wire        [ 1:0] header;
    wire signed [10:0] balance;
    gen3_recovery_tx tx (
        clk,
        reset,
        enable,
        stop,
        ts2,
        stream,
        2'b00,
        4'd4,
        6'd0,
        6'd40,
        6'd0,
        data,
        valid,
        start,
        done,
        stopped,
        header,
        balance,
        ts2_done,
        eieos_done,
        idle_word,
        INITFC1 != 0 && stream,
        32'b0,
        1'b0,
        1'b0,
        unused_ready,
        unused_submit,
        unused_fault,
    );
    integer fd, cycle = 0, count = 0;
    reg [1023:0] path;
    always @(negedge clk)
        if (!reset) begin
            $fdisplay(fd, "%0d %0d %0d %0d %08x", cycle, valid, start, header, data);
            cycle = cycle + 1;
            if (done) count = count + 1;
        end
    initial begin
        if (!$value$plusargs("OUT=%s", path)) $fatal(1, "missing path");
        fd = $fopen(path, "w");
        repeat (3) @(negedge clk);
        reset  = 0;
        enable = 1;
        wait (count >= 40);
        @(negedge clk);
        #1;
        ts2 = 1;
        wait (count >= 80);
        @(negedge clk);
        #1;
        stream = 1;
        repeat (12000) @(negedge clk);
        if (STOP_PHASE >= 0) begin
            wait (tx.fc_first);
            @(negedge clk);
            repeat (STOP_PHASE) @(negedge clk);
        end
        #1;
        stop = 1;
        wait (stopped);
        repeat (4) @(negedge clk);
        $fclose(fd);
        $finish;
    end
endmodule

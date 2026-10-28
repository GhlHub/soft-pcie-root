// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_phy_control;
    reg mgmt_clk = 0;
    always #10 mgmt_clk = ~mgmt_clk;
    reg user_clk = 0, fast = 0, run = 1;
    always begin
        if (fast) #2;
        else #4;
        if (run) user_clk = ~user_clk;
        else user_clk = 0;
    end
    reg reset_i = 1, user_reset_i = 1, req_valid_i = 0;
    reg [1:0] req_rate_i = 0;
    reg drained_i = 0, electrical_idle_ack_i = 0, rate_idle_i = 1, user_gen3_ready_i = 0;
    reg pll_lock_i = 1, tx_reset_done_i = 1, rx_reset_done_i = 1;
    wire req_ready_o, quiesce_o, electrical_idle_o, applied_valid_o, done_o, fault_o, busy_o;
    wire [2:0] txrate_o, rxrate_o;
    wire [ 1:0] applied_rate_o;
    wire [ 3:0] fault_reason_o;
    wire        clock_sample_o;
    wire [15:0] clock_edges_o;
    gen3_phy_control #(
        .TIMEOUT_CYCLES  (180),
        .IDLE_HOLD_CYCLES(3),
        .STABLE_CYCLES   (3),
        .WINDOW_CYCLES   (16),
        .GEN1_EDGES      (40),
        .FAST_EDGES      (80),
        .TOLERANCE       (3)
    ) dut (
        .*
    );
    task tick;
        begin
            @(posedge mgmt_clk);
            #1;
            @(negedge mgmt_clk);
        end
    endtask
    task change(input [1:0] rate, input integer stop_clock);
        begin
            req_rate_i  = rate;
            req_valid_i = 1;
            tick;
            req_valid_i = 0;
            repeat (3) tick;
            if (electrical_idle_o) $fatal(1, "early EI");
            drained_i = 1;
            tick;
            electrical_idle_ack_i = 1;
            while (txrate_o != {1'b0, rate}) tick;
            if (rxrate_o != txrate_o || !electrical_idle_o) $fatal(1, "rate wiring");
            rate_idle_i = 0;
            repeat (4) tick;
            fast              = (rate != 0);
            run               = !1'(stop_clock);
            user_gen3_ready_i = (rate == 2);
            rate_idle_i       = 1;
            while (!done_o && !fault_o) tick;
            if (stop_clock) begin
                if (!fault_o || applied_valid_o || !electrical_idle_o)
                    $fatal(1, "stopped clock completion");
            end else begin
                if (!done_o || fault_o || applied_rate_o != rate || !applied_valid_o)
                    $fatal(1, "integrated rate/clock confirmation");
                drained_i             = 0;
                electrical_idle_ack_i = 0;
                tick;
            end
        end
    endtask
    initial begin
        repeat (4) tick;
        reset_i      = 0;
        user_reset_i = 0;
        repeat (4) tick;
        change(2, 0);
        change(1, 0);
        change(0, 0);
        change(2, 1);
        $display("PASS: connected rate controller and independent clock measurement");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "watchdog");
    end
endmodule

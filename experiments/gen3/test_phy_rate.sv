// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_phy_rate;
    reg clk = 0;
    always #10 clk = ~clk;
    reg reset_i = 1, req_valid_i = 0;
    reg [1:0] req_rate_i = 0;
    reg drained_i = 0, electrical_idle_ack_i = 0, rate_idle_i = 1, user_gen3_ready_i = 0;
    reg pll_lock_i = 1, tx_reset_done_i = 1, rx_reset_done_i = 1, clocks_ready_i = 0;
    wire req_ready_o, quiesce_o, electrical_idle_o, clock_check_o, applied_valid_o, done_o, fault_o,
        busy_o;
    wire [1:0] gt_rate_o, applied_rate_o;
    wire [3:0] fault_reason_o;
    gen3_phy_rate #(
        .TIMEOUT_CYCLES  (30),
        .IDLE_HOLD_CYCLES(3),
        .STABLE_CYCLES   (3)
    ) dut (
        .*
    );
    task tick;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask
    task reset;
        begin
            reset_i = 1;
            tick;
            reset_i = 0;
            repeat (3) tick;
        end
    endtask
    task request(input [1:0] rate);
        begin
            req_rate_i  = rate;
            req_valid_i = 1;
            tick;
            req_valid_i = 0;
        end
    endtask
    task prechange;
        begin
            drained_i = 1;
            tick;
            electrical_idle_ack_i = 1;
            repeat (5) tick;
        end
    endtask
    task finish_change(input [1:0] rate);
        begin
            rate_idle_i = 0;
            repeat (4) tick;
            user_gen3_ready_i = (rate == 2);
            rate_idle_i       = 1;
            repeat (4) tick;
            if (!clock_check_o || !electrical_idle_o || applied_valid_o)
                $fatal(1, "early completion");
            clocks_ready_i = 1;
            repeat (3) tick;
            if (!done_o || applied_rate_o != rate || !applied_valid_o || electrical_idle_o ||
                busy_o)
                $fatal(1, "rate completion");
            clocks_ready_i = 0;
            tick;
        end
    endtask
    initial begin
        reset;
        request(2);
        repeat (5) tick;
        if (!quiesce_o || electrical_idle_o || gt_rate_o != 0) $fatal(1, "drain violation");
        prechange;
        if (gt_rate_o != 2) $fatal(1, "no rate request");
        // Stale rate-idle high cannot count as completion.
        repeat (5) tick;
        if (clock_check_o || done_o) $fatal(1, "stale idle accepted");
        finish_change(2);
        // Actual fallback traverses same drain/idle/fresh-transition sequence.
        request(1);
        prechange;
        finish_change(1);
        request(0);
        prechange;
        finish_change(0);
        // Same-rate request still requalifies clocks but needs no fake rate busy.
        request(0);
        prechange;
        if (!clock_check_o) $fatal(1, "same rate clock check");
        clocks_ready_i = 1;
        repeat (3) tick;
        if (!done_o) $fatal(1, "same rate completion");
        reset;
        drained_i             = 0;
        electrical_idle_ack_i = 0;
        clocks_ready_i        = 0;
        request(2);
        repeat (31) tick;
        if (!fault_o || electrical_idle_o || gt_rate_o != 0 || !quiesce_o)
            $fatal(1, "drain timeout truncated ownership");
        reset;
        request(2);
        prechange;
        repeat (31) tick;
        if (!fault_o || !electrical_idle_o || applied_valid_o || fault_reason_o != 6)
            $fatal(1, "rate timeout");
        reset;
        clocks_ready_i = 1;
        request(2);
        prechange;
        repeat (31) tick;
        if (!fault_o || gt_rate_o != 0) $fatal(1, "stale clock acknowledgement accepted");
        reset;
        clocks_ready_i = 0;
        request(2);
        prechange;
        rate_idle_i = 0;
        repeat (3) tick;
        rate_idle_i       = 1;
        user_gen3_ready_i = 1;
        repeat (4) tick;
        pll_lock_i     = 0;
        clocks_ready_i = 1;
        repeat (31) tick;
        if (!fault_o || applied_valid_o) $fatal(1, "lost PLL lock");
        $display("PASS: rate sequencing, fresh acknowledgements, fallback and drain-safe faults");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "watchdog");
    end
endmodule

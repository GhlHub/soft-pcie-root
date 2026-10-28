// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_clock_watch;
    reg mgmt_clk = 0;
    always #10 mgmt_clk = ~mgmt_clk;
    reg user_clk = 0, run = 1, fast = 0;
    always begin
        if (fast) #2;
        else #4;
        if (run) user_clk = ~user_clk;
        else user_clk = 0;
    end
    reg reset_i = 1, user_reset_i = 1, check_i = 0;
    reg [1:0] rate_i = 0;
    wire ready_o, sample_o;
    wire [15:0] measured_o;
    gen3_clock_watch #(
        .WINDOW_CYCLES(32),
        .GEN1_EDGES   (80),
        .FAST_EDGES   (160),
        .TOLERANCE    (3)
    ) dut (
        .*
    );
    task ticks(input integer n);
        begin
            repeat (n) begin
                @(posedge mgmt_clk);
                #1;
            end
            @(negedge mgmt_clk);
        end
    endtask
    initial begin
        ticks(5);
        reset_i      = 0;
        user_reset_i = 0;
        check_i      = 1;
        ticks(100);
        if (!ready_o) $fatal(1, "125MHz not qualified");
        rate_i = 2;
        ticks(70);
        if (ready_o) $fatal(1, "wrong frequency accepted");
        fast = 1;
        ticks(100);
        if (!ready_o) $fatal(1, "250MHz not qualified");
        run = 0;
        ticks(70);
        if (ready_o || measured_o != 0) $fatal(1, "stopped clock accepted");
        run = 1;
        ticks(100);
        if (!ready_o) $fatal(1, "clock restart observation");
        check_i = 0;
        ticks(1);
        if (ready_o) $fatal(1, "stale clock acknowledgement");
        $display("PASS: independent clock frequency and stopped-clock observation");
        $finish;
    end
endmodule

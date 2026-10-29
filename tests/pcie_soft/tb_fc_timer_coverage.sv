// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module tb_fc_timer_coverage;
    parameter integer HALF_PERIOD   = 4;
    parameter integer UPDATE_CYCLES = 1024;
    reg clk = 0;
    always #(HALF_PERIOD) clk = ~clk;
    reg rst = 0, up = 0, enable = 1, rv = 0, ready = 1, reserve = 0, replay = 0, release_credit = 0;
    reg [7:0] typ = 0, hdr = 0;
    reg [11:0] dat = 0;
    reg [1:0] cls = 1, release_cls = 0;
    reg [8:0] cost = 1, release_data = 1;
    wire valid, credit, active, error;
    wire [7:0] ot, oh;
    wire [11:0] od;
    pcie_soft_flow_control #(
        .UPDATE_CYCLES(UPDATE_CYCLES)
    ) dut (
        clk,
        rst,
        up,
        enable,
        rv,
        typ,
        hdr,
        dat,
        valid,
        ready,
        ot,
        oh,
        od,
        reserve,
        replay,
        cls,
        cost,
        credit,
        active,
        release_credit,
        release_cls,
        release_data,
        error
    );
    integer txs = 0, j;
    reg     [ 7:0] np_advertised_h = 2;
    reg     [ 7:0] advertised_h = 4;
    reg     [11:0] advertised_d = 32;
    reg     [ 7:0] expected_h = 4;
    reg     [11:0] expected_d = 32;
    integer        deadline;
    reg            stalled = 0;
    reg     [27:0] held;
    always @(posedge clk)
        if (rst && up) begin
            if (stalled && (!valid || {ot, oh, od} !== held))
                $fatal(1, "FC offer changed under stall");
            stalled = valid && !ready;
            held    = {ot, oh, od};
            if (release_credit && release_cls == 0) begin
                expected_h = expected_h + 1'b1;
                expected_d = expected_d + {3'b0, release_data};
            end
            if (valid && ready) begin
                if (ot == 8'h40 && (oh != 4 || od != 32)) $fatal(1, "Posted initial capacity");
                if (ot == 8'h50 && (oh != 2 || od != 16)) $fatal(1, "NP initial capacity changed");
                if (ot == 8'h80) begin
                    advertised_h = oh;
                    advertised_d = od;
                end
                if (ot == 8'h90) np_advertised_h = oh;
                if (ot[5:4] !== 2'(txs % 3)) $fatal(1, "FC class ordering");
                txs = txs + 1;
                if (ot[5:4] == 2 && {oh, od} !== 0)
                    $fatal(1, "Root must advertise infinite completion credits");
            end
        end else begin
            stalled = 0;
            txs     = 0;
        end
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task receive_fc(input [7:0] t, input [7:0] h, input [11:0] d);
        @(negedge clk);
        rv  = 1;
        typ = t;
        hdr = h;
        dat = d;
        @(negedge clk);
        rv = 0;
    endtask
    task spend;
        if (!credit) $fatal(1, "Expected credit");
        @(negedge clk);
        reserve = 1;
        @(negedge clk);
        reserve = 0;
        cycles(1);
    endtask
    integer tick;
    initial begin
        cycles(3);
        @(negedge clk);
        rst = 1;
        up  = 1;
        receive_fc(8'h40, 1, 1);
        receive_fc(8'h50, 1, 1);
        receive_fc(8'h60, 0, 0);
        wait (dut.phase_q == 1);
        receive_fc(8'hc0, 1, 1);
        wait (active);
        // Synchronize to an externally observed UpdateFC-Cpl acceptance.
        do @(negedge clk); while (!(valid && ot == 8'ha0));
        cycles(1);
        if (valid) $fatal(1, "Offer not retired");
        @(negedge clk);
        enable = 0;
        cycles(11);
        if (valid) $fatal(1, "Refresh progressed while TX disabled");
        @(negedge clk);
        enable = 1;
        ready  = 0;
        for (tick = 1; tick <= UPDATE_CYCLES; tick = tick + 1) begin
            cycles(1);
            if (tick < UPDATE_CYCLES && valid) $fatal(1, "Early UpdateFC tick=%0d", tick);
        end
        if (!valid || ot != 8'h80 || oh != 4 || od != 32)
            $fatal(1, "Missing UpdateFC at configured deadline");
        cycles(7);
        if (!valid || ot != 8'h80 || oh != 4 || od != 32) $fatal(1, "Held UpdateFC changed");
        @(negedge clk);
        ready = 1;
        cycles(1);
        // A fresh returned credit must schedule a new round even during the
        // periodic waiting interval. Existing scoreboard checks class order.
        do @(negedge clk); while (!(valid && ot == 8'ha0));
        cycles(1);
        @(negedge clk);
        release_credit = 1;
        cycles(1);
        @(negedge clk);
        release_credit = 0;
        deadline       = 0;
        while (advertised_h != 5 || advertised_d != 33) begin
            cycles(1);
            deadline = deadline + 1;
            if (deadline > 8) $fatal(1, "Returned credit did not wake scheduler");
        end
        $display("PASS UpdateFC configured boundary U=%0d HALF_PERIOD=%0d", UPDATE_CYCLES,
                 HALF_PERIOD);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "UpdateFC watchdog");
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_startup_qualification;
    parameter integer CASE = 0;
    reg clk = 0, rst_n = 0, manual = 0, ready = 1;
    always #4 clk = ~clk;
    wire [4:0] state;
    wire [1:0] kind;
    reg valid = 0, bad = 0, txdone = 0;
    reg [7:0] lane = 0, rate = 8'h0e, control = 0;
    integer cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;
    wire auto_ts = cycle % 8 == 0;
    gen3_startup_ltssm #(
        .QUIET_CYCLES (4),
        .POLL_CYCLES  (20000),
        .CONFIG_CYCLES(512)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .enable_i            (1'b1),
        .phy_ready_i         (ready),
        .rx_electrical_idle_i(1'b0),
        .detect_done_i       (state == 1),
        .receiver_present_i  (1'b1),
        .retrain_i           (1'b0),
        .ts_valid_i          (manual ? valid : auto_ts),
        .ts2_i               (state == 3 || state == 8),
        .inverted_i          (1'b0),
        .ts_bad_i            (manual && bad),
        .rx_link_i           (8'b0),
        .rx_lane_i           (lane),
        .rx_rate_i           (rate),
        .rx_control_i        (control),
        .rx_link_pad_i       (state < 4),
        .rx_lane_pad_i       (state < 6),
        .tx_ts_done_i        (manual ? txdone : auto_ts),
        .tx_ts_kind_i        (kind),
        .rx_idle_pair_i      (1'b0),
        .tx_idle_pair_i      (1'b0),
        .rx_error_i          (1'b0),
        .tx_kind_o           (kind),
        .state_o             (state),
        .force_gen1_i        (1'b1),
        .phy_gen2_i          (1'b0),
        .phy_rate_ready_i    (1'b1),
        .eios_done_i         (1'b0)
    );
    task tick;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask
    task send_ts(input integer count);
        begin
            repeat (count) begin
                valid = 1;
                tick();
                valid = 0;
                tick();
            end
        end
    endtask
    task enter_complete;
        begin
            manual  = 0;
            valid   = 0;
            bad     = 0;
            txdone  = 0;
            lane    = 0;
            rate    = 8'h0e;
            control = 0;
            ready   = 1;
            wait (state == 8);
            @(negedge clk);
            manual = 1;
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        enter_complete();
        if (CASE <= 3) begin
            send_ts(7);
            // None of these interruptions may combine two shorter runs into
            // the required eight consecutive, matching training sequences.
            if (CASE == 0) begin
                bad = 1;
                tick();
                bad = 0;
            end
            if (CASE == 1) begin
                lane = 1;
                send_ts(1);
                lane = 0;
            end
            if (CASE == 2) begin
                rate = 8'h06;
                send_ts(1);
                rate = 8'h0e;
            end
            if (CASE == 3) begin
                control = 8'h10;
                send_ts(1);
                control = 0;
            end
            send_ts(7);
            txdone = 1;
            repeat (20) tick();
            txdone = 0;
            if (state != 8)
                $fatal(1, "nonconsecutive/mismatched TS2 qualification accepted case=%0d", CASE);
            send_ts(1);
            repeat (3) tick();
            if (state != 9) $fatal(1, "eight consecutive TS2s did not qualify case=%0d", CASE);
        end else begin
            send_ts(8);
            if (CASE == 4) begin
                control = 1;
                valid   = 1;
                tick();
                valid = 0;
                if (state != 14) $fatal(1, "unsupported control bypassed after qualification");
            end else if (CASE == 5) begin
                ready = 0;
                tick();
                if (state != 0) $fatal(1, "PHY loss bypassed after qualification");
                enter_complete();
                send_ts(7);
                txdone = 1;
                repeat (20) tick();
                if (state != 8) $fatal(1, "qualification survived PHY loss");
            end else begin
                rst_n = 0;
                tick();
                rst_n = 1;
                enter_complete();
                send_ts(7);
                txdone = 1;
                repeat (20) tick();
                if (state != 8) $fatal(1, "qualification survived synchronous reset");
            end
        end
        $display("PASS: startup qualification case %0d", CASE);
        $finish;
    end
    initial begin
        #500000;
        $fatal(1, "qualification watchdog state=%0d", state);
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_eq_phase1;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst = 1, enter = 0, cancel = 0, skip_phase23 = 1;
    reg phy_gen3_ready = 1, preset_applied = 1, rx_aligned = 1;
    reg rx_ts_event = 0, rx_ts1_valid = 1;
    reg [ 1:0] rx_ec = 1;
    reg [31:0] rx_symbols6_9 = 32'h00103001;
    wire active, tx_ts1_valid, go_rcvrlock, go_phase2, go_speed;
    wire phase1_success, phase2_success, phase3_success, complete, phases23_skipped, failed;
    wire [1:0] tx_ec;
    wire [3:0] tx_preset;
    wire [5:0] tx_fs, tx_lf, tx_post, peer_fs, peer_lf;
    wire [ 2:0] failure_reason;
    wire [15:0] ts_events;
    gen3_eq_phase1 #(
        .TIMEOUT_CYCLES(16),
        .SETTLE_CYCLES (2)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .enter           (enter),
        .cancel          (cancel),
        .skip_phase23    (skip_phase23),
        .phy_gen3_ready  (phy_gen3_ready),
        .preset_applied  (preset_applied),
        .applied_preset  (4'd4),
        .applied_fs      (6'd40),
        .applied_lf      (6'd12),
        .applied_post    (6'd0),
        .rx_aligned      (rx_aligned),
        .rx_ts_event     (rx_ts_event),
        .rx_ts1_valid    (rx_ts1_valid),
        .rx_ec           (rx_ec),
        .rx_symbols6_9   (rx_symbols6_9),
        .rx_fs           (6'd48),
        .rx_lf           (6'd16),
        .active          (active),
        .tx_ts1_valid    (tx_ts1_valid),
        .tx_ec           (tx_ec),
        .tx_preset       (tx_preset),
        .tx_fs           (tx_fs),
        .tx_lf           (tx_lf),
        .tx_post         (tx_post),
        .peer_fs         (peer_fs),
        .peer_lf         (peer_lf),
        .go_rcvrlock     (go_rcvrlock),
        .go_phase2       (go_phase2),
        .go_speed        (go_speed),
        .phase1_success  (phase1_success),
        .phase2_success  (phase2_success),
        .phase3_success  (phase3_success),
        .complete        (complete),
        .phases23_skipped(phases23_skipped),
        .failed          (failed),
        .failure_reason  (failure_reason),
        .ts_events       (ts_events)
    );
    task tick;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask
    task start;
        begin
            enter = 1;
            tick;
            enter = 0;
        end
    endtask
    task ready_attempt;
        begin
            start;
            repeat (3) tick;
        end
    endtask
    task ts;
        begin
            rx_ts_event = 1;
            tick;
            rx_ts_event = 0;
        end
    endtask
    initial begin
        tick;
        rst = 0;
        ready_attempt;
        if (!tx_ts1_valid || tx_ec != 1 || tx_preset != 4 || tx_fs != 40 || tx_lf != 12 ||
            tx_post != 0)
            $fatal(1, "transmitted preset fields");
        ts;
        if (!active) $fatal(1, "single TS accepted");
        // Policy cannot change halfway through an attempt.
        skip_phase23 = 0;
        ts;
        if (!go_rcvrlock || active || !complete || !phase1_success || !phase2_success ||
            !phase3_success || !phases23_skipped || failed || peer_fs != 48 || peer_lf != 16)
            $fatal(1, "skip result");
        tick;
        if (go_rcvrlock) $fatal(1, "pulse not cleared");
        ready_attempt;
        ts;
        rx_ec = 2;
        ts;
        rx_ec = 1;
        ts;
        if (!active) $fatal(1, "nonconsecutive TS accepted");
        ts;
        if (!go_phase2 || complete || phases23_skipped || phase2_success || phase3_success)
            $fatal(1, "full mode handoff");
        skip_phase23 = 1;
        ready_attempt;
        ts;
        rx_symbols6_9 = 32'h00103011;
        ts;
        if (!active) $fatal(1, "changed symbols 6..9 accepted");
        ts;
        if (!go_rcvrlock) $fatal(1, "matching replacement pair rejected");
        ready_attempt;
        ts;
        rx_aligned = 0;
        tick;
        rx_aligned = 1;
        ts;
        if (!active) $fatal(1, "alignment loss retained TS pair");
        rx_ts1_valid = 0;
        ts;
        rx_ts1_valid = 1;
        ts;
        if (!active) $fatal(1, "invalid TS retained pair");
        ts;
        if (!go_rcvrlock) $fatal(1, "requalified pair");
        // Stale TS on entry and during settling cannot complete the attempt.
        rx_ts_event = 1;
        start;
        repeat (2) tick;
        if (!active) $fatal(1, "stale early TS");
        rx_ts_event = 0;
        cancel      = 1;
        tick;
        cancel = 0;
        if (active || go_rcvrlock || go_speed) $fatal(1, "cancel result");
        // No preset acknowledgement: bounded failure, never transmit false fields.
        preset_applied = 0;
        start;
        repeat (15) begin
            tick;
            if (!active || tx_ts1_valid || go_speed) $fatal(1, "early timeout");
        end
        tick;
        if (!go_speed || active || !complete || !failed || phase1_success || failure_reason != 2)
            $fatal(1, "missing preset timeout");
        tick;
        if (go_speed) $fatal(1, "fallback pulse not cleared");
        preset_applied = 1;
        phy_gen3_ready = 0;
        start;
        repeat (16) tick;
        if (!go_speed || !failed || failure_reason != 1) $fatal(1, "missing PHY timeout");
        phy_gen3_ready = 1;
        start;
        repeat (14) tick;
        ts;
        ts;
        if (!go_rcvrlock || failed) $fatal(1, "deadline pair precedence");
        ready_attempt;
        ts;
        rst = 1;
        tick;
        rst = 0;
        if (active || complete || failed || phase1_success || tx_ts1_valid)
            $fatal(1, "synchronous reset");
        $display("PASS: Gen3 downstream phase 1 shortcut, handoff, qualification and timeout");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "watchdog");
    end
endmodule

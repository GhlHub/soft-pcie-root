// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
// Behavioral control-plane experiments, not an analog channel model.
module test_gen3_peer;
    parameter  integer SETTLE   = 2;
    localparam integer DEADLINE = 192;
    reg clk = 0;
    always #2 clk = ~clk;
    reg rst = 1, enter = 0, cancel = 0, skip_phase23 = 0;
    reg phy_gen3_ready = 1, preset_applied = 0;
    wire rx_aligned;
    wire rx_ts_event, rx_ts1_valid;
    wire [ 1:0] rx_ec;
    reg  [ 3:0] applied_preset = 0;
    wire [31:0] rx_symbols6_9;
    wire [5:0] decoded_fs, decoded_lf;
    wire active, tx_ts1_valid, go_rcvrlock, go_phase2, go_speed;
    wire phase1_success, phase2_success, phase3_success, complete, phases23_skipped, failed;
    wire [1:0] tx_ec;
    wire [3:0] tx_preset;
    wire [5:0] tx_fs, tx_lf, tx_post, peer_fs, peer_lf;
    wire [ 2:0] failure_reason;
    wire [15:0] ts_events;
    gen3_eq_phase1 #(
        .TIMEOUT_CYCLES(DEADLINE),
        .SETTLE_CYCLES (SETTLE)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .enter           (enter),
        .cancel          (cancel),
        .skip_phase23    (skip_phase23),
        .phy_gen3_ready  (phy_gen3_ready),
        .preset_applied  (preset_applied),
        .applied_preset  (applied_preset),
        .applied_fs      (6'd40),
        .applied_lf      (6'd12),
        .applied_post    (6'd0),
        .rx_aligned      (rx_aligned),
        .rx_ts_event     (rx_ts_event),
        .rx_ts1_valid    (rx_ts1_valid),
        .rx_ec           (rx_ec),
        .rx_symbols6_9   (rx_symbols6_9),
        .rx_fs           (decoded_fs),
        .rx_lf           (decoded_lf),
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
    reg [31:0] wire_data = 0;
    reg wire_valid = 0, wire_start = 0;
    reg [1:0] wire_header = 1;
    wire decoder_error, eios;
    wire [127:0] last_ts;
    gen3_training_rx decoder (
        clk,
        rst,
        1'b1,
        wire_data,
        wire_valid,
        wire_start,
        wire_header,
        rx_aligned,
        rx_ts_event,
        rx_ts1_valid,
        rx_ec,
        decoded_fs,
        decoded_lf,
        rx_symbols6_9,
        decoder_error,
        eios,
        last_ts
    );
    integer to_lock = 0, to_phase2 = 0, to_speed = 0, errors = 0;
    integer decoded_events = 0, valid_events = 0;
    always @(negedge clk) begin
        if (!rst) begin
            if (go_rcvrlock) to_lock = to_lock + 1;
            if (go_phase2) to_phase2 = to_phase2 + 1;
            if (go_speed) to_speed = to_speed + 1;
            if (rx_ts_event) decoded_events = decoded_events + 1;
            if (rx_ts1_valid) valid_events = valid_events + 1;
            if (decoder_error) errors = errors + 1;
        end
    end
    reg [4095:0] path;
    integer fd, rc, op, a, b, c, d, row = 0;
    initial begin
        if (!$value$plusargs("VECTORS=%s", path)) $fatal(1, "Missing peer vectors");
        fd = $fopen(path, "r");
        if (!fd) $fatal(1, "Cannot open peer vectors");
        repeat (3) @(posedge clk);
        #1;
        rst = 0;
        while (!$feof(
            fd
        )) begin
            rc = $fscanf(fd, "%d %h %h %h %h\n", op, a, b, c, d);
            if (rc != 5) $fatal(1, "Bad vector row %0d", row);
            row = row + 1;
            // Drive after the monitor at negedge; sample after the next edge.
            @(negedge clk);
            #0.1;
            enter          = 0;
            cancel         = 0;
            preset_applied = 0;
            wire_valid     = 0;
            if (op == 0) begin
                wire_data      = a;
                wire_valid     = b[0];
                wire_start     = b[1];
                wire_header    = b[3:2];
                enter          = c[0];
                cancel         = c[1];
                phy_gen3_ready = c[2];
                preset_applied = c[3];
                skip_phase23   = c[4];
                applied_preset = 4'(d);
            end else if (op == 1) begin
                if ({phases23_skipped, failed, phase1_success, complete, active} !== 5'(a) ||
                    failure_reason !== 3'(b) ||
                    {8'(to_speed), 8'(to_phase2), 8'(to_lock)} !== 24'(c) || errors != d)
                    $fatal(
                        1,
                        "Peer result row=%0d flags=%b reason=%d routes=%d/%d/%d errors=%d",
                        row,
                        {
                            phases23_skipped, failed, phase1_success, complete, active
                        },
                        failure_reason,
                        to_speed,
                        to_phase2,
                        to_lock,
                        errors
                    );
            end else if (op == 2) begin
                if (!tx_ts1_valid || tx_preset !== 4'(a) || tx_fs != 40 || tx_lf != 12 ||
                    tx_post != 0)
                    $fatal(1, "Acknowledged preset changed or absent row=%0d", row);
            end else if (op == 3) begin
                if (decoded_events != a || valid_events != b)
                    $fatal(
                        1,
                        "Peer decoder events row=%0d total=%0d valid=%0d expected=%0d/%0d",
                        row,
                        decoded_events,
                        valid_events,
                        a,
                        b
                    );
            end else $fatal(1, "Unknown opcode");
            @(posedge clk);
            #1;
        end
        $fclose(fd);
        $display("PASS: independent Gen3 peer vectors rows=%0d settle=%0d", row, SETTLE);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Peer watchdog");
    end
endmodule

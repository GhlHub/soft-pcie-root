// SPDX-License-Identifier: Apache-2.0
// Downstream x1 Recovery.Equalization phase 1, 8 GT/s only.
// All inputs are synchronous to clk. Run clk continuously during this substate;
// an independent PHY management watchdog must cover stopped-clock failure.
module gen3_eq_phase1 #(
    parameter integer CLK_HZ = 250000000,
    parameter integer TIMEOUT_CYCLES = (CLK_HZ / 1000) * 24,
    parameter integer SETTLE_CYCLES = CLK_HZ / 2000000
)(
    input wire clk, rst,
    input wire enter, cancel,
    // Latch policy per attempt. False hands off to a separate phase 2 engine.
    input wire skip_phase23,
    input wire phy_gen3_ready,
    // Ack means preset is effective at the pins, not merely queued for a CDC.
    input wire preset_applied,
    input wire [3:0] applied_preset,
    input wire [5:0] applied_fs, applied_lf, applied_post,
    input wire rx_aligned,
    // One event per complete TS. valid includes lane/link ID, TS1 encoding,
    // training symbol checks (reserved bits do not invalidate a TS). Other TS
    // events break the pair; permitted intervening SKP/EIEOS do not emit events.
    input wire rx_ts_event, rx_ts1_valid,
    input wire [1:0] rx_ec,
    input wire [5:0] rx_fs, rx_lf,
    // Raw decoded symbols 6..9, including reserved bits (comparison permitted).
    input wire [31:0] rx_symbols6_9,
    output reg active,
    output wire tx_ts1_valid,
    output wire [1:0] tx_ec,
    output reg [3:0] tx_preset,
    output reg [5:0] tx_fs, tx_lf, tx_post,
    output reg [5:0] peer_fs, peer_lf,
    // Pulses to outer LTSSM; never reset packet/replay ownership on these.
    output reg go_rcvrlock, go_phase2, go_speed,
    output reg phase1_success, phase2_success, phase3_success,
    output reg complete, phases23_skipped, failed,
    // Sticky per-attempt diagnostic: 0 none, 1 PHY not ready, 2 preset not
    // acknowledged, 3 unaligned, 4 no matching pair, 5 PHY lost after ack.
    output reg [2:0] failure_reason,
    output reg [15:0] ts_events
);
    localparam integer TW = (TIMEOUT_CYCLES > 1) ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam integer SW = (SETTLE_CYCLES > 1) ? $clog2(SETTLE_CYCLES+1) : 1;
    reg [TW-1:0] timer;
    reg [SW-1:0] settle;
    reg skip_latched, preset_valid, seen_ts;
    reg [31:0] previous_symbols6_9;
    // Values are captured once per attempt. Changing PHY settings externally
    // during an attempt requires cancel/re-entry, not a silent coefficient swap.
    assign tx_ts1_valid = active && preset_valid && phy_gen3_ready;
    assign tx_ec = 2'b01;
    wire qualified = preset_valid && phy_gen3_ready && rx_aligned && settle == 0;
    wire matching_ts = rx_ts1_valid && rx_ec == 2'b01;
    initial begin
        if (TIMEOUT_CYCLES < 1 || SETTLE_CYCLES < 0 ||
            SETTLE_CYCLES > CLK_HZ / 2000000)
            $fatal(1, "Invalid equalization timer parameters");
    end
    always @(posedge clk) begin
        if (rst) begin
            active <= 0; timer <= 0; settle <= 0;
            skip_latched <= 0; preset_valid <= 0; seen_ts <= 0;
            go_rcvrlock <= 0; go_phase2 <= 0; go_speed <= 0;
            phase1_success <= 0; phase2_success <= 0; phase3_success <= 0;
            complete <= 0; phases23_skipped <= 0; failed <= 0;
            failure_reason <= 0; ts_events <= 0;
        end else begin
            go_rcvrlock <= 0; go_phase2 <= 0; go_speed <= 0;
            if (cancel) begin
                active <= 0; preset_valid <= 0; seen_ts <= 0;
            end else if (enter && !active) begin
                active <= 1; timer <= 0; settle <= SW'(SETTLE_CYCLES);
                skip_latched <= skip_phase23; preset_valid <= 0; seen_ts <= 0;
                phase1_success <= 0; phase2_success <= 0; phase3_success <= 0;
                complete <= 0; phases23_skipped <= 0; failed <= 0;
                failure_reason <= 0; ts_events <= 0;
            end else if (active) begin
                if (rx_ts_event && ts_events != 16'hffff)
                    ts_events <= ts_events + 1'b1;
                if (settle != 0) settle <= settle - 1'b1;
                if (!preset_valid && preset_applied && phy_gen3_ready) begin
                    preset_valid <= 1;
                    tx_preset <= applied_preset;
                    tx_fs <= applied_fs; tx_lf <= applied_lf; tx_post <= applied_post;
                end
                if (!qualified) seen_ts <= 0;
                else if (rx_ts_event) begin
                    seen_ts <= matching_ts;
                    if (matching_ts) begin
                        peer_fs <= rx_fs; peer_lf <= rx_lf;
                        previous_symbols6_9 <= rx_symbols6_9;
                    end
                end
                // A pair on the deadline wins over the timeout, as in the
                // ordered next-state conditions in the Base Specification.
                if (preset_valid && !phy_gen3_ready) begin
                    // A completed preset acknowledgement cannot survive loss
                    // of PHY readiness. Require a new outer-LTSSM attempt.
                    active <= 0; preset_valid <= 0; seen_ts <= 0;
                    go_speed <= 1; complete <= 1; failed <= 1;
                    failure_reason <= 3'd5;
                end else if (qualified && rx_ts_event && matching_ts && seen_ts &&
                    rx_symbols6_9 == previous_symbols6_9) begin
                    active <= 0; phase1_success <= 1;
                    if (skip_latched) begin
                        go_rcvrlock <= 1; complete <= 1;
                        phase2_success <= 1; phase3_success <= 1;
                        phases23_skipped <= 1;
                    end else go_phase2 <= 1;
                end else if (timer == TW'(TIMEOUT_CYCLES-1)) begin
                    active <= 0; go_speed <= 1; complete <= 1; failed <= 1;
                    if (!phy_gen3_ready) failure_reason <= 3'd1;
                    else if (!preset_valid) failure_reason <= 3'd2;
                    else if (!rx_aligned) failure_reason <= 3'd3;
                    else failure_reason <= 3'd4;
                end else timer <= timer + 1'b1;
            end
        end
    end
endmodule

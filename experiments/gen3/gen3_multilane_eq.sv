// SPDX-License-Identifier: Apache-2.0
// Shared Gen3 equalization attempt with one real Phase 1 and adaptive Phase 2/3
// engine per configured lane. The PIPE word clocks must already be common.
// Entry requires Gen3 PHY readiness and actual per-lane preset acknowledgements.
// This is a training boundary, not the rate-change LTSSM or packet backend.
module gen3_multilane_eq #(
    parameter integer LINK_WIDTH      = 1,
    parameter integer PHASE1_CYCLES   = 6000000,
    parameter integer PHASE2_CYCLES   = 8000000,
    parameter integer PHASE3_CYCLES   = 6000000,
    parameter integer TOTAL_CYCLES    = 20000000,
    parameter integer SETTLE_CYCLES   = 125,
    parameter integer REQUEST_CYCLES  = 375000,
    parameter integer EVALUATE_CYCLES = 25000,
    parameter integer APPLY_CYCLES    = 125
) (
    input wire clk, reset_i, enter_i, cancel_i,
    input wire [LINK_WIDTH-1:0] phy_ready_i, preset_applied_i,
    input wire [LINK_WIDTH*4-1:0] preset_i,
    input wire [LINK_WIDTH*6-1:0] local_fs_i, local_lf_i,
    input wire [LINK_WIDTH*18-1:0] initial_coeff_i,
    input wire [LINK_WIDTH*32-1:0] rx_data_i,
    input wire [LINK_WIDTH-1:0] rx_valid_i, rx_start_i,
    input wire [LINK_WIDTH*2-1:0] rx_header_i,
    input wire [LINK_WIDTH-1:0] txeq_done_i, rxeq_done_i, rxeq_adapt_done_i, rxeq_preset_sel_i,
    input wire [LINK_WIDTH*18-1:0] txeq_coeff_i, rxeq_proposal_i,
    output wire [LINK_WIDTH*32-1:0] tx_data_o,
    output wire [LINK_WIDTH-1:0] tx_valid_o, tx_start_o,
    output wire [LINK_WIDTH*2-1:0] tx_header_o, txeq_ctrl_o, rxeq_ctrl_o,
    output wire [LINK_WIDTH*4-1:0] txeq_preset_o, rxeq_preset_o,
    output wire [LINK_WIDTH*6-1:0] txeq_coeff_o,
    output wire active_o,
    output reg done_o, failed_o,
    output wire [1:0] phase_o,
    output reg [LINK_WIDTH-1:0] phase1_complete_o, phase23_complete_o
);
    localparam [1:0] IDLE = 0, PHASE1 = 1, PHASE23 = 2, TERMINAL = 3;
    reg [             1:0] state;
    reg [            31:0] timer;
    reg [LINK_WIDTH*4-1:0] preset_q;
    reg [LINK_WIDTH*6-1:0] local_fs_q, local_lf_q;
    reg [LINK_WIDTH*18-1:0] initial_coeff_q;
    wire [LINK_WIDTH-1:0] p1_done, p1_failed, p23_done, p23_failed;
    wire [LINK_WIDTH-1:0] aligned, event_ts, valid_ts, qualified_ts, rx_error;
    wire start_attempt = enter_i && state == IDLE && !cancel_i;
    wire enter_adapt;
    wire link_fault = !(&phy_ready_i) || (|rx_error) || (state == PHASE1 && (|p1_failed)) ||
        (state == PHASE23 && ((|p23_failed) || !(&aligned))) || (|(phase1_complete_o & ~aligned)) ||
        (|(phase1_complete_o & event_ts & ~qualified_ts)) || timer >= TOTAL_CYCLES - 1;
    assign enter_adapt = state == PHASE1 && (&phase1_complete_o) && !link_fault && !cancel_i;
    wire cancel_engines = cancel_i || state == TERMINAL || (active_o && link_fault);
    assign active_o = state == PHASE1 || state == PHASE23;
    assign phase_o  = state;
    always @(posedge clk) begin
        if (reset_i) begin
            state              <= IDLE;
            timer              <= 0;
            done_o             <= 0;
            failed_o           <= 0;
            preset_q           <= 0;
            local_fs_q         <= 0;
            local_lf_q         <= 0;
            initial_coeff_q    <= 0;
            phase1_complete_o  <= 0;
            phase23_complete_o <= 0;
        end else begin
            done_o <= 0;
            if (cancel_i) begin
                state              <= IDLE;
                timer              <= 0;
                phase1_complete_o  <= 0;
                phase23_complete_o <= 0;
            end else if (start_attempt) begin
                state              <= PHASE1;
                timer              <= 0;
                failed_o           <= 0;
                preset_q           <= preset_i;
                local_fs_q         <= local_fs_i;
                local_lf_q         <= local_lf_i;
                initial_coeff_q    <= initial_coeff_i;
                phase1_complete_o  <= 0;
                phase23_complete_o <= 0;
            end else if (active_o) begin
                if (timer != 32'hffffffff) timer <= timer + 1'b1;
                // Fatal conditions override cached success and deadline-edge done.
                if (link_fault) begin
                    state    <= TERMINAL;
                    failed_o <= 1;
                end else if (state == PHASE1) begin
                    phase1_complete_o <= phase1_complete_o | p1_done;
                    if (&phase1_complete_o) state <= PHASE23;
                end else begin
                    phase23_complete_o <= phase23_complete_o | p23_done;
                    if (&phase23_complete_o) begin
                        state  <= TERMINAL;
                        done_o <= 1;
                    end
                end
            end
        end
    end
    for (genvar lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin : lanes
        wire [ 0:0] unused_0_eios_o;
        wire [ 0:0] unused_1_active;
        wire [ 0:0] unused_2_tx_ts1_valid;
        wire [ 1:0] unused_3_tx_ec;
        wire [ 3:0] unused_4_tx_preset;
        wire [ 5:0] unused_5_tx_fs;
        wire [ 5:0] unused_6_tx_lf;
        wire [ 5:0] unused_7_tx_post;
        wire [ 0:0] unused_8_go_rcvrlock;
        wire [ 0:0] unused_9_go_speed;
        wire [ 0:0] unused_10_phase1_success;
        wire [ 0:0] unused_11_phase2_success;
        wire [ 0:0] unused_12_phase3_success;
        wire [ 0:0] unused_13_complete;
        wire [ 0:0] unused_14_phases23_skipped;
        wire [ 2:0] unused_15_failure_reason;
        wire [15:0] unused_16_ts_events;
        wire [ 0:0] unused_17_active_o;
        wire [ 3:0] unused_18_reason_o;
        wire [ 3:0] unused_19_attempts_o;
        wire [ 3:0] unused_20_applied_preset_o;
        wire [17:0] unused_21_applied_coeff_o;
        wire [ 0:0] unused_22_ts_done_o;
        wire [ 0:0] unused_23_stopped_o;
        wire [10:0] unused_24_balance_o;
        wire [ 1:0] ec;
        wire [5:0] fs, lf, peer_fs, peer_lf;
        wire [31:0] fields, adapt_fields;
        wire [127:0] last_ts;
        wire [1:0] adapt_txctrl, adapt_rxctrl;
        wire reset_interval;
        wire normal_rate = last_ts[35] && !last_ts[39];
        wire good_ts = valid_ts[lane] && normal_rate;
        assign qualified_ts[lane] = good_ts;
        wire [30:0] p1_fields = {
            1'b0,
            initial_coeff_q[18*lane+:6],
            2'b0,
            local_lf_q[6*lane+:6],
            2'b0,
            local_fs_q[6*lane+:6],
            1'b0,
            preset_q[4*lane+:4],
            1'b0,
            2'b01
        };
        wire [31:0] tx_fields = state == PHASE23 ? adapt_fields : {^p1_fields, p1_fields};
        gen3_training_rx #(
            .LANE_ID(lane)
        ) rx (
            .clk         (clk),
            .reset_i     (reset_i || start_attempt),
            .enable_i    (active_o),
            .data_i      (rx_data_i[lane*32+:32]),
            .valid_i     (rx_valid_i[lane]),
            .start_i     (rx_start_i[lane]),
            .header_i    (rx_header_i[lane*2+:2]),
            .aligned_o   (aligned[lane]),
            .ts_event_o  (event_ts[lane]),
            .ts1_valid_o (valid_ts[lane]),
            .ec_o        (ec),
            .fs_o        (fs),
            .lf_o        (lf),
            .symbols6_9_o(fields),
            .error_o     (rx_error[lane]),
            .eios_o      (unused_0_eios_o),
            .last_ts_o   (last_ts)
        );
        gen3_eq_phase1 #(
            .TIMEOUT_CYCLES(PHASE1_CYCLES),
            .SETTLE_CYCLES (SETTLE_CYCLES)
        ) phase1 (
            .clk             (clk),
            .rst             (reset_i),
            .enter           (start_attempt),
            .cancel          (cancel_engines),
            .skip_phase23    (1'b0),
            .phy_gen3_ready  (phy_ready_i[lane]),
            .preset_applied  (preset_applied_i[lane]),
            .applied_preset  (preset_q[4*lane+:4]),
            .applied_fs      (local_fs_q[6*lane+:6]),
            .applied_lf      (local_lf_q[6*lane+:6]),
            .applied_post    (initial_coeff_q[18*lane+:6]),
            .rx_aligned      (aligned[lane]),
            .rx_ts_event     (event_ts[lane]),
            .rx_ts1_valid    (good_ts),
            .rx_ec           (ec),
            .rx_fs           (fs),
            .rx_lf           (lf),
            .rx_symbols6_9   (fields),
            .active          (unused_1_active),
            .tx_ts1_valid    (unused_2_tx_ts1_valid),
            .tx_ec           (unused_3_tx_ec),
            .tx_preset       (unused_4_tx_preset),
            .tx_fs           (unused_5_tx_fs),
            .tx_lf           (unused_6_tx_lf),
            .tx_post         (unused_7_tx_post),
            .peer_fs         (peer_fs),
            .peer_lf         (peer_lf),
            .go_rcvrlock     (unused_8_go_rcvrlock),
            .go_phase2       (p1_done[lane]),
            .go_speed        (unused_9_go_speed),
            .phase1_success  (unused_10_phase1_success),
            .phase2_success  (unused_11_phase2_success),
            .phase3_success  (unused_12_phase3_success),
            .complete        (unused_13_complete),
            .phases23_skipped(unused_14_phases23_skipped),
            .failed          (p1_failed[lane]),
            .failure_reason  (unused_15_failure_reason),
            .ts_events       (unused_16_ts_events)
        );
        gen3_eq_adapt #(
            .PHASE2_CYCLES  (PHASE2_CYCLES),
            .PHASE3_CYCLES  (PHASE3_CYCLES),
            .REQUEST_CYCLES (REQUEST_CYCLES),
            .SETTLE_CYCLES  (SETTLE_CYCLES),
            .EVALUATE_CYCLES(EVALUATE_CYCLES),
            .APPLY_CYCLES   (APPLY_CYCLES)
        ) adapt (
            .clk              (clk),
            .reset_i          (reset_i),
            .enter_i          (enter_adapt),
            .cancel_i         (cancel_engines),
            .phy_ready_i      (phy_ready_i[lane]),
            .ts_event_i       (event_ts[lane]),
            .ts_valid_i       (good_ts),
            .aligned_i        (aligned[lane]),
            .rx_error_i       (rx_error[lane]),
            .rx_fields_i      (fields),
            .initial_preset_i (preset_q[4*lane+:4]),
            .initial_coeff_i  (initial_coeff_q[18*lane+:18]),
            .local_fs_i       (local_fs_q[6*lane+:6]),
            .local_lf_i       (local_lf_q[6*lane+:6]),
            .peer_fs_i        (peer_fs),
            .peer_lf_i        (peer_lf),
            .txeq_done_i      (txeq_done_i[lane]),
            .txeq_coeff_i     (txeq_coeff_i[18*lane+:18]),
            .rxeq_done_i      (rxeq_done_i[lane]),
            .rxeq_adapt_done_i(rxeq_adapt_done_i[lane]),
            .rxeq_preset_sel_i(rxeq_preset_sel_i[lane]),
            .rxeq_proposal_i  (rxeq_proposal_i[18*lane+:18]),
            .txeq_ctrl_o      (adapt_txctrl),
            .rxeq_ctrl_o      (adapt_rxctrl),
            .txeq_preset_o    (txeq_preset_o[4*lane+:4]),
            .rxeq_preset_o    (rxeq_preset_o[4*lane+:4]),
            .txeq_coeff_o     (txeq_coeff_o[6*lane+:6]),
            .tx_fields_o      (adapt_fields),
            .reset_interval_o (reset_interval),
            .active_o         (unused_17_active_o),
            .done_o           (p23_done[lane]),
            .failed_o         (p23_failed[lane]),
            .reason_o         (unused_18_reason_o),
            .attempts_o       (unused_19_attempts_o),
            .applied_preset_o (unused_20_applied_preset_o),
            .applied_coeff_o  (unused_21_applied_coeff_o)
        );
        assign txeq_ctrl_o[2*lane+:2] = active_o && !cancel_engines ? adapt_txctrl : 2'b0;
        assign rxeq_ctrl_o[2*lane+:2] = active_o && !cancel_engines ? adapt_rxctrl : 2'b0;
        gen3_training_tx #(
            .EXTERNAL_EQ(1),
            .LANE_ID    (lane)
        ) tx (
            .clk             (clk),
            .reset_i         (reset_i || start_attempt),
            .enable_i        (active_o && !cancel_engines),
            .stop_i          (cancel_engines),
            .ec_i            (2'b01),
            .preset_i        (preset_q[4*lane+:4]),
            .first_i         (local_fs_q[6*lane+:6]),
            .second_i        (local_lf_q[6*lane+:6]),
            .post_i          (initial_coeff_q[18*lane+:6]),
            .data_o          (tx_data_o[32*lane+:32]),
            .valid_o         (tx_valid_o[lane]),
            .start_o         (tx_start_o[lane]),
            .ts_done_o       (unused_22_ts_done_o),
            .stopped_o       (unused_23_stopped_o),
            .header_o        (tx_header_o[2*lane+:2]),
            .balance_o       (unused_24_balance_o),
            .eq_fields_i     (tx_fields),
            .reset_interval_i(reset_interval && state == PHASE23)
        );
        wire unused_ts = ^{last_ts[127:40], last_ts[38:36], last_ts[34:0]};
    end
    initial begin
        if (LINK_WIDTH != 1 && LINK_WIDTH != 2) $fatal(1, "LINK_WIDTH must be 1 or 2");
        if (TOTAL_CYCLES < 1) $fatal(1, "TOTAL_CYCLES must be positive");
    end
endmodule

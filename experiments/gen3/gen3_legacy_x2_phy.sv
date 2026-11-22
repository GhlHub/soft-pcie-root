// SPDX-License-Identifier: Apache-2.0
// Shared Gen1/Gen2 LTSSM and two 8b/10b lane interfaces. Link ownership is in
// pcie_soft_link. PHY status from the two lanes must use the same user clock.
module gen3_legacy_x2_phy #(
    parameter integer QUIET_CYCLES    = 1500000,
    parameter integer POLL_CYCLES     = 3000000,
    parameter integer CONFIG_CYCLES   = 250000,
    parameter integer RECOVERY_CYCLES = 3000000,
    parameter integer POLL_TX_COUNT   = 1024,
    parameter integer GEN2_ENABLE     = 0,
    parameter integer GEN3_ENABLE     = 0,
    parameter integer TX_PRESET       = 4
) (
    input wire clk, rst_n, enable_i, retrain_i,
    input wire [1:0] phy_ready_i, rx_idle_i, detect_done_i, receiver_present_i,
    input wire force_gen1_i, phy_gen2_i, phy_gen3_i, phy_rate_ready_i,
    output wire detect_o, electrical_idle_o,
    output wire target_gen2_o, target_gen3_o, gen3_handoff_o, speed_idle_o, deemphasis_o,
    output wire [1:0] polarity_o,
    input wire [31:0] phy_rx_data_i,
    input wire [3:0] phy_rx_control_i,
    input wire [1:0] phy_rx_valid_i, phy_rx_error_i,
    output wire [31:0] phy_tx_data_o,
    output wire [3:0] phy_tx_control_o,
    input wire [31:0] tx_symbols_i,
    input wire [3:0] tx_control_i,
    input wire transmitting_i,
    output wire hold_tx_o,
    output wire [31:0] rx_symbols_o,
    output wire [3:0] rx_control_o,
    output wire rx_valid_o, abort_candidate_o,
    output wire l0_o, link_up_o, epoch_started_o, failed_o, retrain_done_o,
    output wire [4:0] state_o,
    output wire [127:0] polling_debug_o
);
    initial if (TX_PRESET < 0 || TX_PRESET > 10) $fatal(1, "Invalid Gen3 Phase 0 TX preset");
    wire train_link_pad, train_lane_pad, trained_l0, align_enable;
    wire [ 1:0] train_kind;
    wire [15:0] train_lane;
    wire [1:0] ts, ts2, inverted, bad_ts, rx_link_pad, rx_lane_pad;
    wire [15:0] rx_link, rx_lane, rx_rate, rx_train_control;
    wire [1:0] sent, boundary, train_valid;
    wire [3:0] sent_kind;
    wire [1:0] rx_idle_sample, rx_idle_pair;
    wire [1:0] final_ts2;
    wire deskew_fault, aligned;
    wire [7:0] train_rate;
    wire eios_request, eios_done, eios_active, phase_zero;
    wire [1:0] codec_kind;
    reg deskew_fault_q, l0_q;
    always @(posedge clk) begin
        deskew_fault_q <= rst_n && deskew_fault;
        l0_q           <= rst_n && l0_o;
    end
    assign l0_o              = trained_l0 && aligned && !deskew_fault;
    assign abort_candidate_o = l0_q && !l0_o;

    wire start_skp, send_skp;
    reg        tail_skp_q;
    reg [10:0] skp_counter_q;
    assign start_skp = !tail_skp_q && skp_counter_q >= 1200 && !transmitting_i && (&boundary) &&
        !electrical_idle_o && !eios_request;
    assign send_skp = start_skp || tail_skp_q;
    assign hold_tx_o = !l0_o || send_skp || (|train_valid);
    always @(posedge clk) begin
        if (!rst_n || electrical_idle_o || tail_skp_q) begin
            skp_counter_q <= 0;
            tail_skp_q    <= 0;
        end else if (start_skp) tail_skp_q <= 1;
        else if (skp_counter_q < 1600) skp_counter_q <= skp_counter_q + 2;
    end
    wire        train_ready = !transmitting_i && !send_skp && !eios_active;
    wire        tx_idle_pair = train_ready && !(|train_valid);
    wire [15:0] eios_symbols;
    if (GEN2_ENABLE != 0) begin : speed_ordered_sets
        localparam integer EIOS_BITS = GEN3_ENABLE == 0 ? 2 : 4;
        reg [EIOS_BITS-1:0] eios_word;
        assign eios_active  = eios_request && (&boundary) && !transmitting_i && !send_skp;
        assign eios_done    = eios_active && eios_word == EIOS_BITS'(target_gen3_o ? 15 : phy_gen2_i ? 3 : 1);
        assign eios_symbols = eios_word[0] ? 16'h7c7c : 16'h7cbc;
        always @(posedge clk) begin
            if (!rst_n || !eios_request) eios_word <= 0;
            else if (eios_active) eios_word <= eios_word + 1'b1;
        end
        reg [5:0] eieos_count;
        reg first_eieos_sent, ts2_seen;
        wire training = phy_gen2_i && (state_o == 11 || state_o == 12);
        wire eieos_due = training && !(state_o == 12 && ts2_seen && train_rate[7]) &&
            (!first_eieos_sent || eieos_count >= 32);
        assign codec_kind = eieos_due && (&boundary) ? 2'd3 : train_kind;
        always @(posedge clk) begin
            if (!rst_n || !training) begin
                eieos_count      <= 0;
                first_eieos_sent <= 0;
                ts2_seen         <= 0;
            end else if ((&sent) && sent_kind == 4'b1111) begin
                eieos_count      <= 0;
                first_eieos_sent <= 1;
            end else if (state_o == 12 && (|(ts & ts2)) && !ts2_seen) begin
                eieos_count <= 0;
                ts2_seen    <= 1;
            end else if ((&sent) && eieos_count < 32) eieos_count <= eieos_count + 1'b1;
        end
    end else begin : fixed_rate_ordered_sets
        assign eios_active  = 0;
        assign eios_done    = 0;
        assign eios_symbols = 0;
        assign codec_kind   = train_kind;
    end
    gen3_multilane_startup #(
        .LINK_WIDTH     (2),
        .QUIET_CYCLES   (QUIET_CYCLES),
        .POLL_CYCLES    (POLL_CYCLES),
        .CONFIG_CYCLES  (CONFIG_CYCLES),
        .RECOVERY_CYCLES(RECOVERY_CYCLES),
        .POLL_TX_COUNT  (POLL_TX_COUNT),
        .GEN2_ENABLE    (GEN2_ENABLE),
        .GEN3_ENABLE    (GEN3_ENABLE)
    ) startup (
        .clk                 (clk),
        .reset_i             (!rst_n),
        .enable_i            (enable_i),
        .phy_ready_i         (phy_ready_i),
        .rx_electrical_idle_i(rx_idle_i),
        .detect_done_i       (detect_done_i),
        .receiver_present_i  (receiver_present_i),
        .ts_valid_i          (ts),
        .ts2_i               (ts2),
        .inverted_i          (inverted),
        .ts_bad_i            (bad_ts),
        .rx_link_i           (rx_link),
        .rx_lane_i           (rx_lane),
        .rx_rate_i           (rx_rate),
        .rx_control_i        (rx_train_control),
        .rx_link_pad_i       (rx_link_pad),
        .rx_lane_pad_i       (rx_lane_pad),
        .tx_ts_done_i        (sent),
        .tx_ts_kind_i        (sent_kind),
        .rx_symbol_valid_i   (rx_idle_sample),
        .rx_idle_pair_i      (rx_idle_pair),
        .tx_idle_pair_i      ({2{tx_idle_pair}}),
        .rx_error_i          (phy_rx_error_i),
        .retrain_i           (retrain_i || deskew_fault_q),
        .force_gen1_i        (force_gen1_i),
        .phy_gen2_i          (phy_gen2_i),
        .phy_gen3_i          (phy_gen3_i),
        .phy_rate_ready_i    (phy_rate_ready_i),
        .eios_done_i         (eios_done),
        .detect_o            (detect_o),
        .electrical_idle_o   (electrical_idle_o),
        .tx_kind_o           (train_kind),
        .tx_lane_o           (train_lane),
        .tx_link_pad_o       (train_link_pad),
        .tx_lane_pad_o       (train_lane_pad),
        .polarity_o          (polarity_o),
        .l0_o                (trained_l0),
        .link_up_o           (link_up_o),
        .epoch_started_o     (epoch_started_o),
        .failed_o            (failed_o),
        .retrain_done_o      (retrain_done_o),
        .state_o             (state_o),
        .rx_alignment_o      (align_enable),
        .tx_rate_o           (train_rate),
        .eios_o              (eios_request),
        .speed_idle_o        (speed_idle_o),
        .target_gen2_o       (target_gen2_o),
        .target_gen3_o       (target_gen3_o),
        .gen3_handoff_o      (gen3_handoff_o),
        .tx_eq_o             (phase_zero),
        .deemphasis_o        (deemphasis_o),
        .polling_debug_o     (polling_debug_o)
    );
    pcie_legacy_x2_rx receive (
        .clk           (clk),
        .rst_n         (rst_n),
        .align_enable_i(align_enable),
        .deliver_i     (trained_l0),
        .final_ts2_i   (final_ts2),
        .lane_data_i   (phy_rx_data_i),
        .lane_control_i(phy_rx_control_i),
        .lane_valid_i  (phy_rx_valid_i),
        .lane_error_i  (phy_rx_error_i),
        .idle_sample_o (rx_idle_sample),
        .idle_pair_o   (rx_idle_pair),
        .symbols_o     (rx_symbols_o),
        .control_o     (rx_control_o),
        .valid_o       (rx_valid_o),
        .aligned_o     (aligned),
        .fault_o       (deskew_fault)
    );
    wire [31:0] striped, unused_stream;
    pcie_lane_stripe #(
        .LANES  (2),
        .SYMBOLS(2)
    ) stripe (
        .stream_i(tx_symbols_i),
        .lanes_o (striped),
        .lanes_i (32'b0),
        .stream_o(unused_stream)
    );
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : lanes
        wire [15:0] training_data;
        wire [1:0] training_control;
        wire [15:0] symbols = transmitting_i ? striped[16*lane+:16] :
            eios_active ? eios_symbols : start_skp ? 16'h1cbc :
            tail_skp_q ? 16'h1c1c : train_valid[lane] ? training_data : 16'b0;
        wire [1:0] control = transmitting_i ? {tx_control_i[lane+2], tx_control_i[lane]} :
            (send_skp || eios_active) ? 2'b11 : train_valid[lane] ? training_control : 2'b0;
        wire unused_tx_ready, unused_tx_valid;
        wire [ 1:0] unused_keep;
        wire [15:0] unused_lfsr;
        assign final_ts2[lane] = ts[lane] && ts2[lane] && !inverted[lane] && !bad_ts[lane] &&
            !rx_link_pad[lane] && !rx_lane_pad[lane] && rx_rate[8*lane+1] && !rx_rate[8*lane+7] &&
            rx_train_control[8*lane+:5] == 0 && rx_link[8*lane+:8] == 0 &&
            rx_lane[8*lane+:8] == 8'(lane);
        if (GEN3_ENABLE != 0) begin : phase_zero_codec
            gen3_legacy_training codec (
                .clk          (clk),
                .rst_n        (rst_n && !speed_idle_o),
                .tx_ready_i   (train_ready),
                .tx_kind_i    (codec_kind),
                .tx_link_i    (8'd0),
                .tx_lane_i    (train_lane[8*lane+:8]),
                .tx_control_i (8'd0),
                .tx_link_pad_i(train_link_pad),
                .tx_lane_pad_i(train_lane_pad),
                .tx_data_o    (training_data),
                .tx_ctrl_o    (training_control),
                .tx_valid_o   (train_valid[lane]),
                .tx_done_o    (sent[lane]),
                .tx_boundary_o(boundary[lane]),
                .tx_kind_o    (sent_kind[2*lane+:2]),
                .rx_data_i    (phy_rx_data_i[16*lane+:16]),
                .rx_ctrl_i    (phy_rx_control_i[2*lane+:2]),
                .rx_valid_i   (phy_rx_valid_i[lane]),
                .rx_error_i   (phy_rx_error_i[lane]),
                .rx_ts_valid_o(ts[lane]),
                .rx_ts2_o     (ts2[lane]),
                .rx_inverted_o(inverted[lane]),
                .rx_bad_o     (bad_ts[lane]),
                .rx_link_o    (rx_link[8*lane+:8]),
                .rx_lane_o    (rx_lane[8*lane+:8]),
                .rx_rate_o    (rx_rate[8*lane+:8]),
                .rx_control_o (rx_train_control[8*lane+:8]),
                .rx_link_pad_o(rx_link_pad[lane]),
                .rx_lane_pad_o(rx_lane_pad[lane]),
                .tx_eq_i      (phase_zero),
                .tx_preset_i  (4'(TX_PRESET)),
                .tx_rate_i    (train_rate)
            );
        end else begin : legacy_codec
            pcie_soft_training codec (
                .clk          (clk),
                .rst_n        (rst_n && !speed_idle_o),
                .tx_ready_i   (train_ready),
                .tx_kind_i    (codec_kind),
                .tx_link_i    (8'd0),
                .tx_lane_i    (train_lane[8*lane+:8]),
                .tx_control_i (8'd0),
                .tx_link_pad_i(train_link_pad),
                .tx_lane_pad_i(train_lane_pad),
                .tx_data_o    (training_data),
                .tx_ctrl_o    (training_control),
                .tx_valid_o   (train_valid[lane]),
                .tx_done_o    (sent[lane]),
                .tx_boundary_o(boundary[lane]),
                .tx_kind_o    (sent_kind[2*lane+:2]),
                .rx_data_i    (phy_rx_data_i[16*lane+:16]),
                .rx_ctrl_i    (phy_rx_control_i[2*lane+:2]),
                .rx_valid_i   (phy_rx_valid_i[lane]),
                .rx_error_i   (phy_rx_error_i[lane]),
                .rx_ts_valid_o(ts[lane]),
                .rx_ts2_o     (ts2[lane]),
                .rx_inverted_o(inverted[lane]),
                .rx_bad_o     (bad_ts[lane]),
                .rx_link_o    (rx_link[8*lane+:8]),
                .rx_lane_o    (rx_lane[8*lane+:8]),
                .rx_rate_o    (rx_rate[8*lane+:8]),
                .rx_control_o (rx_train_control[8*lane+:8]),
                .rx_link_pad_o(rx_link_pad[lane]),
                .rx_lane_pad_o(rx_lane_pad[lane]),
                .tx_rate_i    (train_rate)
            );
            wire unused_phase_zero = phase_zero;
        end
        pcie_soft_scrambler #(.PRECOMPUTE_ADVANCE(GEN3_ENABLE != 0)) scrambler (
            .clk            (clk),
            .rst_n          (rst_n),
            .s_data_i       (symbols),
            .s_ctrl_i       (control),
            .s_keep_i       (2'b11),
            .data_scramble_i({2{!train_valid[lane] || transmitting_i}}),
            .s_valid_i      (1'b1),
            .s_ready_o      (unused_tx_ready),
            .m_data_o       (phy_tx_data_o[16*lane+:16]),
            .m_ctrl_o       (phy_tx_control_o[2*lane+:2]),
            .m_keep_o       (unused_keep),
            .m_valid_o      (unused_tx_valid),
            .m_ready_i      (1'b1),
            .lfsr_o         (unused_lfsr)
        );
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
// Gen3 portion of the native x2 link. Legacy training owns the wire until
// Phase 0 is complete and both PHY lanes have acknowledged the Gen3 rate.
module gen3_x2_port #(
    parameter integer TX_PRESET             = 4,
    parameter integer GUARD_CYCLES          = 125,
    parameter integer REQUEST_CYCLES        = 375000,
    parameter integer EVALUATE_CYCLES       = 25000,
    parameter integer APPLY_CYCLES          = 125,
    parameter integer POSTED_HEADER_CREDITS = 4
) (
    input wire clk, reset_i, phase0_i, handoff_i, legacy_idle_i,
    input wire [1:0] phy_ready_i, rx_idle_i,
    input wire [63:0] rx_data_i,
    input wire [1:0] rx_valid_i, rx_start_i,
    input wire [3:0] rx_header_i,
    input wire [5:0] phy_fs_i, phy_lf_i,
    input wire [35:0] phy_coeff_i, phy_rx_proposal_i,
    input wire [1:0] txeq_done_i, rxeq_done_i, rxeq_adapt_done_i, rxeq_preset_sel_i,
    output wire [3:0] txeq_ctrl_o, rxeq_ctrl_o,
    output wire [7:0] txeq_preset_o, rxeq_preset_o,
    output wire [11:0] txeq_coeff_o,
    output wire rate_allowed_o,
    output reg selected_o,
    output wire [63:0] tx_data_o,
    output wire [1:0] tx_valid_o, tx_start_o,
    output wire [3:0] tx_header_o,
    output wire tx_idle_o, link_up_o, dl_active_o, error_o,
    output wire [4:0] state_o,
    output wire [127:0] completion_debug_o,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire [2:0] cmd_op_i,
    input wire [63:0] cmd_address_i,
    input wire [15:0] cmd_bdf_i,
    input wire [31:0] cmd_data_i,
    input wire [3:0] cmd_be_i,
    output wire rsp_valid_o,
    input wire rsp_ready_i,
    output wire [31:0] rsp_data_o,
    output wire [2:0] rsp_status_o,
    input wire [63:0] app_tx_data_i,
    input wire [1:0] app_tx_words_i,
    input wire app_tx_valid_i, app_tx_last_i,
    output wire app_tx_ready_o,
    input wire [8:0] app_tx_credits_i,
    output wire [63:0] app_rx_data_o,
    output wire [1:0] app_rx_words_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i
);
    localparam [7:0] INITIAL_PRESETS = {2{4'(TX_PRESET)}};
    wire initial_failed;
    wire [3:0] initial_command, adaptive_tx_command;
    wire [11:0] local_fs, local_lf;
    wire [35:0] initial_coefficients, applied_coefficients;
    wire eq_done, eq_failed, eq_active, port_error;
    wire [1:0] eq_phase, restart_interval;
    wire [ 4:0] port_state;
    wire [63:0] eq_fields;
    wire [127:0] eq_failure_debug, packet_debug;
    wire [7:0] adaptive_presets, applied_presets;
    reg  post_start_q;
    wire enter_equalization = handoff_i && rate_allowed_o && !selected_o;
    always @(posedge clk) begin
        if (reset_i) begin
            selected_o   <= 0;
            post_start_q <= 0;
        end else begin
            if (enter_equalization) selected_o <= 1;
            if (eq_done) post_start_q <= 1;
        end
    end
    assign error_o = initial_failed || eq_failed || port_error;
    assign state_o = eq_failed || initial_failed ? 5'd31 :
        port_state != 0 ? port_state : !selected_o ? 5'd0 : eq_phase >= 2 ? 5'd21 : 5'd20;
    assign completion_debug_o = post_start_q ? packet_debug : eq_failure_debug;
    assign txeq_ctrl_o = selected_o ? adaptive_tx_command : initial_command;
    assign txeq_preset_o = eq_active && eq_phase == 2 ? adaptive_presets :
        post_start_q ? applied_presets : INITIAL_PRESETS;
    gen3_x2_initial_eq #(
        .GUARD_CYCLES(GUARD_CYCLES)
    ) phase_zero (
        .clk            (clk),
        .reset_i        (reset_i),
        .request_i      (phase0_i),
        .tx_idle_i      (legacy_idle_i),
        .rx_idle_i      (rx_idle_i),
        .phy_ready_i    (phy_ready_i),
        .txeq_done_i    (txeq_done_i),
        // The generated GTH wrapper exposes identical driver FS/LF for
        // both lanes. Coefficients and completion status remain per-lane.
        .phy_fs_i       ({2{phy_fs_i}}),
        .phy_lf_i       ({2{phy_lf_i}}),
        .phy_coeff_i    (phy_coeff_i),
        .txeq_ctrl_o    (initial_command),
        .ready_o        (rate_allowed_o),
        .failed_o       (initial_failed),
        .local_fs_o     (local_fs),
        .local_lf_o     (local_lf),
        .initial_coeff_o(initial_coefficients)
    );
    gen3_multilane_eq #(
        .LINK_WIDTH     (2),
        .SETTLE_CYCLES  (GUARD_CYCLES),
        .REQUEST_CYCLES (REQUEST_CYCLES),
        .EVALUATE_CYCLES(EVALUATE_CYCLES),
        .APPLY_CYCLES   (APPLY_CYCLES),
        .STANDALONE_TX  (1'b0)
    ) equalization (
        .clk               (clk),
        .reset_i           (reset_i),
        .enter_i           (enter_equalization),
        .cancel_i          (1'b0),
        .phy_ready_i       (phy_ready_i),
        .preset_applied_i  ({2{rate_allowed_o}}),
        .preset_i          (INITIAL_PRESETS),
        .local_fs_i        (local_fs),
        .local_lf_i        (local_lf),
        .initial_coeff_i   (initial_coefficients),
        .rx_data_i         (rx_data_i),
        .rx_valid_i        (rx_valid_i),
        .rx_start_i        (rx_start_i),
        .rx_header_i       (rx_header_i),
        .txeq_done_i       (txeq_done_i),
        .rxeq_done_i       (rxeq_done_i),
        .rxeq_adapt_done_i (rxeq_adapt_done_i),
        .rxeq_preset_sel_i (rxeq_preset_sel_i),
        .txeq_coeff_i      (phy_coeff_i),
        .rxeq_proposal_i   (phy_rx_proposal_i),
        .tx_data_o         (),
        .tx_valid_o        (),
        .tx_start_o        (),
        .tx_header_o       (),
        .txeq_ctrl_o       (adaptive_tx_command),
        .rxeq_ctrl_o       (rxeq_ctrl_o),
        .txeq_preset_o     (adaptive_presets),
        .rxeq_preset_o     (rxeq_preset_o),
        .txeq_coeff_o      (txeq_coeff_o),
        .active_o          (eq_active),
        .done_o            (eq_done),
        .failed_o          (eq_failed),
        .phase_o           (eq_phase),
        .phase1_complete_o (),
        .phase23_complete_o(),
        .tx_fields_o       (eq_fields),
        .restart_interval_o(restart_interval),
        .applied_preset_o  (applied_presets),
        .applied_coeff_o   (applied_coefficients),
        .failure_debug_o   (eq_failure_debug)
    );
    gen3_x2_post_port #(
        .INTEGRATED_EQ        (1'b1),
        .POSTED_HEADER_CREDITS(POSTED_HEADER_CREDITS)
    ) data_link (
        .clk                  (clk),
        .reset_i              (reset_i),
        .start_i              (post_start_q),
        .phy_ready_i          (phy_ready_i),
        .tx_preset_i          (applied_presets),
        .tx_coeff_i           (applied_coefficients),
        .rx_data_i            (rx_data_i),
        .rx_valid_i           (rx_valid_i),
        .rx_start_i           (rx_start_i),
        .rx_header_i          (rx_header_i),
        .tx_data_o            (tx_data_o),
        .tx_valid_o           (tx_valid_o),
        .tx_start_o           (tx_start_o),
        .tx_header_o          (tx_header_o),
        .tx_idle_o            (tx_idle_o),
        .link_up_o            (link_up_o),
        .dl_active_o          (dl_active_o),
        .epoch_o              (),
        .failed_o             (),
        .error_o              (port_error),
        .state_o              (port_state),
        .completion_debug_o   (packet_debug),
        .cmd_valid_i          (cmd_valid_i),
        .cmd_ready_o          (cmd_ready_o),
        .cmd_op_i             (cmd_op_i),
        .cmd_address_i        (cmd_address_i),
        .cmd_bdf_i            (cmd_bdf_i),
        .cmd_data_i           (cmd_data_i),
        .cmd_be_i             (cmd_be_i),
        .rsp_valid_o          (rsp_valid_o),
        .rsp_ready_i          (rsp_ready_i),
        .rsp_data_o           (rsp_data_o),
        .rsp_status_o         (rsp_status_o),
        .app_tx_data_i        (app_tx_data_i),
        .app_tx_words_i       (app_tx_words_i),
        .app_tx_valid_i       (app_tx_valid_i),
        .app_tx_last_i        (app_tx_last_i),
        .app_tx_ready_o       (app_tx_ready_o),
        .app_tx_credits_i     (app_tx_credits_i),
        .app_rx_data_o        (app_rx_data_o),
        .app_rx_words_o       (app_rx_words_o),
        .app_rx_valid_o       (app_rx_valid_o),
        .app_rx_last_o        (app_rx_last_o),
        .app_rx_ready_i       (app_rx_ready_i),
        .eq_active_i          (selected_o && !post_start_q),
        .eq_restart_interval_i(|restart_interval),
        .eq_failed_i          (eq_failed),
        .eq_fields_i          (eq_fields)
    );
endmodule

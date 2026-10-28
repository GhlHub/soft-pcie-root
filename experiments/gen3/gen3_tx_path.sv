// SPDX-License-Identifier: Apache-2.0
// Integrated experimental Gen3 transmit transport and management rate control.
// user_clk is supplied by native BUFG_GT control; all packet/sink inputs are
// synchronous to user_clk. Management requests are synchronous to mgmt_clk.
// Cold reset in each domain is synchronous; never reset this path on Recovery.
module gen3_tx_path #(
    parameter integer TIMEOUT_CYCLES   = 50000,
    parameter integer IDLE_HOLD_CYCLES = 50,
    parameter integer STABLE_CYCLES    = 8,
    parameter integer WINDOW_CYCLES    = 256,
    parameter integer GEN1_EDGES       = 640,
    parameter integer FAST_EDGES       = 1280,
    parameter integer TOLERANCE        = 8,
    parameter integer SKP_INTERVAL     = 372
) (
    input wire mgmt_clk, mgmt_reset_i, user_clk, user_reset_i,
    input wire req_valid_i,
    input wire [1:0] req_rate_i,
    output wire req_ready_o,
    input wire rate_idle_i, user_gen3_ready_i, pll_lock_i,
    input wire tx_reset_done_i, rx_reset_done_i,
    // LTSSM data-stream permission (after training/equalization), user domain.
    input wire data_enable_i,
    input wire [31:0] packet_data_i,
    input wire packet_valid_i, packet_last_i,
    input wire [15:0] packet_id_i,
    output wire packet_ready_o, packet_done_o,
    output wire [15:0] packet_done_id_o,
    output wire [31:0] tx_data_o,
    output wire tx_valid_o, tx_start_o,
    output wire [1:0] tx_header_o,
    output wire submit_o,
    output wire [31:0] submit_token_o,
    input wire complete_i,
    input wire [31:0] complete_token_i,
    // True only after ALL physical transmit stages, including OS, are empty.
    input wire wire_empty_i, legacy_drained_i,
    // PHY acknowledgement of commanded electrical idle, asynchronous level.
    input wire electrical_idle_ack_i,
    output wire electrical_idle_o, quiesce_o,
    output wire [2:0] txrate_o, rxrate_o,
    output wire [1:0] applied_rate_o,
    output wire applied_valid_o, rate_done_o, rate_fault_o, busy_o,
    output wire [3:0] rate_fault_reason_o,
    output wire transport_fault_o, stopped_o,
    output wire clock_sample_o,
    output wire [15:0] clock_edges_o
);
    wire controller_ready, rate_quiesce, scheduler_fault, completion_fault;
    wire packet_last, retire, pending;
    wire [15:0] packet_identity, pending_identity;
    wire [7:0] skp_pending;
    reg stop_source, permit_source, drain_source;
    wire rate_permission = applied_valid_o && applied_rate_o == 2 && !busy_o && !rate_fault_o;
    (* ASYNC_REG="TRUE" *) reg [1:0] stop_sync, permit_sync;
    (* ASYNC_REG="TRUE" *) reg [1:0] drain_sync, idle_sync;
    wire drain_user = stop_sync[1] && stopped_o && !pending && wire_empty_i && legacy_drained_i &&
        !transport_fault_o;
    assign transport_fault_o = scheduler_fault || completion_fault;
    assign quiesce_o         = rate_quiesce;
    // Wait for the preceding four-phase drain acknowledgement to clear before
    // accepting another request. Otherwise a quick second request could reuse it.
    assign req_ready_o       = controller_ready && !drain_sync[1];
    always @(posedge user_clk) begin
        if (user_reset_i) begin
            stop_sync    <= 0;
            permit_sync  <= 0;
            drain_source <= 0;
        end else begin
            stop_sync    <= {stop_sync[0], stop_source};
            permit_sync  <= {permit_sync[0], permit_source};
            drain_source <= drain_user;
        end
    end
    always @(posedge mgmt_clk) begin
        if (mgmt_reset_i) begin
            drain_sync    <= 0;
            idle_sync     <= 0;
            stop_source   <= 0;
            permit_source <= 0;
        end else begin
            stop_source   <= rate_quiesce;
            permit_source <= rate_permission;
            drain_sync    <= {drain_sync[0], drain_source};
            idle_sync     <= {idle_sync[0], electrical_idle_ack_i};
        end
    end
    gen3_phy_control #(
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .IDLE_HOLD_CYCLES(IDLE_HOLD_CYCLES),
        .STABLE_CYCLES   (STABLE_CYCLES),
        .WINDOW_CYCLES   (WINDOW_CYCLES),
        .GEN1_EDGES      (GEN1_EDGES),
        .FAST_EDGES      (FAST_EDGES),
        .TOLERANCE       (TOLERANCE)
    ) physical_control (
        .mgmt_clk             (mgmt_clk),
        .reset_i              (mgmt_reset_i),
        .user_clk             (user_clk),
        .user_reset_i         (user_reset_i),
        .req_valid_i          (req_valid_i && req_ready_o),
        .req_rate_i           (req_rate_i),
        .req_ready_o          (controller_ready),
        .drained_i            (drain_sync[1]),
        .electrical_idle_ack_i(idle_sync[1]),
        .rate_idle_i          (rate_idle_i),
        .user_gen3_ready_i    (user_gen3_ready_i),
        .pll_lock_i           (pll_lock_i),
        .tx_reset_done_i      (tx_reset_done_i),
        .rx_reset_done_i      (rx_reset_done_i),
        .quiesce_o            (rate_quiesce),
        .electrical_idle_o    (electrical_idle_o),
        .txrate_o             (txrate_o),
        .rxrate_o             (rxrate_o),
        .applied_rate_o       (applied_rate_o),
        .applied_valid_o      (applied_valid_o),
        .done_o               (rate_done_o),
        .fault_o              (rate_fault_o),
        .busy_o               (busy_o),
        .fault_reason_o       (rate_fault_reason_o),
        .clock_sample_o       (clock_sample_o),
        .clock_edges_o        (clock_edges_o)
    );
    gen3_tx_schedule #(
        .SKP_INTERVAL(SKP_INTERVAL)
    ) scheduler (
        .clk             (user_clk),
        .reset_i         (user_reset_i),
        .enable_i        (data_enable_i && permit_sync[1] && !completion_fault),
        .stop_i          (stop_sync[1] || !data_enable_i || completion_fault),
        .packet_data_i   (packet_data_i),
        .packet_valid_i  (packet_valid_i),
        .packet_last_i   (packet_last_i),
        .packet_id_i     (packet_id_i),
        .packet_ready_o  (packet_ready_o),
        .retire_i        (retire),
        .wire_drained_i  (wire_empty_i && !pending),
        .packet_done_o   (packet_done_o),
        .packet_done_id_o(packet_done_id_o),
        .tx_data_o       (tx_data_o),
        .tx_valid_o      (tx_valid_o),
        .tx_header_o     (tx_header_o),
        .tx_start_o      (tx_start_o),
        .tx_packet_last_o(packet_last),
        .tx_packet_id_o  (packet_identity),
        .stopped_o       (stopped_o),
        .fault_o         (scheduler_fault),
        .skp_pending_o   (skp_pending)
    );
    gen3_tx_completion completion (
        .clk             (user_clk),
        .reset_i         (user_reset_i),
        .last_i          (packet_last && tx_valid_o),
        .packet_id_i     (packet_identity),
        .submit_o        (submit_o),
        .token_o         (submit_token_o),
        .complete_i      (complete_i),
        .complete_token_i(complete_token_i),
        .retire_o        (retire),
        .pending_o       (pending),
        .fault_o         (completion_fault),
        .pending_packet_o(pending_identity)
    );
    wire unused_diagnostics = ^{skp_pending, pending_identity};
endmodule

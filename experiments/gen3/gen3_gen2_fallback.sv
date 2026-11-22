// SPDX-License-Identifier: Apache-2.0
// Startup-only Gen2 backend on the SAME native PHY. Never activated after Gen3 L0.
// The host shell keeps its 64-bit paths/eight slots. No accepted owner is reset.
module gen3_gen2_fallback #(
    parameter integer QUIET_CYCLES       = 1500000,
                      POLL_CYCLES        = 3000000,
                      CONFIG_CYCLES      = 250000,
    parameter integer COMPLETION_TIMEOUT = 6250000,
    parameter integer IDLE_CYCLES        = 250,
    parameter integer SWITCH_TIMEOUT     = 6000000
) (
    input wire clk, reset_i, start_i,
    input wire phy_ready_i, phystatus_i, rx_idle_i,
    input wire [1:0] initial_rate_i,
    input wire [2:0] rx_status_i,
    input wire [15:0] rx_data_i,
    input wire [1:0] rx_k_i,
    input wire rx_valid_i,
    output wire [15:0] tx_data_o,
    output wire [1:0] tx_k_o,
    output wire detect_o, idle_o, polarity_o, deemphasis_o,
    output wire [1:0] powerdown_o,
    output reg [1:0] rate_o,
    output wire selected_o, link_up_o, dl_active_o, busy_o,
    output wire [4:0] state_o,
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
    input wire [31:0] app_tx_data_i,
    input wire app_tx_valid_i, app_tx_last_i,
    output wire app_tx_ready_o,
    input wire [1:0] app_tx_class_i,
    input wire [8:0] app_tx_credits_i,
    output wire [31:0] app_rx_data_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i,
    output wire error_o,
    output wire [127:0] completion_debug_o,
    input wire force_gen1_i, retrain_i
);
    localparam [2:0] OFF = 0, GUARD = 1, ARM = 2, WAIT_RATE = 3, RUN = 4, FAILED = 5;
    reg [ 2:0] state;
    reg [23:0] timer;
    reg        first_switch;
    wire target_gen2, speed_idle, link_idle, link_detect, link_error, link_fallback;
    wire link_up, dl_active;
    wire [4:0] link_state;
    reg  [1:0] detect_phase;
    wire       run = state == RUN;
    assign selected_o = state != OFF;
    assign state_o    = state == RUN ? link_state : state == FAILED ? 5'd31 : 5'd30;
    assign busy_o     = state != RUN || !link_up;
    // A bounded rate switch pauses the wire, not the accepted ownership epoch.
    // The backend clears its epoch on real link loss; switch failure is terminal.
    wire retained_epoch = !first_switch && state != FAILED;
    wire link_cmd_ready;
    assign link_up_o = retained_epoch && link_up;
    assign dl_active_o = retained_epoch && dl_active;
    assign cmd_ready_o = run && link_cmd_ready;
    assign error_o = state == FAILED || link_error;
    assign idle_o = !run || link_idle;
    assign powerdown_o = run && (link_state == 0 || (link_state == 1 && detect_phase == 0)) ?
        2'b10 : 2'b00;
    reg detect_done, present;
    assign detect_o = run && link_detect && detect_phase == 0;
    always @(posedge clk) begin
        if (reset_i) begin
            state        <= OFF;
            timer        <= 0;
            rate_o       <= 2;
            first_switch <= 1;
            detect_phase <= 0;
            detect_done  <= 0;
            present      <= 0;
        end else begin
            detect_done <= 0;
            if (timer != 24'hffffff) timer <= timer + 1'b1;
            if (!run || !link_detect) detect_phase <= 0;
            else
                case (detect_phase)
                    0:
                    if (phystatus_i) begin
                        present <= rx_status_i == 3;
                        if (rx_status_i == 3) detect_phase <= 1;
                        else begin
                            detect_phase <= 2;
                            detect_done  <= 1;
                        end
                    end
                    1:
                    if (phystatus_i) begin
                        detect_phase <= 2;
                        detect_done  <= 1;
                    end
                    default: begin
                    end
                endcase
            case (state)
                OFF:
                if (start_i) begin
                    state  <= GUARD;
                    timer  <= 0;
                    rate_o <= initial_rate_i;
                end
                GUARD:
                if (int'(timer) >= IDLE_CYCLES) begin
                    state <= ARM;
                    timer <= 0;
                end
                ARM:
                if (!phystatus_i && phy_ready_i) begin
                    rate_o <= first_switch ? 0 : {1'b0, target_gen2};
                    state  <= first_switch && rate_o == 0 ? RUN : WAIT_RATE;
                    if (first_switch && rate_o == 0) first_switch <= 0;
                    timer <= 0;
                end
                WAIT_RATE:
                if (phystatus_i && phy_ready_i) begin
                    state        <= RUN;
                    first_switch <= 0;
                    timer        <= 0;
                end
                RUN:
                if (speed_idle && rate_o != {1'b0, target_gen2}) begin
                    state <= GUARD;
                    timer <= 0;
                end
                default: begin
                end
            endcase
            if (state != OFF && state != RUN && state != FAILED &&
                int'(timer) >= SWITCH_TIMEOUT - 1)
                state <= FAILED;
        end
    end
    // Hold only the never-used backend in reset before its FIRST rate switch.
    // Later speed changes pause its own LTSSM and preserve every owner.
    wire link_reset_n = !reset_i && !first_switch;
    wire unused_target_gen3, unused_gen3_handoff;
    pcie_soft_link #(
        .GEN2_ENABLE       (1),
        .QUIET_CYCLES      (QUIET_CYCLES),
        .POLL_CYCLES       (POLL_CYCLES),
        .CONFIG_CYCLES     (CONFIG_CYCLES),
        .COMPLETION_TIMEOUT(COMPLETION_TIMEOUT)
    ) link (
        .clk               (clk),
        .rst_n             (link_reset_n),
        .enable_i          (1'b1),
        .phy_ready_i       (phy_ready_i),
        .rx_idle_i         (rx_idle_i),
        .detect_done_i     (detect_done),
        .receiver_present_i(present),
        .detect_o          (link_detect),
        .electrical_idle_o (link_idle),
        .polarity_o        (polarity_o),
        .phy_rx_data_i     (rx_data_i),
        .phy_rx_ctrl_i     (rx_k_i),
        .phy_rx_valid_i    (rx_valid_i && run),
        .phy_rx_error_i    (rx_valid_i && rx_status_i[2]),
        .phy_tx_data_o     (tx_data_o),
        .phy_tx_ctrl_o     (tx_k_o),
        .link_up_o         (link_up),
        .dl_active_o       (dl_active),
        .state_o           (link_state),
        .retrain_i         (retrain_i),
        .cmd_valid_i       (cmd_valid_i && run),
        .cmd_ready_o       (link_cmd_ready),
        .cmd_op_i          (cmd_op_i),
        .cmd_address_i     (cmd_address_i),
        .cmd_bdf_i         (cmd_bdf_i),
        .cmd_data_i        (cmd_data_i),
        .cmd_be_i          (cmd_be_i),
        .rsp_valid_o       (rsp_valid_o),
        .rsp_ready_i       (rsp_ready_i),
        .rsp_data_o        (rsp_data_o),
        .rsp_status_o      (rsp_status_o),
        .app_tx_data_i     (app_tx_data_i),
        .app_tx_valid_i    (app_tx_valid_i),
        .app_tx_last_i     (app_tx_last_i),
        .app_tx_ready_o    (app_tx_ready_o),
        .app_tx_class_i    (app_tx_class_i),
        .app_tx_credits_i  (app_tx_credits_i),
        .app_rx_data_o     (app_rx_data_o),
        .app_rx_valid_o    (app_rx_valid_o),
        .app_rx_last_o     (app_rx_last_o),
        .app_rx_ready_i    (app_rx_ready_i),
        .completion_debug_o(completion_debug_o),
        .error_o           (link_error),
        .force_gen1_i      (force_gen1_i),
        .phy_gen2_i        (rate_o == 1),
        .phy_rate_ready_i  (run),
        .target_gen2_o     (target_gen2),
        .speed_idle_o      (speed_idle),
        .fallback_o        (link_fallback),
        .deemphasis_o      (deemphasis_o),
        .phy_gen3_i        (1'b0),
        .target_gen3_o     (unused_target_gen3),
        .gen3_handoff_o    (unused_gen3_handoff)
    );
    wire unused = link_fallback;
endmodule

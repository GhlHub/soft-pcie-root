// Isolated OP063 SSD-A hardware shell. Control/application ports use core_clk_o.
// External reset and 50MHz management enable must be stable at freerun clock.
// PERST outputs are FPGA-facing active HIGH (OP063 performs inversion).
module pcie_soft_root_port #(
    parameter integer GEN2_ENABLE       = 1,
    parameter integer PERST_HOLD_CYCLES = 5000000
) (
    input wire freerun_clk_i, reset_i, enable_i,
    input wire refclk_p_i, refclk_n_i, rx_p_i, rx_n_i,
    output wire tx_p_o, tx_n_o, core_clk_o,
    output wire perst_a_o, perst_b_o, disable_ssd2_power_o,
    input wire retrain_i,
    output wire link_up_o, dl_active_o,
    output wire [4:0] state_o,
    output wire [15:0] diagnostic_o,
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
    input wire force_gen1_i,
    output wire gen2_o, rate_busy_o, fallback_o
);
    localparam integer PW = $clog2(PERST_HOLD_CYCLES + 1);
    reg [PW-1:0] perst_count_q = 0;
    reg          perst_asserted_q = 1;
    always @(posedge freerun_clk_i) begin
        if (reset_i || !enable_i) begin
            perst_count_q    <= 0;
            perst_asserted_q <= 1;
        end else if (perst_count_q < PW'(PERST_HOLD_CYCLES)) begin
            perst_count_q <= perst_count_q + 1'b1;
            if (perst_count_q == PW'(PERST_HOLD_CYCLES - 1)) perst_asserted_q <= 0;
        end
    end
    // Drive the physical reset from a flop. A binary-counter comparator can
    // glitch during carry propagation even while its sampled value is correct.
    assign perst_a_o            = perst_asserted_q;
    assign perst_b_o            = 1'b1;
    assign disable_ssd2_power_o = 1'b1;
    wire       core_reset = reset_i || perst_a_o;
    (* ASYNC_REG="TRUE" *)reg  [2:0] release_q = 0;
    // The sole asynchronous-reset logic outside the vendor PHY is the reset
    // synchronizer. It asserts even if the GTH-generated user clock is stopped.
    always @(posedge core_clk_o or posedge core_reset)
        if (core_reset) release_q <= 0;
        else release_q <= {release_q[1:0], 1'b1};
    wire ready, rx_idle, detect_done, present, detect, eidle, polarity;
    wire [15:0] tx_data, rx_data;
    wire [1:0] tx_ctrl, rx_ctrl;
    wire rx_valid, rx_error;
    wire [11:0] phy_diagnostic;
    wire target_gen2, speed_idle, rate_ready, rate_fault, deemphasis;
    (* ASYNC_REG="TRUE" *) reg [2:0] policy_sync_q = 7;
    always @(posedge core_clk_o) policy_sync_q <= {policy_sync_q[1:0], force_gen1_i};
    assign rate_busy_o  = speed_idle;

    assign diagnostic_o = {detect, eidle, release_q[2], perst_a_o, phy_diagnostic};
    pcie_soft_gth phy (
        freerun_clk_i,
        reset_i,
        refclk_p_i,
        refclk_n_i,
        rx_p_i,
        rx_n_i,
        tx_p_o,
        tx_n_o,
        core_clk_o,
        tx_data,
        tx_ctrl,
        detect,
        eidle,
        polarity,
        rx_data,
        rx_ctrl,
        rx_valid,
        rx_error,
        ready,
        detect_done,
        present,
        rx_idle,
        phy_diagnostic,
        target_gen2,
        speed_idle,
        gen2_o,
        rate_ready,
        rate_fault,
        deemphasis
    );
    pcie_soft_link #(
        .GEN2_ENABLE(GEN2_ENABLE)
    ) controller (
        .clk               (core_clk_o),
        .rst_n             (release_q[2]),
        .enable_i          (1'b1),
        .force_gen1_i      (policy_sync_q[2]),
        .phy_gen2_i        (gen2_o),
        .phy_rate_ready_i  (rate_ready),
        .target_gen2_o     (target_gen2),
        .speed_idle_o      (speed_idle),
        .fallback_o        (fallback_o),
        .deemphasis_o      (deemphasis),
        .phy_ready_i       (ready && !rate_fault),
        .rx_idle_i         (rx_idle),
        .detect_done_i     (detect_done),
        .receiver_present_i(present),
        .detect_o          (detect),
        .electrical_idle_o (eidle),
        .polarity_o        (polarity),
        .phy_rx_data_i     (rx_data),
        .phy_rx_ctrl_i     (rx_ctrl),
        .phy_rx_valid_i    (rx_valid),
        .phy_rx_error_i    (rx_error),
        .phy_tx_data_o     (tx_data),
        .phy_tx_ctrl_o     (tx_ctrl),
        .link_up_o         (link_up_o),
        .dl_active_o       (dl_active_o),
        .state_o           (state_o),
        .retrain_i         (retrain_i),
        .cmd_valid_i       (cmd_valid_i),
        .cmd_ready_o       (cmd_ready_o),
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
        .error_o           (error_o),
        .completion_debug_o(completion_debug_o)
    );
endmodule

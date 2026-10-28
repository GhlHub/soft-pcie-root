// SPDX-License-Identifier: Apache-2.0
// Shared TX/RX user-clock qualification for the native PCIe PHY. The generated
// native clock path (gen3_native_clock) supplies user_clk; no fabric clock mux.
// Cold reset inputs must be synchronous in their respective domains. The
// outer initialization controller still owns GT/CPLL/QPLL reset/calibration.
module gen3_phy_control #(
    parameter integer TIMEOUT_CYCLES   = 50000,
    parameter integer IDLE_HOLD_CYCLES = 50,
    parameter integer STABLE_CYCLES    = 8,
    parameter integer WINDOW_CYCLES    = 256,
    parameter integer GEN1_EDGES       = 640,
    parameter integer FAST_EDGES       = 1280,
    parameter integer TOLERANCE        = 8
) (
    input wire mgmt_clk, reset_i, user_clk, user_reset_i,
    input wire req_valid_i,
    input wire [1:0] req_rate_i,
    output wire req_ready_o,
    input wire drained_i, electrical_idle_ack_i,
    input wire rate_idle_i, user_gen3_ready_i, pll_lock_i,
    input wire tx_reset_done_i, rx_reset_done_i,
    output wire quiesce_o, electrical_idle_o,
    output wire [2:0] txrate_o, rxrate_o,
    output wire [1:0] applied_rate_o,
    output wire applied_valid_o, done_o, fault_o, busy_o,
    output wire [3:0] fault_reason_o,
    output wire clock_sample_o,
    output wire [15:0] clock_edges_o
);
    wire check_clock, clock_ready;
    wire [1:0] gt_rate;
    assign txrate_o = {1'b0, gt_rate};
    assign rxrate_o = {1'b0, gt_rate};
    gen3_clock_watch #(
        .WINDOW_CYCLES(WINDOW_CYCLES),
        .GEN1_EDGES   (GEN1_EDGES),
        .FAST_EDGES   (FAST_EDGES),
        .TOLERANCE    (TOLERANCE)
    ) watch_clock (
        .user_clk    (user_clk),
        .user_reset_i(user_reset_i),
        .mgmt_clk    (mgmt_clk),
        .reset_i     (reset_i),
        .check_i     (check_clock),
        .rate_i      (gt_rate),
        .ready_o     (clock_ready),
        .sample_o    (clock_sample_o),
        .measured_o  (clock_edges_o)
    );
    gen3_phy_rate #(
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .IDLE_HOLD_CYCLES(IDLE_HOLD_CYCLES),
        .STABLE_CYCLES   (STABLE_CYCLES)
    ) rate_control (
        .clk                  (mgmt_clk),
        .reset_i              (reset_i),
        .req_valid_i          (req_valid_i),
        .req_rate_i           (req_rate_i),
        .req_ready_o          (req_ready_o),
        .drained_i            (drained_i),
        .electrical_idle_ack_i(electrical_idle_ack_i),
        .rate_idle_i          (rate_idle_i),
        .user_gen3_ready_i    (user_gen3_ready_i),
        .pll_lock_i           (pll_lock_i),
        .tx_reset_done_i      (tx_reset_done_i),
        .rx_reset_done_i      (rx_reset_done_i),
        .clocks_ready_i       (clock_ready),
        .quiesce_o            (quiesce_o),
        .electrical_idle_o    (electrical_idle_o),
        .clock_check_o        (check_clock),
        .gt_rate_o            (gt_rate),
        .applied_rate_o       (applied_rate_o),
        .applied_valid_o      (applied_valid_o),
        .done_o               (done_o),
        .fault_o              (fault_o),
        .fault_reason_o       (fault_reason_o),
        .busy_o               (busy_o)
    );
endmodule

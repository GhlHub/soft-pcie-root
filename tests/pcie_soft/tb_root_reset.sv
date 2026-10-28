`timescale 1ns / 1ps
// Digital PHY stand-in ONLY for reset/power sequencing. The real PHY is
// separately synthesized; this model makes no serial/analog/link claim.
module pcie_soft_gth (
    input wire freerun_clk_i, reset_i, refclk_p_i, refclk_n_i, rx_p_i, rx_n_i,
    output wire tx_p_o, tx_n_o, core_clk_o,
    input wire [15:0] tx_data_i,
    input wire [1:0] tx_ctrl_i,
    input wire detect_i, electrical_idle_i, polarity_i,
    output wire [15:0] rx_data_o,
    output wire [1:0] rx_ctrl_o,
    output wire rx_valid_o, rx_error_o, ready_o, detect_done_o, receiver_present_o, rx_idle_o,
    output wire [11:0] diagnostic_o,
    input wire target_gen2_i, speed_idle_i,
    output wire gen2_o, rate_ready_o, rate_fault_o,
    input wire deemphasis_i
);
    reg clock_q = 0, running = 1;
    always #4 if (running) clock_q = ~clock_q;
    assign core_clk_o         = clock_q;
    assign tx_p_o             = 0;
    assign tx_n_o             = 1;
    assign rx_data_o          = 0;
    assign rx_ctrl_o          = 0;
    assign rx_valid_o         = 0;
    assign rx_error_o         = 0;
    assign ready_o            = !reset_i;
    assign detect_done_o      = 0;
    assign receiver_present_o = 0;
    assign rx_idle_o          = 1;
    assign gen2_o             = target_gen2_i;
    assign rate_ready_o       = 1;
    assign rate_fault_o       = 0;
    assign diagnostic_o       = 12'h1ff;
endmodule
module tb_root_reset;
    reg freerun = 0;
    always #10 freerun = ~freerun;
    reg reset = 1, enable = 0;
    wire core, pa, pb, power, up, active, cmdready, rspvalid, atready, arvalid, arlast, error;
    wire txp, txn;
    wire [4:0] state;
    wire [31:0] response, appdata;
    wire [2:0] status;
    pcie_soft_root_port #(
        .PERST_HOLD_CYCLES(8)
    ) dut (
        .force_gen1_i        (1'b1),
        .gen2_o              (),
        .rate_busy_o         (),
        .fallback_o          (),
        .freerun_clk_i       (freerun),
        .reset_i             (reset),
        .enable_i            (enable),
        .refclk_p_i          (1'b0),
        .refclk_n_i          (1'b1),
        .rx_p_i              (1'b0),
        .rx_n_i              (1'b1),
        .tx_p_o              (txp),
        .tx_n_o              (txn),
        .core_clk_o          (core),
        .perst_a_o           (pa),
        .perst_b_o           (pb),
        .disable_ssd2_power_o(power),
        .retrain_i           (1'b0),
        .link_up_o           (up),
        .dl_active_o         (active),
        .state_o             (state),
        .diagnostic_o        (),
        .cmd_valid_i         (1'b0),
        .cmd_ready_o         (cmdready),
        .cmd_op_i            (3'b0),
        .cmd_address_i       (64'b0),
        .cmd_bdf_i           (16'b0),
        .cmd_data_i          (32'b0),
        .cmd_be_i            (4'hf),
        .rsp_valid_o         (rspvalid),
        .rsp_ready_i         (1'b1),
        .rsp_data_o          (response),
        .rsp_status_o        (status),
        .app_tx_data_i       (32'b0),
        .app_tx_valid_i      (1'b0),
        .app_tx_last_i       (1'b0),
        .app_tx_ready_o      (atready),
        .app_tx_class_i      (2'b0),
        .app_tx_credits_i    (9'b0),
        .app_rx_data_o       (appdata),
        .app_rx_valid_o      (arvalid),
        .app_rx_last_o       (arlast),
        .app_rx_ready_i      (1'b1),
        .error_o             (error)
    );
    initial begin
        repeat (3) @(negedge freerun);
        reset  = 0;
        enable = 1;
        repeat (7) begin
            @(posedge freerun);
            #1;
            if (!pa) $fatal(1, "PERST released early");
        end
        @(posedge freerun);
        #1;
        if (pa || !pb || !power) $fatal(1, "PERST/SSD B power policy");
        repeat (4) @(negedge core);
        if (!dut.release_q[2]) $fatal(1, "Core reset did not release");
        force dut.controller.ltssm.target_gen2_o = 1'b1;
        wait (core == 0);
        dut.phy.running = 0;
        release dut.controller.ltssm.target_gen2_o;
        @(negedge freerun);
        enable = 0;
        @(posedge freerun);
        #1;
        if (dut.phy.target_gen2_i !== 0)
            $fatal(1, "Stopped clock retained native Gen2 rate through reset");
        if (!pa || dut.release_q !== 0) $fatal(1, "Stopped-clock reset did not assert");
        @(negedge freerun);
        enable = 1;
        repeat (8) @(posedge freerun);
        #1;
        if (pa || dut.release_q !== 0) $fatal(1, "Stopped core released reset without clocks");
        dut.phy.running = 1;
        repeat (2) begin
            @(posedge core);
            #1;
            if (dut.release_q[2]) $fatal(1, "Reset release too early");
        end
        @(posedge core);
        #1;
        if (!dut.release_q[2]) $fatal(1, "Reset release synchronizer failed");
        $display(
            "PASS root shell: PERST hold, SSD B safe state, clock-stopped assertion and three-edge reset release (digital PHY stand-in)"
                );
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Reset watchdog");
    end
endmodule

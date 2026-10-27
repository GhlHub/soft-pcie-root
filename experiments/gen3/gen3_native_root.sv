// SPDX-License-Identifier: Apache-2.0
// Experimental native Gen3 PHY adapter for the unchanged host/DMA shell.
// Enable is latched for the cold boot. Deasserting enable cannot reset accepted
// ownership. No live reconfiguration, hot removal or stopped-clock recovery.
module gen3_native_root(
 input wire freerun_clk_i,reset_i,enable_i,
 input wire refclk_p_i,refclk_n_i,rx_p_i,rx_n_i,
 output wire tx_p_o,tx_n_o,core_clk_o,
 output wire perst_a_o,perst_b_o,disable_ssd2_power_o,
 input wire retrain_i,
 output wire link_up_o,dl_active_o,
 output wire [4:0] state_o,
 output reg [15:0] diagnostic_o,
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
 input wire app_tx_valid_i,app_tx_last_i,
 output wire app_tx_ready_o,
 input wire [1:0] app_tx_class_i,
 input wire [8:0] app_tx_credits_i,
 output wire [31:0] app_rx_data_o,
 output wire app_rx_valid_o,app_rx_last_o,
 input wire app_rx_ready_i,
 output wire error_o,
 output reg [127:0] completion_debug_o,
 input wire force_gen1_i,
 output wire gen2_o,rate_busy_o,fallback_o
);

    wire gtref,rawref,refclk,pclk;
    IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) reference_clock(
        .I(refclk_p_i),.IB(refclk_n_i),.CEB(1'b0),.O(gtref),.ODIV2(rawref));
    BUFG_GT management_clock(.I(rawref),.CE(1'b1),.CEMASK(1'b0),.CLR(1'b0),
        .CLRMASK(1'b0),.DIV(3'b0),.O(refclk));
    assign core_clk_o=pclk;
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_sync=7;
    (* ASYNC_REG="TRUE" *) reg [1:0] enable_sync=0;
    reg started=0;
    reg [23:0] hold_count=0;
    reg release_phy=0,release_ssd=0;
    always @(posedge refclk)begin
        reset_sync<={reset_sync[1:0],reset_i};
        enable_sync<={enable_sync[0],enable_i};
        if(reset_sync[2])begin started<=0;hold_count<=0;release_phy<=0;release_ssd<=0;end
        else begin
            if(enable_sync[1])started<=1;
            if(started && hold_count<10000000)hold_count<=hold_count+1'b1;
            release_phy<=started && hold_count>=100000;
            release_ssd<=started && hold_count>=10000000;
        end
    end
    assign perst_a_o=!release_ssd;
    assign perst_b_o=1;
    assign disable_ssd2_power_o=1;
    wire phystatus_rst,phystatus,powergood;
    wire [63:0] rx_data;wire [1:0] rx_k,rx_start,rx_header;
    wire rx_valid,rx_data_valid,rx_idle;
    wire [2:0] rx_status;
    wire [31:0] tx_data;wire [1:0] tx_k,tx_header,rate,txeq_ctrl,powerdown;
    wire tx_valid,tx_start,detect,idle,polarity;
    wire [3:0] txeq_preset;
    wire [5:0] txeq_fs,txeq_lf;wire [17:0] txeq_coeff;
    wire txeq_done;
    wire [63:0] phy_diag;
    (* ASYNC_REG="TRUE" *) reg [2:0] release_sync=0;
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync=0,idle_sync=3;
    always @(posedge pclk)begin
        release_sync<={release_sync[1:0],release_ssd};
        ready_sync<={ready_sync[0],!phystatus_rst};
        idle_sync<={idle_sync[0],rx_idle};
    end
    wire reset=!release_sync[2];
    wire [127:0] status,last_ts;
    reg detect_source=0;
    always @(posedge pclk)begin
        if(reset)begin detect_source<=0;diagnostic_o<=0;completion_debug_o<=0;end
        else begin
            detect_source<=status[4:0]==0 && status[9:5]<=1;
            diagnostic_o<={8'b0,rate,ready_sync[1],idle_sync[1],detect,idle,phystatus,rx_valid};
            completion_debug_o<=last_ts;
        end
    end
    assign state_o=status[4:0];
    assign link_up_o=status[4:0]==18;
    assign rate_busy_o=status[4:0]!=18;
    assign gen2_o=0; // ABI bit denotes Gen2, not generic high-speed operation.
    assign fallback_o=0;
    gen3_eq_bringup #(.DATALINK_ENABLE(1),.RECOVERY_ENABLE(1),.OBSERVE_CYCLES(0)) experiment(
        .clk(pclk),.reset_i(reset),.phy_ready_i(ready_sync[1]),.preset_i(4'd4),
        .rx_data_i(rx_data[31:0]),.rx_k_i(rx_k),.rx_valid_i(rx_valid),.rx_data_valid_i(rx_data_valid),
        .rx_start_i(rx_start[0]),.rx_header_i(rx_header),.rx_idle_i(idle_sync[1]),.phystatus_i(phystatus),.rx_status_i(rx_status),
        .txeq_done_i(txeq_done),.txeq_fs_i(txeq_fs),.txeq_lf_i(txeq_lf),.txeq_coeff_i(txeq_coeff),
        .tx_data_o(tx_data),.tx_k_o(tx_k),.tx_header_o(tx_header),.tx_valid_o(tx_valid),.tx_start_o(tx_start),
        .detect_o(detect),.idle_o(idle),.polarity_o(polarity),.rate_o(rate),.txeq_ctrl_o(txeq_ctrl),.txeq_preset_o(txeq_preset),
        .last_ts_o(last_ts),.status_o(status),.powerdown_o(powerdown),
        .cmd_valid_i(cmd_valid_i),.cmd_ready_o(cmd_ready_o),.cmd_op_i(cmd_op_i),.cmd_address_i(cmd_address_i),.cmd_bdf_i(cmd_bdf_i),
        .cmd_data_i(cmd_data_i),.cmd_be_i(cmd_be_i),.rsp_valid_o(rsp_valid_o),.rsp_ready_i(rsp_ready_i),.rsp_data_o(rsp_data_o),.rsp_status_o(rsp_status_o),
        .app_tx_data_i(app_tx_data_i),.app_tx_valid_i(app_tx_valid_i),.app_tx_last_i(app_tx_last_i),.app_tx_ready_o(app_tx_ready_o),
        .app_tx_class_i(app_tx_class_i),.app_tx_credits_i(app_tx_credits_i),.app_rx_data_o(app_rx_data_o),.app_rx_valid_o(app_rx_valid_o),
        .app_rx_last_o(app_rx_last_o),.app_rx_ready_i(app_rx_ready_i),.dl_active_o(dl_active_o),.link_error_o(error_o));
    gen3_reference_phy phy (
        .eq_diag(phy_diag),
        .phy_refclk(refclk),.phy_gtrefclk(gtref),.phy_rst_n(release_phy),
        .phy_txdata({32'b0,tx_data}),.phy_txdatak(tx_k),.phy_txdata_valid(tx_valid),
        .phy_txstart_block(tx_start),.phy_txsync_header(tx_header),
        .phy_rxp(rx_p_i),.phy_rxn(rx_n_i),.phy_txp(tx_p_o),.phy_txn(tx_n_o),
        .phy_txdetectrx(detect),.phy_txelecidle(idle || reset),.phy_txcompliance(1'b0),
        .phy_rxpolarity(polarity),.phy_powerdown(powerdown),
        .phy_rate(rate),.phy_txmargin(3'b0),.phy_txswing(1'b0),.phy_txdeemph(1'b1),
        .phy_txeq_ctrl(txeq_ctrl),.phy_txeq_preset(txeq_preset),.phy_txeq_coeff(6'b0),
        .phy_rxeq_ctrl(2'b0),.phy_rxeq_txpreset(4'b0),
        .as_mac_in_detect(detect_source),.as_cdr_hold_req(1'b0),
        .phy_coreclk(),.phy_userclk(),.phy_mcapclk(),.phy_pclk(pclk),
        .phy_rxdata(rx_data),.phy_rxdatak(rx_k),.phy_rxdata_valid(rx_data_valid),
        .phy_rxstart_block(rx_start),.phy_rxsync_header(rx_header),.phy_rxvalid(rx_valid),
        .phy_phystatus(phystatus),.phy_phystatus_rst(phystatus_rst),
        .phy_rxelecidle(rx_idle),.phy_rxstatus(rx_status),
        .phy_txeq_fs(txeq_fs),.phy_txeq_lf(txeq_lf),.phy_txeq_new_coeff(txeq_coeff),
        .phy_txeq_done(txeq_done),.phy_rxeq_preset_sel(),.phy_rxeq_new_txcoeff(),
        .phy_rxeq_adapt_done(),.phy_rxeq_done(),.gt_gtpowergood(powergood));

    wire unused=^{freerun_clk_i,retrain_i,force_gen1_i,phy_diag,powergood,rx_data[63:32],rx_start[1]};
endmodule

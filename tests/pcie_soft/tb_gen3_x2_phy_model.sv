// SPDX-License-Identifier: Apache-2.0
// Behavioral clock and native PIPE test boundary. The peer supplies the
// transceiver indications. Analog behavior and the GT clock model are out of scope.
module IBUFDS_GTE4 #(
    parameter [1:0] REFCLK_HROW_CK_SEL = 0
) (
    input wire I, IB, CEB,
    output wire O, ODIV2
);
    assign O     = I;
    assign ODIV2 = I;
endmodule

module BUFG_GT (
    input wire I, CE, CEMASK, CLR, CLRMASK,
    input wire [2:0] DIV,
    output wire O
);
    assign O = I;
endmodule

module gen3_reference_phy_x2 (
    input wire phy_refclk, phy_gtrefclk, phy_rst_n,
    input wire [127:0] phy_txdata,
    input wire [3:0] phy_txdatak,
    input wire [1:0] phy_txdata_valid, phy_txstart_block,
    input wire [3:0] phy_txsync_header,
    input wire [1:0] phy_rxp, phy_rxn,
    output wire [1:0] phy_txp, phy_txn,
    input wire phy_txdetectrx,
    input wire [1:0] phy_txelecidle, phy_txcompliance, phy_rxpolarity, phy_powerdown, phy_rate,
    input wire [2:0] phy_txmargin,
    input wire phy_txswing, phy_txdeemph,
    input wire [3:0] phy_txeq_ctrl, phy_rxeq_ctrl,
    input wire [7:0] phy_txeq_preset, phy_rxeq_txpreset,
    input wire [11:0] phy_txeq_coeff,
    input wire as_mac_in_detect, as_cdr_hold_req,
    output wire phy_coreclk, phy_userclk, phy_mcapclk, phy_pclk,
    output wire [127:0] phy_rxdata,
    output wire [3:0] phy_rxdatak,
    output wire [1:0] phy_rxdata_valid,
    output wire [3:0] phy_rxstart_block, phy_rxsync_header,
    output wire [1:0] phy_rxvalid, phy_phystatus, phy_rxelecidle,
    output wire phy_phystatus_rst,
    output wire [5:0] phy_rxstatus, phy_txeq_fs, phy_txeq_lf,
    output wire [35:0] phy_txeq_new_coeff, phy_rxeq_new_txcoeff,
    output wire [1:0] phy_txeq_done, phy_rxeq_done, phy_rxeq_adapt_done, phy_rxeq_preset_sel,
    output wire [1:0] gt_gtpowergood,
    output wire [63:0] eq_diag
);
    assign phy_pclk = phy_refclk;
    assign phy_txp = 0;
    assign phy_txn = 0;
    assign {phy_coreclk, phy_userclk, phy_mcapclk, eq_diag} = 0;
    assign phy_phystatus_rst = !phy_rst_n;
    assign gt_gtpowergood = 2'b11;
    assign phy_rxdata = tb.rx_bus;
    assign phy_rxdatak = tb.rx_k_bus;
    assign phy_rxvalid = tb.rx_wire_valid;
    assign phy_rxdata_valid = {tb.rx_valid[0], tb.rx_valid[1]};
    assign phy_rxstart_block = {1'b0, tb.rx_start[0], 1'b0, tb.rx_start[1]};
    assign phy_rxsync_header = {tb.rx_header[1:0], tb.rx_header[3:2]};
    assign phy_rxelecidle = {2{tb.peer_idle}};
    assign phy_phystatus = {tb.rate_done[0], tb.rate_done[1]};
    assign phy_rxstatus = 6'b011011;
    assign phy_txeq_done = {tb.tx_done[0], tb.tx_done[1]};
    assign phy_rxeq_done = {tb.rx_done[0], tb.rx_done[1]};
    assign phy_rxeq_adapt_done = 2'b11;
    assign phy_rxeq_preset_sel = 0;
    assign phy_txeq_fs = 40;
    assign phy_txeq_lf = 12;
    assign phy_txeq_new_coeff = {2{{6'd0, 6'd40, 6'd0}}};
    assign phy_rxeq_new_txcoeff = 0;
endmodule

// Real AMD GTH PHY only: no hard PCIe block. Core/RX use the TX 125MHz clock.
// RX native elastic-buffer SKP clock correction is configured by the generator.
// freerun_clk_i=50MHz, OP063 reference=100MHz; no packet-side backpressure.
module pcie_soft_gth(
 input wire freerun_clk_i,reset_i,
 input wire refclk_p_i,refclk_n_i,rx_p_i,rx_n_i,
 output wire tx_p_o,tx_n_o,core_clk_o,
 input wire [15:0] tx_data_i,
 input wire [1:0] tx_ctrl_i,
 input wire detect_i,electrical_idle_i,polarity_i,
 output wire [15:0] rx_data_o,
 output wire [1:0] rx_ctrl_o,
 output wire rx_valid_o,rx_error_o,
 output wire ready_o,detect_done_o,receiver_present_o,rx_idle_o,
 output wire [11:0] diagnostic_o,
 input wire target_gen2_i,speed_idle_i,
 output wire gen2_o,rate_ready_o,rate_fault_o,input wire deemphasis_i
);
 wire refclk,txactive,txpma,rxpma,txdone,rxdone,lock,powergood,aligned,idle,phystatus;
 wire [15:0] rxctrl0,rxctrl1;
 wire [7:0] rxctrl2,rxctrl3;
 wire [2:0] rxstatus,bufstatus;
 wire [1:0] power_state=electrical_idle_i&&!speed_idle_i?2'b10:2'b00;
 wire rate_idle,rate_applied,rate_busy,rate_fault;
 (* ASYNC_REG="TRUE" *) reg [2:0] rate_meta_q=0,rate_mid_q=0,rate_sync_q=0;
 always @(posedge core_clk_o)begin
  rate_meta_q<={rate_fault,rate_busy,rate_applied};rate_mid_q<=rate_meta_q;rate_sync_q<=rate_mid_q;
 end
 assign gen2_o=rate_sync_q[0];assign rate_fault_o=rate_sync_q[2];
 assign rate_ready_o=!rate_sync_q[1]&&!rate_sync_q[2]&&gen2_o==target_gen2_i;
 pcie_soft_rate_control rate_control(freerun_clk_i,reset_i,target_gen2_i,rate_idle,rate_applied,rate_busy,rate_fault);
 IBUFDS_GTE4 reference_buffer(.I(refclk_p_i),.IB(refclk_n_i),.CEB(1'b0),.O(refclk),.ODIV2());
 pcie_gen1_gt gt(
 .gtwiz_userclk_tx_reset_in(!txpma),.gtwiz_userclk_tx_srcclk_out(),.gtwiz_userclk_tx_usrclk_out(),
 .gtwiz_userclk_tx_usrclk2_out(core_clk_o),.gtwiz_userclk_tx_active_out(txactive),
 .gtwiz_userclk_rx_active_in(txactive),
 .gtwiz_reset_clk_freerun_in(freerun_clk_i),.gtwiz_reset_all_in(reset_i),
 .gtwiz_reset_tx_pll_and_datapath_in(1'b0),.gtwiz_reset_tx_datapath_in(1'b0),
 .gtwiz_reset_rx_pll_and_datapath_in(1'b0),.gtwiz_reset_rx_datapath_in(1'b0),
 .gtwiz_reset_rx_cdr_stable_out(),.gtwiz_reset_tx_done_out(txdone),.gtwiz_reset_rx_done_out(rxdone),
 .gtwiz_userdata_tx_in(tx_data_i),.gtwiz_userdata_rx_out(rx_data_o),
 .drpclk_in(freerun_clk_i),.gthrxn_in(rx_n_i),.gthrxp_in(rx_p_i),.gtrefclk0_in(refclk),
 // UG576 dedicated PCIe ports: release PCIe reset after the buffered PHY
 // reset helpers complete; GTHE4 requires CPLL lock feedback in PCIe mode.
 // TX buffer is enabled, so no buffer-bypass alignment handshake is needed.
 .pcierstidle_in(ready_o&&!reset_i),.cpllfreqlock_in(lock),
 .rx8b10ben_in(1'b1),.rxcommadeten_in(1'b1),.rxmcommaalignen_in(1'b1),.rxpcommaalignen_in(1'b1),
 .rxpd_in(power_state),.rxpolarity_in(polarity_i),.rxusrclk_in(core_clk_o),.rxusrclk2_in(core_clk_o),
 .rxrate_in({2'b0,target_gen2_i}),.txrate_in({2'b0,target_gen2_i}),
 .txdeemph_in({1'b0,!target_gen2_i||deemphasis_i}),.pcierateidle_out(rate_idle),
 .tx8b10ben_in(1'b1),.txctrl0_in(16'b0),.txctrl1_in(16'b0),.txctrl2_in({6'b0,tx_ctrl_i}),
 .txdetectrx_in(detect_i),.txelecidle_in(electrical_idle_i),.txpd_in(power_state),
 .cplllock_out(lock),.gthtxn_out(tx_n_o),.gthtxp_out(tx_p_o),.gtpowergood_out(powergood),
 .phystatus_out(phystatus),.rxbyteisaligned_out(aligned),.rxbyterealign_out(),.rxcommadet_out(),
 .rxctrl0_out(rxctrl0),.rxctrl1_out(rxctrl1),.rxctrl2_out(rxctrl2),.rxctrl3_out(rxctrl3),
 .rxelecidle_out(idle),.rxoutclk_out(),.rxpmaresetdone_out(rxpma),.rxresetdone_out(),
 .rxstatus_out(rxstatus),.rxbufstatus_out(bufstatus),.txpmaresetdone_out(txpma),.txresetdone_out());
 // GT reset-controller indications originate on the freerun clock. RXELECIDLE
 // is asynchronous. Keep them out of core combinational control until sampled.
 (* ASYNC_REG="TRUE" *) reg [4:0] ready_meta=0,ready_mid=0,ready_sync=0;
 (* ASYNC_REG="TRUE" *) reg [2:0] idle_sync=7;
 always @(posedge core_clk_o) begin
  ready_meta<={txdone,rxdone,lock,powergood,txactive};
  ready_mid<=ready_meta;ready_sync<=ready_mid;
  idle_sync<={idle_sync[1:0],idle};
 end
 assign ready_o=&ready_sync;assign rx_idle_o=idle_sync[2];
 assign rx_ctrl_o=rxctrl0[1:0];
 assign rx_valid_o=ready_o&&aligned&&!rx_idle_o;
 assign rx_error_o=(|rxctrl1[1:0]) || (|rxctrl3[1:0]) || bufstatus[2];
 assign detect_done_o=detect_i&&phystatus;
 assign receiver_present_o=rxstatus==3'b011;
 // Raw diagnostic levels cross to management in pcie_root_csr. In particular
 // these remain observable even when the core clock/reset is not running.
 assign diagnostic_o={receiver_present_o,phystatus,aligned,idle,ready_o,
                      rxpma,txpma,txactive,powergood,lock,rxdone,txdone};
 wire unused_status=^{rxctrl0[15:2],rxctrl1[15:2],rxctrl2,rxctrl3[7:2],rxpma,bufstatus[1:0]};
endmodule

// ZCU104 SSD1 laboratory top; management is independent of the PCIe clock.
module soft_pcie_root(
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 aclk CLK",
    X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 50000000" *)
 input wire aclk,
 (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 aresetn RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
 input wire aresetn,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 host_clk_i CLK", X_INTERFACE_PARAMETER="FREQ_HZ 125000000" *)
 input wire host_clk_i,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
 input wire [11:0] s_axi_awaddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
 input wire  s_axi_awvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
 output wire  s_axi_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
 input wire [31:0] s_axi_wdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
 input wire [3:0] s_axi_wstrb,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
 input wire  s_axi_wvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
 output wire  s_axi_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
 output wire [1:0] s_axi_bresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
 output wire  s_axi_bvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
 input wire  s_axi_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
 input wire [11:0] s_axi_araddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
 input wire  s_axi_arvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
 output wire  s_axi_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
 output wire [31:0] s_axi_rdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
 output wire [1:0] s_axi_rresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
 output wire  s_axi_rvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
 input wire  s_axi_rready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM AWADDR" *)
 input wire [24:0] s_mem_awaddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM AWVALID" *)
 input wire s_mem_awvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM AWREADY" *)
 output wire s_mem_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM WDATA" *)
 input wire [31:0] s_mem_wdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM WSTRB" *)
 input wire [3:0] s_mem_wstrb,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM WVALID" *)
 input wire s_mem_wvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM WREADY" *)
 output wire s_mem_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM BRESP" *)
 output wire [1:0] s_mem_bresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM BVALID" *)
 output wire s_mem_bvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM BREADY" *)
 input wire s_mem_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM ARADDR" *)
 input wire [24:0] s_mem_araddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM ARVALID" *)
 input wire s_mem_arvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM ARREADY" *)
 output wire s_mem_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM RDATA" *)
 output wire [31:0] s_mem_rdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM RRESP" *)
 output wire [1:0] s_mem_rresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM RVALID" *)
 output wire s_mem_rvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_MEM RREADY" *)
 input wire s_mem_rready,
 (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_DDR, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2" *)
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWADDR" *)
 output wire [31:0] m_ddr_awaddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWLEN" *)
 output wire [7:0] m_ddr_awlen,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWSIZE" *)
 output wire [2:0] m_ddr_awsize,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWBURST" *)
 output wire [1:0] m_ddr_awburst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWCACHE" *)
 output wire [3:0] m_ddr_awcache,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWPROT" *)
 output wire [2:0] m_ddr_awprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWVALID" *)
 output wire m_ddr_awvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR AWREADY" *)
 input wire m_ddr_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR WDATA" *)
 output wire [63:0] m_ddr_wdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR WSTRB" *)
 output wire [7:0] m_ddr_wstrb,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR WLAST" *)
 output wire m_ddr_wlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR WVALID" *)
 output wire m_ddr_wvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR WREADY" *)
 input wire m_ddr_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR BRESP" *)
 input wire [1:0] m_ddr_bresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR BVALID" *)
 input wire m_ddr_bvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR BREADY" *)
 output wire m_ddr_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARADDR" *)
 output wire [31:0] m_ddr_araddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARLEN" *)
 output wire [7:0] m_ddr_arlen,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARSIZE" *)
 output wire [2:0] m_ddr_arsize,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARBURST" *)
 output wire [1:0] m_ddr_arburst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARCACHE" *)
 output wire [3:0] m_ddr_arcache,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARPROT" *)
 output wire [2:0] m_ddr_arprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARVALID" *)
 output wire m_ddr_arvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR ARREADY" *)
 input wire m_ddr_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR RDATA" *)
 input wire [63:0] m_ddr_rdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR RRESP" *)
 input wire [1:0] m_ddr_rresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR RLAST" *)
 input wire m_ddr_rlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR RVALID" *)
 input wire m_ddr_rvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_DDR RREADY" *)
 output wire m_ddr_rready,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 core_clk_o CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_MEM:M_DDR, ASSOCIATED_RESET core_resetn_o, FREQ_HZ 125000000" *)
 output wire core_clk_o,
 (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 core_resetn_o RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
 output wire core_resetn_o,
 (* X_INTERFACE_INFO="xilinx.com:signal:interrupt:1.0 irq_o INTERRUPT", X_INTERFACE_PARAMETER="SENSITIVITY LEVEL_HIGH" *)
 output wire irq_o,
 input wire refclk_p_i,refclk_n_i,rx_p_i,rx_n_i,
 output wire tx_p_o,tx_n_o,perst_a_o,disable_ssd2_power_o
);
 // Packaging fixes the backend and these dimensions together. Negotiated
 // fallback speed does not change packet width or accepted-owner capacity.
 localparam integer PACKET_DWORDS=1;
 localparam integer READ_PREFETCH_SLOTS=2;
 wire enable,cv,cr,rv,rr;
 wire linkup_raw,active_raw,error_raw,linkup,active,error;
 wire [4:0] state_raw;
 wire gen2,rate_busy,fallback;
 wire force_gen1;
 wire rx_cross_fault,tx_cross_fault;
 wire core_clk=host_clk_i;
 wire link_clk;
 (* ASYNC_REG="TRUE" *) reg [8:0] host_status_meta_q=0,host_status_mid_q=0,host_status_sync_q=0;
 (* ASYNC_REG="TRUE", DONT_TOUCH="TRUE" *) reg [2:0] link_release_q=0;
 always @(posedge link_clk or negedge aresetn)
  if(!aresetn)link_release_q<=0;else link_release_q<={link_release_q[1:0],1'b1};
 reg [8:0] link_status_q=0;
 reg [2:0] rate_status_q=0;
 always @(posedge link_clk)begin
  if(!link_release_q[2])begin link_status_q<=0;rate_status_q<=0;end
  else begin
   link_status_q<={rx_cross_fault,error_raw,state_raw,active_raw,linkup_raw};
   rate_status_q<={fallback,rate_busy,gen2};
  end
 end
 always @(posedge core_clk)begin
  if(!mailbox_release_q[2])begin host_status_meta_q<=0;host_status_mid_q<=0;host_status_sync_q<=0;end
  else begin
   host_status_meta_q<=link_status_q;host_status_mid_q<=host_status_meta_q;host_status_sync_q<=host_status_mid_q;
  end
 end
 reg host_seen_link_q,host_lost_link_q;
 always @(posedge core_clk)begin
  if(!mailbox_release_q[2])begin host_seen_link_q<=0;host_lost_link_q<=0;end
  else begin
   if(host_status_sync_q[1])host_seen_link_q<=1;
   if((host_seen_link_q&&!host_status_sync_q[1])||host_status_sync_q[8]||tx_cross_fault)host_lost_link_q<=1;
  end
 end
 assign linkup=host_status_sync_q[0];
 assign active=host_status_sync_q[1]&&!host_lost_link_q;
 assign error=host_status_sync_q[7]||host_lost_link_q;
 wire [4:0] state=host_status_sync_q[6:2];wire [2:0] op,status;wire [63:0] address;wire [15:0] bdf;
 wire [31:0] data,result;wire [3:0] be;
 wire [15:0] phy_diagnostic;
 wire [127:0] completion_debug;
 (* ASYNC_REG="TRUE" *) reg [2:0] mailbox_release_q=0;
 // Mailbox ownership persists through software PERST; only global reset clears
 // toggles. Otherwise re-enabling a link could replay the previous command.
 always @(posedge core_clk or negedge aresetn)
  if(!aresetn)mailbox_release_q<=0;else mailbox_release_q<={mailbox_release_q[1:0],1'b1};
 assign core_clk_o=core_clk;
 assign core_resetn_o=mailbox_release_q[2];
 wire pv,pr,prv,prr,cv_mux,cr_mux,rv_mux,rr_mux;
 wire [2:0] pop;wire [63:0] pa;wire [31:0] pd;wire [3:0] pbe;
 wire [118:0] mux_payload;
 wire [32*PACKET_DWORDS-1:0] txdata,rxdata;wire rxsingle,txsingle;wire txvalid,txlast,txready,rxvalid,rxlast,rxready;
 wire [31:0] perf_events;
 wire [8:0] txcost;wire msi;wire [4:0] vector;wire dma_fault,dma_idle,dma_enable;
 pcie_cmd_mux mux(.clk(core_clk),.rst_n(mailbox_release_q[2]),
 .a_valid_i(cv),.a_ready_o(cr),.a_payload_i({op,address,bdf,data,be}),.a_rsp_valid_o(rv),.a_rsp_ready_i(rr),
 .b_valid_i(pv),.b_ready_o(pr),.b_payload_i({pop,pa,16'b0,pd,pbe}),.b_rsp_valid_o(prv),.b_rsp_ready_i(prr),
 .valid_o(cv_mux),.ready_i(cr_mux),.payload_o(mux_payload),.rsp_valid_i(rv_mux),.rsp_ready_o(rr_mux));
 pcie_host_axi #(.PACKET_DWORDS(PACKET_DWORDS),.READ_PREFETCH_SLOTS(READ_PREFETCH_SLOTS)) host(.clk(core_clk),.rst_n(mailbox_release_q[2]),.link_active_i(active),
 .s_axi_awaddr(s_mem_awaddr),
 .s_axi_awvalid(s_mem_awvalid),
 .s_axi_awready(s_mem_awready),
 .s_axi_wdata(s_mem_wdata),
 .s_axi_wstrb(s_mem_wstrb),
 .s_axi_wvalid(s_mem_wvalid),
 .s_axi_wready(s_mem_wready),
 .s_axi_bresp(s_mem_bresp),
 .s_axi_bvalid(s_mem_bvalid),
 .s_axi_bready(s_mem_bready),
 .s_axi_araddr(s_mem_araddr),
 .s_axi_arvalid(s_mem_arvalid),
 .s_axi_arready(s_mem_arready),
 .s_axi_rdata(s_mem_rdata),
 .s_axi_rresp(s_mem_rresp),
 .s_axi_rvalid(s_mem_rvalid),
 .s_axi_rready(s_mem_rready),
 .cmd_valid_o(pv),.cmd_ready_i(pr),.cmd_op_o(pop),.cmd_address_o(pa),.cmd_data_o(pd),.cmd_be_o(pbe),
 .rsp_valid_i(prv),.rsp_ready_o(prr),.rsp_data_i(result),.rsp_status_i(status),
 .perf_events_i(perf_events),.msi_valid_i(msi),.msi_vector_i(vector),.dma_fault_i(dma_fault),.dma_idle_i(dma_idle),.dma_enable_o(dma_enable),.irq_o(irq_o));
 pcie_ddr_bridge #(.RX_DWORDS(PACKET_DWORDS),.TX_DWORDS(PACKET_DWORDS),
 .READ_SLOTS(READ_PREFETCH_SLOTS),.PIPELINED_READS(PACKET_DWORDS==2)) ddr(.clk(core_clk),.rst_n(mailbox_release_q[2]),.link_active_i(active),.dma_enable_i(dma_enable),
 .rx_last_single_i(rxsingle),.rx_data_i(rxdata),.rx_valid_i(rxvalid),.rx_last_i(rxlast),.rx_ready_o(rxready),
 .tx_last_single_o(txsingle),.tx_data_o(txdata),.tx_valid_o(txvalid),.tx_last_o(txlast),.tx_ready_i(txready),.tx_credits_o(txcost),
 .perf_events_o(perf_events),.msi_valid_o(msi),.msi_vector_o(vector),.fault_o(dma_fault),.idle_o(dma_idle),
 .m_axi_awaddr(m_ddr_awaddr),
 .m_axi_awlen(m_ddr_awlen),
 .m_axi_awsize(m_ddr_awsize),
 .m_axi_awburst(m_ddr_awburst),
 .m_axi_awcache(m_ddr_awcache),
 .m_axi_awprot(m_ddr_awprot),
 .m_axi_awvalid(m_ddr_awvalid),
 .m_axi_awready(m_ddr_awready),
 .m_axi_wdata(m_ddr_wdata),
 .m_axi_wstrb(m_ddr_wstrb),
 .m_axi_wlast(m_ddr_wlast),
 .m_axi_wvalid(m_ddr_wvalid),
 .m_axi_wready(m_ddr_wready),
 .m_axi_bresp(m_ddr_bresp),
 .m_axi_bvalid(m_ddr_bvalid),
 .m_axi_bready(m_ddr_bready),
 .m_axi_araddr(m_ddr_araddr),
 .m_axi_arlen(m_ddr_arlen),
 .m_axi_arsize(m_ddr_arsize),
 .m_axi_arburst(m_ddr_arburst),
 .m_axi_arcache(m_ddr_arcache),
 .m_axi_arprot(m_ddr_arprot),
 .m_axi_arvalid(m_ddr_arvalid),
 .m_axi_arready(m_ddr_arready),
 .m_axi_rdata(m_ddr_rdata),
 .m_axi_rresp(m_ddr_rresp),
 .m_axi_rlast(m_ddr_rlast),
 .m_axi_rvalid(m_ddr_rvalid),
 .m_axi_rready(m_ddr_rready));
 pcie_root_csr csr(
 .aclk(aclk),.aresetn(aresetn),
 .s_axi_awaddr(s_axi_awaddr),
 .s_axi_awvalid(s_axi_awvalid),
 .s_axi_awready(s_axi_awready),
 .s_axi_wdata(s_axi_wdata),
 .s_axi_wstrb(s_axi_wstrb),
 .s_axi_wvalid(s_axi_wvalid),
 .s_axi_wready(s_axi_wready),
 .s_axi_bresp(s_axi_bresp),
 .s_axi_bvalid(s_axi_bvalid),
 .s_axi_bready(s_axi_bready),
 .s_axi_araddr(s_axi_araddr),
 .s_axi_arvalid(s_axi_arvalid),
 .s_axi_arready(s_axi_arready),
 .s_axi_rdata(s_axi_rdata),
 .s_axi_rresp(s_axi_rresp),
 .s_axi_rvalid(s_axi_rvalid),
 .s_axi_rready(s_axi_rready),
 .force_gen1_o(force_gen1),.rate_status_i(rate_status_q),.enable_o(enable),.core_clk_i(core_clk),.core_reset_n_i(mailbox_release_q[2]),
 .link_up_i(linkup),.dl_active_i(active),.error_i(error|dma_fault|tx_cross_fault),.state_i(state),.phy_status_i(phy_diagnostic),.completion_debug_i(completion_debug),
 .cmd_valid_o(cv),.cmd_ready_i(cr),.cmd_op_o(op),.cmd_address_o(address),.cmd_bdf_o(bdf),.cmd_data_o(data),.cmd_be_o(be),
 .rsp_valid_i(rv),.rsp_ready_o(rr),.rsp_data_i(result),.rsp_status_i(status));
 wire root_cv,root_cr,root_rv,root_rr;
 wire [118:0] root_command;
 wire [34:0] host_response;
 wire [31:0] root_result;wire [2:0] root_status;
 pcie_cmd_cdc command_crossing(core_clk,link_clk,aresetn,active_raw,
  cv_mux,cr_mux,mux_payload,rv_mux,rr_mux,host_response,
  root_cv,root_cr,root_command,root_rv,root_rr,{root_status,root_result});
 assign {status,result}=host_response;
 wire [31:0] root_rxdata;wire root_rxvalid,root_rxlast,root_rxready;
 wire [42:0] root_tx_payload;wire root_txvalid,root_txlast,root_txready;

 wire [32*PACKET_DWORDS:0] packed_rxdata;
 wire packed_rxvalid,packed_rxlast,packed_rxready;
 generate if(PACKET_DWORDS==2)begin: wide_rx
  pcie_rx_pack rx_pack(.clk(link_clk),.rst_n(link_release_q[2]),
   .s_data_i(root_rxdata),.s_valid_i(root_rxvalid),.s_last_i(root_rxlast),.s_ready_o(root_rxready),
   .m_data_o(packed_rxdata),.m_valid_o(packed_rxvalid),.m_last_o(packed_rxlast),.m_ready_i(packed_rxready));
 end else begin: narrow_rx
  assign packed_rxdata={1'b0,root_rxdata};
  assign packed_rxvalid=root_rxvalid;assign packed_rxlast=root_rxlast;assign root_rxready=packed_rxready;
 end endgenerate
 pcie_cdc_packet #(.WIDTH(32*PACKET_DWORDS+1),.WORDS(64/PACKET_DWORDS),.SLOTS(4)) rx_crossing(
  link_clk,core_clk,aresetn,packed_rxdata,packed_rxvalid,packed_rxlast,packed_rxready,rx_cross_fault,
  {rxsingle,rxdata},rxvalid,rxlast,rxready);
 wire [32*PACKET_DWORDS+3:0] crossed_tx;
 wire crossed_valid,crossed_last,crossed_ready;
 pcie_cdc_packet #(.WIDTH(32*PACKET_DWORDS+4),.WORDS(64/PACKET_DWORDS),.SLOTS(4)) tx_crossing(
  core_clk,link_clk,aresetn,{txcost[2:0],txsingle,txdata},txvalid,txlast,txready,tx_cross_fault,
  crossed_tx,crossed_valid,crossed_last,crossed_ready);
 generate if(PACKET_DWORDS==2)begin: wide_tx
  pcie_tx_unpack tx_unpack(.clk(link_clk),.rst_n(link_release_q[2]),
   .s_data_i(crossed_tx),.s_valid_i(crossed_valid),.s_last_i(crossed_last),.s_ready_o(crossed_ready),
   .m_data_o(root_tx_payload),.m_valid_o(root_txvalid),.m_last_o(root_txlast),.m_ready_i(root_txready));
 end else begin: narrow_tx
  assign root_tx_payload={2'd2,6'b0,crossed_tx[35:33],crossed_tx[31:0]};
  assign root_txvalid=crossed_valid;assign root_txlast=crossed_last;assign crossed_ready=root_txready;
 end endgenerate
 pcie_soft_root_port root_port(
 .freerun_clk_i(aclk),.reset_i(!aresetn),.enable_i(enable),
 .refclk_p_i(refclk_p_i),.refclk_n_i(refclk_n_i),.rx_p_i(rx_p_i),.rx_n_i(rx_n_i),
 .tx_p_o(tx_p_o),.tx_n_o(tx_n_o),.core_clk_o(link_clk),.perst_a_o(perst_a_o),.perst_b_o(),.disable_ssd2_power_o(disable_ssd2_power_o),
 .force_gen1_i(force_gen1),.gen2_o(gen2),.rate_busy_o(rate_busy),.fallback_o(fallback),.retrain_i(1'b0),.link_up_o(linkup_raw),.dl_active_o(active_raw),.state_o(state_raw),.diagnostic_o(phy_diagnostic),.completion_debug_o(completion_debug),
 .cmd_valid_i(root_cv),.cmd_ready_o(root_cr),.cmd_op_i(root_command[118:116]),.cmd_address_i(root_command[115:52]),.cmd_bdf_i(root_command[51:36]),.cmd_data_i(root_command[35:4]),.cmd_be_i(root_command[3:0]),
 .rsp_valid_o(root_rv),.rsp_ready_i(root_rr),.rsp_data_o(root_result),.rsp_status_o(root_status),
 .app_tx_data_i(root_tx_payload[31:0]),.app_tx_valid_i(root_txvalid),.app_tx_last_i(root_txlast),.app_tx_ready_o(root_txready),.app_tx_class_i(root_tx_payload[42:41]),.app_tx_credits_i(root_tx_payload[40:32]),
 .app_rx_data_o(root_rxdata),.app_rx_valid_o(root_rxvalid),.app_rx_last_o(root_rxlast),.app_rx_ready_i(root_rxready),.error_o(error_raw));
endmodule

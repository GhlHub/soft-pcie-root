// Core-clock AXI-Lite BAR window and host control. No clock crossing here.
// 0x0000000..0x0000fff: control; 0x1000000..0x1ffffff: PCI BAR PIO.
module pcie_host_axi #(parameter integer TIMEOUT_CYCLES=62500000, PACKET_DWORDS=1, READ_PREFETCH_SLOTS=2)(
 input wire clk,rst_n,link_active_i,
 input wire [24:0] s_axi_awaddr,input wire s_axi_awvalid,output wire s_axi_awready,
 input wire [31:0] s_axi_wdata,input wire [3:0] s_axi_wstrb,
 input wire s_axi_wvalid,output wire s_axi_wready,
 output reg [1:0] s_axi_bresp,output reg s_axi_bvalid,input wire s_axi_bready,
 input wire [24:0] s_axi_araddr,input wire s_axi_arvalid,output wire s_axi_arready,
 output reg [31:0] s_axi_rdata,output reg [1:0] s_axi_rresp,
 output reg s_axi_rvalid,input wire s_axi_rready,
 output wire cmd_valid_o,input wire cmd_ready_i,output wire [2:0] cmd_op_o,
 output wire [63:0] cmd_address_o,output wire [31:0] cmd_data_o,output wire [3:0] cmd_be_o,
 input wire rsp_valid_i,output wire rsp_ready_o,input wire [31:0] rsp_data_i,input wire [2:0] rsp_status_i,
 input wire msi_valid_i,input wire [4:0] msi_vector_i,
 input wire [31:0] perf_events_i,
 input wire dma_fault_i,dma_idle_i,output reg dma_enable_o,output wire irq_o
);
 reg aw_q,w_q,read_pending_q;reg [24:0] awaddr_q,araddr_q;
 reg [31:0] wdata_q,pending_q,mask_q;reg [3:0] wstrb_q;
 reg [1:0] state_q;reg pio_write_q;reg [31:0] pio_addr_q,pio_data_q;reg [3:0] pio_be_q;
 localparam integer TW=$clog2(TIMEOUT_CYCLES+1);
 reg [TW-1:0] timer_q;
 reg fault_q;
 wire [31:0] event_mask=msi_valid_i?(32'b1<<msi_vector_i):0;
 assign irq_o=|(pending_q&mask_q);
 // PIO read and write commands are serialized, independently latched AXI
 // channels are held until their matching response. MSI/CSR stays ordered.
 assign s_axi_awready=!aw_q&&!s_axi_bvalid;
 assign s_axi_wready=!w_q&&!s_axi_bvalid;
 assign s_axi_arready=!read_pending_q&&!s_axi_rvalid;
 assign cmd_valid_o=state_q==1;
 assign cmd_op_o=pio_write_q?3'd1:3'd0;
 assign cmd_address_o={32'b0,pio_addr_q};assign cmd_data_o=pio_data_q;assign cmd_be_o=pio_be_q;
 assign rsp_ready_o=state_q==2||state_q==3;
 function automatic [31:0] merge(input [31:0] a,b,input [3:0] s);
  integer i;begin merge=a;for(i=0;i<4;i=i+1)if(s[i])merge[i*8+:8]=b[i*8+:8];end
 endfunction
 // Profiling is independent of DMA ownership. Clear dominates counting;
 // freeze includes the last enabled edge. Registered events lag by one cycle.
 reg [31:0] perf_events_q,perf_overflow_q;
 reg [31:0] perf_count_q[0:31];
 reg perf_enable_q;
 wire perf_write=(state_q==0||state_q==3)&&aw_q&&w_q&&!s_axi_bvalid&&awaddr_q==25'h80&&wstrb_q[0];
 integer pc;
 always @(posedge clk)begin
  if(!rst_n)begin
   perf_events_q<=0;perf_enable_q<=0;perf_overflow_q<=0;
   for(pc=0;pc<32;pc=pc+1)perf_count_q[pc]<=0;
  end else begin
   perf_events_q<=perf_events_i;
   if(perf_write)perf_enable_q<=wdata_q[0];
   if(perf_write&&wdata_q[1])begin
    perf_overflow_q<=0;
    for(pc=0;pc<32;pc=pc+1)perf_count_q[pc]<=0;
   end else if(perf_enable_q)begin
    for(pc=0;pc<32;pc=pc+1)if(perf_events_q[pc])begin
     perf_count_q[pc]<=perf_count_q[pc]+1'b1;
     if(&perf_count_q[pc])perf_overflow_q[pc]<=1;
    end
   end
  end
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   aw_q<=0;w_q<=0;read_pending_q<=0;awaddr_q<=0;araddr_q<=0;wdata_q<=0;wstrb_q<=0;
   s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
   pending_q<=0;mask_q<=0;dma_enable_o<=0;state_q<=0;pio_write_q<=0;
   pio_addr_q<=0;pio_data_q<=0;pio_be_q<=0;fault_q<=0;timer_q<=0;
  end else begin
   pending_q<=pending_q|event_mask;
   if(s_axi_awvalid&&s_axi_awready)begin aw_q<=1;awaddr_q<=s_axi_awaddr;end
   if(s_axi_wvalid&&s_axi_wready)begin w_q<=1;wdata_q<=s_axi_wdata;wstrb_q<=s_axi_wstrb;end
   if(s_axi_arvalid&&s_axi_arready)begin read_pending_q<=1;araddr_q<=s_axi_araddr;end
   if(s_axi_bvalid&&s_axi_bready)s_axi_bvalid<=0;
   if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
   if(state_q==0||state_q==3)begin
    if(aw_q&&w_q&&!s_axi_bvalid)begin
     aw_q<=0;w_q<=0;s_axi_bresp<=0;
     if(!awaddr_q[24]&&awaddr_q[1:0]!=0)begin s_axi_bresp<=2;s_axi_bvalid<=1;end
     else if(awaddr_q[24])begin
      if(!link_active_i||fault_q||wstrb_q==0)begin s_axi_bvalid<=1;s_axi_bresp<=0;end
      else begin pio_write_q<=1;pio_addr_q<=32'ha3000000|{8'b0,awaddr_q[23:2],2'b0};pio_data_q<=wdata_q;pio_be_q<=wstrb_q;state_q<=1;end
     end else begin
      s_axi_bvalid<=1;
      case(awaddr_q)
       25'h10:if(wstrb_q[0])begin
        if(wdata_q[0]&&(dma_fault_i||fault_q||!link_active_i))s_axi_bresp<=2;
        else dma_enable_o<=wdata_q[0];
       end
       25'h80:begin end // Counter control handled independently above.
       25'h24:mask_q<=merge(mask_q,wdata_q,wstrb_q);
       25'h28:pending_q<=(pending_q&~merge(32'b0,wdata_q,wstrb_q))|event_mask;
       default:s_axi_bresp<=2;
      endcase
     end
    end else if(read_pending_q&&!s_axi_rvalid)begin
     read_pending_q<=0;s_axi_rdata<=0;s_axi_rresp<=0;
     if(!araddr_q[24]&&araddr_q[1:0]!=0)begin s_axi_rresp<=2;s_axi_rvalid<=1;end
     else if(araddr_q[24])begin
      if(!link_active_i||fault_q)begin s_axi_rvalid<=1;s_axi_rresp<=0;s_axi_rdata<=32'hffffffff;end
      else begin pio_write_q<=0;pio_addr_q<=32'ha3000000|{8'b0,araddr_q[23:2],2'b0};pio_data_q<=0;pio_be_q<=15;state_q<=1;end
     end else begin
      s_axi_rvalid<=1;
      case(araddr_q)
       25'h0:s_axi_rdata<=32'h44425231; // DBR1
       25'h4:s_axi_rdata<=32'h00010000;
       25'h10:s_axi_rdata<={31'b0,dma_enable_o};
       25'h14:s_axi_rdata<={28'b0,link_active_i,dma_idle_i,fault_q,dma_fault_i};
       25'h20:s_axi_rdata<=pending_q;
       25'h24:s_axi_rdata<=mask_q;
       25'h80:s_axi_rdata<={31'b0,perf_enable_q};
       25'h84:s_axi_rdata<=perf_overflow_q;
       25'h88:s_axi_rdata<=PACKET_DWORDS==2?32'h50524632:32'h50524631; // PRF2/PRF1
       25'h8c:s_axi_rdata<=125000000;
       25'h90:s_axi_rdata<={16'b0,8'(READ_PREFETCH_SLOTS),8'(PACKET_DWORDS)};
       default:if(araddr_q>=25'h100&&araddr_q<25'h180)
        s_axi_rdata<=perf_count_q[araddr_q[6:2]];
       else s_axi_rresp<=2;
      endcase
     end
    end
   end
   if(state_q==1||state_q==2)timer_q<=timer_q+1'b1;else timer_q<=0;
   // Timeout before acceptance can withdraw an offer. After acceptance keep
   // the requester owner reserved and drain its late result in state3.
   if((state_q==1||state_q==2)&&timer_q==TW'(TIMEOUT_CYCLES-1)&&
      !(state_q==1&&cmd_ready_i)&&!(state_q==2&&rsp_valid_i))begin
    fault_q<=1;state_q<=state_q==2?2'd3:2'd0;
    if(pio_write_q)begin s_axi_bvalid<=1;s_axi_bresp<=0;end
    else begin s_axi_rvalid<=1;s_axi_rresp<=0;s_axi_rdata<=32'hffffffff;end
   end
   if(state_q==3&&rsp_valid_i)state_q<=0;
   if(state_q==1&&cmd_ready_i)state_q<=2;
   if(state_q==2&&rsp_valid_i)begin
    state_q<=0;
    if(rsp_status_i>=3)fault_q<=1;
    if(pio_write_q)begin s_axi_bvalid<=1;s_axi_bresp<=0;end
    else begin s_axi_rvalid<=1;s_axi_rresp<=0;s_axi_rdata<=rsp_status_i==0?rsp_data_i:32'hffffffff;end
   end
  end
 end
endmodule

`timescale 1ns/1ps
// Ideal-memory service-rate test, not a PCIe/SSD throughput prediction.
// Independent external AXI scoreboard; usable against the prior bridge too.
module tb_ddr_pipeline;
 parameter MAX_SERVICE_CYCLES=38;
 parameter ALIGN=0,FOUR=0,STALLS=0,WORDS=32;
 localparam BEATS=(WORDS+ALIGN+1)/2;
 integer cycle=0;
 wire awready=STALLS==0 || cycle%7==0;
 wire wready=STALLS==0 || cycle%5==0;
 reg clk=0;always #4 clk=~clk;
 reg rst=0;
 reg [31:0] rxdata=0;reg rxvalid=0,rxlast=0;wire rxready;
 wire [31:0] awaddr;wire [7:0] awlen,wstrb;wire [63:0] wdata;
 wire awvalid,wvalid,wlast,bready,arvalid,msi,fault,idle;
 wire [4:0] vector;
 reg bvalid=0;
 pcie_ddr_bridge dut(.clk(clk),.rst_n(rst),.link_active_i(1'b1),.dma_enable_i(1'b1),
 .rx_data_i(rxdata),.rx_valid_i(rxvalid),.rx_last_i(rxlast),.rx_ready_o(rxready),
 .tx_data_o(),.tx_valid_o(),.tx_last_o(),.tx_ready_i(1'b1),.tx_credits_o(),
 .msi_valid_o(msi),.msi_vector_o(vector),.fault_o(fault),.idle_o(idle),
 .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(),.m_axi_awburst(),.m_axi_awcache(),.m_axi_awprot(),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bresp(2'b0),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
 .m_axi_araddr(),.m_axi_arlen(),.m_axi_arsize(),.m_axi_arburst(),.m_axi_arcache(),.m_axi_arprot(),.m_axi_arvalid(arvalid),.m_axi_arready(1'b1),
 .m_axi_rdata(64'b0),.m_axi_rresp(2'b0),.m_axi_rlast(1'b0),.m_axi_rvalid(1'b0),.m_axi_rready());
 integer addresses=0,responses=0,beat=0,first_aw=0,last_aw=0,max_gap=0,irqs=0;
 reg writing=0;
 reg held_w_valid=0,held_aw_valid=0;
 reg [72:0] held_w;
 reg [39:0] held_aw;
 always @(posedge clk)begin
  if(rst&&held_w_valid&&(!wvalid||{wdata,wstrb,wlast}!==held_w))$fatal(1,"Stalled W changed");
  if(rst&&held_aw_valid&&(!awvalid||{awaddr,awlen}!==held_aw))$fatal(1,"Stalled AW changed");
  held_w_valid<=rst&&wvalid&&!wready;held_w<={wdata,wstrb,wlast};
  held_aw_valid<=rst&&awvalid&&!awready;held_aw<={awaddr,awlen};
 end
 function [31:0] payload(input integer packet,word_index);
  payload=32'hcafe0000 ^ (packet<<8) ^ word_index;
 endfunction
 function [31:0] swap(input [31:0] v);swap={v[7:0],v[15:8],v[23:16],v[31:24]};endfunction
 always @(posedge clk)begin
  cycle<=cycle+1;
  if(rst)begin
   if(fault||arvalid)$fatal(1,"Unexpected fault/read");
   if(awvalid&&awready)begin
    if(writing||awaddr!=4096+addresses*256||awlen!=BEATS-1)$fatal(1,"AXI write address/order");
    if(addresses==0)first_aw<=cycle;
    else if(cycle-last_aw>max_gap)max_gap<=cycle-last_aw;
    last_aw<=cycle;addresses<=addresses+1;writing<=1;beat<=0;
   end
   if(bvalid&&bready)begin bvalid<=0;responses<=responses+1;end
   if(wvalid&&wready)begin
    if(!writing||wlast!=(beat==BEATS-1))$fatal(1,"Write ownership/last");
    for(integer lane=0;lane<2;lane=lane+1)begin
     if(beat*2+lane>=ALIGN&&beat*2+lane<WORDS+ALIGN)begin
      if(wstrb[lane*4+:4]!==4'hf||wdata[lane*32+:32]!==payload(addresses-1,beat*2+lane-ALIGN))
       $fatal(1,"Payload corruption packet%0d beat%0d lane%0d",addresses-1,beat,lane);
     end else if(wstrb[lane*4+:4]!==0)$fatal(1,"Unwritten lane enabled");
    end
    beat<=beat+1;
    if(wlast)begin writing<=0;bvalid<=1;end
   end
   if(msi)begin
    if(vector!=17||responses!=32||addresses!=32||writing||bvalid)$fatal(1,"MSI ordering");
    irqs<=irqs+1;
   end
  end
 end
 task word(input [31:0] data,input last);
  @(negedge clk);rxdata=data;rxvalid=1;rxlast=last;
  do @(posedge clk);while(!rxready);
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(integer packet=0;packet<32;packet=packet+1)begin
   word(swap((FOUR?32'h60000000:32'h40000000)|WORDS),0);
   word(swap(WORDS==1?32'h01005a0f:32'h01005aff),0);
   if(FOUR)word(0,0);
   word(swap(4096+packet*256+ALIGN*4),0);
   for(integer i=0;i<WORDS;i=i+1)word(payload(packet,i),i==WORDS-1);
  end
  word(swap(32'h40000001),0);word(swap(32'h01005a0f),0);word(swap(32'hfee00000),0);word(17,1);
  @(negedge clk);rxvalid=0;rxlast=0;
  wait(idle);repeat(3)@(negedge clk);
  if(irqs!=1||responses!=32||max_gap>MAX_SERVICE_CYCLES)$fatal(1,"Pipeline service gap %0d, expected <=%0d",max_gap,MAX_SERVICE_CYCLES);
  $display("PASS PIPELINE: packets=%0d max_service_cycles=%0d interval_cycles=%0d ideal_payload_MB_s=%0.3f",addresses,max_gap,last_aw-first_aw,31.0*WORDS*4*125/(last_aw-first_aw));
  $finish;
 end
 initial begin #1000000;$fatal(1,"Pipeline watchdog");end
endmodule

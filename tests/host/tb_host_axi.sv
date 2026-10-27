`timescale 1ns/1ps
module tb_host_axi;
 parameter PACKET_DWORDS=1,READ_PREFETCH_SLOTS=2;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,active=1;
 reg [24:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg [31:0] wdata=0;reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
 wire cv;reg cr=0;wire [2:0] op;wire [63:0] addr;wire [31:0] data;wire [3:0] be;
 reg rv=0;wire rr;reg [31:0] result=0;reg [2:0] status=0;
 reg [31:0] perf=0, frozen_count=0;
 reg msi=0;reg [4:0] vector=0;reg dfault=0;wire enable,irq;
 pcie_host_axi #(.TIMEOUT_CYCLES(40),.PACKET_DWORDS(PACKET_DWORDS),.READ_PREFETCH_SLOTS(READ_PREFETCH_SLOTS)) dut(.clk(clk),.rst_n(rst),.link_active_i(active),
 .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
 .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
 .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
 .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
 .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
 .cmd_valid_o(cv),.cmd_ready_i(cr),.cmd_op_o(op),.cmd_address_o(addr),.cmd_data_o(data),.cmd_be_o(be),
 .rsp_valid_i(rv),.rsp_ready_o(rr),.rsp_data_i(result),.rsp_status_i(status),
 .perf_events_i(perf),.msi_valid_i(msi),.msi_vector_i(vector),.dma_fault_i(dfault),.dma_idle_i(1'b1),.dma_enable_o(enable),.irq_o(irq));
 task aw(input [24:0] a);
  @(negedge clk);awaddr=a;awvalid=1;do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;
 endtask
 task wd(input [31:0] d,input [3:0] b);
  @(negedge clk);wdata=d;wstrb=b;wvalid=1;do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;
 endtask
 task b(input [1:0] expected);
  wait(bvalid);repeat(3)begin @(posedge clk);if(!bvalid||bresp!==expected)$fatal(1,"B hold/response");end
  @(negedge clk);bready=1;@(negedge clk);bready=0;
 endtask
 task ar(input [24:0] a);
  @(negedge clk);araddr=a;arvalid=1;do @(posedge clk);while(!arready);@(negedge clk);arvalid=0;
 endtask
 task r(input [31:0] d,input [1:0] e);
  wait(rvalid);repeat(4)begin @(posedge clk);if(!rvalid||rdata!==d||rresp!==e)$fatal(1,"R hold/response %x expected%x",rdata,d);end
  @(negedge clk);rready=1;@(negedge clk);rready=0;
 endtask
 task response(input [31:0] d,input [2:0] s);
  @(negedge clk);result=d;status=s;rv=1;do @(posedge clk);while(!rr);@(negedge clk);rv=0;
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  ar(0);r(32'h44425231,0);
  wd(1,1);aw(25'h10);b(0);if(!enable)$fatal(1,"DMA enable");
  aw(25'h24);wd(32'h20020,15);b(0);
  @(negedge clk);msi=1;vector=17;@(negedge clk);msi=0;
  if(!irq)$fatal(1,"MSI not asserted");ar(25'h20);r(32'h20000,0);
  aw(25'h28);wd(32'h20000,15);b(0);if(irq)$fatal(1,"MSI ack failed");
  // A new same-vector MSI wins over a simultaneous W1C acknowledgement.
  aw(25'h28);wd(32'h20,15);
  @(negedge clk);msi=1;vector=5;@(negedge clk);msi=0;b(0);
  ar(25'h20);r(32'h20,0);aw(25'h28);wd(32'h20,15);b(0);
  // Disabled counters, enable/clear, event capture, freeze and byte strobes.
  ar('h88);r(PACKET_DWORDS==2?32'h50524632:32'h50524631,0);ar('h8c);r(125000000,0);
  ar('h90);r((READ_PREFETCH_SLOTS<<8)|PACKET_DWORDS,0);
  perf=32'h80000001;repeat(5)@(negedge clk);ar('h100);r(0,0);
  aw('h80);wd(3,1);b(0);
  @(negedge clk);perf=0;repeat(3)@(negedge clk);
  aw('h80);wd(0,1);b(0);
  if(dut.perf_count_q[0]==0||dut.perf_count_q[0]!=dut.perf_count_q[31])$fatal(1,"event count");
  frozen_count=dut.perf_count_q[0];perf=32'hffffffff;repeat(8)@(negedge clk);
  ar('h100);r(frozen_count,0);ar('h17c);r(dut.perf_count_q[31],0);
  ar('h104);r(0,0);ar('h84);r(0,0);
  aw('h80);wd(3,2);b(0);ar('h80);r(0,0);
  aw('h80);wd(2,1);b(0);ar('h100);r(0,0);
  // Directed wrap injection avoids a 2^32-cycle simulation.
  @(negedge clk);dut.perf_count_q[0]=32'hffffffff;perf=1;
  aw('h80);wd(1,1);b(0);aw('h80);wd(0,1);b(0);
  ar('h84);r(1,0);aw('h80);wd(2,1);b(0);ar('h84);r(0,0);
  perf=0;
  // Noninterleaved BAR write: address/data held during requester stalls.
  wd(32'habcdef01,4'hc);aw(25'h1001236);
  wait(cv);repeat(7)begin @(posedge clk);if(op!=1||addr!=64'ha3001234||data!=32'habcdef01||be!=12||bvalid)$fatal(1,"PIO write snapshot");end
  @(negedge clk);cr=1;@(negedge clk);cr=0;
  repeat(8)@(negedge clk);if(bvalid)$fatal(1,"Posted write acknowledged before sent");
  response(0,0);b(0);
  ar(25'h1004003);wait(cv);if(op!=0||addr!=64'ha3004000||be!=15)$fatal(1,"PIO read request");
  @(negedge clk);cr=1;@(negedge clk);cr=0;response(32'h12345678,0);r(32'h12345678,0);
  // UR is an access error but does not quarantine other good commands.
  ar(25'h1004000);wait(cv);@(negedge clk);cr=1;@(negedge clk);cr=0;response(32'hffffffff,1);r(32'hffffffff,0);
  ar(25'h1004000);wait(cv);@(negedge clk);cr=1;@(negedge clk);cr=0;response(32'hffffffff,3);r(32'hffffffff,0);
  ar(25'h1004000);r(32'hffffffff,0);if(cv)$fatal(1,"Timeout did not quarantine");
  // Alignment and unsupported local addresses fail without sending any TLP.
  ar(25'h40);r(0,2);aw(25'h12);wd(1,15);b(2);
  // Timeout after acceptance returns the CPU response once, retains the
  // requester ownership, and consumes a late result without a second response.
  @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;
  ar(25'h1004000);wait(cv);@(negedge clk);cr=1;@(negedge clk);cr=0;
  r(32'hffffffff,0);if(!rr)$fatal(1,"Late drain ownership missing");
  ar(0);r(32'h44425231,0);response(32'h12345678,0);
  repeat(3)@(negedge clk);if(rvalid)$fatal(1,"Late response delivered twice");
  // Timeout before acceptance cannot launch a phantom command later.
  @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;
  ar(25'h1004000);wait(cv);r(32'hffffffff,0);
  if(cv||rr)$fatal(1,"Unaccepted timeout still owns command");
  $display("PASS HOST: AXI channel independence, strobes, holds, PIO ownership, MSI and timeout quarantine");$finish;
 end
 initial begin #100000;$fatal(1,"host watchdog");end
endmodule

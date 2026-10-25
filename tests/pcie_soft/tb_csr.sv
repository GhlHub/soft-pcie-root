`timescale 1ns/1ps
module tb_csr;
 reg clk=0,core=0,run_core=1,rstn=0,up=0,active=0;
 always #10 clk=~clk;
 always #4 if(run_core)core=~core;
 reg [11:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,arvalid=0,bready=0,rready=0;
 reg [31:0] wdata=0;reg [3:0] wstrb=15;
 wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
 wire enable,cv,rr;reg cr=0,rv=0;wire [2:0] op;wire [63:0] addr;wire [15:0] bdf;
 wire [31:0] data;wire [3:0] be;integer accepted=0;
 reg [15:0] phy=16'h1234;
 pcie_root_csr #(.TIMEOUT_CYCLES(80),.CLOCK_WINDOW_CYCLES(160),.HEARTBEAT_BITS(4)) dut(
 .force_gen1_o(),.rate_status_i(3'b0),.aclk(clk),.aresetn(rstn),.s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
 .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
 .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
 .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
 .enable_o(enable),.core_clk_i(core),.core_reset_n_i(rstn),.link_up_i(up),.dl_active_i(active),.error_i(1'b0),.state_i(5'd10),.phy_status_i(phy),.completion_debug_i(128'h01234567_89abcdef_fedcba98_76543210),
 .cmd_valid_o(cv),.cmd_ready_i(cr),.cmd_op_o(op),.cmd_address_o(addr),.cmd_bdf_o(bdf),.cmd_data_o(data),.cmd_be_o(be),
 .rsp_valid_i(rv),.rsp_ready_o(rr),.rsp_data_i(32'h1234abcd),.rsp_status_i(3'b0));
 always @(posedge core)if(rstn&&cv&&cr)accepted<=accepted+1;
 task write_reg(input [11:0] a,input [31:0] d,input [3:0] s,input reverse,input [1:0] expected);
 begin
  if(reverse)begin
   @(negedge clk);wdata=d;wstrb=s;wvalid=1;
   do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;
   repeat(3)@(negedge clk);awaddr=a;awvalid=1;
   do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;
  end else begin
   @(negedge clk);awaddr=a;awvalid=1;
   do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;
   repeat(3)@(negedge clk);wdata=d;wstrb=s;wvalid=1;
   do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;
  end
  wait(bvalid);repeat(3)begin @(negedge clk);if(!bvalid||bresp!=expected)$fatal(1,"B response/stall %x",a);end
  bready=1;@(negedge clk);bready=0;
 end endtask
 task read_reg(input [11:0] a,input [31:0] expected,input [31:0] mask);
 begin
  @(negedge clk);araddr=a;arvalid=1;
  do @(posedge clk);while(!arready);@(negedge clk);arvalid=0;
  wait(rvalid);repeat(3)begin @(negedge clk);if(!rvalid||rresp!=0||(rdata&mask)!=(expected&mask))$fatal(1,"Read %x: %x expected %x",a,rdata,expected);end
  rready=1;@(negedge clk);rready=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rstn=1;
  read_reg(0,32'h53525031,32'hffffffff);
  repeat(330)@(negedge clk);
  read_reg('hc,32'h00041234,32'hffffffff);
  read_reg('h1c,160,32'hffffffff);
  read_reg('h40,32'h01234567,32'hffffffff);
  read_reg('h44,32'h89abcdef,32'hffffffff);
  read_reg('h48,32'hfedcba98,32'hffffffff);
  read_reg('h4c,32'h76543210,32'hffffffff);
  read_reg('h50,8,32'hffffffff);
  write_reg('h10,2,1,0,0);read_reg('h10,2,32'hffffffff);
  write_reg('h10,0,1,0,0);
  read_reg('h18,50,32'hffffffff); // 400 core edges / 8 per heartbeat toggle.
  write_reg('h18,1,15,0,2); // Diagnostics are read-only.
  write_reg('h30,1,15,0,2); // Disabled admission fails, AXI still completes.
  write_reg('h10,1,1,1,0);up=1;active=1;repeat(4)@(negedge clk);
  write_reg('h10,3,1,0,2);read_reg('h10,1,32'hffffffff); // Policy held while enabled.
  write_reg('h20,32'h10203040,15,0,0);
  write_reg('h20,32'hffffabcd,1,1,0);read_reg('h20,32'h102030cd,32'hffffffff);
  write_reg('h24,32'h12345678,15,0,0);
  write_reg('h28,32'hf00dcafe,15,1,0);
  write_reg('h2c,32'h010000f2,15,0,0);
  write_reg('h30,1,1,1,0);
  wait(cv);repeat(4)begin @(negedge core);if(!cv||addr!=64'h12345678102030cd||bdf!='h100||data!='hf00dcafe||be!=15||op!=2)$fatal(1,"Mailbox payload unstable");end
  write_reg('h30,1,1,0,2); // Busy cannot overwrite payload.
  write_reg('h28,32'h11223344,15,1,0); // Staging changes cannot alter accepted command.
  if(data!=32'hf00dcafe)$fatal(1,"Busy staging corrupted the held mailbox");
  @(negedge core);cr=1;@(negedge core);cr=0;
  repeat(4)@(negedge core);rv=1;wait(rr);@(negedge core);rv=0;
  repeat(6)@(negedge clk);read_reg('h34,2,32'hffffffff);read_reg('h38,32'h1234abcd,32'hffffffff);
  // A link disable/re-enable must not reset the CDC mailbox or repeat a command.
  write_reg('h10,0,1,0,0);write_reg('h10,1,1,1,0);
  repeat(10)@(negedge core);if(cv||accepted!=1)$fatal(1,"Command repeated after enable cycle");
  write_reg('h30,1,1,0,0);wait(cv);
  if(data!=32'h11223344)$fatal(1,"Second command did not snapshot new staging");
  @(negedge core);cr=1;@(negedge core);cr=0;
  repeat(4)@(negedge core);rv=1;wait(rr);@(negedge core);rv=0;
  repeat(6)@(negedge clk);read_reg('h34,2,32'hffffffff);
  if(accepted!=2)$fatal(1,"Toggle wrap lost/duplicated command");
  wait(core==0);run_core=0;
  phy=16'habcd;repeat(330)@(negedge clk);
  read_reg('hc,32'h0004abcd,32'hffffffff);
  read_reg('h18,0,32'hffffffff); // Raw PHY levels and clock-loss diagnosis survive.
  write_reg('h30,1,1,0,0);
  read_reg(0,32'h53525031,32'hffffffff); // AXI remains live without GTH clock.
  repeat(85)@(negedge clk);read_reg('h34,32'h306,32'hffffffff);
  write_reg('h30,1,1,0,2);write_reg('h10,0,1,1,2); // quarantine
  run_core=1;repeat(10)@(negedge core);rstn=0;repeat(5)@(negedge clk);rstn=1;
  read_reg('h34,0,32'hffffffff);
  // Link disappearance between software's status check and submit is a
  // command failure, never an AXI write abort or a new core request.
  write_reg('h10,1,1,0,0);active=0;repeat(6)@(negedge clk);
  write_reg('h30,1,1,0,0);read_reg('h34,32'h406,32'hffffffff);
  if(cv)$fatal(1,"Inactive link submitted a command");
  $display("PASS CSR: independent AXI channels, stalls, strobes, mailbox, enable-cycle ownership, stopped clock and timeout quarantine");$finish;
 end
 initial begin #100000;$fatal(1,"CSR watchdog");end
endmodule

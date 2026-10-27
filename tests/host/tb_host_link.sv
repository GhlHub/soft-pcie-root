`timescale 1ns/1ps
// Independent procedural endpoint partner at the decoded GTH-symbol boundary.
// Normal-polynomial CRC division, byte-parallel scrambling, real packet bytes.
module tb_host_link #(
 parameter integer PROFILE_FC_CYCLES=1024,
 parameter integer PROFILE_B_DELAY=0
);
 // Simulation-only sweep: production controller defaults remain unchanged.
 defparam dut.flow.UPDATE_CYCLES=PROFILE_FC_CYCLES;
 reg [7:0] profile_limit_h=4,profile_used_h=0;
 reg [11:0] profile_limit_d=32,profile_used_d=0;
 integer profile_states[0:8];
 integer profile_wait=0,profile_count=0,profile_aw=0,profile_w=0,profile_b=0;
 reg profile_running=0;
 time profile_start;

 reg clk=0;always #4 clk=~clk;

 reg rst=0,enable=1,phyready=1,rxidle=1,detectdone=0,present=1,retrain=0;
 wire detect,txidle,polarity,up,active,error;
 wire [4:0] state;wire [15:0] phy_tx;wire [1:0] phy_tc;
 reg [15:0] phy_rx=0;reg [1:0] phy_rc=0;reg peer_enabled=0;
 reg cv=0;wire cr;reg [2:0] op=0;reg [63:0] addr=0;reg [15:0] bdf=16'h0100;
 reg [31:0] cmddata=0;reg [3:0] be=15;
 wire rspv;reg rspr=0;wire [31:0] rspdata;wire [2:0] rspstatus;
 wire [31:0] atd;wire atv,atl;wire atr;
 wire [1:0] atclass=2;wire [8:0] atcost;
 wire [31:0] ard;wire arv,arl;wire arr;
 pcie_soft_link #(.QUIET_CYCLES(16),.POLL_CYCLES(100000),.CONFIG_CYCLES(10000),.COMPLETION_TIMEOUT(4096)) dut(
 .force_gen1_i(1'b1),.phy_gen2_i(1'b0),.phy_rate_ready_i(1'b1),.target_gen2_o(),.speed_idle_o(),.fallback_o(),.clk(clk),.rst_n(rst),.enable_i(enable),.phy_ready_i(phyready),.rx_idle_i(rxidle),.detect_done_i(detectdone),.receiver_present_i(present),
 .detect_o(detect),.electrical_idle_o(txidle),.polarity_o(polarity),.phy_rx_data_i(phy_rx),.phy_rx_ctrl_i(phy_rc),
 .phy_rx_valid_i(peer_enabled),.phy_rx_error_i(1'b0),.phy_tx_data_o(phy_tx),.phy_tx_ctrl_o(phy_tc),
 .link_up_o(up),.dl_active_o(active),.state_o(state),.retrain_i(retrain),
 .cmd_valid_i(cv),.cmd_ready_o(cr),.cmd_op_i(op),.cmd_address_i(addr),.cmd_bdf_i(bdf),.cmd_data_i(cmddata),.cmd_be_i(be),
 .rsp_valid_o(rspv),.rsp_ready_i(rspr),.rsp_data_o(rspdata),.rsp_status_o(rspstatus),
 .app_tx_data_i(atd),.app_tx_valid_i(atv),.app_tx_last_i(atl),.app_tx_ready_o(atr),.app_tx_class_i(atclass),.app_tx_credits_i(atcost),
 .app_rx_data_o(ard),.app_rx_valid_o(arv),.app_rx_last_o(arl),.app_rx_ready_i(arr),.error_o(error));
 reg [9:0] queue[0:131071];integer producer=0,consumer=0;
 reg [15:0] peer_lfsr=16'hffff,monitor_lfsr=16'hffff;
 reg [9:0] symbol;reg [15:0] rxword;reg [1:0] rxk;
 integer lane,skip_count=0,monitor_training=0;
 reg [7:0] byte_value;reg bypass;
 function [7:0] reverse8(input [7:0] x);
  for(integer n=0;n<8;n=n+1)reverse8[n]=x[7-n];
 endfunction
 function [31:0] reverse32(input [31:0] x);
  for(integer n=0;n<32;n=n+1)reverse32[n]=x[31-n];
 endfunction
 function [15:0] reverse16(input [15:0] x);
  for(integer n=0;n<16;n=n+1)reverse16[n]=x[15-n];
 endfunction
 function [15:0] step(input [15:0] x);
  reg [15:0] expanded;
  begin expanded={x[7:0],x[15:8]};step=expanded^(16'(x[15:8])<<3)^(16'(x[15:8])<<4)^(16'(x[15:8])<<5);end
 endfunction
 function [31:0] crc32(input [31:0] c,input [7:0] x);
  reg [31:0] v;
  begin v=c;for(integer n=0;n<8;n=n+1)v=(v<<1)^((v[31]^x[n])?32'h04c11db7:0);crc32=v;end
 endfunction
 function [15:0] crc16(input [15:0] c,input [7:0] x);
  reg [15:0] v;
  begin v=c;for(integer n=0;n<8;n=n+1)v=(v<<1)^((v[15]^x[n])?16'h100b:0);crc16=v;end
 endfunction
 function [31:0] swap(input [31:0] x);swap={x[7:0],x[15:8],x[23:16],x[31:24]};endfunction
 task push(input [7:0] x,input k,input scramble);
  queue[producer]={scramble,k,x};producer=producer+1;
 endtask
 always @(negedge clk) begin
  if(!rst) begin peer_lfsr=16'hffff;phy_rx=0;phy_rc=0;end
  else if(peer_enabled) begin
   rxword=0;rxk=0;
   for(lane=0;lane<2;lane=lane+1) begin
    symbol=consumer<producer?queue[consumer]:10'h200;
    if(consumer<producer)consumer=consumer+1;
    byte_value=symbol[7:0];
    if(!symbol[8]&&symbol[9])byte_value=byte_value^reverse8(peer_lfsr[15:8]);
    rxword[lane*8+:8]=byte_value;rxk[lane]=symbol[8];
    if(symbol[8]&&symbol[7:0]==8'hbc)peer_lfsr=16'hffff;
    else if(!(symbol[8]&&symbol[7:0]==8'h1c))peer_lfsr=step(peer_lfsr);
   end
   phy_rx=rxword;phy_rc=rxk;
  end
 end
 task ts(input ts2,input lp,input np);
  push(8'hbc,1,0);push(lp?8'hf7:8'h00,lp,0);push(np?8'hf7:8'h00,np,0);
  push(32,0,0);push(2,0,0);push(0,0,0);
  repeat(10)push(ts2?8'h45:8'h4a,0,0);
 endtask
 task dllp(input [31:0] body);
  reg [15:0] c;
  begin
   push(8'h5c,1,0);c=16'hffff;
   for(integer n=0;n<4;n=n+1)begin push(body[n*8+:8],0,1);c=crc16(c,body[n*8+:8]);end
   c=~reverse16(c);push(c[7:0],0,1);push(c[15:8],0,1);push(8'hfd,1,0);
  end
 endtask
 task fc(input [7:0] typ,input [7:0] h,input [11:0] d);
  dllp({d[7:0],h[1:0],2'b0,d[11:8],2'b0,h[7:2],typ});
 endtask
 task ack(input nak,input [11:0] seq);
  dllp({seq[7:0],4'b0,seq[11:8],8'b0,nak?8'h10:8'h00});
 endtask
 reg [31:0] outbound[0:63];
 task tlp(input [11:0] seq,input integer words,input corrupt);
  reg [31:0] c;reg [7:0] v;
  begin
   push(8'hfb,1,0);push({4'b0,seq[11:8]},0,1);push(seq[7:0],0,1);
   c=crc32(crc32(32'hffffffff,{4'b0,seq[11:8]}),seq[7:0]);
   for(integer n=0;n<words;n=n+1)for(integer b=0;b<4;b=b+1)begin
    v=outbound[n][b*8+:8];push(v,0,1);c=crc32(c,v);
   end
   c=~reverse32(c);if(corrupt)c=c^1;
   for(integer n=0;n<4;n=n+1)push(c[n*8+:8],0,1);
   push(8'hfd,1,0);
  end
 endtask
 task cpl(input [11:0] seq,input [7:0] tag,input withdata,input [31:0] value,input corrupt);
  outbound[0]=swap(withdata?32'h4a000001:32'h0a000000);
  outbound[1]=swap(32'h01000004);outbound[2]=swap({16'b0,tag,8'b0});outbound[3]=value;
  tlp(seq,withdata?4:3,corrupt);
 endtask
 // TX monitor checks framing, polynomial residue and captured request layout.
 reg [7:0] received[0:511];integer frame_kind=0,frame_bytes=0,packets=0,naks=0,acks=0,init1=0,init2_count=0;
 reg [31:0] captured[0:63];reg [11:0] captured_seq;
 reg [31:0] check32,actual32;reg [15:0] check16;
 integer errors=0;time last_packet_end=0,last_packet_start=0,replay_end=0;
 always @(posedge clk) if(rst) begin
  if(error)errors=errors+1;
  for(integer b=0;b<2;b=b+1) begin
   byte_value=phy_tx[b*8+:8];bypass=0;
   if(phy_tc[b]&&byte_value==8'hbc) begin monitor_lfsr=16'hffff;monitor_training=15;bypass=1;end
   else begin
    if(phy_tc[b]&&byte_value==8'h1c) begin monitor_training=0;skip_count=skip_count+1;bypass=1;end
    else begin
     if(monitor_training!=0) begin bypass=1;monitor_training=monitor_training-1;end
     if(!phy_tc[b]&&!bypass)byte_value=byte_value^reverse8(monitor_lfsr[15:8]);
     monitor_lfsr=step(monitor_lfsr);
    end
   end
   if(phy_tc[b]&&(byte_value==8'hfb||byte_value==8'h5c)) begin frame_kind=byte_value==8'hfb ? 1:2;frame_bytes=0;if(frame_kind==1)last_packet_start=$time;end
   else if(phy_tc[b]&&byte_value==8'hfd&&frame_kind!=0) begin
    if(frame_kind==1) begin
     check32=32'hffffffff;
     for(integer n=0;n<frame_bytes-4;n=n+1)check32=crc32(check32,received[n]);
     actual32={received[frame_bytes-1],received[frame_bytes-2],received[frame_bytes-3],received[frame_bytes-4]};
     if(actual32!==~reverse32(check32))$fatal(1,"Root emitted bad LCRC");
     captured_seq={received[0][3:0],received[1]};
     for(integer n=0;n<(frame_bytes-6)/4;n=n+1)captured[n]={received[5+4*n],received[4+4*n],received[3+4*n],received[2+4*n]};
     packets=packets+1;last_packet_end=$time;
    end else begin
     check16=16'hffff;for(integer n=0;n<4;n=n+1)check16=crc16(check16,received[n]);
     if({received[5],received[4]}!==~reverse16(check16))$fatal(1,"Root emitted bad DLLP CRC");
     if(received[0]==8'h10)naks=naks+1;
     if(received[0]==0)acks=acks+1;
     if(received[0]==8'h40)init1=init1+1;
     if(received[0]==8'hc0)init2_count=init2_count+1;
     if(received[0]==8'h80)begin
      profile_limit_h={received[1][5:0],received[2][7:6]};
      profile_limit_d={received[2][3:0],received[3]};
     end
    end
    frame_kind=0;
   end else if(!phy_tc[b]&&frame_kind!=0) begin received[frame_bytes]=byte_value;frame_bytes=frame_bytes+1;end
  end
 end else begin monitor_lfsr=16'hffff;monitor_training=0;frame_kind=0;frame_bytes=0;end
 task cycles(input integer n);repeat(n)begin @(posedge clk);#1;end endtask
 task command(input [2:0] kind,input [63:0] a,input [31:0] value);
  wait(cr);@(negedge clk);op=kind;addr=a;cmddata=value;cv=1;@(negedge clk);cv=0;
 endtask
 task response(input [31:0] value);
  wait(rspv);if(rspstatus!==0||rspdata!==value)$fatal(1,"Root response %0d %08x wanted %08x",rspstatus,rspdata,value);
  cycles(5);@(negedge clk);rspr=1;@(negedge clk);rspr=0;cycles(1);
 endtask
 integer trace_state=-1;
 always @(posedge clk) if($test$plusargs("TRACE")) begin
  if(state!==trace_state)begin $display("TRACE state=%0d t=%0t",state,$time);trace_state=state;end
  if(dut.rx_dllp_valid)$display("TRACE RX DLLP=%08x phase=%0d seen=%b",dut.rx_dllp,dut.flow.phase_q,dut.flow.seen_q);
  if(dut.rx_packet_error)$display("TRACE RX error body=%0d tail=%08x crc16=%04x",dut.receiver.body_q,dut.receiver.tail_q,dut.receiver.crc16_q);
  if(dut.fc_dllp_valid&&dut.fc_dllp_ready)$display("TRACE TX FC=%02x phase=%0d seen=%b seen2=%b",dut.fc_type,dut.flow.phase_q,dut.flow.seen_q,dut.flow.seen2_q);
  if($time>120000)$finish;
 end
 wire msi,fault,idle;wire [4:0] vector;
 wire [31:0] awaddr,araddr;wire [63:0] wdata;wire [7:0] awlen,arlen;
 wire [2:0] awsize,awprot,arsize,arprot;wire [1:0] awburst,arburst;
 wire [3:0] awcache,arcache;wire [7:0] wstrb;wire awvalid,wvalid,wlast,bready,arvalid,rready;
 reg awready=0,wready=0,bvalid=0,arready=0,rvalid=0,rlast=0;
 reg [1:0] bresp=0,rresp=0;reg [63:0] rdata=0;
 pcie_ddr_bridge bridge(.clk(clk),.rst_n(rst),.link_active_i(active),.dma_enable_i(1'b1),
 .rx_last_single_i(1'b0),.rx_data_i(ard),.rx_valid_i(arv),.rx_last_i(arl),.rx_ready_o(arr),
 .tx_data_o(atd),.tx_valid_o(atv),.tx_last_o(atl),.tx_ready_i(atr),.tx_credits_o(atcost),
 .msi_valid_o(msi),.msi_vector_o(vector),.fault_o(fault),.idle_o(idle),
 .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awcache(awcache),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
 .m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arburst(arburst),.m_axi_arcache(arcache),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
 .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
 always @(posedge clk) if(profile_running) begin
  profile_states[bridge.state_q]=profile_states[bridge.state_q]+1;
  // These channel occupancies overlap packet preparation; not FSM states.
  if(awvalid)profile_aw=profile_aw+1;
  if(wvalid)profile_w=profile_w+1;
  if(bready)profile_b=profile_b+1;
 end
 reg [7:0] mem[0:8191];integer cycle=0,writes=0,reads=0,interrupts=0;
 reg writing=0,reading=0,inject_b=0,inject_r=0,hold_b=0;
 integer wa=0,wl=0,wi=0,ra=0,rl=0,ri=0,profile_b_count=0;
 always @(negedge clk)begin
  cycle=cycle+1;
  // This integration model accepts only one write at a time, including B delay.
  awready=!writing&&!bvalid&&profile_b_count==0&&cycle%3!=0;
  wready=writing&&cycle%5!=0;arready=!reading&&!rvalid&&cycle%4!=0;

 end
 always @(posedge clk)begin
  if(!rst)begin writing<=0;reading<=0;bvalid<=0;rvalid<=0;end
  else begin
   if(awvalid&&awready)begin
    if(awsize!=3||awaddr[2:0]!=0||awburst!=1||awaddr+8*(awlen+1)>8192||awaddr[11:0]+8*(awlen+1)>4096)$fatal(1,"Bad AXI write burst");
    wa<=awaddr;wl<=awlen+1;wi<=0;writing<=1;writes<=writes+1;
   end
   if(wvalid&&wready)begin
    if(wlast!==(wi==wl-1))$fatal(1,"AXI WLAST");
    for(integer b=0;b<8;b=b+1)if(wstrb[b])mem[wa+wi*8+b]<=wdata[b*8+:8];
    if(wlast)begin
     writing<=0;bvalid<=PROFILE_B_DELAY==0;profile_b_count<=PROFILE_B_DELAY;
     bresp<=inject_b?2:0;
    end else wi<=wi+1;
   end
   if(profile_b_count>0)begin
    profile_b_count<=profile_b_count-1;
    if(profile_b_count==1)bvalid<=1;
   end
   if(bvalid&&bready&&!hold_b)bvalid<=0;
   if(arvalid&&arready)begin
    if(arsize!=3||araddr[2:0]!=0||arburst!=1||arlen>7||araddr+8*(arlen+1)>8192||araddr[5:0]+8*(arlen+1)>64)$fatal(1,"Bad AXI read/RCB burst");
    ra<=araddr;rl<=arlen+1;ri<=0;reading<=1;reads<=reads+1;
   end
   if(reading&&(!rvalid||rready)&&cycle%3!=0)begin
    for(integer b=0;b<8;b=b+1)rdata[b*8+:8]<=mem[ra+ri*8+b];
    rvalid<=1;rlast<=ri==rl-1;rresp<=inject_r?2:0;
    if(ri==rl-1)reading<=0;else ri<=ri+1;
   end else if(rvalid&&rready)rvalid<=0;
   if(msi)begin
    if(vector!=17)$fatal(1,"MSI vector");
    if(mem[4096]!=8'h00||mem[4223]!=8'hba)$fatal(1,"MSI overtook DDR write");
    interrupts<=interrupts+1;
   end
  end
 end

 initial begin
  for(integer n=0;n<8192;n=n+1)mem[n]=0;
  cycles(4);@(negedge clk);rst=1;
  wait(detect);@(negedge clk);detectdone=1;@(negedge clk);detectdone=0;rxidle=0;peer_enabled=1;
  wait(state==2);repeat(1030)ts(0,1,1);
  wait(state==3);repeat(32)ts(1,1,1);
  wait(state==4);repeat(8)ts(0,0,1);
  wait(state==6);repeat(12)ts(0,0,0);
  wait(state==8);repeat(32)ts(1,0,0);
  wait(state==10);fc(8'h40,2,16);fc(8'h50,2,16);fc(8'h60,0,0);
  fc(8'hc0,2,16);fc(8'hd0,2,16);fc(8'he0,0,0);
  wait(init2_count!=0);fc(8'hc0,2,16);fc(8'hd0,2,16);fc(8'he0,0,0);
  wait(active);cycles(30);
  if($test$plusargs("PROFILE"))begin
   for(integer n=0;n<9;n=n+1)profile_states[n]=0;
   profile_start=$time;profile_running=1;
   // Model SSD read-data DMA: maximum-payload posted writes to host memory.
   // Admit using only decoded wire UpdateFC counters, never internal readiness.
   while(profile_count<512)begin
    @(negedge clk);
    if(consumer==producer)begin
     if(8'(profile_limit_h-profile_used_h)!=0 &&
        12'(profile_limit_d-profile_used_d)>=8)begin
      outbound[0]=swap(32'h40000020);outbound[1]=swap(32'h01005aff);
      outbound[2]=swap(32'h1000);
      for(integer n=0;n<32;n=n+1)outbound[n+3]=32'hba000000+n;
      tlp(12'(profile_count),35,0);
      profile_used_h=profile_used_h+1'b1;profile_used_d=profile_used_d+12'd8;
      profile_count=profile_count+1;
     end else profile_wait=profile_wait+1;
    end
   end
   wait(writes==512);wait(idle);profile_running=0;
   if(fault||errors||mem[4223]!=8'hba)$fatal(1,"Profile fault/data %b/%0d",fault,errors);
   $display("PROFILE fc_cycles=%0d b_delay=%0d bytes=65536 ns=%0d MBps=%0f credit_wait=%0d RX=%0d CHECK=%0d AW_offer=%0d W_offer=%0d B_owned=%0d",
    PROFILE_FC_CYCLES,PROFILE_B_DELAY,$time-profile_start,
    65536.0*1000.0/($time-profile_start),profile_wait,
    profile_states[0],profile_states[1],profile_aw,profile_w,profile_b);
   $finish;
  end
  command(2,0,0);wait(packets==1);ack(0,0);cpl(0,0,1,32'h12348086,0);response(32'h12348086);
  command(1,64'ha3001000,32'hdeadbeef);wait(packets==2);
  if(captured[0]!==swap(32'h40000001)||captured[2]!==swap(32'ha3001000)||captured[3]!==32'hdeadbeef)$fatal(1,"BAR write layout");
  response(0);ack(0,1);
  command(0,64'ha3000000,0);wait(packets==3);ack(0,2);cpl(1,2,1,32'hcafef00d,0);response(32'hcafef00d);
  outbound[0]=swap(32'h60000020);outbound[1]=swap(32'h01005aff);outbound[2]=0;outbound[3]=swap(32'h1000);
  for(integer n=0;n<32;n=n+1)outbound[n+4]=32'hba000000+n;
  tlp(2,36,0);wait(writes==1);wait(idle);cycles(4);
  outbound[0]=swap(32'h00000014);outbound[1]=swap(32'h01005aff);outbound[2]=swap(32'h1004);tlp(3,3,0);
  wait(packets==4);
  if(captured[0]!==swap(32'h4a00000f)||captured[1]!==swap(80)||captured[2]!==swap(32'h01005a04))$fatal(1,"First split completion header");
  for(integer n=0;n<15;n=n+1)if(captured[n+3]!==32'hba000001+n)$fatal(1,"First DDR data");
  ack(0,3);wait(packets==5);
  if(captured[0]!==swap(32'h4a000005)||captured[1]!==swap(20)||captured[2]!==swap(32'h01005a40))$fatal(1,"Second split completion header");
  for(integer n=0;n<5;n=n+1)if(captured[n+3]!==32'hba000010+n)$fatal(1,"Second DDR data");
  ack(0,4);
  outbound[0]=swap(32'h40000001);outbound[1]=swap(32'h01005a0f);outbound[2]=swap(32'hfee00000);outbound[3]=17;tlp(4,4,0);
  wait(interrupts==1);cycles(30);
  if(fault||errors||writes!=1||reads!=2)$fatal(1,"Integrated bridge faults/counts %b/%0d/%0d/%0d",fault,errors,writes,reads);
  $display("PASS HOST LINK: independent symbol partner config/BAR requests, DDR writes/read completions, CRC/sequence/FC and MSI ordering");$finish;
 end
 initial begin if($test$plusargs("PROFILE"))#20000000;else #2000000;$fatal(1,"host-link watchdog state=%0d packets=%0d",state,packets);end
endmodule

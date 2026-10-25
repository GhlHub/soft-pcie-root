`timescale 1ns/1ps
module tb_ddr_bridge;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,active=1,enable=1;
 reg [7:0] header_tag=8'h5a,expected_tag=8'h5a;
 reg [31:0] rxdata=0;reg rxvalid=0,rxlast=0;wire rxready;
 wire [31:0] txdata;wire txvalid,txlast;reg txready=0;wire [8:0] cost;
 wire [31:0] perf;
 wire msi,fault,idle;wire [4:0] vector;
 wire [31:0] awaddr,araddr;wire [63:0] wdata;wire [7:0] awlen,arlen;
 wire [2:0] awsize,awprot,arsize,arprot;wire [1:0] awburst,arburst;
 wire [3:0] awcache,arcache;wire [7:0] wstrb;wire awvalid,wvalid,wlast,bready,arvalid,rready;
 reg awready=0,wready=0,bvalid=0,arready=0,rvalid=0,rlast=0;
 reg [1:0] bresp=0,rresp=0;reg [63:0] rdata=0;
 pcie_ddr_bridge dut(.clk(clk),.rst_n(rst),.link_active_i(active),.dma_enable_i(enable),
 .rx_data_i(rxdata),.rx_valid_i(rxvalid),.rx_last_i(rxlast),.rx_ready_o(rxready),
 .tx_data_o(txdata),.tx_valid_o(txvalid),.tx_last_o(txlast),.tx_ready_i(txready),.tx_credits_o(cost),
 .perf_events_o(perf),.msi_valid_o(msi),.msi_vector_o(vector),.fault_o(fault),.idle_o(idle),
 .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awcache(awcache),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
 .m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arburst(arburst),.m_axi_arcache(arcache),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
 .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
 reg [7:0] mem[0:8191];integer cycle=0,writes=0,reads=0,interrupts=0;
 reg writing=0,reading=0,inject_b=0,inject_r=0,hold_b=0,hold_tx=0,hold_r=0,hold_ar=0,hold_aw=0,hold_w=0;
 integer wa=0,wl=0,wi=0,ri=0;
 integer w_accepted_q=0,b_in_q=0,b_out_q=0,ar_in_q=0,r_out_q=0,r_send_q=0;
 integer b_budget=-1,max_w=0,max_r=0,r_last_adjust=0;
 reg [1:0] b_queue[0:1];
 integer ra_queue[0:1],rl_queue[0:1];
 wire b_pending=b_in_q!=b_out_q;
 always @* reading=ar_in_q!=r_out_q;
 always @(negedge clk)begin
  cycle=cycle+1;awready=!hold_aw&&!writing&&(w_accepted_q-b_out_q)<2&&cycle%3!=0;
  wready=!hold_w&&writing&&cycle%5!=0;arready=!hold_ar&&(ar_in_q-r_out_q)<2&&cycle%4!=0;
  txready=!hold_tx&&cycle%7!=0&&cycle%7!=1;
 end
 always @(posedge clk)begin
  if(!rst)begin
   writing<=0;bvalid<=0;rvalid<=0;ri<=0;
   w_accepted_q<=0;b_in_q<=0;b_out_q<=0;ar_in_q<=0;r_out_q<=0;r_send_q<=0;
  end else begin
   if(w_accepted_q-b_out_q>max_w)max_w<=w_accepted_q-b_out_q;
   if(ar_in_q-r_out_q>max_r)max_r<=ar_in_q-r_out_q;
   if(w_accepted_q-b_out_q>2||ar_in_q-r_out_q>2)$fatal(1,"Outstanding AXI bound exceeded");
   if(awvalid&&awready)begin
    if(awsize!=3||awaddr[2:0]!=0||awburst!=1||awaddr+8*(awlen+1)>8192||awaddr[11:0]+8*(awlen+1)>4096)$fatal(1,"Bad AXI write burst");
    wa<=awaddr;wl<=awlen+1;wi<=0;writing<=1;writes<=writes+1;w_accepted_q<=w_accepted_q+1;
   end
   if(wvalid&&wready)begin
    if(wlast!==(wi==wl-1))$fatal(1,"AXI WLAST");
    for(integer b=0;b<8;b=b+1)if(wstrb[b])mem[wa+wi*8+b]<=wdata[b*8+:8];
    if(wlast)begin writing<=0;b_queue[b_in_q%2]<=inject_b?2:0;b_in_q<=b_in_q+1;end
    else wi<=wi+1;
   end
   if(b_pending&&!hold_b&&!bvalid&&b_budget!=0)begin bvalid<=1;bresp<=b_queue[b_out_q%2];end
   if(bvalid&&bready)begin bvalid<=0;b_out_q<=b_out_q+1;if(b_budget>0)b_budget<=b_budget-1;end
   if(arvalid&&arready)begin
    if(arsize!=3||araddr[2:0]!=0||arburst!=1||arlen>7||araddr+8*(arlen+1)>8192||araddr[5:0]+8*(arlen+1)>64)$fatal(1,"Bad AXI read/RCB burst");
    ra_queue[ar_in_q%2]<=araddr;rl_queue[ar_in_q%2]<=arlen+1;ar_in_q<=ar_in_q+1;reads<=reads+1;
   end
   if(r_send_q!=ar_in_q&&(!rvalid||rready)&&!hold_r&&cycle%3!=0)begin
    for(integer b=0;b<8;b=b+1)rdata[b*8+:8]<=mem[ra_queue[r_send_q%2]+ri*8+b];
    rvalid<=1;rlast<=ri==rl_queue[r_send_q%2]-1+r_last_adjust;rresp<=inject_r?2:0;
    if(ri==rl_queue[r_send_q%2]-1+r_last_adjust)begin r_send_q<=r_send_q+1;ri<=0;end else ri<=ri+1;
   end else if(rvalid&&rready)rvalid<=0;
   if(rvalid&&rready&&rlast)r_out_q<=r_out_q+1;
   if(msi)begin
    if(w_accepted_q!=b_out_q)$fatal(1,"MSI delivered before every B response");
    if(vector!=17)$fatal(1,"MSI vector");
    if(mem[4096]!=8'h00||mem[4223]!=8'hba)$fatal(1,"MSI overtook DDR write");
    interrupts<=interrupts+1;
   end
  end
 end
 // Profile signals checked against external handshakes and memory-model
 // ownership, including stalls and accepted-response drain after link loss.
 reg [31:0] perf_coverage=0;
 always @(posedge clk)if(rst)begin
  perf_coverage<=perf_coverage|perf;
  if(perf[8] !== (arvalid&&arready) || perf[10] !== (rvalid&&rready) ||
     perf[11] !== (rvalid&&rready&&rlast) || perf[9] !== (arvalid&&!arready) ||
     perf[4] !== (txvalid&&!txready) || perf[5] !== (txvalid&&txready) ||
     perf[7] !== (txvalid&&txready&&txlast))$fatal(1,"Profile handshake mismatch");
  if(perf[14] !== (ar_in_q-r_out_q==1) || perf[15] !== (ar_in_q-r_out_q==2))
   $fatal(1,"Profile outstanding latency occupancy mismatch");
  if(perf[2]&&txvalid)$fatal(1,"Empty completion slot reported during TX");
 end
 reg aw_stalled=0,w_stalled=0,ar_stalled=0,tx_stalled=0;
 reg [42:0] held_aw,held_ar;
 reg [72:0] held_w;
 reg [32:0] held_tx;
 always @(posedge clk)begin
  if(rst)begin
   if(aw_stalled&&(!awvalid||{awaddr,awlen,awsize}!==held_aw))$fatal(1,"Unstable AW offer");
   if(w_stalled&&(!wvalid||{wdata,wstrb,wlast}!==held_w))$fatal(1,"Unstable W offer");
   if(ar_stalled&&(!arvalid||{araddr,arlen,arsize}!==held_ar))$fatal(1,"Unstable AR offer");
   if(tx_stalled&&active&&(!txvalid||{txdata,txlast}!==held_tx))$fatal(1,"Unstable completion offer");
  end
  aw_stalled<=rst&&awvalid&&!awready;held_aw<={awaddr,awlen,awsize};
  w_stalled<=rst&&wvalid&&!wready;held_w<={wdata,wstrb,wlast};
  ar_stalled<=rst&&arvalid&&!arready;held_ar<={araddr,arlen,arsize};
  tx_stalled<=rst&&active&&txvalid&&!txready;held_tx<={txdata,txlast};
 end
 function [31:0] swap(input [31:0] v);swap={v[7:0],v[15:8],v[23:16],v[31:24]};endfunction
 task send(input [31:0] d,input last);
  @(negedge clk);rxdata=d;rxvalid=1;rxlast=last;
  do @(posedge clk);while(!rxready);
  @(negedge clk);rxvalid=0;
 endtask
 task header(input write,input four,input [63:0] addr,input integer len,input [3:0] firstbe,lastbe);
  send(swap((write?(four?32'h60000000:32'h40000000):(four?32'h20000000:0))|(len&1023)),0);
  send(swap(32'h01000000|({24'b0,header_tag}<<8)|((lastbe<<4)|firstbe)),0);
  if(four)send(swap(addr[63:32]),0);
  send(swap(addr[31:0]),!write);
 endtask
 task reset;
  wait(idle);@(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;active=1;enable=1;
 endtask
 task completion(input integer bytes,lower,words,input integer base,input integer status);
  integer index;reg [31:0] expected;
  begin
   index=0;
   while(index<(status==0?words+3:3))begin
    @(posedge clk);
    if(txvalid&&txready)begin
     case(index)
      0:expected=swap((status==0?32'h4a000000:32'h0a000000)|(status==0?words:0));
      1:expected=swap((status<<13)|(bytes&4095));
      2:expected=swap(32'h01000000|({24'b0,expected_tag}<<8)|lower);
      default:expected={mem[base+(index-3)*4+3],mem[base+(index-3)*4+2],mem[base+(index-3)*4+1],mem[base+(index-3)*4]};
     endcase
     if(txdata!==expected||txlast!==(index==(status==0?words+2:2)))$fatal(1,"Completion index%0d data %x expected%x last%b",index,txdata,expected,txlast);
     if(cost!==(status==0?(words+3)/4:0))$fatal(1,"Completion credits");
     index=index+1;
    end
   end
  end
 endtask
 integer prior,offset,n,left,chunk,byteleft;
 initial begin
  for(n=0;n<8192;n=n+1)mem[n]=(n*7+3)&255;
  repeat(4)@(negedge clk);rst=1;
  // Maximum MPS128 four-DWORD write with byte-enable edge masks.
  header(1,1,4096,32,4'hc,4'h3);
  for(n=0;n<32;n=n+1)send(32'hba000000+n,n==31);
  wait(idle);@(negedge clk);
  if(mem[4096]!==8'h03||mem[4097]!==8'h0a||mem[4098]!==0||mem[4099]!==8'hba||mem[4220]!==31||mem[4223]!==8'h7c)$fatal(1,"Write byte enable corruption");
  // Full write then MSI must wait for the actual DDR write response.
  header(1,0,4096,32,15,15);for(n=0;n<32;n=n+1)send(32'hba000000+n,n==31);
  header(1,1,64'hfee00000,1,15,0);send(17,1);
  wait(idle);repeat(3)@(negedge clk);if(interrupts!=1||fault)$fatal(1,"MSI/DMA status");
  // Misaligned-to-RCB 512-byte read, first/last enabled-byte edges.
  header(0,1,4100,128,4'hc,4'h7);left=128;offset=4100;byteleft=509;
  while(left>0)begin
   chunk=16-((offset>>2)&15);if(chunk>left)chunk=left;
   completion(byteleft,(offset&127)+(left==128?2:0),chunk,offset,0);
   byteleft=byteleft-(chunk*4)+(left==128?2:0);offset=offset+chunk*4;left=left-chunk;
  end
  wait(idle);if(fault)$fatal(1,"Read fault");
  // Encoded zero length means 4096 bytes, not an empty request.
  header(0,0,0,1024,15,15);
  for(n=0;n<64;n=n+1)completion(4096-n*64,(n*64)&127,16,n*64,0);
  wait(idle);if(fault)$fatal(1,"4KiB read fault");
  header(0,0,64,1,4'h5,0);completion(3,64,1,64,0);wait(idle);
  // Zero-byte flush must not perform an AXI read or leak stale packet data.
  prior=reads;header(0,0,128,1,0,0);
  n=0;while(n<4)begin @(posedge clk);if(txvalid&&txready)begin
   if(n==1&&swap(txdata)!=1)$fatal(1,"Zero-byte count");
   if(n==3&&txdata!=0)$fatal(1,"Zero-byte completion data");n=n+1;
  end end
  wait(idle);if(reads!=prior)$fatal(1,"Zero-byte flush touched DDR");
  // DDR errors produce CA and sticky fatal quarantine.
  inject_r=1;header(0,0,64,4,15,15);completion(0,0,0,0,4);wait(idle);
  if(!fault)$fatal(1,"Missing AXI RRESP fault");inject_r=0;reset();
  // Out-of-range/high-address reads return UR and never reach AXI.
  prior=reads;header(0,1,64'h100000040,4,15,15);completion(0,0,0,0,1);wait(idle);
  if(reads!=prior||!fault)$fatal(1,"DDR range bypass");reset();
  // Crossing 4KiB and malformed payload cannot modify memory.
  prior=writes;header(1,0,4092,2,15,15);send(32'hffffffff,0);send(32'hffffffff,1);wait(idle);
  if(writes!=prior||!fault)$fatal(1,"4KiB write bypass");reset();
  header(1,0,4096,2,15,15);send(32'hffffffff,1);wait(idle);
  if(writes!=prior||!fault)$fatal(1,"Truncated write bypass");reset();
  // AXI write errors quarantine; disabled admission cannot issue memory reads.
  inject_b=1;header(1,0,512,1,15,0);send(32'h11112222,1);wait(idle);
  if(!fault)$fatal(1,"Missing B error quarantine");inject_b=0;reset();
  enable=0;prior=reads;header(0,0,64,1,15,0);completion(0,0,0,0,1);wait(idle);
  if(!fault||reads!=prior)$fatal(1,"Disabled DMA issued AXI");reset();
  prior=writes;header(1,1,4096,33,15,15);
  for(n=0;n<33;n=n+1)send(32'hffffffff,n==32);wait(idle);
  if(!fault||writes!=prior)$fatal(1,"Oversized payload issued AXI");reset();
  prior=writes;
  send(swap(32'h40000401),0);send(swap(32'h01005a0f),0);send(swap(512),0);send(32'h12345678,1);wait(idle);
  if(!fault||writes!=prior)$fatal(1,"Translated address type accepted");reset();
  // Both DWORD alignments, every MPS length and byte-lane guards.
  for(integer align=0;align<2;align=align+1)begin
   for(integer len=1;len<=32;len=len+1)begin
    for(integer b=0;b<144;b=b+1)mem[1024+b]=8'hcc;
    header(1,0,1024+align*4,len,len==1?4'h5:4'hc,len==1?0:4'h3);
    for(integer j=0;j<len;j=j+1)send(32'h44332211,j==len-1);
    wait(idle);@(negedge clk);
    for(integer b=0;b<144;b=b+1)begin
     if(b>=align*4&&b<(align+len)*4&&
        (len==1?((b%4)==0||(b%4)==2):
        ((b>=align*4+4||(b%4)>=2)&&(b<(align+len-1)*4||(b%4)<2))))begin
      if(mem[1024+b]!==8'(32'h44332211>>((b%4)*8)))$fatal(1,"64-bit write lane len%0d align%0d byte%0d",len,align,b);
     end else if(mem[1024+b]!==8'hcc)$fatal(1,"64-bit write guard");
    end
    header(0,0,1024+align*4,len,len==1?4'h5:4'hc,len==1?0:4'h3);
    left=len;offset=1024+align*4;byteleft=len==1?3:len*4-4;
    while(left>0)begin
     chunk=16-((offset>>2)&15);if(chunk>left)chunk=left;
     completion(byteleft,(offset&127)+(left==len&&len!=1?2:0),chunk,offset,0);
     byteleft=byteleft-chunk*4+(left==len&&len!=1?2:0);
     offset=offset+chunk*4;left=left-chunk;
    end
    wait(idle);if(fault)$fatal(1,"64-bit alignment sweep fault");
   end
  end
  // Two writes remain outstanding while a checked third waits and four queue.
  prior=writes;hold_b=1;
  header(1,0,512,1,15,0);send(32'h12345678,1);wait(b_pending);
  for(n=0;n<5;n=n+1)begin header(1,0,520+n*8,1,15,0);send(32'h55667788+n,1);end
  header(1,0,64'hfee00000,1,15,0);send(17,1);
  repeat(12)@(negedge clk);
  if(rxready||idle||writes!=prior+2||interrupts!=1)$fatal(1,"Pending capacity/order failure");
  // A fifth pending packet must be backpressured until a slot is released.
  rxvalid=1;rxdata=swap(32'h40000001);rxlast=0;
  repeat(8)begin @(posedge clk);if(rxready)$fatal(1,"Full queue accepted extra DWORD");end
  @(negedge clk);hold_b=0;
  do @(posedge clk);while(!rxready);
  @(negedge clk);rxvalid=0;
  send(swap(32'h01005a0f),0);send(swap(560),0);send(32'habcdef01,1);
  wait(idle);repeat(3)@(negedge clk);
  if(writes!=prior+7||interrupts!=2||fault||mem[560]!=1||mem[536]!=8'h8a)$fatal(1,"Pending drain/wrap failure");
  // Two AR handshakes before any R response. No third slot may issue while
  // the completion sink is stalled, even after both responses finish.
  prior=reads;hold_r=1;hold_tx=1;
  header(0,0,2048,48,15,15);wait(reads==prior+2);repeat(10)@(negedge clk);
  if(reads!=prior+2||dut.read_pending_q!=2)$fatal(1,"Two reads were not outstanding");
  hold_r=0;wait(dut.slot_done_q==2'b11);repeat(10)@(negedge clk);
  if(reads!=prior+2)$fatal(1,"Read slot reused while completion stalled");
  hold_tx=0;
  completion(192,0,16,2048,0);completion(128,64,16,2112,0);completion(64,0,16,2176,0);
  wait(idle);if(fault)$fatal(1,"Prefetch completion integrity");
  // Explicit two-B MSI fence: returning only the first B is insufficient.
  hold_b=1;prior=interrupts;
  header(1,0,600,1,15,0);send(32'h1,1);
  header(1,0,608,1,15,0);send(32'h2,1);
  header(1,0,64'hfee00000,1,15,0);send(17,1);
  wait(dut.write_out_q==2);repeat(12)@(negedge clk);
  if(interrupts!=prior)$fatal(1,"MSI before both B responses");
  b_budget=1;hold_b=0;wait(dut.write_out_q==1);repeat(12)@(negedge clk);
  if(interrupts!=prior||idle)$fatal(1,"MSI escaped after first B only");
  b_budget=-1;wait(idle);repeat(3)@(negedge clk);
  if(interrupts!=prior+1||fault)$fatal(1,"MSI did not follow second B");
  // Pending reads retain requester tags and payload while TX is stalled.
  hold_tx=1;
  header(0,0,1028,3,15,15);wait(txvalid);
  header_tag=8'ha7;header(0,1,1084,2,15,15);header_tag=8'h5a;
  repeat(10)@(negedge clk);
  if(dut.pending_count_q!=1||idle)$fatal(1,"Read was not queued behind held completion");
  hold_tx=0;
  completion(12,4,3,1028,0);
  expected_tag=8'ha7;completion(8,60,1,1084,0);
  completion(4,64,1,1088,0);expected_tag=8'h5a;
  wait(idle);if(fault)$fatal(1,"Pending read completion failure");
  // Drop queued requests on link loss but drain the active accepted write.
  prior=writes;hold_b=1;
  header(1,0,512,1,15,0);send(32'h98765432,1);wait(b_pending);
  header(1,0,520,1,15,0);send(32'hffffffff,1);
  @(negedge clk);active=0;repeat(4)@(negedge clk);
  if(idle||!fault||!bready)$fatal(1,"Lost active ownership during queue flush");
  hold_b=0;wait(idle);@(negedge clk);
  if(writes!=prior+1||mem[520]!=8'h88)$fatal(1,"Queued request survived link loss");
  reset();prior=writes;
  // Link loss after AXI acceptance must finish B; no reset/withdrawal.
  header(1,0,512,4,15,15);for(n=0;n<4;n=n+1)send(32'h12345678,n==3);
  wait(awvalid&&awready);@(negedge clk);active=0;
  wait(idle);if(writes!=prior+1||!fault||mem[512]!=8'h78)$fatal(1,"Link loss lost accepted DMA");
  reset();prior=reads;
  header(0,0,1028,15,15,15);wait(arvalid&&arready);
  @(negedge clk);active=0;
  wait(idle);@(negedge clk);
  if(reads!=prior+1||!fault||txvalid||reading||rvalid)$fatal(1,"Link loss lost accepted read drain");
  reset();prior=reads;hold_r=1;
  header(0,0,2048,48,15,15);wait(reads==prior+2);
  @(negedge clk);active=0;repeat(5)@(negedge clk);
  if(idle||!rready||!fault)$fatal(1,"Two reads lost on link loss");
  hold_r=0;wait(idle);if(reads!=prior+2||reading||rvalid||txvalid)$fatal(1,"Two read drain failure");
  reset();prior=reads;hold_ar=1;
  header(0,0,2048,32,15,15);wait(arvalid);
  @(negedge clk);active=0;repeat(5)@(negedge clk);
  if(!arvalid||idle)$fatal(1,"Held AR cancelled on loss");
  hold_ar=0;wait(idle);if(reads!=prior+1||!fault)$fatal(1,"Held AR not drained");
  reset();hold_b=1;prior=interrupts;
  inject_b=1;header(1,0,600,1,15,0);send(3,1);wait(b_pending);inject_b=0;
  header(1,0,608,1,15,0);send(4,1);wait(dut.write_out_q==2);
  header(1,0,64'hfee00000,1,15,0);send(17,1);
  hold_b=0;wait(idle);repeat(3)@(negedge clk);
  if(!fault||interrupts!=prior)$fatal(1,"B error must suppress MSI after drain");
  // An error in the first prefetched burst still drains the second accepted
  // burst, produces just one CA, and must not issue the remaining third.
  reset();prior=reads;hold_r=1;inject_r=1;
  header(0,0,2048,48,15,15);wait(reads==prior+2);
  hold_r=0;completion(0,0,0,0,4);wait(idle);
  if(reads!=prior+2||!fault||reading||rvalid||txvalid)$fatal(1,"Read error lost prefetched ownership");
  inject_r=0;
  reset();hold_b=1;prior=writes;
  header(1,0,600,1,15,0);send(5,1);
  header(1,0,608,1,15,0);send(6,1);wait(dut.write_out_q==2);
  @(negedge clk);active=0;repeat(6)@(negedge clk);
  if(idle||!bready||!fault)$fatal(1,"Two B owners lost on link loss");
  b_budget=1;hold_b=0;wait(dut.write_out_q==1);repeat(6)@(negedge clk);
  if(idle||!bready)$fatal(1,"Idle before second B drained");
  b_budget=-1;wait(idle);if(writes!=prior+2)$fatal(1,"Unexpected write after link loss");
  // Malformed RLAST at either side of the expected beat count must retain
  // the second burst owner and never expose a partial successful completion.
  for(integer adjustment=-1;adjustment<=1;adjustment=adjustment+2)begin
   reset();prior=reads;hold_r=1;r_last_adjust=adjustment;
   header(0,0,2048,48,15,15);wait(reads==prior+2);hold_r=0;
   completion(0,0,0,0,4);wait(idle);
   if(reads!=prior+2||!fault||reading||rvalid)$fatal(1,"Malformed RLAST ownership");
  end
  r_last_adjust=0;
  // A zero-byte flush also fences both earlier writes without reading DDR.
  reset();hold_b=1;prior=reads;
  header(1,0,600,1,15,0);send(7,1);
  header(1,0,608,1,15,0);send(8,1);wait(dut.write_out_q==2);
  header(0,0,128,1,0,0);repeat(12)@(negedge clk);
  if(txvalid||reads!=prior)$fatal(1,"Zero-byte flush bypassed B fence");
  b_budget=1;hold_b=0;wait(dut.write_out_q==1);repeat(12)@(negedge clk);
  if(txvalid)$fatal(1,"Zero-byte flush escaped first B");
  b_budget=-1;
  n=0;while(n<4)begin @(posedge clk);if(txvalid&&txready)begin
   if(n==1&&swap(txdata)!=1)$fatal(1,"Flush byte count");
   if(n==3&&txdata!=0)$fatal(1,"Flush data");n=n+1;
  end end
  wait(idle);if(reads!=prior||fault)$fatal(1,"Flush touched DDR");
  // Writer owns the payload even before AW acceptance. Preparing an MSI
  // concurrently must not mistake zero accepted B owners for an empty fence.
  reset();hold_aw=1;prior=interrupts;
  header(1,0,4096,32,15,15);for(n=0;n<32;n=n+1)send(32'hba000000+n,n==31);
  wait(awvalid);
  header(1,0,64'hfee00000,1,15,0);send(17,1);
  repeat(16)@(negedge clk);
  if(dut.write_out_q!=0||interrupts!=prior||idle||!awvalid)$fatal(1,"MSI bypassed offered AW owner");
  hold_aw=0;wait(idle);repeat(3)@(negedge clk);
  if(interrupts!=prior+1||fault)$fatal(1,"MSI after pipelined writer");
  // The next packet is prepared during W backpressure but cannot overwrite
  // the writer's payload or metadata. Malformed next packet waits then faults.
  reset();hold_w=1;prior=writes;
  header(1,0,1028,32,4'hc,4'h3);for(n=0;n<32;n=n+1)send(32'h44332211,n==31);
  wait(wvalid);
  header(1,0,4092,2,15,15);send(32'hffffffff,0);send(32'hffffffff,1);
  repeat(16)@(negedge clk);
  if(dut.count_q!=5||dut.pending_count_q!=0||!wvalid||idle)$fatal(1,"Preparation did not overlap stalled W");
  hold_w=0;wait(idle);
  if(writes!=prior+1||!fault||mem[1030]!=8'h33||mem[1152]!=8'h11||mem[1153]!=8'h22)$fatal(1,"Pipelined validation/payload isolation");
  // Held AW and a fully prepared following packet survive independently:
  // loss drops only the unissued packet, and drains the already offered AW.
  reset();hold_aw=1;prior=writes;
  header(1,0,1024,32,15,15);for(n=0;n<32;n=n+1)send(32'hdead0000+n,n==31);
  wait(awvalid);
  header(1,0,2048,32,15,15);for(n=0;n<32;n=n+1)send(32'hbad00000+n,n==31);
  wait(dut.count_q==35);@(negedge clk);active=0;
  repeat(8)@(negedge clk);
  if(!awvalid||idle||!fault)$fatal(1,"Held pipelined AW lost");
  hold_aw=0;wait(idle);
  if(writes!=prior+1||mem[1027]!=8'hde||mem[1148]!=31)$fatal(1,"Held writer drain/payload failure");
  // An earlier failing B suppresses a fully prepared next write; an already
  // offered second AW must still drain even when that B error arrives.
  reset();hold_b=1;inject_b=1;prior=writes;
  header(1,0,600,1,15,0);send(9,1);wait(b_pending);inject_b=0;
  hold_aw=1;header(1,0,608,1,15,0);send(10,1);wait(awvalid);
  header(1,0,616,1,15,0);send(11,1);repeat(16)@(negedge clk);
  hold_b=0;wait(fault);repeat(4)@(negedge clk);
  if(!awvalid||idle)$fatal(1,"B error cancelled offered AW");
  hold_aw=0;wait(idle);
  if(writes!=prior+2||mem[608]!=10)$fatal(1,"B error failed to drain writer/quarantine next packet");
  if((perf_coverage&32'h0003ffff)!=32'h0003ffff)$fatal(1,"Missing read profile coverage %x",perf_coverage);
  if(max_w!=2||max_r!=2)$fatal(1,"Two outstanding coverage absent");
  $display("PASS DDR: two outstanding reads/writes, all-B-before-MSI, prefetched slots, held-AR and two-read drain, B-error MSI suppression,");
  $display("PASS DDR: MPS128 writes, BE, MSI ordering, RCB64/512B/4KiB completions, zero-byte flush, errors, bounds, malformed and link-loss drain");$finish;
 end
 initial begin #3000000;$fatal(1,"watchdog state%0d",dut.state_q);end
endmodule

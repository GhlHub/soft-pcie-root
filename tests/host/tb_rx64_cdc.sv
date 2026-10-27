`timescale 1ns/1ps
// End-to-end pair packing and whole-packet CDC; independent DWORD scoreboard.
module tb_rx64_cdc;
 reg sclk=0,mclk=0,rst=0,run_s=1,run_m=1;
 integer shalf=2;
 always begin #(shalf);if(run_s)sclk=~sclk;end
 always begin #4;if(run_m)mclk=~mclk;end
 reg [2:0] release_q=0;
 always @(posedge sclk or negedge rst)
  if(!rst)release_q<=0;else release_q<={release_q[1:0],1'b1};
 reg [31:0] sd=0;reg sv=0,sl=0,mr=0;
 wire sr,pv,pl,pr,mv,ml,fault;wire [64:0] pd,md;
 pcie_rx_pack pack(sclk,release_q[2],sd,sv,sl,sr,pd,pv,pl,pr);
 pcie_cdc_packet #(.WIDTH(65),.WORDS(32),.SLOTS(4)) dut(
  sclk,mclk,rst,pd,pv,pl,pr,fault,md,mv,ml,mr);
 integer sent=0,received=0,word_index=0,backpressure=0;
 integer lengths[0:259];
 function [31:0] value(input integer packet,index);
  value=32'hca000000^(packet<<10)^index;
 endfunction
 reg stalled=0;reg [65:0] held;
 always @(posedge mclk)begin
  if(rst&&stalled&&(!mv||{ml,md}!==held))$fatal(1,"CDC output changed under stall");
  stalled<=rst&&mv&&!mr;held<={ml,md};
  if(rst&&mv&&mr)begin
   if(received>=sent)$fatal(1,"Partial packet published");
   if(md[31:0]!==value(received,word_index))$fatal(1,"Low DWORD/order");
   if(md[64]!==((word_index+1)==lengths[received]))$fatal(1,"Single DWORD flag");
   if(!md[64]&&md[63:32]!==value(received,word_index+1))$fatal(1,"High DWORD/order");
   word_index=word_index+(md[64]?1:2);
   if(ml!==(word_index==lengths[received]))$fatal(1,"Packet boundary");
   if(ml)begin received=received+1;word_index=0;end
  end
 end
 always @(posedge sclk)if(release_q[2]&&sv&&!sr)backpressure=backpressure+1;
 task word(input [31:0] d,input last);
  @(negedge sclk);sd=d;sv=1;sl=last;
  do @(posedge sclk);while(!sr);
  if(last)sent=sent+1;
 endtask
 task packet(input integer n);
  for(integer i=0;i<lengths[n];i=i+1)word(value(n,i),i==lengths[n]-1);
  @(negedge sclk);sv=0;
 endtask
 initial begin
  for(integer n=0;n<260;n=n+1)lengths[n]=(n%64)+1;
  lengths[0]=3;
  #13;rst=1;repeat(6)@(negedge sclk);mr=1;
  word(value(0,0),0);word(value(0,1),0);
  @(negedge sclk);sv=0;
  repeat(12)@(negedge mclk);if(mv||received)$fatal(1,"Incomplete pair packet exposed");
  word(value(0,2),1);@(negedge sclk);sv=0;wait(received==1);
  // Source runs against a stopped destination, then independent stalls/rates.
  @(negedge mclk);run_m=0;mr=0;
  fork
   begin
    for(integer n=1;n<257;n=n+1)begin
     if(n==90)shalf=4;
     if(n==180)shalf=2;
     packet(n);
    end
   end
   begin
    repeat(120)@(negedge sclk);run_m=1;
    for(integer i=0;i<14000;i=i+1)begin @(negedge mclk);mr=i%9>2;end
    mr=1;
   end
  join
  wait(received==257);if(fault||backpressure==0)$fatal(1,"Missing pressure or unexpected fault");
  // 65 DWORDs exceed the 64-DWORD packet capacity and must not be published.
  for(integer i=0;i<65;i=i+1)word(32'hdeadbeef,i==64);
  sent=sent-1;@(negedge sclk);sv=0;
  repeat(30)@(negedge mclk);if(!fault||received!=257||mv)$fatal(1,"Oversize escaped");
  packet(257);wait(received==258);
  // Global reset clears a partial pair even if the source clock is stopped.
  word(32'hdeadbeef,0);@(negedge sclk);sv=0;run_s=0;rst=0;
  #31;rst=1;repeat(8)@(negedge mclk);if(mv)$fatal(1,"Stale reset ownership");
  run_s=1;sent=0;received=0;word_index=0;repeat(7)@(negedge sclk);
  packet(0);wait(received==1);if(fault)$fatal(1,"Fault after global reset");
  $display("PASS RX64 CDC: odd/even lengths 1..64, capacity, stalls, stopped clocks, wrap, oversize, reset");$finish;
 end
 initial begin #1000000;$fatal(1,"RX64 watchdog");end
endmodule

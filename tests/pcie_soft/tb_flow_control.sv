`timescale 1ns/1ps
module tb_flow_control;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,up=0,enable=1,rv=0,ready=1,reserve=0,replay=0,release_credit=0;
 reg [7:0] typ=0,hdr=0;reg [11:0] dat=0;reg [1:0] cls=1,release_cls=0;
 reg [8:0] cost=1,release_data=1;
 wire valid,credit,active,error;wire [7:0] ot,oh;wire [11:0] od;
 pcie_soft_flow_control #(.UPDATE_CYCLES(1024)) dut(clk,rst,up,enable,rv,typ,hdr,dat,
  valid,ready,ot,oh,od,reserve,replay,cls,cost,credit,active,release_credit,release_cls,release_data,error);
 integer txs=0,j;
 reg [7:0] np_advertised_h=2;
 reg [7:0] advertised_h=4;reg [11:0] advertised_d=32;
 reg [7:0] expected_h=4;reg [11:0] expected_d=32;
 integer deadline;reg stalled=0;reg [27:0] held;
 always @(posedge clk) if(rst&&up) begin
  if(stalled && (!valid || {ot,oh,od}!==held)) $fatal(1,"FC offer changed under stall");
  stalled=valid&&!ready;held={ot,oh,od};
  if(release_credit && release_cls==0)begin
   expected_h=expected_h+1'b1;expected_d=expected_d+{3'b0,release_data};
  end
  if(valid&&ready) begin
   if(ot==8'h40 && (oh!=4 || od!=32))$fatal(1,"Posted initial capacity");
   if(ot==8'h50 && (oh!=2 || od!=16))$fatal(1,"NP initial capacity changed");
   if(ot==8'h80)begin advertised_h=oh;advertised_d=od;end
   if(ot==8'h90)np_advertised_h=oh;
   if(ot[5:4]!==2'(txs%3)) $fatal(1,"FC class ordering");txs=txs+1;
   if(ot[5:4]==2 && {oh,od}!==0) $fatal(1,"Root must advertise infinite completion credits");
  end
 end else begin stalled=0;txs=0;end
 task cycles(input integer n);repeat(n) begin @(posedge clk);#1;end endtask
 task receive_fc(input [7:0] t,input [7:0] h,input [11:0] d);
  @(negedge clk);rv=1;typ=t;hdr=h;dat=d;@(negedge clk);rv=0;
 endtask
 task spend;
  if(!credit) $fatal(1,"Expected credit");
  @(negedge clk);reserve=1;@(negedge clk);reserve=0;cycles(1);
 endtask
 initial begin
  cycles(3);@(negedge clk);rst=1;up=1;
  if(active) $fatal(1,"Premature DL_Active");
  receive_fc(8'h40,1,1);receive_fc(8'h50,1,1);receive_fc(8'h60,0,0);
  wait(dut.phase_q==1);receive_fc(8'hc0,1,1);wait(active);cycles(2);
  spend();if(credit) $fatal(1,"Credit underflow allowed");
  replay=1;cycles(1);spend();replay=0;cycles(1);if(credit) $fatal(1,"Replay charged fresh credit");
  // Cross both modulo counter boundaries with a one-credit window.
  for(j=2;j<4200;j=j+1) begin
   receive_fc(8'h90,8'(j),12'(j));cycles(1);spend();
   if(credit) $fatal(1,"Credit conservation/wrap failed %0d",j);
  end
  cls=2;cost=8;cycles(1);spend();if(!credit) $fatal(1,"Infinite credits throttled");
  ready=0;wait(valid);cycles(2);
  @(negedge clk);release_credit=1;cycles(1);@(negedge clk);release_credit=0;
  cycles(8);ready=1;cycles(60);
  // Force releases on snapshot and acceptance edges, across header/data
  // wrap. Each return must be advertised well before the 1024-cycle fallback.
  release_data=8;
  for(j=0;j<520;j=j+1)begin
   @(negedge clk);release_credit=1;
   @(negedge clk);release_credit=0;
   deadline=0;
   while(advertised_h!=expected_h || advertised_d!=expected_d)begin
    cycles(1);deadline=deadline+1;
    if(deadline>32)$fatal(1,"Returned credit waited for timer at %0d",j);
   end
  end
  // Consecutive returns cover the snapshot and acceptance edges themselves.
  wait(!dut.offer_q && dut.class_q==0);
  @(negedge clk);release_credit=1;cycles(4);
  @(negedge clk);release_credit=0;cycles(32);
  if(advertised_h!=expected_h || advertised_d!=expected_d)$fatal(1,"Simultaneous return lost");
  // New returns while an old snapshot is held cannot be lost on acceptance.
  ready=0;release_credit=1;cycles(1);release_credit=0;wait(valid);
  cycles(2);release_credit=1;cycles(1);release_credit=0;cycles(5);
  ready=1;cycles(32);
  if(advertised_h!=expected_h || advertised_d!=expected_d)$fatal(1,"Stalled snapshot lost return");
  // Header-only NP returns also wake the scheduler; all three classes
  // retain round-robin service (checked by the monitor on every handshake).
  @(negedge clk);release_cls=1;release_data=0;release_credit=1;
  @(negedge clk);release_credit=0;cycles(32);
  if(np_advertised_h!=3)$fatal(1,"NP return not prompt");
  release_cls=0;release_data=8;
  // No-return periodic rounds still run.
  j=txs;cycles(1100);if(txs<j+3)$fatal(1,"Missing periodic fallback");
  @(negedge clk);enable=0;cycles(10);if(credit) $fatal(1,"Traffic admitted while PHY paused");
  @(negedge clk);release_credit=1;cycles(1);
  @(negedge clk);release_credit=0;cycles(5);
  enable=1;cycles(32);
  if(advertised_h!=expected_h || advertised_d!=expected_d)$fatal(1,"Paused return lost");
  if(!active) $fatal(1,"Recovery destroyed credit initialization");
  @(negedge clk);up=0;cycles(2);if(active||credit||valid) $fatal(1,"Link loss retained credits");
  $display("PASS FC: Init1/Init2, three classes, infinite Cpl, stalls, credit exhaustion, replay, 8/12-bit wrap, recovery/link loss");$finish;
 end
 initial begin #2000000;$fatal(1,"FC watchdog");end
endmodule

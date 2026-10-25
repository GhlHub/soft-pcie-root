`timescale 1ns/1ps
module tb_gen2_training;
 reg clk=0;always #4 clk=~clk;
 reg rst=0,force1=0,phy2=0,ready=1,eidle=1,dd=0,tv=0,is2=0,lp=1,np=1;
 reg [7:0] rate=6;
 wire detect,ei,done,up,l0,holdtimer,polarity,failed,target,fallback,sidle,eios,deemphasis;
 wire [4:0] state;wire [1:0] kind;wire [7:0] tl,tn,tr;wire tlp,tnp;
 reg rxidle=0,txidle=0,txdone=0,eiosdone=0;
 pcie_soft_ltssm #(.GEN2_ENABLE(1),.QUIET_CYCLES(8),.POLL_CYCLES(20000),.CONFIG_CYCLES(1000)) dut(
 clk,rst,1'b1,1'b1,eidle,dd,1'b1,detect,ei,1'b0,done,tv,is2,1'b0,1'b0,8'b0,8'b0,rate,8'b0,lp,np,
 txdone,kind,rxidle,txidle,1'b0,kind,tl,tn,tlp,tnp,up,l0,holdtimer,polarity,failed,state,
 force1,phy2,ready,eiosdone,tr,eios,sidle,target,fallback,deemphasis);
 task cycle;@(posedge clk);#1;endtask
 task reset(input bit force_gen1,input bit capable);
  @(negedge clk);rst=0;phy2=0;force1=force_gen1;rate=capable?6:2;eidle=1;dd=0;tv=0;txdone=0;rxidle=0;txidle=0;eiosdone=0;ready=1;
  repeat(4)cycle();@(negedge clk);rst=1;
  wait(detect);@(negedge clk);dd=1;cycle();@(negedge clk);dd=0;eidle=0;
 endtask
 task advance(input integer wanted,input bit ts2,input bit linkpad,input bit lanepad,input [7:0] r);
  integer guard;
  begin
   @(negedge clk);tv=1;txdone=1;is2=ts2;lp=linkpad;np=lanepad;rate=r;
   guard=0;while(state!=wanted&&guard<4000)begin cycle();guard++;end
   if(state!=wanted)$fatal(1,"state %0d wanted %0d rate %x",state,wanted,r);
   @(negedge clk);tv=0;txdone=0;
  end
 endtask
 task idle_to_l0;
  @(negedge clk);tv=0;txdone=0;rxidle=1;txidle=1;
  wait(l0);@(negedge clk);rxidle=0;txidle=0;
 endtask
 task initial_train(input [7:0] r);
  advance(3,0,1,1,r);advance(4,1,1,1,r);advance(6,0,0,1,r);advance(8,0,0,0,r);advance(9,1,0,0,r);idle_to_l0();
 endtask
 task speed_change(input bit expected);
  wait(eios);if(!up||!holdtimer)$fatal(1,"lost ownership before EIOS");
  @(negedge clk);eiosdone=1;cycle();@(negedge clk);eiosdone=0;
  wait(sidle);if(target!=phy2)$fatal(1,"rate changed before peer idle");
  repeat(8)cycle();if(target!=phy2)$fatal(1,"rate changed with peer active");
  @(negedge clk);ready=0;eidle=1;
  wait(state==17);repeat(12)cycle();
  if(target!=expected||state!=17||!ei||!up)$fatal(1,"rate request/hold incorrect");
  @(negedge clk);phy2=expected;ready=1;cycle();
  @(negedge clk);eidle=0;
  wait(state==11);#1;if(tr[7])$fatal(1,"speed-change bit not cleared after change");
 endtask
 initial begin
  reset(1,1);initial_train(6);repeat(20)cycle();if(!l0||tr!=2||target)$fatal(1,"forced Gen1 upgraded");
  reset(0,0);initial_train(2);repeat(20)cycle();if(!l0||target)$fatal(1,"Gen1 peer upgraded");
  reset(0,1);initial_train(6);wait(state==11);#1;if(!tr[7])$fatal(1,"no directed upgrade");
  advance(12,0,0,0,8'h86);
  // Speed negotiation must transmit 32 TS2 after the first matching TS2.
  @(negedge clk);tv=1;txdone=1;is2=1;rate=8'hc6;
  repeat(31)cycle();if(eios)$fatal(1,"fewer than 32 TS2");
  wait(eios);@(negedge clk);tv=0;txdone=0;
  speed_change(1);if(!deemphasis)$fatal(1,"peer de-emphasis preference lost");
  advance(12,0,0,0,6);advance(13,1,0,0,6);idle_to_l0();repeat(20)cycle();
  if(!l0||!phy2||fallback||failed)$fatal(1,"Gen2 L0 failed");
  // A speed-change request does not toggle rates: highest common remains Gen2.
  advance(11,0,0,0,8'h86);advance(12,0,0,0,8'h86);advance(15,1,0,0,8'h86);
  speed_change(1);advance(12,0,0,0,6);advance(13,1,0,0,6);idle_to_l0();
  // A partner may direct a return from Gen2 to Gen1 while retaining ownership.
  advance(11,0,0,0,8'h82);advance(12,0,0,0,8'h82);advance(15,1,0,0,8'h82);
  speed_change(0);advance(12,0,0,0,6);advance(13,1,0,0,6);idle_to_l0();repeat(20)cycle();
  if(!l0||phy2||failed||!up)$fatal(1,"peer-directed downshift failed");
  // Repeat the upgrade, but with no TS lock at 5GT/s. Return to old rate.
  reset(0,1);initial_train(6);wait(state==11);advance(12,0,0,0,8'h86);advance(15,1,0,0,8'h86);
  speed_change(1);wait(eios);if(!fallback)$fatal(1,"missing fallback status");
  speed_change(0);advance(12,0,0,0,6);advance(13,1,0,0,6);idle_to_l0();repeat(30)cycle();
  if(!l0||phy2||!fallback||failed||!up)$fatal(1,"fallback did not retain link");
  $display("PASS Gen2 training: capability, force Gen1, 32 TS2, idle handshake, de-emphasis, upgrade and timeout fallback");$finish;
 end
 initial begin #2000000;$fatal(1,"Gen2 watchdog %0d",state);end
endmodule

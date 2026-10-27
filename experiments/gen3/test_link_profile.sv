// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_link_profile;
 reg clk=0;always #2 clk=~clk;
 reg reset=1,cv=0,rr=0;reg [31:0] events=0,data=0;reg [63:0] address=0;
 wire cr,rv;wire [31:0] result;wire [2:0] status;
 gen3_link_profile #(.COUNTER_BITS(8)) dut(clk,reset,events,cv,cr,address,data,rv,rr,result,status);
 task tick(input integer n);repeat(n)@(negedge clk);endtask
 task command(input [63:0] a,input [31:0] d,input [2:0] expected);
  @(negedge clk);address=a;data=d;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;
  if(!rv||status!=expected)$fatal(1,"reply missing/status");
 endtask
 task finish_reply;
  rr=1;tick(1);rr=0;
 endtask
 reg [31:0] held;
 initial begin
  tick(3);reset=0;
  command(0,0,0);if(result!=32'h4c505232)$fatal(1,"magic");finish_reply;
  command(64'h10,1,0);finish_reply;
  events=3;tick(300);
  command(64'h100,0,2);finish_reply;
  command(64'h10,0,0);finish_reply;
  command(64'hc,0,0);if(result!=3)$fatal(1,"overflow bitmap");finish_reply;
  command(64'h100,0,0);held=result;events=32'hffffffff;tick(20);
  if(result!=held||!rv||cr)$fatal(1,"held response changed");finish_reply;
  command(64'h100,0,0);if(result!=held)$fatal(1,"frozen counters changed");finish_reply;
  command(64'h108,0,0);if(result!=0)$fatal(1,"wrong event selection");finish_reply;
  command(64'h101,0,2);finish_reply;
  command(64'h100000100,0,2);finish_reply;
  command(64'h10,2,2);finish_reply;
  events=0;command(64'h10,1,0);finish_reply;tick(4);
  command(64'h10,0,0);finish_reply;
  command(64'hc,0,0);if(result!=0)$fatal(1,"clear overflow");finish_reply;
  reset=1;tick(2);reset=0;
  command(64'h100,0,0);if(result!=0)$fatal(1,"reset counter");finish_reply;
  $display("PASS LINK PROFILE: coherent freeze, held reply, overflow, decode, restart, synchronous reset");$finish;
 end
 initial begin #100000;$fatal(1,"profile watchdog");end
endmodule

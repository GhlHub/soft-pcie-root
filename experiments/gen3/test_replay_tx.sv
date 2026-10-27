// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_replay_tx;
 reg clk=0;always #2 clk=~clk;
 reg reset=1,enable=1,iv=0,il=0,ready=1,response=0,nak=0;
 reg [31:0] data=0;reg [11:0] ackseq=0;
 wire ir,ov,ol,confirmed,retry,fault,pending;wire [31:0] outdata;wire [11:0] seq;
 gen3_replay_tx #(.REPLAY_CYCLES(32)) dut(clk,reset,enable,data,iv,il,ir,
 outdata,ov,ol,ready,response,nak,ackseq,confirmed,retry,fault,pending,seq);
 integer frames=0,confirms=0,retries=0,index=0,fd;reg [31:0] first_frame[0:5];
 reg [1023:0] path;
 always @(posedge clk)if(!reset)begin
  if(confirmed)confirms=confirms+1;
  if(retry)retries=retries+1;
  if(ov && ready)begin
   $fdisplay(fd,"%0d %0d %08x",frames,index,outdata);
   if(frames==0)first_frame[index]=outdata;
   else if(frames==1 && outdata!==first_frame[index])$fatal(1,"Retry changed bytes");
   if(ol)begin frames=frames+1;index=0;end else index=index+1;
  end
 end
 task tick(input integer n);repeat(n)@(negedge clk);endtask
 task send;
  for(integer j=0;j<4;j=j+1)begin
   wait(ir);@(negedge clk);iv=1;il=j==3;data=j==0?32'h01000040:32'h10203040+j;
   @(negedge clk);iv=0;
  end
 endtask
 task ack(input [11:0] value,input bit is_nak);
  @(negedge clk);response=1;ackseq=value;nak=is_nak;
  @(negedge clk);response=0;nak=0;
 endtask
 initial begin
  if(!$value$plusargs("OUT=%s",path))$fatal(1,"missing OUT");fd=$fopen(path,"w");
  tick(3);reset=0;
  // No ACK: retain bank, retransmit byte-identically, accept ACK during retry.
  send();wait(frames==1);tick(2);if(!pending || confirms!=0)$fatal(1,"Premature retirement");
  wait(frames==1 && index==2);ack(0,0);wait(confirms==1);tick(2);
  if(frames!=2 || pending || fault || seq!=1)$fatal(1,"ACK while retransmitting failed");
  // NAK then loss of permission: ownership cannot disappear on Recovery.
  send();wait(frames==3);enable=0;ack(0,1);tick(80);
  if(!pending || confirms!=1 || fault)$fatal(1,"Pause lost bank");
  enable=1;wait(frames==4);ack(1,0);wait(confirms==2);tick(2);
  // Future ACK cannot release ownership.
  send();wait(frames==5);ack(8,0);tick(5);
  if(!fault || !pending || confirms!=2)$fatal(1,"Future ACK released ownership");
  $fclose(fd);$display("PASS: replay CRC/frame trace, delayed ACK, timeout, NAK, paused ownership, future ACK quarantine");$finish;
 end
 initial begin #100000;$fatal(1,"Replay test timeout frames=%d index=%d",frames,index);end
endmodule

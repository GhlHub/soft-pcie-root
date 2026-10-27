// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_native_link;
 parameter integer CORRUPT=0;
 reg clk=0;always #2 clk=~clk;
 reg reset=1,command=0;
 wire [1:0] active,error,cr,rsp,appready,appvalid,applast;
 wire [31:0] result[0:1],appdata[0:1];wire [2:0] status[0:1];
 wire [31:0] wire_data[0:1];wire [1:0] wire_header[0:1];wire [1:0] wire_valid,wire_start;
 reg reply=0;reg [1:0] reply_word=0;
 wire [31:0] reply_data=reply_word==0?32'h0100004a:reply_word==1?32'h04000001:reply_word==2?32'b0:32'h1234144d;
 integer requests=0,naks=0;
 always @(posedge clk)begin
  if(!reset && appvalid[1] && applast[1])begin reply<=1;requests=requests+1;end
  if(reply && appready[1])begin
   reply_word<=reply_word+1'b1;
   if(reply_word==3)reply<=0;
  end
 end
 for(genvar g=0;g<2;g=g+1)begin: side
  wire [31:0] txdata,decoded,rxdata,dllpbody;wire txvalid,txlast,txready,submit,txfault;
  wire [31:0] symbols;wire [127:0] ts,debug;
  wire aligned,eventts,validts,validts2,rxerror,eios,streamstart,decodedvalid,stream;
  wire [1:0] ec,position,rxclass;wire [5:0] fs,lf;
  wire packetactive,eds,rxvalid,rxlast,rxready,response,nak,dllp,packeterror;
  wire [11:0] seq;wire [8:0] credits;wire [3:0] diag;
  wire pending,done,stopped,ts2done,eieosdone,idleword;wire signed [10:0] balance;
  reg in_tlp=0,corrupted=0;reg [6:0] txindex=0;
  wire corrupt_word=g==0 && CORRUPT!=0 && !corrupted && in_tlp && txindex==2;
  always @(posedge clk)if(!reset && txvalid && txready)begin
   if(txindex==0)in_tlp<=txdata[3:0]==4'hf;
   if(corrupt_word)corrupted<=1;
   txindex<=txlast?0:txindex+1'b1;
  end
  gen3_recovery_tx tx(clk,reset,1'b1,1'b0,1'b0,1'b1,2'b0,4'd4,6'b0,6'd40,6'b0,
   wire_data[g],wire_valid[g],wire_start[g],done,stopped,wire_header[g],balance,ts2done,eieosdone,idleword,
   1'b0,txdata^(corrupt_word?32'b1:32'b0),txvalid,txlast,txready,submit,txfault,);
  gen3_native_rx rx(clk,reset,1'b1,wire_data[1-g],wire_valid[1-g],wire_start[1-g],wire_header[1-g],
   eds,diag[1],aligned,eventts,validts,validts2,ec,fs,lf,symbols,rxerror,eios,ts,
   streamstart,decodedvalid,decoded,position,stream);
  gen3_data_rx #(.BUFFERED(1)) packets(clk,reset,streamstart,rxerror,
   decodedvalid,decoded,position,packetactive,eds,rxdata,rxvalid,rxlast,rxready,rxclass,credits,
   response,nak,seq,dllp,dllpbody,packeterror,diag);
  wire local_command=g==0?command:1'b0;
  wire [31:0] local_reply_data=g==1?reply_data:32'b0;
  wire local_reply=g==1?reply:1'b0;
  wire local_last=g==1 && reply_word==3;
  gen3_link_layer link(clk,reset,1'b1,1'b1,rxdata,rxvalid,rxlast,rxready,rxclass,credits,
   response,nak,seq,dllp,dllpbody,txdata,txvalid,txlast,txready,
   local_command,cr[g],3'd2,64'b0,16'h0100,32'b0,4'hf,
   rsp[g],1'b0,result[g],status[g],local_reply_data,local_reply,local_last,
   appready[g],2'd2,9'd1,appdata[g],appvalid[g],applast[g],1'b1,active[g],error[g],pending,debug,5'b0);
  always @(posedge clk)if(!reset)begin
   if(response && nak)naks=naks+1;
   if(txfault || rxerror || diag[1] || error[g])$fatal(1,"Native link fault side %d tx=%b rx=%b frame=%b link=%b",g,txfault,rxerror,diag[1],error[g]);
  end
 end
 initial begin
  repeat(4)@(negedge clk);reset=0;
  wait(&active);wait(cr[0]);@(negedge clk);command=1;@(negedge clk);command=0;
  wait(rsp[0]);repeat(10)@(negedge clk);
  if(status[0]!=0 || result[0]!=32'h1234144d || requests!=1 || naks!=CORRUPT)
   $fatal(1,"Native config result %d %h requests=%d naks=%d",status[0],result[0],requests,naks);
  $display("PASS: complete native scrambled Gen3 path, FC, config TLP/completion, ACK/NAK, CRC corruption=%d",CORRUPT);$finish;
 end
 initial begin #200000;$fatal(1,"Native link timeout active=%b",active);end
endmodule

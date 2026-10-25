`timescale 1ns/1ps
module tb_packet_tx_banks;
 reg clk=0;always #2 clk=~clk;
 reg rst=0,hold=0,v=0,last=0;reg [31:0] data=0;wire ready,done,busy,overflow;
 wire [15:0] symbols;wire [1:0] control;
 pcie_soft_packet_tx #(.MAX_DWORDS(8)) dut(.clk(clk),.rst_n(rst),.hold_i(hold),
 .tlp_data_i(data),.tlp_valid_i(v),.tlp_last_i(last),.tlp_ready_o(ready),.sequence_i(12'd0),
 .dllp_valid_i(1'b0),.dllp_body_i(32'b0),.symbols_o(symbols),.control_o(control),
 .packet_done_o(done),.transmitting_o(busy),.overflow_o(overflow));
 integer finished=0,errors=0;
 always @(posedge clk)if(rst)begin
  if(done)finished=finished+1;
  if(overflow)errors=errors+1;
  if(dut.count_q>2)$fatal(1,"Bank count overflow");
 end
 task word(input integer x,input reg final_word);
  @(negedge clk);data=32'(x);last=final_word;v=1;
  do @(posedge clk);while(!ready);
  @(negedge clk);v=0;
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  // An oversized packet is consumed to LAST but never published.
  for(integer i=0;i<10;i=i+1)word(i,i==9);
  repeat(30)@(negedge clk);
  if(finished||busy||errors!=1)$fatal(1,"Overlength not discarded");
  // Collection continues through hold; an incomplete bank cannot transmit.
  word(0,0);hold=1;
  repeat(12)@(negedge clk);
  if(busy)$fatal(1,"Incomplete bank leaked");
  for(integer i=1;i<8;i=i+1)word(i,i==7);
  repeat(12)@(negedge clk);
  if(ready||busy||finished)$fatal(1,"Prepared hold bypass");
  hold=0;word(99,1);
  @(negedge clk);
  if(dut.count_q!=2||ready)$fatal(1,"Two-bank full backpressure");
  wait(finished==2);repeat(3)@(negedge clk);
  if(!ready||dut.count_q!=0)$fatal(1,"Bank release");
  // Reset partial collection and prove the storage can be reused.
  word(77,0);rst=0;repeat(3)@(negedge clk);rst=1;
  word(88,1);wait(finished==3);
  $display("PASS PACKET TX BANKS: overlength drop, partial/hold, full backpressure, reset/reuse");$finish;
 end
 initial begin #100000;$fatal(1,"Timeout");end
endmodule

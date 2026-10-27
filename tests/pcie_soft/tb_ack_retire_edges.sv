// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ack_retire_edges;
 reg clk=0;always #2 clk=~clk;
 reg rst=0,sv=0,sl=0,allow=0,wd=0,av=0;reg [31:0] sd=0;reg [11:0] as=0;
 reg [15:0] age=0;
 wire sr,mv,ml,ar,err,ov,rec,to;wire [31:0] md;wire [11:0] seq,ws;wire [3:0] pending,sent;
 pcie_soft_replay dut(.clk(clk),.rst_n(rst),.link_reset_i(1'b0),.enable_i(1'b1),
 .s_data_i(sd),.s_valid_i(sv),.s_last_i(sl),.s_ready_o(sr),
 .m_data_o(md),.m_valid_o(mv),.m_last_o(ml),.m_sequence_o(seq),.m_ready_i(1'b1),
 .wire_sequence_o(ws),.tx_allow_i(allow),.tx_wire_done_i(wd),.phy_hold_i(1'b0),.retrain_done_i(1'b0),
 .response_valid_i(av),.response_ready_o(ar),.response_nak_i(1'b0),.response_sequence_i(as),.response_age_i(age),
 .pending_o(pending),.sent_o(sent),.response_error_o(err),.overflow_o(ov),.recovery_req_o(rec),.timeout_event_o(to));
 integer copied=0,index=0;
 always @(posedge clk)if(rst)begin
  if(err||ov||rec||to)$fatal(1,"Unexpected edge-case fault");
  if(mv)begin
   if(seq!=12'(copied)||md!=32'(copied*2+index)||ml!=(index==1))$fatal(1,"Payload identity");
   if(ml)begin copied=copied+1;index=0;end else index=1;
  end
 end
 task tick;@(negedge clk);endtask
 task beat(input [31:0] value,input bit last);
  tick;sd=value;sv=1;sl=last;do @(posedge clk);while(!sr);tick;sv=0;
 endtask
 task ack(input [11:0] value);
  tick;av=1;as=value;age=0;do @(posedge clk);while(!ar);tick;av=0;
 endtask
 initial begin
  repeat(4)tick;rst=1;beat(0,0);beat(1,1);beat(2,0);beat(3,1);
  allow=1;wait(copied==2);tick;allow=0;
  if(pending!=2||sent!=0||dut.inflight_q!=2)$fatal(1,"Staged setup");
  beat(4,0); // partial next packet remains outside committed ownership count
  wd=1;if(ws!=0)$fatal(1,"First staged identity");tick;wd=0;
  if(sent!=1||dut.inflight_q!=1)$fatal(1,"First wire completion");
  // All three operations share this edge. ACK age belongs to packet zero;
  // packet one has only just reached the wire and must receive a fresh timer.
  sd=5;sv=1;sl=1;wd=1;av=1;as=0;age=16'hffff;
  #1;if(!ar||!sr||ws!=1)$fatal(1,"Simultaneous admission/identity");
  tick;sv=0;wd=0;av=0;
  if(pending!=2||sent!=1||dut.inflight_q!=0||dut.timer_q!=0||!dut.timer_running_q||dut.timeout_pending_q)
   $fatal(1,"Simultaneous commit/wire/ACK accounting or timer");
  ack(1);if(pending!=1||sent!=0)$fatal(1,"Unsent suffix lost");
  ack(1);if(pending!=1)$fatal(1,"Duplicate ACK changed suffix");
  allow=1;wait(copied==3);tick;wd=1;if(ws!=2)$fatal(1,"Reused slot identity");tick;wd=0;
  ack(2);if(pending!=0||sent!=0)$fatal(1,"Final drain");
  $display("PASS ACK EDGES: simultaneous commit/wire/ACK, fresh timeout epoch, duplicate ACK and unsent suffix");$finish;
 end
 initial begin #100000;$fatal(1,"Edge test watchdog");end
endmodule

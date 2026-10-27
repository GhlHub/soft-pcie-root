// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Independent input/copy/wire/ACK scoreboards with delayed wire completion.
// Exercise ring reuse through sequence wrap while normal ACKs retire under stalls.
module tb_ack_retire;
 parameter integer ACK_PERIOD=17;
 localparam integer N=4200;
 reg clk=0;always #2 clk=~clk;
 reg rst=0,sv=0,sl=0,ready=0,wd=0,av=0;reg [31:0] sd=0;
 reg [11:0] as=0;reg [15:0] age=0;
 wire sr,mv,ml,mrep,wr,ar,error,overflow,recovery,replaying,te;
 wire [31:0] md;wire [11:0] ms,ws,acknowledged;
 wire [3:0] pending,sent;
 pcie_soft_replay #(.REPLAY_TIMEOUT_CYCLES(512)) dut(
 .clk(clk),.rst_n(rst),.link_reset_i(1'b0),.enable_i(1'b1),
 .s_data_i(sd),.s_valid_i(sv),.s_last_i(sl),.s_ready_o(sr),
 .m_data_o(md),.m_valid_o(mv),.m_last_o(ml),.m_sequence_o(ms),.m_replay_o(mrep),.m_ready_i(ready),
 .wire_sequence_o(ws),.wire_replay_o(wr),.tx_allow_i(1'b1),.tx_wire_done_i(wd),
 .phy_hold_i(1'b0),.retrain_done_i(1'b0),.response_valid_i(av),.response_ready_o(ar),
 .response_nak_i(1'b0),.response_sequence_i(as),.response_age_i(age),
 .pending_o(pending),.sent_o(sent),.replaying_o(replaying),.acknowledged_o(acknowledged),
 .recovery_req_o(recovery),.response_error_o(error),.overflow_o(overflow),.timeout_event_o(te));
 integer cycle=0,copied=0,outword=0,completed=0,retired=0,ack_target=0;
 integer qhead=0,qtail=0,due[0:N-1],identity[0:N-1];
 integer overlap=0,stalled=0,cumulative=0,simultaneous=0,start_ack=0,triple=0;
 reg accepted_ack=0,held=0;reg [44:0] hold_data;
 function automatic [31:0] word(input integer p,w);word=32'ha1000000+32'(p*16+w);endfunction
 always @(posedge clk)if(rst)begin
  cycle=cycle+1;accepted_ack=av&&ar;
  if(error||overflow||recovery||replaying||te||mrep||wr)$fatal(1,"Unexpected error/replay");
  if(pending>8||sent>pending||dut.inflight_q>2)$fatal(1,"Ownership bounds");
  if(held&&(!mv||{ml,ms,md}!==hold_data))$fatal(1,"Stalled copy changed");
  held=mv&&!ready;hold_data={ml,ms,md};
  if(accepted_ack)begin
   if(ack_target>completed||ack_target<=retired)$fatal(1,"ACK of unsent or old prefix");
   if(dut.inflight_q!=0)overlap=overlap+1;
   if(mv&&!ready)stalled=stalled+1;
   if(ack_target-retired>1)cumulative=cumulative+1;
   if(dut.tx_state_q==0 && pending>sent+dut.inflight_q)start_ack=start_ack+1;
   if(wd)begin
    simultaneous=simultaneous+1;
    if(sv&&sr&&sl)triple=triple+1;
   end
   retired=ack_target;
  end
  if(wd)begin
   if(qhead==qtail||ws!==12'(identity[qhead])||identity[qhead]!=completed)$fatal(1,"Wire identity changed by ACK");
   completed=completed+1;qhead=qhead+1;
  end
  if(mv&&ready)begin
   if(ms!==12'(copied)||md!==word(copied,outword)||ml!=(outword==7))$fatal(1,"Copy data/sequence/length mismatch");
   if(ml)begin
    identity[qtail]=copied;due[qtail]=cycle+23;qtail=qtail+1;copied=copied+1;outword=0;
   end else outword=outword+1;
  end
 end
 always @(negedge clk)if(rst)begin
  ready=cycle%13>=5;
  wd=qhead<qtail&&due[qhead]<=cycle;
  if(accepted_ack)av=0;
  if(!av&&completed>retired&&(cycle%ACK_PERIOD==0||completed==N))begin
   av=1;ack_target=completed;as=12'(completed-1);
   // An aged ACK for all older packets must not age a concurrently sent packet.
   age=wd?16'hffff:16'b0;
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(integer p=0;p<N;p=p+1)for(integer w=0;w<8;w=w+1)begin
   @(negedge clk);sd=word(p,w);sv=1;sl=w==7;
   do @(posedge clk);while(!sr);
  end
  @(negedge clk);sv=0;
  wait(retired==N);repeat(4)@(negedge clk);
  if(pending!=0||sent!=0||copied!=N||completed!=N||acknowledged!=12'(N-1))$fatal(1,"Final ownership");
  if(overlap==0||stalled==0||simultaneous==0||start_ack==0)$fatal(1,"Missing concurrent ACK coverage");
  if(ACK_PERIOD>20&&cumulative==0)$fatal(1,"Missing cumulative ACK");
  $display("PASS ACK RETIRE: packets=%0d staged=%0d stalled_copy=%0d cumulative=%0d simultaneous_wire=%0d launch=%0d triple_commit_wire_ack=%0d",N,overlap,stalled,cumulative,simultaneous,start_ack,triple);$finish;
 end
 initial begin #3000000;$fatal(1,"ACK retirement watchdog");end
endmodule

`timescale 1ns/1ps
// Coupled replay/serializer test with actual delayed wire completion. Check the
// serialized sequence, payload and LCRC independently of both internal banks.
module tb_tx_overlap;
 reg clk=0;always #2 clk=~clk;
 reg rst=0,link_reset=0,hold=0,allow=0,permit_timeout=0;
 reg [31:0] sd=0;reg sv=0,sl=0;wire sr;
 wire [31:0] md;wire mv,ml,mr,mrep;wire [11:0] ms,ws;wire wr;
 wire wd;reg dq=0;
 reg av=0,an=0;reg [11:0] as=0;wire ar;
 wire [3:0] pending,sent;wire err,ov,rec,rev,tev,sov;
 reg dv=0;wire dr;wire [15:0] sy;wire [1:0] ct;wire busy;
 pcie_soft_replay #(.REPLAY_TIMEOUT_CYCLES(4096)) replay_store(
 .clk(clk),.rst_n(rst),.link_reset_i(link_reset),.enable_i(1'b1),
 .s_data_i(sd),.s_valid_i(sv),.s_last_i(sl),.s_ready_o(sr),
 .m_data_o(md),.m_valid_o(mv),.m_last_o(ml),.m_sequence_o(ms),.m_replay_o(mrep),.m_ready_i(mr),
 .wire_sequence_o(ws),.wire_replay_o(wr),.tx_allow_i(allow),.tx_wire_done_i(dq),.phy_hold_i(hold),.retrain_done_i(1'b0),
 .response_valid_i(av),.response_ready_o(ar),.response_nak_i(an),.response_sequence_i(as),.response_age_i(16'b0),
 .pending_o(pending),.sent_o(sent),.response_error_o(err),.overflow_o(ov),.recovery_req_o(rec),.replay_event_o(rev),.timeout_event_o(tev));
 pcie_soft_packet_tx transmitter(.clk(clk),.rst_n(rst&&!link_reset),.hold_i(hold),
 .tlp_data_i(md),.tlp_valid_i(mv),.tlp_last_i(ml),.tlp_ready_o(mr),.sequence_i(ms),
 .dllp_valid_i(dv),.dllp_ready_o(dr),.dllp_body_i(32'h12345678),
 .symbols_o(sy),.control_o(ct),.packet_done_o(wd),.transmitting_o(busy),.overflow_o(sov));
 function automatic [31:0] crcbyte(input [31:0] old,input [7:0] d);
 reg [31:0] c;begin c=old;for(integer b=0;b<8;b=b+1)c=(c>>1)^((c[0]^d[b])?32'hedb88320:0);crcbyte=c;end
 endfunction
 function automatic [31:0] word(input integer seq,index);word=32'h90230000+32'(seq*256+index);endfunction
 integer lengths[0:4095];integer seen[0:4095];integer packet_seq=0,pos=0;
 reg [31:0] crc=0;reg packet_active=0;integer done_count=0,overlap=0,replays=0,dllps=0;
 integer wire_log[0:63];reg [11:0] last_wire_seq=0;
 always @(posedge clk) begin
  if(!rst||link_reset) begin
   dq<=0;packet_active=0;pos=0;done_count=0;overlap=0;replays=0;dllps=0;
   for(integer i=0;i<4096;i=i+1)seen[i]=0;
  end else begin
   dq<=wd;
   if(err||ov||rec||sov||(tev&&!permit_timeout))$fatal(1,"Unexpected error");
   if(sent>pending||replay_store.inflight_q>2)$fatal(1,"Ownership bounds");
   if(ar && replay_store.inflight_q!=0)$fatal(1,"ACK before wire drain");
   if(mv&&mr&&busy)overlap=overlap+1;
   if(dv&&dr)dllps=dllps+1;
   for(integer lane=0;lane<2;lane=lane+1)begin
    if(ct[lane]&&sy[8*lane+:8]==8'hfb)begin
     if(packet_active)$fatal(1,"Nested STP");packet_active=1;pos=0;crc=32'hffffffff;
    end else if(packet_active)begin
     pos=pos+1;
     if(pos==1)begin packet_seq=int'(sy[8*lane+:8]&8'h0f)*256;crc=crcbyte(crc,sy[8*lane+:8]);end
     else if(pos==2)begin packet_seq=packet_seq+int'(sy[8*lane+:8]);crc=crcbyte(crc,sy[8*lane+:8]);end
     else if(pos<3+lengths[packet_seq]*4)begin
      if(ct[lane]||sy[8*lane+:8]!==8'(word(packet_seq,(pos-3)/4)>>(8*((pos-3)%4))))$fatal(1,"Wire payload seq=%0d pos=%0d",packet_seq,pos);
      crc=crcbyte(crc,sy[8*lane+:8]);
     end else if(pos<7+lengths[packet_seq]*4)begin
      if(ct[lane]||sy[8*lane+:8]!==8'((~crc)>>(8*(pos-3-lengths[packet_seq]*4))))$fatal(1,"LCRC mismatch");
     end else begin
      if(!ct[lane]||sy[8*lane+:8]!=8'hfd||!wd)$fatal(1,"END/length/wire done");
      packet_active=0;seen[packet_seq]=seen[packet_seq]+1;
      wire_log[done_count]=packet_seq;done_count=done_count+1;last_wire_seq=12'(packet_seq);
     end
    end
   end
   if(dq)begin
    if(ws!==last_wire_seq)$fatal(1,"Wire identity got %0d expected %0d",ws,last_wire_seq);
    if(wr)replays=replays+1;
   end
  end
 end
 task cycles(input integer n);repeat(n)@(negedge clk);endtask
 task packet(input integer seq,n);
  lengths[seq]=n;
  for(integer i=0;i<n;i=i+1)begin
   @(negedge clk);sd=word(seq,i);sl=i==n-1;sv=1;
   do @(posedge clk);while(!sr);
  end
  @(negedge clk);sv=0;sl=0;
 endtask
 task response(input reg nak,input [11:0] seq);
  @(negedge clk);av=1;an=nak;as=seq;
  do @(posedge clk);while(!ar);
  @(negedge clk);av=0;
 endtask
 task reset_link;
  @(negedge clk);link_reset=1;av=0;sv=0;hold=0;allow=0;dv=0;
  cycles(3);link_reset=0;cycles(2);
  if(pending!=0||sent!=0||busy||mv)$fatal(1,"Reset validity");
 endtask
 initial begin
  cycles(4);rst=1;
  packet(0,64);packet(1,19);packet(2,3);packet(3,64);
  allow=1;
  wait(wd);@(negedge clk);
  // NAK while the next original is already being prepared/transmitted.
  response(1,12'hfff);
  wait(done_count>=6);cycles(3);allow=0;
  if(seen[0]<2||seen[1]<2||replays<2||overlap==0)$fatal(1,"Missing replay/overlap coverage");
  response(0,12'(wire_log[done_count-1]));
  // Drain remaining originals and ACK; ordering must survive bank reuse.
  allow=1;wait(seen[3]!=0);cycles(3);response(0,3);cycles(3);
  if(pending!=0||sent!=0)$fatal(1,"ACK failed to release");
  reset_link();packet(0,64);packet(1,64);allow=1;
  wait(replay_store.inflight_q==2);@(negedge clk);hold=1;dv=1;
  wait(!busy);cycles(5);
  if(done_count!=1||dr)$fatal(1,"Hold failed at packet boundary");
  // DLLP must win arbitration over a queued TLP when hold releases.
  hold=0;do @(posedge clk);while(!dr);@(negedge clk);dv=0;
  wait(done_count==2);cycles(3);response(0,1);
  if(dllps!=1)$fatal(1,"DLLP arbitration");
  reset_link();packet(0,64);packet(1,19);allow=1;permit_timeout=1;
  wait(done_count==2);wait(tev);wait(done_count==4);cycles(3);allow=0;
  if(replays!=2)$fatal(1,"Timeout did not replay drained original window");
  response(0,1);cycles(3);permit_timeout=0;
  if(pending!=0)$fatal(1,"Timeout ACK drain");
  reset_link();packet(0,64);packet(1,64);allow=1;
  wait(replay_store.inflight_q==2);reset_link();cycles(150);
  if(done_count!=0)$fatal(1,"Stale packet after reset");
  packet(0,19);allow=1;wait(done_count==1);cycles(3);response(0,0);cycles(3);
  if(pending!=0)$fatal(1,"Reuse after reset");
  $display("PASS TX OVERLAP: wire payload/sequence/LCRC, delayed completion identity, ACK/NAK/timeout drain, two banks, hold/DLLP, reset/reuse");$finish;
 end
 initial begin #1000000;$fatal(1,"Timeout");end
endmodule

`timescale 1ns/1ps
module tb_cmd_cdc;
 reg hc=0,lc=0,run_host=1,run_link=1;integer link_half=2;
 always #4 if(run_host)hc=~hc;always #(link_half) if(run_link)lc=~lc;
 reg reset=0,active=1,hv=0,hr=0,lr=0,lrv=0;
 reg [118:0] hp=0;reg [34:0] response=0;
 wire hready,hrv,lv,lrr;wire [118:0] lp;wire [34:0] result;
 integer requests=0;
 pcie_cmd_cdc dut(hc,lc,reset,active,hv,hready,hp,hrv,hr,result,lv,lr,lp,lrv,lrr,response);
 always @(posedge lc)if(!reset)requests<=0;else if(lv&&lr)requests<=requests+1;
 task send(input [118:0] data);
  @(negedge hc);hp=data;hv=1;do @(posedge hc);while(!hready);@(negedge hc);hv=0;
 endtask
 task receive(input [34:0] expected);
  wait(hrv);repeat(5)begin @(negedge hc);if(result!==expected||!hrv||hready)$fatal(1,"response ownership");end
  hr=1;@(negedge hc);hr=0;
 endtask
 initial begin
  repeat(4)@(negedge hc);reset=1;repeat(80)@(negedge hc);
  $display("stage initial %t",$time);
  // Model owner reset deasserting later than its independent FIFO reset.
  force dut.h_release_q=0;hp=119'h55;hv=1;
  repeat(8)begin @(negedge hc);if(hready||dut.requests.fifo.wr_en)$fatal(1,"reset skew accepted unowned command");end
  release dut.h_release_q;
  do @(posedge hc);while(!hready);@(negedge hc);hv=0;
  wait(lv);if(lp!==119'h55)$fatal(1,"reset skew payload");
  @(negedge lc);lr=1;@(negedge lc);lr=0;
  response={3'd0,32'h55};lrv=1;do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  receive({3'd0,32'h55});if(requests!=1)$fatal(1,"reset skew duplicate");
  reset=0;repeat(4)@(negedge hc);reset=1;repeat(80)@(negedge hc);
  wait(lc==0);run_link=0;send(119'h12345678);repeat(20)@(negedge hc);
  if(hready||hrv||lv)$fatal(1,"stopped link lost command ownership");
  run_link=1;wait(lv);repeat(8)begin @(negedge lc);if(lp!==119'h12345678)$fatal(1,"payload/stall");end
  lr=1;@(negedge lc);lr=0;repeat(10)@(negedge lc);
  response={3'd0,32'hdeadbeef};lrv=1;do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  receive({3'd0,32'hdeadbeef});
  // Loss before issue returns failure without sending a request.
  @(negedge lc);active=0;send(119'h2222);receive({3'd4,32'd0});if(requests!=1)$fatal(1,"queued command replayed");
  @(negedge lc);active=1;send(119'h3333);wait(lv);@(negedge lc);lr=1;@(negedge lc);lr=0;
  active=0;receive({3'd4,32'd0});
  // Loss after acceptance reports once, but retains the old response owner.
  @(negedge lc);active=1;send(119'h4444);repeat(30)@(negedge hc);
  if(lv||hrv||requests!=2)$fatal(1,"late ownership reused");
  @(negedge lc);response={3'd0,32'hbad};lrv=1;do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  receive({3'd4,32'd0});if(requests!=2)$fatal(1,"quarantined command issued");
  $display("stage wrap %t",$time);
  // Fresh ownership after global recovery; exercise pointer wrap at both rates.
  reset=0;repeat(4)@(negedge hc);reset=1;repeat(80)@(negedge hc);
  for(integer n=0;n<48;n=n+1)begin
   if(n==24)begin wait(lc==0);run_link=0;#80;link_half=4;run_link=1;end
   send(119'h123456789abcdef000000000000000+n);
   wait(lv);if(lp!==(119'h123456789abcdef000000000000000+n))$fatal(1,"wrap payload");
   @(negedge lc);lr=1;@(negedge lc);lr=0;
   response={3'd0,32'h80000000+32'(n)};lrv=1;
   do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
   receive({3'd0,32'h80000000+32'(n)});
  end
  $display("stage pause %t",$time);
  // Hold a published response while host clock stops; resume without reset.
  send(119'h5555);wait(lv);@(negedge lc);lr=1;@(negedge lc);lr=0;
  wait(hc==0);run_host=0;@(negedge lc);response={3'd0,32'h5555};lrv=1;
  do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  repeat(25)@(negedge lc);run_host=1;receive({3'd0,32'h5555});
  $display("stage link reset %t",$time);
  // Reset while link (response write clock) is stopped with stale data held.
  send(119'h6666);wait(lv);@(negedge lc);lr=1;@(negedge lc);lr=0;
  response={3'd0,32'h6666};lrv=1;do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  wait(hrv);wait(lc==0);run_link=0;reset=0;repeat(5)@(negedge hc);reset=1;
  repeat(40)begin @(negedge hc);if(hrv||hready)$fatal(1,"stale response escaped stopped-clock reset");end
  run_link=1;repeat(100)@(negedge hc);
  if(hrv||lv||!hready)$fatal(1,"reset recovery");
  $display("stage host reset %t",$time);
  // Symmetric global reset with host (request write clock) stopped.
  send(119'h7777);wait(lv);wait(hc==0);run_host=0;reset=0;
  repeat(5)@(negedge lc);reset=1;
  repeat(40)begin @(negedge lc);if(lv)$fatal(1,"stale request escaped stopped-clock reset");end
  run_host=1;repeat(100)@(negedge hc);
  if(hrv||lv||!hready)$fatal(1,"host stopped reset recovery");
  send(119'h8888);wait(lv);if(lp!==119'h8888)$fatal(1,"post-reset payload");
  @(negedge lc);lr=1;@(negedge lc);lr=0;
  response={3'd0,32'h8888};lrv=1;do @(posedge lc);while(!lrr);@(negedge lc);lrv=0;
  receive({3'd0,32'h8888});
  $display("PASS CMD CDC: stopped clock, held payload, backpressure, queued loss, accepted loss, late response drain, quarantine, pointer wrap, both rates, both stopped-clock global resets");$finish;
 end
 initial begin #100000;$fatal(1,"cmd CDC watchdog hready=%b lv=%b hrv=%b reqbusy=%b/%b seen=%b/%b rspbusy=%b/%b seen=%b/%b",hready,lv,hrv,dut.requests.wr_busy,dut.requests.rd_busy,dut.requests.s_reset_seen_q,dut.requests.m_reset_seen_q,dut.responses.wr_busy,dut.responses.rd_busy,dut.responses.s_reset_seen_q,dut.responses.m_reset_seen_q);end
endmodule

`timescale 1ns/1ps
module tb_cmd_mux;
 reg clk=0;always #4 clk=~clk;reg rst=0;
 reg av=0,bv=0,ready=0,rv=0,ar=0,br=0;
 wire aready,bready,arv,brv,v,rr;wire [118:0] payload;
 pcie_cmd_mux dut(clk,rst,av,aready,119'h123,arv,ar,bv,bready,119'h456,brv,br,v,ready,payload,rv,rr);
 initial begin
  repeat(3)@(negedge clk);rst=1;av=1;bv=1;
  repeat(4)begin @(posedge clk);if(!v||payload!=119'h123)$fatal(1,"initial grant");end
  @(negedge clk);ready=1;@(negedge clk);av=0;
  repeat(5)begin @(posedge clk);if(v||bready)$fatal(1,"busy interleaving");end
  @(negedge clk);rv=1;repeat(3)begin @(posedge clk);if(!arv||brv||rr)$fatal(1,"response owner/stall");end
  @(negedge clk);ar=1;@(negedge clk);rv=0;ar=0;
  @(posedge clk);if(!v||payload!=119'h456)$fatal(1,"alternate grant");
  @(negedge clk);bv=0;rv=1;br=1;@(negedge clk);rv=0;
  // Hold an offered B command stable when a new A request appears.
  @(negedge clk);rst=0;ready=0;av=0;bv=0;rv=0;br=0;
  @(negedge clk);rst=1;bv=1;@(negedge clk);av=1;
  repeat(3)begin @(posedge clk);if(payload!=119'h456||!v)$fatal(1,"Offer changed during stall");end
  // A timed-out unaccepted B command can withdraw without trapping A.
  @(negedge clk);bv=0;repeat(2)@(negedge clk);
  if(!v||payload!=119'h123)$fatal(1,"Withdrawn offer trapped arbiter");
  $display("PASS MUX: response ownership, fairness and stalls");$finish;
 end
 initial begin #10000;$fatal(1,"mux watchdog");end
endmodule

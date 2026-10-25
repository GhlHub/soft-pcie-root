`timescale 1ns/1ps
module tb_rate_control;
 reg clk=0;always #10 clk=~clk;
 reg reset=1,target=0,idle=1;
 wire applied,busy,fault;
 pcie_soft_rate_control #(.HOLD_CYCLES(12),.TIMEOUT_CYCLES(40)) dut(clk,reset,target,idle,applied,busy,fault);
 task cycles(input integer n);repeat(n)begin @(posedge clk);#1;end endtask
 initial begin
  cycles(3);@(negedge clk);reset=0;cycles(5);
  @(negedge clk);target=1;wait(busy);cycles(15);
  if(applied||!busy||fault)$fatal(1,"old idle level acknowledged a switch");
  @(negedge clk);idle=0;cycles(5);if(applied)$fatal(1,"busy switch acknowledged");
  @(negedge clk);idle=1;wait(!busy);#1;if(!applied||fault)$fatal(1,"Gen2 handshake failed");
  @(negedge clk);target=0;idle=0;wait(busy);cycles(5);@(negedge clk);idle=1;
  cycles(3);if(!busy)$fatal(1,"minimum idle hold shortened");
  wait(!busy);#1;if(applied||fault)$fatal(1,"Gen1 return failed");
  @(negedge clk);target=1;wait(busy);wait(fault);#1;
  if(applied||busy)$fatal(1,"timeout did not fail closed");
  @(negedge clk);idle=0;cycles(5);@(negedge clk);idle=1;cycles(50);
  if(applied||busy||!fault)$fatal(1,"fault recovered without global reset");
  $display("PASS rate control: busy-idle handshake, minimum hold, both speeds, stuck-idle quarantine");$finish;
 end
 initial begin #10000;$fatal(1,"rate watchdog");end
endmodule

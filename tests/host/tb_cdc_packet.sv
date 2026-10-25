`timescale 1ns/1ps
module tb_cdc_packet;
 reg sclk=0,mclk=0,run_s=1,run_m=1,rst=0;
 integer shalf=4;
 always begin #(shalf);if(run_s)sclk=~sclk;end
 always begin #5;if(run_m)mclk=~mclk;end
 reg [31:0] data=0;reg valid=0,last=0,ready=0;
 wire sr,mv,ml,fault;wire [31:0] md;
 pcie_cdc_packet #(.WORDS(8),.SLOTS(4)) dut(sclk,mclk,rst,data,valid,last,sr,fault,md,mv,ml,ready);
 integer expected=0,got=0;
 reg check_data=1;
 always @(posedge mclk)if(rst&&mv&&ready&&check_data)begin
  if(md!==32'(expected)||ml!==(expected%5==4))$fatal(1,"CDC data/order/last %0d %0d %b",md,expected,ml);
  expected=expected+1;got=got+1;
 end
 task beat(input integer v,input l);
  @(negedge sclk);data=v;valid=1;last=l;
  do @(posedge sclk);while(!sr);
  @(negedge sclk);valid=0;
 endtask
 initial begin
  #21;rst=1;repeat(5)@(negedge sclk);
  // Incomplete packet must not be published, even with consumer ready.
  ready=1;beat(0,0);beat(1,0);repeat(12)@(negedge mclk);
  if(mv||got)$fatal(1,"Partial packet published");
  beat(2,0);beat(3,0);beat(4,1);wait(got==5);ready=0;
  // Four complete slots, stop reader clock; fifth slot is backpressured.
  @(negedge mclk);run_m=0;
  for(integer i=5;i<25;i=i+1)beat(i,i%5==4);
  repeat(8)@(negedge sclk);if(sr)$fatal(1,"CDC capacity overflow");
  run_m=1;ready=1;wait(got==25);
  // Variable link rate, independent stalls and ring wrap.
  fork
   begin
    for(integer i=25;i<1025;i=i+1)begin
     if(i==250)shalf=2;
     if(i==700)shalf=4;
     beat(i,i%5==4);
    end
   end
   begin
    for(integer i=0;i<3000;i=i+1)begin @(negedge mclk);ready=(i%7!=0&&i%7!=1);end
    ready=1;
   end
  join
  wait(got==1025);
  // Oversize is dropped, not exposed as a truncated valid packet.
  for(integer i=0;i<12;i=i+1)beat(999,i==11);
  repeat(12)@(negedge mclk);if(mv||!fault)$fatal(1,"Oversize not quarantined");
  for(integer i=1025;i<1030;i=i+1)beat(i,i%5==4);wait(got==1030);
  // Global reset while writer clock is stopped cannot retain old ownership.
  @(negedge sclk);run_s=0;rst=0;#31;rst=1;
  repeat(8)@(negedge mclk);if(mv)$fatal(1,"Stale packet after reset");
  run_s=1;expected=0;got=0;
  repeat(5)@(negedge sclk);
  for(integer i=0;i<5;i=i+1)beat(i,i==4);wait(got==5);
  $display("PASS CDC: whole packets, capacity, stopped clocks, rate changes, stalls, wrap, oversize and global reset");$finish;
 end
 initial begin #200000;$fatal(1,"CDC watchdog got%0d",got);end
endmodule

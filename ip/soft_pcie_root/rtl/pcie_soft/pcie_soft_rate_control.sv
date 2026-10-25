// PCIe-mode GTH rate handshake, timed by the independent 50MHz clock.
// RX/TXRATE are driven by a stable link-clock request, only in electrical idle.
// A busy->idle transition is mandatory; an old high level is not completion.
module pcie_soft_rate_control #(
 parameter integer HOLD_CYCLES=500, TIMEOUT_CYCLES=50000
)(
 input wire clk,reset_i,target_gen2_i,rate_idle_i,
 output reg applied_gen2_o,output reg busy_o,output reg fault_o
);
 (* ASYNC_REG="TRUE" *) reg [2:0] target_sync_q,idle_sync_q;
 reg requested_q,saw_busy_q;
 reg [$clog2(TIMEOUT_CYCLES+1)-1:0] timer_q;
 always @(posedge clk)begin
  if(reset_i)begin
   target_sync_q<=0;idle_sync_q<=0;applied_gen2_o<=0;busy_o<=0;fault_o<=0;
   requested_q<=0;saw_busy_q<=0;timer_q<=0;
  end else begin
   target_sync_q<={target_sync_q[1:0],target_gen2_i};
   idle_sync_q<={idle_sync_q[1:0],rate_idle_i};
   if(!busy_o&&!fault_o&&target_sync_q[2]!=applied_gen2_o)begin
    busy_o<=1;requested_q<=target_sync_q[2];saw_busy_q<=!idle_sync_q[2];timer_q<=0;
   end else if(busy_o)begin
    if(!idle_sync_q[2])saw_busy_q<=1;
    if(int'(timer_q)>=HOLD_CYCLES&&saw_busy_q&&idle_sync_q[2])begin
     applied_gen2_o<=requested_q;busy_o<=0;
    end else if(int'(timer_q)>=TIMEOUT_CYCLES-1)begin fault_o<=1;busy_o<=0;end
    else timer_q<=timer_q+1'b1;
   end
  end
 end
endmodule

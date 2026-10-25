// One requester/tag shared by configuration mailbox and BAR PIO. Selection
// remains locked until the selected owner accepts its response.
module pcie_cmd_mux(
 input wire clk,rst_n,
 input wire a_valid_i,output wire a_ready_o,input wire [118:0] a_payload_i,
 output wire a_rsp_valid_o,input wire a_rsp_ready_i,
 input wire b_valid_i,output wire b_ready_o,input wire [118:0] b_payload_i,
 output wire b_rsp_valid_o,input wire b_rsp_ready_i,
 output wire valid_o,input wire ready_i,output wire [118:0] payload_o,
 input wire rsp_valid_i,output wire rsp_ready_o
);
 reg busy_q,owner_q,offered_q;reg prefer_b_q;
 wire select_b=(busy_q||offered_q)?owner_q:(b_valid_i&&(!a_valid_i||prefer_b_q));
 assign valid_o=!busy_q&&(select_b?b_valid_i:a_valid_i);
 assign payload_o=select_b?b_payload_i:a_payload_i;
 assign a_ready_o=!busy_q&&!select_b&&ready_i;
 assign b_ready_o=!busy_q&&select_b&&ready_i;
 assign a_rsp_valid_o=busy_q&&!owner_q&&rsp_valid_i;
 assign b_rsp_valid_o=busy_q&&owner_q&&rsp_valid_i;
 assign rsp_ready_o=busy_q&&(owner_q?b_rsp_ready_i:a_rsp_ready_i);
 always @(posedge clk)begin
  if(!rst_n)begin busy_q<=0;owner_q<=0;offered_q<=0;prefer_b_q<=0;end
  else begin
   if(valid_o&&!ready_i)begin offered_q<=1;owner_q<=select_b;end
   // The PIO local timeout may withdraw a command before acceptance.
   if(offered_q&&!(owner_q?b_valid_i:a_valid_i))offered_q<=0;
   if(valid_o&&ready_i)begin busy_q<=1;owner_q<=select_b;offered_q<=0;end
   if(rsp_valid_i&&rsp_ready_o)begin busy_q<=0;prefer_b_q<=!owner_q;end
  end
 end
endmodule

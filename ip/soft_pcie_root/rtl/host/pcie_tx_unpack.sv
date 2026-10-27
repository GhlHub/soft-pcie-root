// SPDX-License-Identifier: Apache-2.0
// Link-clock adapter: one 64-bit host beat becomes one/two link DWORDs.
// The upstream elastic CDC output retains ownership until the final DWORD.
// Payload and credit metadata must remain stable under backpressure.
module pcie_tx_unpack(
 input wire clk,rst_n,
 input wire [67:0] s_data_i,input wire s_valid_i,s_last_i,output wire s_ready_o,
 output wire [42:0] m_data_o,output wire m_valid_o,m_last_o,input wire m_ready_i
);
 reg high_q;
 wire single=s_last_i&&s_data_i[64];
 assign m_data_o={2'd2,6'b0,s_data_i[67:65],high_q?s_data_i[63:32]:s_data_i[31:0]};
 assign m_valid_o=s_valid_i;
 assign m_last_o=s_last_i&&(high_q||single);
 assign s_ready_o=m_ready_i&&(high_q||single);
 always @(posedge clk)begin
  if(!rst_n)high_q<=0;
  else if(m_valid_o&&m_ready_i)high_q<=!(high_q||single);
 end
endmodule

// SPDX-License-Identifier: Apache-2.0
// Pair link DWORDs before whole-packet CDC. Low DWORD is first on the wire;
// bit 64 marks a final single DWORD. No packet is published by this stage.
// Global, locally synchronized reset only: link pauses retain partial pairs.
module pcie_rx_pack (
    input wire clk, rst_n,
    input wire [31:0] s_data_i,
    input wire s_valid_i, s_last_i,
    output wire s_ready_o,
    output reg [64:0] m_data_o,
    output reg m_valid_o, m_last_o,
    input wire m_ready_i
);
    reg         half_q;
    reg  [31:0] low_q;
    wire        space = !m_valid_o || m_ready_i;
    assign s_ready_o = rst_n && space;
    always @(posedge clk) begin
        if (!rst_n) begin
            half_q    <= 0;
            m_valid_o <= 0;
            m_last_o  <= 0;
        end else begin
            if (m_ready_i) m_valid_o <= 0;
            if (s_valid_i && s_ready_o) begin
                if (half_q || s_last_i) begin
                    m_data_o  <= half_q ? {1'b0, s_data_i, low_q} : {1'b1, 32'b0, s_data_i};
                    m_valid_o <= 1;
                    m_last_o  <= s_last_i;
                    half_q    <= 0;
                end else begin
                    low_q  <= s_data_i;
                    half_q <= 1;
                end
            end
        end
    end
endmodule

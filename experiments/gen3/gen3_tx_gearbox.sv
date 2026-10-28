// SPDX-License-Identifier: Apache-2.0
// Experimental fixed-size 130-bit block to 32-bit RAW stream packing.
// Header bit 0, header bit 1, then payload bit 0 ... 127 are sent in order.
// Output bit 0 is earliest. Caller supplies scrambled payload and legal header.
// This is an elastic fabric interface, NOT a directly connected GTH interface.
// Physical TX cannot stall: an adapter must guarantee continuous words while
// active and perform correct electrical-idle draining. No partial-word flush.
// Variable-size SKP ordered sets are not supported by this component.
module gen3_tx_gearbox (
    input wire clk, reset_i,
    input wire [127:0] s_payload_i,
    input wire [1:0] s_header_i,
    input wire s_valid_i,
    output wire s_ready_o,
    output wire [31:0] m_data_o,
    output wire m_valid_o,
    input wire m_ready_i
);
    reg [161:0] bits_q, bits_next;
    reg  [7:0] count_q;
    wire       pop = m_valid_o && m_ready_i;
    wire [7:0] remaining = count_q - (pop ? 8'd32 : 8'd0);
    wire       push = s_valid_i && s_ready_o;
    assign m_valid_o = !reset_i && count_q >= 8'd32;
    assign m_data_o  = bits_q[31:0];
    assign s_ready_o = !reset_i && remaining <= 8'd32;
    always @* begin
        bits_next = pop ? bits_q >> 32 : bits_q;
        // Only the occupied low bits matter; overwrite the complete new block.
        // Variable part select is bounded to [161:0] by s_ready_o.
        if (push) bits_next[remaining+:130] = {s_payload_i, s_header_i};
    end
    always @(posedge clk) begin
        if (reset_i) count_q <= 0;
        else begin
            count_q <= remaining + (push ? 8'd130 : 8'd0);
            if (push || pop) bits_q <= bits_next;
        end
    end
endmodule

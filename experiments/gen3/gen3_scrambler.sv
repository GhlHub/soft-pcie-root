// SPDX-License-Identifier: Apache-2.0
// Gen3 lane scrambler/descrambler; DWORD bytes and bits LSB first.
// Only payload symbols enter here: sync headers do not clock the LFSR.
// Caller classifies ordered sets. SKP: advance=0, xor=0; ordinary bypassed
// ordered sets: advance=15, xor=0; data: advance=15, xor=15.
// TS1/TS2 need per-byte XOR selection, including the DC-balance exception.
// EIEOS final DWORD: reseed_after=1. This is not an ordered-set classifier.
module gen3_scrambler #(
    parameter integer LANE_ID = 0
) (
    input wire clk, reset_i,
    input wire [31:0] s_data_i,
    input wire [3:0] advance_i, xor_i,
    input wire reseed_after_i, s_valid_i,
    output wire s_ready_o,
    output reg [31:0] m_data_o,
    output reg m_valid_o,
    input wire m_ready_i,
    output wire [22:0] state_o
);

    initial if (LANE_ID < 0 || LANE_ID > 1) $fatal(1, "LANE_ID must be 0 or 1");
    localparam [22:0] SEED = LANE_ID == 0 ? 23'h1dbfbc : 23'h0607bb;
    reg [22:0] state_q, next_state, byte_state;
    reg [31:0] next_data;
    integer octet, bit_no;
    always @* begin
        next_state = state_q;
        next_data  = s_data_i;
        byte_state = state_q;
        for (octet = 0; octet < 4; octet = octet + 1) begin
            byte_state = next_state;
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                if (xor_i[octet])
                    next_data[octet*8+bit_no] = s_data_i[octet*8+bit_no] ^ byte_state[22];
                // x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1.
                byte_state = {byte_state[21:0], 1'b0} ^ (byte_state[22] ? 23'h210125 : 23'b0);
            end
            if (advance_i[octet]) next_state = byte_state;
        end
        if (reseed_after_i) next_state = SEED;
    end
    assign state_o   = state_q;
    assign s_ready_o = !reset_i && (!m_valid_o || m_ready_i);
    always @(posedge clk) begin
        if (reset_i) begin
            state_q   <= SEED;
            m_valid_o <= 0;
        end else if (s_ready_o) begin
            m_valid_o <= s_valid_i;
            if (s_valid_i) begin
                state_q  <= next_state;
                m_data_o <= next_data;
            end
        end
    end
endmodule

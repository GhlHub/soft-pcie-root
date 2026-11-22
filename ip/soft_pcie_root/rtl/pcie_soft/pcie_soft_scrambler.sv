// Experimental Gen1/2 x1 logical-symbol scrambler/descrambler.
// Two consecutive symbols per word, lower byte first; NOT a physical PIPE port.
// data_scramble_i selects XOR per data symbol; control symbols are never XORed.
// COM resets the state, SKP holds it; other present symbols advance it even
// when XOR is disabled (for example, during training). Synchronous reset.
module pcie_soft_scrambler #(
    parameter bit PRECOMPUTE_ADVANCE = 0
) (
    input wire clk,
    input wire rst_n,
    input wire [15:0] s_data_i,
    input wire [1:0] s_ctrl_i,
    input wire [1:0] s_keep_i,
    input wire [1:0] data_scramble_i,
    input wire s_valid_i,
    output wire s_ready_o,
    output wire [15:0] m_data_o,
    output wire [1:0] m_ctrl_o,
    output wire [1:0] m_keep_o,
    output wire m_valid_o,
    input wire m_ready_i,
    output wire [15:0] lfsr_o
);
    localparam [7:0] COM = 8'hbc, SKP = 8'h1c;
    reg [15:0] lfsr_q, data_q;
    reg [1:0] ctrl_q, keep_q;
    reg valid_q;
    reg [15:0] next_lfsr, next_data;

    function automatic [15:0] advance_octet(input [15:0] state);
        reg [15:0] current;
        begin
            current = state;
            for (integer b = 0; b < 8; b = b + 1)
            current = {current[14:0], 1'b0} ^ (current[15] ? 16'h0039 : 16'h0000);
            advance_octet = current;
        end
    endfunction
    if (PRECOMPUTE_ADVANCE) begin : parallel_octets
        wire [15:0] advance_once = advance_octet(lfsr_q);
        wire [15:0] advance_twice = advance_octet(advance_once);
        localparam [15:0] ADVANCED_SEED = advance_octet(16'hffff);
        wire [1:0] reset_symbol, advance_symbol;
        for (genvar i = 0; i < 2; i = i + 1) begin : classify
            assign reset_symbol[i] = s_keep_i[i] && s_ctrl_i[i] && s_data_i[8*i+:8] == COM;
            assign advance_symbol[i] = s_keep_i[i] && !reset_symbol[i] &&
                !(s_ctrl_i[i] && s_data_i[8*i+:8] == SKP);
        end
        wire [15:0]
            first_state = reset_symbol[0] ? 16'hffff : advance_symbol[0] ? advance_once : lfsr_q;
        wire [15:0] both_advanced = reset_symbol[0] ? ADVANCED_SEED :
            advance_symbol[0] ? advance_twice : advance_once;
        always @* begin
            // Select after computing the fixed transforms. The first
            // symbol's K comparison is outside both advance networks.
            next_lfsr = reset_symbol[1] ? 16'hffff :
                advance_symbol[1] ? both_advanced : first_state;
            next_data = s_data_i;
            for (integer b = 0; b < 8; b = b + 1) begin
                if (s_keep_i[0] && !s_ctrl_i[0] && data_scramble_i[0])
                    next_data[b] = s_data_i[b] ^ lfsr_q[15-b];
                if (s_keep_i[1] && !s_ctrl_i[1] && data_scramble_i[1])
                    next_data[8+b] = s_data_i[8+b] ^ first_state[15-b];
            end
        end
    end else begin : serial_octets
        reg [7:0] mask;
        reg       feedback;
        integer octet, bit_index;
        always @* begin
            next_lfsr = lfsr_q;
            next_data = s_data_i;
            mask      = 0;
            feedback  = 0;
            for (octet = 0; octet < 2; octet = octet + 1) begin
                if (s_keep_i[octet]) begin
                    // The first transmitted bit uses the old state bit 15.
                    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                    mask[bit_index] = next_lfsr[15-bit_index];
                    if (!s_ctrl_i[octet] && data_scramble_i[octet])
                        next_data[octet*8+:8] = s_data_i[octet*8+:8] ^ mask;
                    if (s_ctrl_i[octet] && s_data_i[octet*8+:8] == COM) next_lfsr = 16'hffff;
                    else if (!(s_ctrl_i[octet] && s_data_i[octet*8+:8] == SKP)) begin
                        // Serial recurrence for x^16+x^5+x^4+x^3+1.
                        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                            feedback  = next_lfsr[15];
                            next_lfsr = {next_lfsr[14:0], 1'b0} ^ (feedback ? 16'h0039 : 16'd0);
                        end
                    end
                end
            end
        end
    end
    assign s_ready_o = rst_n && (!valid_q || m_ready_i);
    assign m_valid_o = valid_q;
    assign m_data_o  = data_q;
    assign m_ctrl_o  = ctrl_q;
    assign m_keep_o  = keep_q;
    assign lfsr_o    = lfsr_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr_q  <= 16'hffff;
            valid_q <= 1'b0;
        end else if (s_ready_o) begin
            valid_q <= s_valid_i;
            if (s_valid_i) begin
                lfsr_q <= next_lfsr;
                data_q <= next_data;
                ctrl_q <= s_ctrl_i;
                keep_q <= s_keep_i;
            end
        end
    end
endmodule

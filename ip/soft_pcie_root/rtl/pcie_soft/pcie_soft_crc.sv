// Experimental PCIe Gen1/2 CRC arithmetic; not a complete packet engine.
// Lower byte is processed first. clear_i seeds before this cycle's bytes.
// The complemented reflected result has the first wire byte in bits [7:0].
module pcie_soft_crc (
    input wire clk,
    input wire rst_n,
    input wire clear_i,
    input wire valid_i,
    input wire [15:0] data_i,
    input wire [1:0] keep_i,
    output wire [31:0] lcrc_o,
    output wire [15:0] dllp_crc_o
);
    reg [31:0] crc32_q;
    reg [15:0] crc16_q;
    reg [31:0] crc32_next;
    reg [15:0] crc16_next;
    integer octet, bit_index;

    // Reflected forms of x^32+...+1 (04C11DB7) and
    // x^16+x^12+x^3+x+1 (100B). Process data least-significant bit first.
    always @* begin
        crc32_next = clear_i ? 32'hffffffff : crc32_q;
        crc16_next = clear_i ? 16'hffff : crc16_q;
        for (octet = 0; octet < 2; octet = octet + 1) begin
            if (valid_i && keep_i[octet]) begin
                for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                    crc32_next = (crc32_next >> 1) ^
                        ((crc32_next[0] ^ data_i[octet*8+bit_index]) ? 32'hedb88320 : 32'd0);
                    crc16_next = (crc16_next >> 1) ^
                        ((crc16_next[0] ^ data_i[octet*8+bit_index]) ? 16'hd008 : 16'd0);
                end
            end
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            crc32_q <= 32'hffffffff;
            crc16_q <= 16'hffff;
        end else begin
            crc32_q <= crc32_next;
            crc16_q <= crc16_next;
        end
    end
    assign lcrc_o     = ~crc32_q;
    assign dllp_crc_o = ~crc16_q;
endmodule

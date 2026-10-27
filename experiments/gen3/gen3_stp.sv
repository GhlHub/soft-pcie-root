// SPDX-License-Identifier: Apache-2.0
// Gen3 x1 STP framing protection. Byte 0 is in bits [7:0]. Length includes
// STP, complete TLP and LCRC. No PMUX, prefixes or packet validation here.
module gen3_stp (
    input wire [10:0] tx_length_i,
    input wire [11:0] tx_sequence_i,
    output wire [31:0] tx_token_o,
    input wire [31:0] rx_token_i,
    output wire rx_stp_o, rx_eds_o,
    output wire [10:0] rx_length_o,
    output wire [11:0] rx_sequence_o
);
    function automatic [3:0] fcrc(input [10:0] len);
        begin
            fcrc[0]=^(len & 11'h4d7);
            fcrc[1]=^(len & 11'h6bc);
            fcrc[2]=^(len & 11'h35e);
            fcrc[3]=^(len & 11'h1af);
        end
    endfunction
    wire [3:0] tx_crc=fcrc(tx_length_i);
    wire tx_parity=^{tx_length_i,tx_crc};
    assign tx_token_o={tx_sequence_i[7:0],tx_crc,tx_sequence_i[11:8],
                       tx_parity,tx_length_i[10:4],tx_length_i[3:0],4'hf};
    assign rx_length_o={rx_token_i[14:8],rx_token_i[7:4]};
    assign rx_sequence_o={rx_token_i[19:16],rx_token_i[31:24]};
    assign rx_eds_o=rx_token_i==32'h0090801f;
    // Optional reserved/PMUX length checks enabled for this restricted core.
    assign rx_stp_o=rx_token_i[3:0]==4'hf && rx_length_o>=2 && rx_length_o<1152 &&
                    rx_token_i[23:20]==fcrc(rx_length_o) &&
                    rx_token_i[15]==^{rx_length_o,rx_token_i[23:20]};
endmodule

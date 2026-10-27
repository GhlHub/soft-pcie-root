// SPDX-License-Identifier: Apache-2.0
// Search a contiguous RAW bitstream for the complete 8 GT/s EIEOS.
// Data bit 0 arrives first. valid_i pauses delivery, not the serial bitstream.
// end_bit_o identifies the final EIEOS bit in the word accepted on the prior
// edge. A downstream aligner must retain that word's trailing bits.
// search_i must be disabled in Locked phase: this is a detector, not an LTSSM
// or a complete aligner. Reset on a stream discontinuity invalidates history.
module gen3_eieos_detect (
    input wire clk, reset_i, search_i, valid_i,
    input wire [31:0] data_i,
    output reg found_o,
    output reg [4:0] end_bit_o
);
    localparam [129:0] EIEOS = {{8{16'hff00}}, 2'b01};
    reg [128:0] history_q;
    reg [7:0] history_count_q;
    wire [160:0] window_bits = {data_i, history_q};
    reg found_next;
    reg [4:0] end_next;
    integer bit_no;
    always @* begin
        found_next=0;
        end_next=0;
        for (bit_no=0;bit_no<32;bit_no=bit_no+1) begin
            if ((int'(history_count_q)+bit_no >= 129) &&
                window_bits[bit_no +: 130] == EIEOS) begin
                found_next=1;
                end_next=5'(bit_no);
            end
        end
    end
    always @(posedge clk) begin
        if (reset_i) begin
            found_o<=0;
            history_count_q<=0;
        end else begin
            found_o<=0;
            if (valid_i) begin
                history_q<=window_bits[160:32];
                history_count_q<=history_count_q<97 ? history_count_q+8'd32 : 8'd129;
                found_o<=search_i && found_next;
                if (search_i && found_next) end_bit_o<=end_next;
            end
        end
    end
endmodule

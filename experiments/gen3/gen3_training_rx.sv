// SPDX-License-Identifier: Apache-2.0
// Native PIPE training decoder, lane/link zero. Acquires only on a full EIEOS.
// TS14/15 checks are intentionally omitted as permitted by the Base spec.
module gen3_training_rx (
    input wire clk, reset_i, enable_i,
    input wire [31:0] data_i,
    input wire valid_i, start_i,
    input wire [1:0] header_i,
    output reg aligned_o, ts_event_o, ts1_valid_o,
    output reg [1:0] ec_o,
    output reg [5:0] fs_o, lf_o,
    output reg [31:0] symbols6_9_o,
    output reg error_o, eios_o,
    output reg [127:0] last_ts_o
);
    reg [1:0] index;
    reg in_block, is_skip;
    reg  [  2:0] skip_words;
    reg  [  7:0] kind;
    reg  [127:0] decoded;
    reg  [ 22:0] lfsr;
    wire [  1:0] at = start_i ? 2'b0 : index;
    wire [  7:0] this_kind = start_i ? data_i[7:0] : kind;
    wire         skip = start_i ? (header_i == 1 && data_i[7:0] == 8'haa) : is_skip;
    reg  [ 31:0] word_decoded;
    reg  [ 22:0] next_lfsr;
    reg  [127:0] assembled;
    integer j, b;
    always @* begin
        word_decoded = data_i;
        next_lfsr    = lfsr;
        for (j = 0; j < 4; j = j + 1) begin
            for (b = 0; b < 8; b = b + 1) begin
                if ((this_kind == 8'h1e || this_kind == 8'h2d) && !(at == 0 && j == 0))
                    word_decoded[8*j+b] = data_i[8*j+b] ^ next_lfsr[22];
                if (!skip)
                    next_lfsr = {next_lfsr[21:0], 1'b0} ^ (next_lfsr[22] ? 23'h210125 : 23'b0);
            end
        end
        assembled = decoded;
        case (at)
            0: assembled[31:0] = word_decoded;
            1: assembled[63:32] = word_decoded;
            2: assembled[95:64] = word_decoded;
            3: assembled[127:96] = word_decoded;
        endcase
    end
    always @(posedge clk) begin
        if (reset_i || !enable_i) begin
            aligned_o   <= 0;
            in_block    <= 0;
            is_skip     <= 0;
            index       <= 0;
            kind        <= 0;
            skip_words  <= 0;
            lfsr        <= 23'h1dbfbc;
            ts_event_o  <= 0;
            ts1_valid_o <= 0;
            error_o     <= 0;
            eios_o      <= 0;
        end else begin
            ts_event_o  <= 0;
            ts1_valid_o <= 0;
            error_o     <= 0;
            eios_o      <= 0;
            if (valid_i) begin
                if (start_i) begin
                    kind       <= data_i[7:0];
                    is_skip    <= header_i == 1 && data_i[7:0] == 8'haa;
                    in_block   <= header_i == 1;
                    index      <= 1;
                    skip_words <= 1;
                    if (header_i != 1 || in_block ||
                        (data_i[7:0] == 8'haa && data_i != 32'haaaaaaaa)) begin
                        aligned_o <= 0;
                        error_o   <= 1;
                    end
                end else if (in_block && !is_skip) index <= index + 1'b1;
                else if (in_block && is_skip) begin
                    skip_words <= skip_words + 1'b1;
                    if (data_i[7:0] == 8'he1) begin
                        in_block <= 0;
                        is_skip  <= 0;
                        if (skip_words < 1 || skip_words > 5 ||
                            data_i != {lfsr[7:0], lfsr[15:8], !lfsr[22], lfsr[22:16], 8'he1}) begin
                            aligned_o <= 0;
                            error_o   <= 1;
                        end
                    end else if (data_i != 32'haaaaaaaa || skip_words >= 5) begin
                        in_block  <= 0;
                        is_skip   <= 0;
                        aligned_o <= 0;
                        error_o   <= 1;
                    end
                end else begin
                    aligned_o <= 0;
                    error_o   <= 1;
                end
                if (start_i || in_block) begin
                    lfsr    <= next_lfsr;
                    decoded <= assembled;
                    if (!skip && at == 3) begin
                        in_block <= 0;
                        if (this_kind == 0 &&
                            assembled == 128'hff00ff00ff00ff00ff00ff00ff00ff00) begin
                            lfsr      <= 23'h1dbfbc;
                            aligned_o <= 1;
                        end else if (this_kind == 8'h1e || this_kind == 8'h2d) begin
                            ts_event_o <= 1;
                            last_ts_o <= assembled;
                            symbols6_9_o <= assembled[79:48];
                            ec_o <= assembled[49:48];
                            fs_o <= assembled[61:56];
                            lf_o <= assembled[69:64];
                            ts1_valid_o <= aligned_o && this_kind == 8'h1e &&
                                assembled[23:8] == 0 && assembled[42:40] == 0 &&
                                assembled[111:80] == 32'h4a4a4a4a && !(^assembled[79:48]);
                        end else if (this_kind == 8'h66 && assembled[31:0] == 32'h66666666) begin
                            eios_o    <= 1;
                            aligned_o <= 0;
                        end else begin
                            aligned_o <= 0;
                            error_o   <= 1;
                        end
                    end
                end
            end
        end
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
// Two-bank Gen3 STP/body/LCRC formatter. Collection overlaps transmission.
// Downstream acceptance is PCS submission, not proof of wire completion.
module gen3_tlp_source_x2 #(
    parameter integer WORDS = 64
) (
    input wire clk, reset_i,
    input wire [63:0] data_i,
    input wire [1:0] words_i,
    input wire valid_i, last_i,
    output wire ready_o,
    input wire [11:0] sequence_i,
    output wire [63:0] data_o,
    output wire [1:0] words_o,
    output wire valid_o, last_o,
    input wire ready_i,
    output wire submitted_o,
    output reg fault_o
);
    localparam integer W = $clog2(WORDS);
    (* ram_style="distributed" *)reg [31:0] memory   [0:2*WORDS-1];
    reg [ W:0] lengths  [        0:1];
    reg [31:0] checksums[        0:1];
    reg [11:0] sequences[        0:1];
    reg write_bank, read_bank, collecting, dropping;
    reg  [  1:0] count;
    reg  [W-1:0] write_index;
    reg  [  W:0] read_index;
    reg  [ 31:0] crc;
    reg  [ 11:0] collect_sequence;
    wire [W-1:0] index_i = collecting ? write_index : W'(0);
    wire         take = valid_i && ready_o;
    wire         malformed = words_i == 0 || words_i > 2 || (!last_i && words_i != 2);
    wire         commit_packet = take && last_i && !dropping && !malformed;
    wire [ 31:0] stp;
    wire unused_stp, unused_eds;
    wire [10:0] unused_length;
    wire [11:0] unused_seq;
    gen3_stp token (
        11'(lengths[read_bank]) + 11'd2,
        sequences[read_bank],
        stp,
        32'b0,
        unused_stp,
        unused_eds,
        unused_length,
        unused_seq
    );
    function automatic [31:0] crc_byte(input [31:0] old, input [7:0] value);
        reg [31:0] c;
        begin
            c = old;
            for (integer b = 0; b < 8; b = b + 1)
            c = (c >> 1) ^ ((c[0] ^ value[b]) ? 32'hedb88320 : 0);
            crc_byte = c;
        end
    endfunction
    function automatic [31:0] crc_dword(input [31:0] old, input [31:0] value);
        crc_dword = crc_byte(
            crc_byte(crc_byte(crc_byte(old, value[7:0]), value[15:8]), value[23:16]), value[31:24]);
    endfunction
    wire [31:0] seed = collecting ? crc : crc_byte(
        crc_byte(32'hffffffff, {4'b0, sequence_i[11:8]}), sequence_i[7:0]
    );
    // Apply only fixed-length transforms on the feedback path. The final
    // beat chooses one or two DWORDs after the transforms are evaluated.
    wire [31:0] crc_one = crc_dword(seed, data_i[31:0]);
    wire [31:0] crc_two = crc_dword(crc_one, data_i[63:32]);
    wire [31:0] next_crc = words_i == 2 ? crc_two : crc_one;
    assign ready_o = !reset_i && (collecting || dropping || (!fault_o && count < 2));
    assign valid_o = !reset_i && count != 0;
    wire [W:0] total_words = lengths[read_bank] + 2;
    // STP and LCRC add exactly two DWORDs. Cancel them from
    // the final-beat comparison and use the body's parity for its word count.
    assign last_o  = read_index >= lengths[read_bank];
    assign words_o = last_o && lengths[read_bank][0] ? 2'd1 : 2'd2;
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : output_lanes
        wire [W:0] index = read_index + (W + 1)'(lane);
        assign data_o[32*lane+:32] = index == 0 ? stp : index == total_words - 1'b1 ? checksums[
            read_bank] : index < total_words ? memory[{read_bank, W'(index-1'b1)}] : 32'b0;
    end
    assign submitted_o = valid_o && ready_i && last_o;
    always @(posedge clk) begin
        for (integer lane = 0; lane < 2; lane = lane + 1)
        if (take && !dropping && !malformed && lane < int'(words_i))
            memory[{write_bank, W'(index_i+W'(lane))}] <= data_i[32*lane+:32];
        if (commit_packet) begin
            lengths[write_bank]   <= {1'b0, index_i} + (W + 1)'(words_i);
            checksums[write_bank] <= ~next_crc;
            sequences[write_bank] <= collecting ? collect_sequence : sequence_i;
        end
        if (reset_i) begin
            write_bank  <= 0;
            read_bank   <= 0;
            collecting  <= 0;
            dropping    <= 0;
            count       <= 0;
            write_index <= 0;
            read_index  <= 0;
            fault_o     <= 0;
        end else begin
            count <= count + 2'(commit_packet) - 2'(submitted_o);
            if (take) begin
                if (malformed) begin
                    fault_o  <= 1;
                    dropping <= !last_i;
                end
                if (last_i) begin
                    collecting  <= 0;
                    dropping    <= 0;
                    write_index <= 0;
                    if (!dropping && !malformed) write_bank <= !write_bank;
                end else begin
                    collecting  <= 1;
                    write_index <= index_i + W'(words_i);
                    if (int'(index_i) + int'(words_i) >= WORDS) begin
                        dropping <= 1;
                        fault_o  <= 1;
                    end
                end
                if (!collecting) collect_sequence <= sequence_i;
                crc <= next_crc;
            end
            if (valid_o && ready_i) begin
                if (last_o) begin
                    read_index <= 0;
                    read_bank  <= !read_bank;
                end else read_index <= read_index + 2;
            end
        end
    end
    wire unused = ^{unused_stp, unused_eds, unused_length, unused_seq};
endmodule

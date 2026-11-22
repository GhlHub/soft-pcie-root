// SPDX-License-Identifier: Apache-2.0
// Elastic packet width adapter. Words are consecutive low-first DWORDs.
// Metadata belongs to the packet; no merging across packet boundaries.
// Cold reset only: link pauses must retain buffered accepted ownership.
module pcie_packet_width #(
    parameter integer INPUT_DWORDS  = 2,
                      OUTPUT_DWORDS = 4
) (
    input wire clk, rst_n,
    input wire [32*INPUT_DWORDS-1:0] s_data_i,
    input wire [2:0] s_words_i,
    input wire [10:0] s_meta_i,
    input wire s_valid_i, s_last_i,
    output wire s_ready_o,
    output wire [32*OUTPUT_DWORDS-1:0] m_data_o,
    output wire [2:0] m_words_o,
    output wire [10:0] m_meta_o,
    output wire m_valid_o, m_last_o,
    input wire m_ready_i,
    output reg fault_o
);
    wire malformed = s_words_i < 1 || int'(s_words_i) > INPUT_DWORDS ||
        (!s_last_i && int'(s_words_i) != INPUT_DWORDS);
    if (INPUT_DWORDS > OUTPUT_DWORDS) begin : narrow
        // One input beat turns into whole output groups. A new input can
        // replace the last group on the same edge, with no variable shift.
        reg [32*INPUT_DWORDS-1:0] data_q;
        reg [                2:0] remaining_q;
        reg last_q, receiving_packet_q;
        reg  [10:0] meta_q;
        wire        final_group = remaining_q <= 3'(OUTPUT_DWORDS);
        wire        take_out = m_valid_o && m_ready_i;
        wire        take_in = s_valid_i && s_ready_o;
        assign m_valid_o = rst_n && remaining_q != 0;
        assign m_words_o = final_group ? remaining_q : 3'(OUTPUT_DWORDS);
        assign m_last_o  = last_q && final_group;
        assign m_data_o  = data_q[32*OUTPUT_DWORDS-1:0];
        assign m_meta_o  = meta_q;
        assign s_ready_o = rst_n && !fault_o && (remaining_q == 0 || (take_out && final_group));
        always @(posedge clk) begin
            if (!rst_n) begin
                remaining_q        <= 0;
                last_q             <= 0;
                receiving_packet_q <= 0;
                fault_o            <= 0;
            end else begin
                if (take_in && malformed) fault_o <= 1;
                if (take_in && !malformed) begin
                    data_q             <= s_data_i;
                    remaining_q        <= s_words_i;
                    last_q             <= s_last_i;
                    receiving_packet_q <= !s_last_i;
                    if (!receiving_packet_q) meta_q <= s_meta_i;
                end else if (take_out) begin
                    data_q      <= data_q >> (32 * OUTPUT_DWORDS);
                    remaining_q <= final_group ? 3'b0 : remaining_q - 3'(OUTPUT_DWORDS);
                    if (final_group) last_q <= 0;
                end
            end
        end
    end else begin : assemble
        localparam CAPACITY = INPUT_DWORDS + OUTPUT_DWORDS;
        reg [32*CAPACITY-1:0] data_q, data_n;
        reg [3:0] count_q, count_n;
        reg last_q, last_n, packet_q, packet_n;
        reg [10:0] meta_q, meta_n;
        wire       take_out = m_valid_o && m_ready_i;
        wire [3:0] after_count = count_q - (take_out ? {1'b0, m_words_o} : 4'b0);
        wire       after_last = last_q && !(take_out && m_last_o);
        assign m_valid_o = rst_n && (int'(count_q) >= OUTPUT_DWORDS || (last_q && count_q != 0));
        assign m_words_o = int'(count_q) < OUTPUT_DWORDS ? count_q[2:0] : 3'(OUTPUT_DWORDS);
        assign m_last_o = last_q && int'(count_q) <= OUTPUT_DWORDS;
        assign m_data_o = data_q[32*OUTPUT_DWORDS-1:0];
        assign m_meta_o = meta_q;
        assign s_ready_o = rst_n && !fault_o && !after_last &&
            int'(after_count) + INPUT_DWORDS <= CAPACITY;
        always @* begin
            count_n  = after_count;
            last_n   = after_last;
            data_n   = data_q;
            meta_n   = meta_q;
            packet_n = packet_q;
            if (take_out) begin
                data_n = data_q >> (32 * m_words_o);
                if (m_last_o) packet_n = 0;
            end
            if (s_valid_i && s_ready_o && !malformed) begin
                for (integer lane = 0; lane < INPUT_DWORDS; lane = lane + 1)
                if (lane < int'(s_words_i))
                    data_n[32*(int'(after_count)+lane)+:32] = s_data_i[32*lane+:32];
                count_n = after_count + {1'b0, s_words_i};
                last_n  = s_last_i;
                if (!packet_n) meta_n = s_meta_i;
                packet_n = 1;
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                count_q  <= 0;
                last_q   <= 0;
                packet_q <= 0;
                fault_o  <= 0;
            end else begin
                count_q  <= count_n;
                last_q   <= last_n;
                packet_q <= packet_n;
                if (s_valid_i && s_ready_o && malformed) fault_o <= 1;
            end
            if (rst_n) begin
                data_q <= data_n;
                meta_q <= meta_n;
            end
        end
    end
    initial
        if ((INPUT_DWORDS != 1 && INPUT_DWORDS != 2 && INPUT_DWORDS != 4) ||
            (OUTPUT_DWORDS != 1 && OUTPUT_DWORDS != 2 && OUTPUT_DWORDS != 4))
            $fatal(1, "Invalid width adapter geometry");
endmodule

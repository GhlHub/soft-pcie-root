// SPDX-License-Identifier: Apache-2.0
// Whole-packet validation/ownership gate for gen3_stream_rx events.
// Recovery abort discards only the uncommitted candidate. Committed packets,
// receive sequence ownership and stalled output survive abort_i.
module gen3_packet_gate #(
    parameter integer WORDS      = 64,
                      SLOTS      = 16,
                      WORD_INPUT = 0
) (
    input wire clk, reset_i, abort_i,
    input wire start_i,
    input wire [10:0] length_i,
    input wire [11:0] sequence_i,
    input wire [31:0] body_i,
    input wire [2:0] body_bytes_i,
    input wire last_i, finish_i, nullified_i,
    output wire [31:0] data_o,
    output wire valid_o, last_o,
    input wire ready_i,
    output wire [1:0] class_o,
    output wire [8:0] credits_o,
    output reg response_o, nak_o, error_o,
    output reg [11:0] response_sequence_o
);
    localparam integer W = $clog2(WORDS), S = $clog2(SLOTS);
    (* ram_style="distributed" *)reg [31:0] memory [0:SLOTS*WORDS-1];
    reg [ W:0] lengths[      0:SLOTS-1];
    reg [ 1:0] classes[      0:SLOTS-1];
    reg [ 8:0] costs  [      0:SLOTS-1];
    reg [S-1:0] write_slot_q, read_slot_q;
    reg [W-1:0] read_word_q;
    reg [  S:0] occupied_q;
    reg candidate_q, candidate_n, complete_q, complete_n, drop_q, drop_n;
    reg [12:0] bytes_q, bytes_n;
    reg [10:0] declared_q, declared_n;
    reg [11:0] sequence_q, sequence_n, expected_q;
    reg [31:0] crc_q, crc_n, tail_q, tail_n, word_q, word_n, header_q, header_n;
    reg write_enable, commit, response, nak, error;
    reg [W-1:0] write_index;
    reg [31:0] write_data, check_crc, check_tail, check_header;
    reg [12:0] check_bytes, expected_bytes;
    reg [10:0] check_declared, payload_words;
    reg [11:0] check_sequence, distance;
    reg check_candidate, check_complete, check_drop;
    reg [ W:0] commit_words;
    reg [ 1:0] commit_class;
    reg [ 8:0] commit_cost;
    reg [11:0] response_sequence;
    reg [12:0] header_bytes_q, declared_bytes_q;
    reg [10:0] header_payload_q;
    wire [10:0] header_payload = {header_q[17:16], header_q[31:24]} == 0 ?
        11'd1024 : {1'b0, header_q[17:16], header_q[31:24]};
    // The DWORD path captures the header before the final body DWORD. These
    // metadata checks settle before finish; short malformed packets still fail
    // the minimum-length check and cannot commit.
    always @(posedge clk) begin
        if (WORD_INPUT != 0) begin
            header_payload_q <= header_payload;
            header_bytes_q <= 13'd16 + {10'b0, header_q[5], 2'b0} + {10'b0, header_q[23], 2'b0} +
                (header_q[6] ? {header_payload, 2'b0} : 13'b0);
            if (start_i) declared_bytes_q <= ({2'b0, length_i} - 13'd1) << 2;
        end
    end
    wire unused_header_bits = ^{check_header[22:18], check_header[15:7]};
    integer b, index;
    function automatic [31:0] crc_byte(input [31:0] old, input [7:0] octet);
        reg [31:0] c;
        begin
            c = old;
            for (integer k = 0; k < 8; k = k + 1)
            c = (c >> 1) ^ ((c[0] ^ octet[k]) ? 32'hedb88320 : 0);
            crc_byte = c;
        end
    endfunction
    assign valid_o   = occupied_q != 0;
    assign data_o    = memory[{read_slot_q, read_word_q}];
    assign last_o    = {1'b0, read_word_q} == lengths[read_slot_q] - 1'b1;
    assign class_o   = classes[read_slot_q];
    assign credits_o = costs[read_slot_q];
    wire release_packet = valid_o && ready_i && last_o;
    always @* begin
        candidate_n       = candidate_q;
        complete_n        = complete_q;
        drop_n            = drop_q;
        bytes_n           = bytes_q;
        declared_n        = declared_q;
        sequence_n        = sequence_q;
        crc_n             = crc_q;
        tail_n            = tail_q;
        word_n            = word_q;
        header_n          = header_q;
        write_enable      = 0;
        write_index       = 0;
        write_data        = 0;
        commit            = 0;
        response          = 0;
        nak               = 0;
        error             = 0;
        commit_words      = 0;
        commit_class      = 0;
        commit_cost       = 0;
        response_sequence = expected_q - 1'b1;
        index             = 0;
        if (start_i) begin
            candidate_n = 1;
            complete_n = 0;
            bytes_n = 0;
            declared_n = length_i;
            sequence_n = sequence_i;
            drop_n = int'(occupied_q) == SLOTS || int'(length_i) > WORDS + 2;
            crc_n = crc_byte(crc_byte(32'hffffffff, {4'b0, sequence_i[11:8]}), sequence_i[7:0]);
            tail_n = 0;
            word_n = 0;
            header_n = 0;
            if (candidate_q && !finish_i) begin
                error  = 1;
                drop_n = 1;
            end
        end
        if (WORD_INPUT != 0) begin
            // Buffered parser contract: aligned DWORD bodies, no body on STP
            // or finish, and finish strictly after the final body DWORD.
            if (body_bytes_i == 4 && candidate_q && !complete_q) begin
                if (bytes_q >= 4) begin
                    crc_n = crc_byte(
                        crc_byte(
                            crc_byte(crc_byte(crc_q, tail_q[7:0]), tail_q[15:8]), tail_q[23:16]
                        ),
                        tail_q[31:24]
                    );
                    if (int'(bytes_q) <= WORDS * 4) begin
                        write_enable = 1;
                        write_index  = W'((bytes_q >> 2) - 1'b1);
                        write_data   = tail_q;
                        if (bytes_q == 4) header_n = tail_q;
                    end else drop_n = 1;
                end
                tail_n = body_i;
                if (bytes_q <= 8187) bytes_n = bytes_q + 4;
                else drop_n = 1;
            end
        end else begin
            for (b = 0; b < 4; b = b + 1) begin
                if (b < int'(body_bytes_i) && candidate_n && !complete_n) begin
                    if (bytes_n >= 4) begin
                        crc_n                  = crc_byte(crc_n, tail_n[7:0]);
                        index                  = int'(bytes_n) - 4;
                        word_n[8*(index%4)+:8] = tail_n[7:0];
                        if (index % 4 == 3) begin
                            if (index < WORDS * 4) begin
                                write_enable = 1;
                                write_index  = W'(index / 4);
                                write_data   = word_n;
                                if (index == 3) header_n = word_n;
                            end else drop_n = 1;
                        end
                    end
                    tail_n = {body_i[8*b+:8], tail_n[31:8]};
                    if (bytes_n < 8191) bytes_n = bytes_n + 1'b1;
                    else drop_n = 1;
                end
            end
        end
        if (last_i && candidate_n) complete_n = 1;
        // Finish and the following packet's STP may coincide. In that case
        // finish refers to the old candidate, while start initializes the new.
        check_candidate = (WORD_INPUT != 0 || start_i) ? candidate_q : candidate_n;
        check_complete = (WORD_INPUT != 0 || start_i) ? complete_q : complete_n;
        check_drop = (WORD_INPUT != 0 || start_i) ? drop_q : drop_n;
        check_bytes = (WORD_INPUT != 0 || start_i) ? bytes_q : bytes_n;
        check_declared = (WORD_INPUT != 0 || start_i) ? declared_q : declared_n;
        check_sequence = (WORD_INPUT != 0 || start_i) ? sequence_q : sequence_n;
        check_crc = (WORD_INPUT != 0 || start_i) ? crc_q : crc_n;
        check_tail = (WORD_INPUT != 0 || start_i) ? tail_q : tail_n;
        check_header = (WORD_INPUT != 0 || start_i) ? header_q : header_n;
        payload_words = {check_header[17:16], check_header[31:24]} == 0 ?
            11'd1024 : {1'b0, check_header[17:16], check_header[31:24]};
        expected_bytes = 13'd16 + {10'b0, check_header[5], 2'b0} + {10'b0, check_header[23], 2'b0} +
            (check_header[6] ? {payload_words, 2'b0} : 13'b0);
        if (WORD_INPUT != 0) begin
            expected_bytes = header_bytes_q;
            payload_words  = header_payload_q;
        end
        distance = expected_q - check_sequence;
        if (finish_i) begin
            if (!check_candidate || !check_complete) error = 1;
            else
            if (nullified_i && check_tail == check_crc) begin
            end else if (nullified_i || check_tail != ~check_crc || check_bytes != expected_bytes ||
                         check_bytes != (WORD_INPUT != 0 ?
                                         declared_bytes_q : ({2'b0, check_declared} - 13'd1) * 4) ||
                         check_bytes < 16 || (check_header[6] && payload_words > 32)) begin
                response = 1;
                nak      = 1;
                error    = 1;
            end else if (check_sequence == expected_q) begin
                response = 1;
                if (check_drop) begin
                    nak   = 1;
                    error = 1;
                end else begin
                    commit = 1;
                    response_sequence = check_sequence;
                    commit_words = (W + 1)'((int'(check_bytes) - 4) / 4);
                    commit_class = check_header[4:0] == 5'h0a ?
                        2'd2 : ((check_header[4:0] == 0 && check_header[6]) ? 2'd0 : 2'd1);
                    commit_cost = check_header[6] ? 9'((payload_words + 11'd3) >> 2) : 9'b0;
                end
            end else begin
                response = 1;
                if (distance > 2048) begin
                    nak   = 1;
                    error = 1;
                end
            end
            if (!start_i) begin
                candidate_n = 0;
                complete_n  = 0;
            end else if (commit && int'(occupied_q) >= SLOTS - 1) drop_n = 1;
        end
        if (WORD_INPUT != 0 &&
            ((body_bytes_i != 0 && body_bytes_i != 4) ||
             (body_bytes_i != 0 && (start_i || finish_i)) || (last_i && body_bytes_i != 4))) begin
            commit   = 0;
            response = 0;
            error    = 1;
            drop_n   = 1;
        end
    end
    always @(posedge clk) begin
        if (!reset_i && !abort_i && write_enable && !drop_n)
            memory[{write_slot_q, write_index}] <= write_data;
        if (!reset_i && !abort_i && commit) begin
            lengths[write_slot_q] <= commit_words;
            classes[write_slot_q] <= commit_class;
            costs[write_slot_q]   <= commit_cost;
        end
        if (reset_i) begin
            occupied_q   <= 0;
            write_slot_q <= 0;
            read_slot_q  <= 0;
            read_word_q  <= 0;
            expected_q   <= 0;
            candidate_q  <= 0;
            complete_q   <= 0;
            drop_q       <= 0;
            bytes_q      <= 0;
            response_o   <= 0;
            nak_o        <= 0;
            error_o      <= 0;
        end else begin
            response_o <= !abort_i && response;
            nak_o      <= !abort_i && nak;
            error_o    <= !abort_i && error;
            if (!abort_i && response) response_sequence_o <= response_sequence;
            case ({
                (!abort_i && commit), release_packet
            })
                2'b10: occupied_q <= occupied_q + 1'b1;
                2'b01: occupied_q <= occupied_q - 1'b1;
                default: begin
                end
            endcase
            if (!abort_i && commit) begin
                write_slot_q <= write_slot_q + 1'b1;
                expected_q   <= expected_q + 1'b1;
            end
            if (valid_o && ready_i) begin
                if (last_o) begin
                    read_slot_q <= read_slot_q + 1'b1;
                    read_word_q <= 0;
                end else read_word_q <= read_word_q + 1'b1;
            end
            if (abort_i) begin
                candidate_q <= 0;
                complete_q  <= 0;
            end else begin
                candidate_q <= candidate_n;
                complete_q  <= complete_n;
                drop_q      <= drop_n;
                bytes_q     <= bytes_n;
                declared_q  <= declared_n;
                sequence_q  <= sequence_n;
                crc_q       <= crc_n;
                tail_q      <= tail_n;
                word_q      <= word_n;
                header_q    <= header_n;
            end
        end
    end
`ifndef SYNTHESIS
    initial
        if (WORDS < 36 || (WORDS & (WORDS - 1)) != 0 || SLOTS < 2 || (SLOTS & (SLOTS - 1)) != 0)
            $fatal(1, "Invalid packet store geometry");
`endif
endmodule

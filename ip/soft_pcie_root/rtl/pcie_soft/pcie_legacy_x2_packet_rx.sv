// SPDX-License-Identifier: Apache-2.0
// Four-symbol 8b/10b receive pipeline. Only complete, validated packets own
// storage. Recovery can discard a candidate without flushing accepted TLPs.
module pcie_legacy_x2_packet_rx #(
    parameter integer MAX_DWORDS = 64,
    parameter integer DEPTH      = 16
) (
    input wire clk, rst_n, link_reset_i,
    input wire [31:0] symbols_i,
    input wire [3:0] control_i,
    input wire valid_i, error_i,
    output wire [31:0] tlp_data_o,
    output reg tlp_valid_o, tlp_last_o,
    input wire tlp_ready_i,
    output reg [1:0] tlp_class_o,
    output reg [8:0] tlp_credits_o,
    output reg response_o, nak_o,
    output reg [11:0] response_sequence_o,
    output reg dllp_o,
    output reg [31:0] dllp_body_o,
    output reg packet_error_o,
    input wire abort_candidate_i
);
    localparam integer S = $clog2(DEPTH), W = $clog2(MAX_DWORDS);
    localparam [1:0] NONE = 0, TLP = 1, DLLP = 2;
    localparam [1:0] CONTINUE = 0, END = 1, EDB = 2, BROKEN = 3;
    localparam [31:0] LCRC_RESIDUE = 32'hdebb20e3;
    wire        reset = !rst_n || link_reset_i;

    // Any K ends the preceding run of data bytes. Only the suffix after the
    // last K can start the next candidate. A frame wholly inside this beat
    // is malformed, since even the shortest complete DLLP needs eight bytes.
    reg  [31:0] prefix;
    reg  [23:0] suffix;
    reg  [ 2:0] prefix_count;
    reg [1:0] suffix_count, terminator, start_kind;
    reg nested_error, nested_nak;
    always @* begin
        prefix       = 0;
        suffix       = 0;
        prefix_count = 0;
        suffix_count = 0;
        terminator   = CONTINUE;
        start_kind   = NONE;
        nested_error = 0;
        nested_nak   = 0;
        for (integer byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
            if (control_i[byte_index]) begin
                if (start_kind != NONE) begin
                    nested_error = 1;
                    nested_nak   = nested_nak || start_kind == TLP;
                end
                if (terminator == CONTINUE) begin
                    case (symbols_i[8*byte_index+:8])
                        8'hfd:   terminator = END;
                        8'hfe:   terminator = EDB;
                        default: terminator = BROKEN;
                    endcase
                end
                case (symbols_i[8*byte_index+:8])
                    8'hfb:   start_kind = TLP;
                    8'h5c:   start_kind = DLLP;
                    default: start_kind = NONE;
                endcase
                suffix       = 24'(symbols_i >> (8 * (byte_index + 1)));
                suffix_count = 2'(3 - byte_index);
            end else if (terminator == CONTINUE) begin
                prefix[8*byte_index+:8] = symbols_i[8*byte_index+:8];
                prefix_count            = 3'(byte_index + 1);
            end
        end
    end
    reg [31:0] prefix_q;
    reg [23:0] suffix_q;
    reg [ 2:0] prefix_count_q;
    reg [1:0] suffix_count_q, terminator_q, start_kind_q;
    reg valid_q, abort_q, error_q, nested_error_q, nested_nak_q;
    always @(posedge clk) begin
        valid_q        <= !reset && valid_i && !abort_candidate_i;
        abort_q        <= !reset && abort_candidate_i;
        error_q        <= error_i;
        prefix_q       <= prefix;
        prefix_count_q <= prefix_count;
        suffix_q       <= suffix;
        suffix_count_q <= suffix_count;
        terminator_q   <= terminator;
        start_kind_q   <= start_kind;
        nested_error_q <= nested_error;
        nested_nak_q   <= nested_nak;
    end

    // A two-byte prefix aligns the sequence field, header, payload and LCRC
    // to word boundaries. The prefix is excluded from CRC computation.
    reg [23:0] carry_q;
    reg [1:0] carry_count_q, kind_q;
    reg         first_word_q;
    wire [55:0] joined = {32'b0, carry_q} | ({24'b0, prefix_q} << {carry_count_q, 3'b0});
    wire [ 2:0] joined_count = prefix_count_q + {1'b0, carry_count_q};
    wire [23:0] remainder = joined_count[2] ? joined[55:32] : joined[23:0];
    reg  [31:0] event_word;
    reg  [23:0] event_remainder;
    reg  [15:0] event_start_field;
    reg [1:0] event_kind, event_end, event_carry_count, event_start;
    reg event_word_valid, event_first_word, event_start_field_valid;
    reg event_error, event_nak;
    always @(posedge clk) begin
        event_kind <= kind_q;
        event_word <= joined[31:0];
        event_word_valid <= !reset && valid_q && !error_q && kind_q != NONE && joined_count[2];
        event_first_word <= first_word_q;
        event_end <= !reset && valid_q && kind_q != NONE ? (error_q ? BROKEN : terminator_q) :
            CONTINUE;
        event_remainder <= remainder;
        event_carry_count <= joined_count[1:0];
        event_start <= !reset && valid_q && !error_q ? start_kind_q : NONE;
        event_start_field <= suffix_q[15:0];
        event_start_field_valid <= suffix_count_q[1];
        event_error <= !reset && valid_q && (error_q || nested_error_q);
        event_nak <= !reset && valid_q && !error_q && nested_nak_q;

        if (reset || abort_q || (valid_q && error_q)) begin
            kind_q        <= NONE;
            carry_q       <= 0;
            carry_count_q <= 0;
            first_word_q  <= 0;
        end else if (valid_q) begin
            if (terminator_q != CONTINUE) begin
                kind_q       <= start_kind_q;
                first_word_q <= !suffix_count_q[1];
                case (suffix_count_q)
                    0: begin
                        carry_q       <= 0;
                        carry_count_q <= 2;
                    end
                    1: begin
                        carry_q       <= {suffix_q[7:0], 16'b0};
                        carry_count_q <= 3;
                    end
                    2: begin
                        carry_q       <= 0;
                        carry_count_q <= 0;
                    end
                    3: begin
                        carry_q       <= {16'b0, suffix_q[23:16]};
                        carry_count_q <= 1;
                    end
                endcase
            end else if (kind_q != NONE) begin
                carry_q       <= remainder;
                carry_count_q <= joined_count[1:0];
                if (joined_count[2]) first_word_q <= 0;
            end
        end
    end

    function automatic [31:0] crc32_advance(input [31:0] state, input integer bits);
        reg [31:0] crc;
        crc = state;
        for (integer bit_index = 0; bit_index < bits; bit_index = bit_index + 1)
        crc = (crc >> 1) ^ (crc[0] ? 32'hedb88320 : 0);
        return crc;
    endfunction
    function automatic [15:0] dllp_crc(input [31:0] body);
        reg [15:0] crc;
        crc = 16'hffff;
        for (integer bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
        crc = (crc >> 1) ^ ((crc[0] ^ body[bit_index]) ? 16'hd008 : 0);
        return ~crc;
    endfunction

    reg [31:0] crc_q, header_q, dllp_word_q;
    reg [15:0] first_field_q;
    // Number of words after the first two wire bytes, including the LCRC.
    reg [W+1:0] word_count_q;
    reg drop_q;
    wire body_word = event_word_valid && !event_first_word;
    wire tlp_word = body_word && event_kind == TLP;
    wire [15:0]
        first_field = event_word_valid && event_first_word ? event_word[31:16] : first_field_q;
    wire [31:0] word_crc = crc32_advance(crc_q ^ event_word, 32);
    wire [31:0] field_crc = crc32_advance(32'hffff_ffff ^ {16'b0, event_word[31:16]}, 16);
    wire [31:0] start_crc = crc32_advance(32'hffff_ffff ^ {16'b0, event_start_field}, 16);
    wire [31:0]
        frame_crc = tlp_word ? word_crc : event_word_valid && event_first_word ? field_crc : crc_q;
    wire [W+1:0] frame_words = word_count_q + (W + 2)'(body_word);
    wire [31:0] dllp_word = body_word ? event_word : dllp_word_q;

    reg [1:0] tlp_finish_q;
    reg dllp_finish_q, framing_error_q, framing_nak_q;
    reg [31:0] finish_crc_q;
    reg [23:0] finish_remainder_q;
    reg [ 1:0] finish_carry_count_q;
    reg [ W:0] finish_last_word_q;
    reg [ 1:0] finish_class_q;
    reg [ 8:0] finish_credits_q;
    reg [11:0] finish_sequence_q;
    reg [47:0] finish_dllp_q;
    reg finish_drop_q, finish_dllp_shape_q, finish_length_ok_q, finish_has_crc_q;
    reg [S-1:0] write_slot_q, read_slot_q;
    reg [S:0] occupied_q;
    reg [W-1:0] read_word_q;
    reg [11:0] expected_q;
    wire [9:0] payload = {header_q[17:16], header_q[31:24]};
    wire [5:0] expected_words = 6'd4 + {5'b0, header_q[5]} + {5'b0, header_q[23]} +
        (header_q[6] ? payload[5:0] : 6'd0);
    wire payload_valid = !header_q[6] || (payload != 0 && payload <= 32);
    // Feeding the final short word with zero fill advances a zero residue
    // to zero. The reflected 32-bit advance is invertible, so that is
    // equivalent to comparing the running state and the zero-filled word.
    wire good_null = tlp_finish_q == EDB && finish_has_crc_q &&
        finish_crc_q == {8'b0, finish_remainder_q};
    wire bad_tlp = tlp_finish_q != END || finish_crc_q != LCRC_RESIDUE ||
        finish_carry_count_q != 0 || !finish_length_ok_q;
    wire expected = finish_sequence_q == expected_q;
    wire [11:0] distance = expected_q - finish_sequence_q;
    wire commit = !reset && tlp_finish_q != CONTINUE && !bad_tlp && expected && !finish_drop_q;
    wire tlp_nak = tlp_finish_q != CONTINUE && !good_null &&
        (bad_tlp || (expected ? finish_drop_q : distance > 2048));
    wire dllp_ok = finish_dllp_shape_q && finish_dllp_q[47:32] == dllp_crc(finish_dllp_q[31:0]);
    wire
        queue_full = occupied_q == (S + 1)'(DEPTH) || (commit && occupied_q == (S + 1)'(DEPTH - 1));
    wire unused_header = ^{header_q[22:18], header_q[15:7]};

    // Only unowned candidate storage can be written; publication follows the
    // registered RAM write. A same-beat next frame may use the next slot.
    reg [31:0] memory[0:DEPTH*MAX_DWORDS-1];
    reg [W:0] lengths[0:DEPTH-1];
    reg [1:0] classes[0:DEPTH-1];
    reg [8:0] costs[0:DEPTH-1];
    reg ram_write_q;
    reg [W+S-1:0] ram_address_q;
    reg [31:0] ram_data_q, read_data_q;
    assign tlp_data_o = read_data_q;
    wire         accepted = tlp_valid_o && tlp_ready_i;
    wire         release_packet = accepted && tlp_last_o;
    wire [S-1:0] read_slot = read_slot_q + S'(release_packet);
    wire [W-1:0] read_word = release_packet ? {W{1'b0}} : read_word_q + W'(accepted);
    wire         can_read = !tlp_valid_o || tlp_ready_i;
    wire         read_available = occupied_q > (S + 1)'(release_packet);
    wire [S-1:0] candidate_slot = write_slot_q + S'(commit);
    always @(posedge clk) begin
        if (ram_write_q && !reset) memory[ram_address_q] <= ram_data_q;
        if (can_read) read_data_q <= memory[{read_slot, read_word}];
        ram_write_q <= !reset && tlp_word && !drop_q && !queue_full &&
            word_count_q < (W + 2)'(MAX_DWORDS);
        ram_address_q <= {candidate_slot, word_count_q[W-1:0]};
        ram_data_q <= event_word;
        if (commit) begin
            lengths[write_slot_q] <= finish_last_word_q;
            classes[write_slot_q] <= finish_class_q;
            costs[write_slot_q]   <= finish_credits_q;
        end
        tlp_finish_q <= reset || event_kind != TLP ? CONTINUE : event_end;
        dllp_finish_q <= !reset && event_kind == DLLP && event_end != CONTINUE;
        finish_crc_q <= frame_crc;
        finish_remainder_q <= event_remainder;
        finish_carry_count_q <= event_carry_count;
        finish_length_ok_q <= payload_valid && frame_words == (W + 2)'(expected_words);
        finish_has_crc_q <= frame_words != 0 || event_carry_count >= 2;
        finish_last_word_q <= (W + 1)'(frame_words) - (W + 1)'(2);
        finish_class_q <= header_q[4:0] == 5'h0a ?
            2'd2 : (header_q[4:0] == 0 && header_q[6] ? 2'd0 : 2'd1);
        finish_credits_q <= header_q[6] ? 9'(({1'b0, payload} + 11'd3) >> 2) : 9'd0;
        finish_sequence_q <= {first_field[3:0], first_field[15:8]};
        finish_drop_q <= drop_q || (tlp_word && queue_full);
        finish_dllp_q <= {dllp_word, first_field};
        finish_dllp_shape_q <= event_end == END && event_carry_count == 0 && frame_words == 1;
        framing_error_q <= !reset && event_error;
        framing_nak_q <= !reset && event_nak;
        if (event_start != NONE) begin
            word_count_q  <= 0;
            drop_q        <= queue_full;
            crc_q         <= event_start_field_valid ? start_crc : 32'hffff_ffff;
            first_field_q <= event_start_field;
        end else begin
            if (event_word_valid && event_first_word) first_field_q <= event_word[31:16];
            if (event_word_valid && event_kind == TLP) crc_q <= frame_crc;
            if (tlp_word && word_count_q == 0) header_q <= event_word;
            if (body_word && event_kind == DLLP) dllp_word_q <= event_word;
            if (body_word && word_count_q < (W + 2)'(MAX_DWORDS + 1)) word_count_q <= frame_words;
            if (tlp_word && (queue_full || word_count_q >= (W + 2)'(MAX_DWORDS))) drop_q <= 1;
        end

        response_o     <= 0;
        nak_o          <= 0;
        packet_error_o <= 0;
        dllp_o         <= 0;
        if (reset) begin
            occupied_q          <= 0;
            write_slot_q        <= 0;
            read_slot_q         <= 0;
            read_word_q         <= 0;
            expected_q          <= 0;
            response_sequence_o <= 12'hfff;
            tlp_valid_o         <= 0;
        end else begin
            if (can_read) begin
                tlp_valid_o   <= read_available;
                tlp_last_o    <= {1'b0, read_word} == lengths[read_slot];
                tlp_class_o   <= classes[read_slot];
                tlp_credits_o <= costs[read_slot];
            end
            if (accepted) begin
                read_slot_q <= read_slot;
                read_word_q <= read_word;
            end
            case ({
                commit, release_packet
            })
                2'b10:   occupied_q <= occupied_q + 1'b1;
                2'b01:   occupied_q <= occupied_q - 1'b1;
                default: ;
            endcase
            if (commit) begin
                write_slot_q <= write_slot_q + 1'b1;
                expected_q   <= expected_q + 1'b1;
            end
            response_o          <= framing_nak_q || (tlp_finish_q != CONTINUE && !good_null);
            nak_o               <= framing_nak_q || tlp_nak;
            response_sequence_o <= commit ? finish_sequence_q : expected_q - 1'b1;
            packet_error_o      <= framing_error_q || tlp_nak || (dllp_finish_q && !dllp_ok);
            dllp_o              <= dllp_finish_q && dllp_ok;
            if (dllp_finish_q) dllp_body_o <= finish_dllp_q[31:0];
        end
    end
    initial
        if (MAX_DWORDS < 36 || (MAX_DWORDS & (MAX_DWORDS - 1)) != 0 || DEPTH < 2 ||
            (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "Receiver geometry must use power-of-two slots/words and hold MPS128");
endmodule

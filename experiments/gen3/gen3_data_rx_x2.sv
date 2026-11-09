// SPDX-License-Identifier: Apache-2.0
// Gen3 x2 aggregate stream: eight consecutive descrambled bytes per cycle.
// Upstream must remove SKP and validate both lanes' block/ordered-set epochs.
// position_i identifies the eight-byte group in the 32-byte aggregate block.
// Byte-unrolled framing and CRC permit STP/body and finish/next-token overlap.
// Abort discards only a candidate; committed packets and sequence survive.
module gen3_data_rx_x2 #(
    parameter integer WORDS = 64,
                      SLOTS = 16
) (
    input wire clk, reset_i, start_stream_i, abort_i, valid_i,
    input wire [63:0] data_i,
    input wire [1:0] position_i,
    output reg active_o, eds_o,
    output wire [63:0] tlp_data_o,
    output wire [1:0] tlp_words_o,
    output wire tlp_valid_o, tlp_last_o,
    input wire tlp_ready_i,
    output wire [1:0] tlp_class_o,
    output wire [8:0] tlp_credits_o,
    output reg response_o, nak_o,
    output reg [11:0] response_sequence_o,
    output reg dllp_o,
    output reg [31:0] dllp_body_o,
    output reg error_o
);
    localparam W = $clog2(WORDS), S = $clog2(SLOTS);
    localparam [2:0] TOKEN = 0,
        TOKEN_BYTES = 1, DLLP_BYTES = 2, BODY = 3, AFTER = 4, NULL_BYTES = 5, IDLE_SECOND = 6;
    reg [2:0] state_q, state_n;
    reg [63:0] token_q, token_n;
    reg [3:0] token_count_q, token_count_n;
    reg [4:0] token_position_q, token_position_n;
    reg [12:0] remaining_q, remaining_n, bytes_q, bytes_n;
    reg [31:0] crc_q, crc_n, tail_q, tail_n, word_q, word_n, header_q, header_n;
    reg [11:0] sequence_q, sequence_n, expected_q, expected_n;
    reg drop_q, drop_n;
    reg [S-1:0] wr_q, wr_n, rd_q;
    reg [  W-1:0] rd_word_q;
    reg [    S:0] occupied_q;
    reg [   31:0] memory       [0:SLOTS*WORDS-1];
    reg [    W:0] lengths      [      0:SLOTS-1];
    reg [    1:0] classes      [      0:SLOTS-1];
    reg [    8:0] costs        [      0:SLOTS-1];
    reg [    1:0] store;
    reg [S+W-1:0] store_address[            0:1];
    reg [   31:0] store_data   [            0:1];
    reg commit, response, nak, dllp, err, framing, eds;
    reg [S-1:0] commit_slot;
    reg [  W:0] commit_words;
    reg [  1:0] commit_class;
    reg [  8:0] commit_cost;
    reg [ 11:0] response_sequence;
    reg [ 31:0] dllp_body;
    reg [  7:0] octet;
    reg [ 10:0] token_length;
    reg [  3:0] token_crc;
    integer index, writes;
    wire release_packet = tlp_valid_o && tlp_ready_i && tlp_last_o;
    assign tlp_valid_o = occupied_q != 0;
    assign tlp_last_o = {1'b0, rd_word_q} + 2 >= lengths[rd_q];
    assign tlp_words_o = tlp_last_o ? 2'(lengths[rd_q] - {1'b0, rd_word_q}) : 2'd2;
    assign tlp_data_o = {
        tlp_words_o == 2 ? memory[{rd_q, W'(rd_word_q+1'b1)}] : 32'b0, memory[{rd_q, rd_word_q}]
    };
    assign tlp_class_o = classes[rd_q];
    assign tlp_credits_o = costs[rd_q];
    function automatic [31:0] crc_byte(input [31:0] old, input [7:0] v);
        reg [31:0] c;
        begin
            c = old;
            for (integer k = 0; k < 8; k = k + 1) c = (c >> 1) ^ ((c[0] ^ v[k]) ? 32'hedb88320 : 0);
            crc_byte = c;
        end
    endfunction
    function automatic [15:0] crc16(input [31:0] v);
        reg [15:0] c;
        begin
            c = 16'hffff;
            for (integer k = 0; k < 32; k = k + 1) c = (c >> 1) ^ ((c[0] ^ v[k]) ? 16'hd008 : 0);
            crc16 = ~c;
        end
    endfunction
    function automatic [3:0] fcrc(input [10:0] v);
        fcrc = {^(v & 11'h1af), ^(v & 11'h35e), ^(v & 11'h6bc), ^(v & 11'h4d7)};
    endfunction
    // Called only after the complete declared body and nullification decision.
    task automatic finish_packet(input nullified);
        reg [10:0] payload;
        reg [12:0] expected_bytes;
        reg [11:0] distance;
        begin
            payload = {header_n[17:16], header_n[31:24]} == 0 ?
                11'd1024 : {1'b0, header_n[17:16], header_n[31:24]};
            expected_bytes = 13'd16 + {10'b0, header_n[5], 2'b0} + {10'b0, header_n[23], 2'b0} +
                (header_n[6] ? {payload, 2'b0} : 13'b0);
            distance = expected_n - sequence_n;
            if (nullified && tail_n == crc_n) begin
            end else if (nullified || tail_n != ~crc_n || bytes_n != expected_bytes ||
                         bytes_n < 16 || (header_n[6] && payload > 32)) begin
                response = 1;
                nak      = 1;
                err      = 1;
            end else if (sequence_n == expected_n) begin
                response = 1;
                if (drop_n) begin
                    nak = 1;
                    err = 1;
                end else begin
                    commit = 1;
                    commit_slot = wr_n;
                    commit_words = (W + 1)'((bytes_n - 13'd4) >> 2);
                    commit_class = header_n[4:0] == 5'h0a ?
                        2'd2 : ((header_n[4:0] == 0 && header_n[6]) ? 2'd0 : 2'd1);
                    commit_cost = header_n[6] ? 9'((payload + 11'd3) >> 2) : 9'd0;
                    response_sequence = sequence_n;
                    expected_n = expected_n + 1'b1;
                    wr_n = wr_n + 1'b1;
                end
            end else begin
                response = 1;
                if (distance > 2048) begin
                    nak = 1;
                    err = 1;
                end
            end
        end
    endtask
    always @* begin
        state_n           = state_q;
        token_n           = token_q;
        token_count_n     = token_count_q;
        token_position_n  = token_position_q;
        remaining_n       = remaining_q;
        bytes_n           = bytes_q;
        crc_n             = crc_q;
        tail_n            = tail_q;
        word_n            = word_q;
        header_n          = header_q;
        sequence_n        = sequence_q;
        expected_n        = expected_q;
        drop_n            = drop_q;
        wr_n              = wr_q;
        store             = 0;
        writes            = 0;
        index             = 0;
        commit            = 0;
        response          = 0;
        nak               = 0;
        dllp              = 0;
        err               = 0;
        framing           = 0;
        eds               = 0;
        commit_slot       = 0;
        commit_words      = 0;
        commit_class      = 0;
        commit_cost       = 0;
        response_sequence = expected_q - 1'b1;
        dllp_body         = 0;
        octet             = 0;
        token_length      = 0;
        token_crc         = 0;
        for (integer k = 0; k < 2; k = k + 1) begin
            store_address[k] = 0;
            store_data[k]    = 0;
        end
        for (integer b = 0; b < 8; b = b + 1) begin
            octet = data_i[8*b+:8];
            if (valid_i && active_o && !framing && !eds) begin
                if (state_n == AFTER) begin
                    if (octet == 8'hc0) begin
                        state_n       = NULL_BYTES;
                        token_count_n = 0;
                    end else begin
                        finish_packet(0);
                        state_n = TOKEN;
                    end
                end
                case (state_n)
                    TOKEN: begin
                        if (octet == 0) begin
                            if (b % 2 == 0) state_n = IDLE_SECOND;
                        end else if (octet == 8'hf0 || octet[3:0] == 4'hf) begin
                            token_n          = {56'b0, octet};
                            token_count_n    = 1;
                            token_position_n = {position_i, 3'b0} + 5'(b);
                            state_n          = octet == 8'hf0 ? DLLP_BYTES : TOKEN_BYTES;
                        end else framing = 1;
                    end
                    IDLE_SECOND: begin
                        if (octet != 0) framing = 1;
                        state_n = TOKEN;
                    end
                    TOKEN_BYTES: begin
                        token_n[8*token_count_n+:8] = octet;
                        token_count_n               = token_count_n + 1'b1;
                        if (token_count_n == 4) begin
                            if (token_n[31:0] == 32'h0090801f) begin
                                if (token_position_n != 28) framing = 1;
                                else eds = 1;
                                state_n = TOKEN;
                            end else begin
                                token_length = {token_n[14:8], token_n[7:4]};
                                token_crc    = fcrc(token_length);
                                if (token_length < 2 || token_length >= 1152 || token_n[23:20] !=
                                    token_crc || token_n[15] != ^{token_length, token_crc})
                                    framing = 1;
                                else begin
                                    state_n = BODY;
                                    remaining_n = ({2'b0, token_length} - 1'b1) << 2;
                                    sequence_n = {token_n[19:16], token_n[31:24]};
                                    crc_n = crc_byte(
                                        crc_byte(
                                            32'hffffffff, {4'b0, sequence_n[11:8]}
                                        ),
                                        sequence_n[7:0]
                                    );
                                    bytes_n = 0;
                                    tail_n = 0;
                                    word_n = 0;
                                    header_n = 0;
                                    drop_n = int'(occupied_q) + int'(commit) >= SLOTS ||
                                        int'(token_length) > WORDS + 2;
                                end
                            end
                        end
                    end
                    DLLP_BYTES: begin
                        token_n[8*token_count_n+:8] = octet;
                        token_count_n               = token_count_n + 1'b1;
                        if (token_count_n == 8) begin
                            state_n = TOKEN;
                            if (token_n[15:8] != 8'hac) framing = 1;
                            else if (token_n[63:48] != crc16(token_n[47:16])) err = 1;
                            else begin
                                dllp      = 1;
                                dllp_body = token_n[47:16];
                            end
                        end
                    end
                    BODY: begin
                        if (bytes_n >= 4) begin
                            crc_n                  = crc_byte(crc_n, tail_n[7:0]);
                            index                  = int'(bytes_n) - 4;
                            word_n[8*(index%4)+:8] = tail_n[7:0];
                            if (index % 4 == 3) begin
                                if (index == 3) header_n = word_n;
                                if (index < WORDS * 4 && !drop_n) begin
                                    store[writes]         = 1;
                                    store_address[writes] = {wr_n, W'(index / 4)};
                                    store_data[writes]    = word_n;
                                    writes                = writes + 1;
                                end else drop_n = 1;
                            end
                        end
                        tail_n      = {octet, tail_n[31:8]};
                        bytes_n     = bytes_n + 1'b1;
                        remaining_n = remaining_n - 1'b1;
                        if (remaining_n == 0) state_n = AFTER;
                    end
                    NULL_BYTES: begin
                        if (octet != 8'hc0) framing = 1;
                        token_count_n = token_count_n + 1'b1;
                        if (token_count_n == 4 && !framing) begin
                            finish_packet(1);
                            state_n = TOKEN;
                        end
                    end
                    default: framing = 1;
                endcase
            end
        end
    end
    always @(posedge clk) begin
        if (!reset_i && !abort_i && !start_stream_i) begin
            for (integer k = 0; k < 2; k = k + 1)
            if (store[k]) memory[store_address[k]] <= store_data[k];
            if (commit) begin
                lengths[commit_slot] <= commit_words;
                classes[commit_slot] <= commit_class;
                costs[commit_slot]   <= commit_cost;
            end
        end
        response_o <= 0;
        nak_o      <= 0;
        dllp_o     <= 0;
        error_o    <= 0;
        eds_o      <= 0;
        if (reset_i) begin
            active_o         <= 0;
            state_q          <= TOKEN;
            occupied_q       <= 0;
            wr_q             <= 0;
            rd_q             <= 0;
            rd_word_q        <= 0;
            expected_q       <= 0;
            token_count_q    <= 0;
            token_position_q <= 0;
            remaining_q      <= 0;
            bytes_q          <= 0;
            drop_q           <= 0;
        end else begin
            if (release_packet) begin
                rd_q      <= rd_q + 1'b1;
                rd_word_q <= 0;
            end else if (tlp_valid_o && tlp_ready_i) rd_word_q <= rd_word_q + 2;
            case ({
                !abort_i && !start_stream_i && commit, release_packet
            })
                2'b10:   occupied_q <= occupied_q + 1'b1;
                2'b01:   occupied_q <= occupied_q - 1'b1;
                default: ;
            endcase
            if (abort_i || start_stream_i) begin
                active_o      <= start_stream_i && !abort_i;
                state_q       <= TOKEN;
                token_count_q <= 0;
            end else begin
                state_q             <= state_n;
                token_q             <= token_n;
                token_count_q       <= token_count_n;
                token_position_q    <= token_position_n;
                remaining_q         <= remaining_n;
                bytes_q             <= bytes_n;
                crc_q               <= crc_n;
                tail_q              <= tail_n;
                word_q              <= word_n;
                header_q            <= header_n;
                sequence_q          <= sequence_n;
                expected_q          <= expected_n;
                drop_q              <= drop_n;
                wr_q                <= wr_n;
                response_o          <= response;
                nak_o               <= nak;
                response_sequence_o <= response_sequence;
                dllp_o              <= dllp;
                dllp_body_o         <= dllp_body;
                error_o             <= err || framing;
                eds_o               <= eds;
                if (framing || eds) active_o <= 0;
            end
        end
    end
    initial
        if (WORDS < 36 || (WORDS & (WORDS - 1)) != 0 || SLOTS < 2 || (SLOTS & (SLOTS - 1)) != 0)
            $fatal(1, "Invalid x2 receive geometry");
endmodule

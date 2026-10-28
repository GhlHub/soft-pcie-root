// Non-backpressured decoded-symbol receiver, Gen1/Gen2 x1, MPS128. Commits only
// complete, in-order, CRC-valid packets. Sixteen independent ownership slots (4 KiB packet storage).
module pcie_soft_packet_rx #(
    parameter integer MAX_DWORDS = 64,
                      DEPTH      = 16
) (
    input wire clk, rst_n, link_reset_i,
    input wire [15:0] symbols_i,
    input wire [1:0] control_i,
    input wire valid_i, error_i,
    output wire [31:0] tlp_data_o,
    output wire tlp_valid_o, tlp_last_o,
    input wire tlp_ready_i,
    output wire [1:0] tlp_class_o,
    output wire [8:0] tlp_credits_o,
    output reg response_o, nak_o,
    output reg [11:0] response_sequence_o,
    output reg dllp_o,
    output reg [31:0] dllp_body_o,
    output reg packet_error_o
);
    localparam integer S = $clog2(DEPTH), W = $clog2(MAX_DWORDS), BC = $clog2(MAX_DWORDS * 4 + 8);
    (* ram_style="distributed" *)reg [31:0] memory [0:DEPTH*MAX_DWORDS-1];
    reg [ W:0] lengths[           0:DEPTH-1];
    reg [ 1:0] classes[           0:DEPTH-1];
    reg [ 8:0] costs  [           0:DEPTH-1];
    reg [S-1:0] write_slot_q, read_slot_q;
    reg [  S:0] occupied_q;
    reg [W-1:0] read_word_q;
    reg [1:0] mode_q, mode_n;
    reg [BC-1:0] body_q, body_n;
    reg [31:0] tail_q, tail_n, crc_q, crc_n, word_q, word_n, header_q, header_n;
    reg [15:0] crc16_q, crc16_n;
    reg [11:0] sequence_q, sequence_n, expected_q, expected_n;
    reg drop_q, drop_n;
    reg write_word, commit_packet, emit_response, emit_nak, emit_dllp, emit_error;
    reg [31:0] write_data, dllp_body;
    reg [W-1:0] write_index;
    reg [  W:0] commit_words;
    reg [  1:0] commit_class;
    reg [  8:0] commit_cost;
    reg [11:0] response_sequence, distance;
    reg [7:0] octet, older;
    wire [10:0] declared_words = {header_q[17:16], header_q[31:24]} == 0 ?
        11'd1024 : {1'b0, header_q[17:16], header_q[31:24]};
    wire [12:0] expected_bytes = 13'd18 + {10'b0, header_q[5], 2'b0} + {10'b0, header_q[23], 2'b0} +
        (header_q[6] ? {declared_words, 2'b0} : 13'b0);
    reg k;
    integer j;
    reg [BC-1:0] payload_index;
    function automatic [31:0] crc32_byte(input [31:0] old, input [7:0] value);
        reg [31:0] c;
        begin
            c = old;
            for (integer b = 0; b < 8; b = b + 1)
            c = (c >> 1) ^ ((c[0] ^ value[b]) ? 32'hedb88320 : 0);
            crc32_byte = c;
        end
    endfunction
    function automatic [15:0] crc16_byte(input [15:0] old, input [7:0] value);
        reg [15:0] c;
        begin
            c = old;
            for (integer b = 0; b < 8; b = b + 1) c = (c >> 1) ^ ((c[0] ^ value[b]) ? 16'hd008 : 0);
            crc16_byte = c;
        end
    endfunction
    assign tlp_valid_o   = occupied_q != 0;
    assign tlp_data_o    = memory[{read_slot_q, read_word_q}];
    assign tlp_last_o    = {1'b0, read_word_q} == lengths[read_slot_q] - 1'b1;
    assign tlp_class_o   = classes[read_slot_q];
    assign tlp_credits_o = costs[read_slot_q];
    wire release_packet = tlp_valid_o && tlp_ready_i && tlp_last_o;
    always @* begin
        mode_n = mode_q;
        body_n = body_q;
        tail_n = tail_q;
        crc_n = crc_q;
        crc16_n = crc16_q;
        word_n = word_q;
        header_n = header_q;
        sequence_n = sequence_q;
        expected_n = expected_q;
        drop_n = drop_q;
        write_word = 0;
        commit_packet = 0;
        emit_response = 0;
        emit_nak = 0;
        emit_dllp = 0;
        emit_error = 0;
        write_data = 0;
        write_index = 0;
        commit_words = 0;
        response_sequence = expected_q - 1'b1;
        dllp_body = 0;
        // Header is complete several cycles before a minimally valid END. Use
        // the registered header rather than cascading its two-symbol update into
        // the END validator. Metadata RAM inputs need not be zero when WE is low.
        commit_class = header_q[4:0] == 5'h0a ?
            2'd2 : ((header_q[4:0] == 0 && header_q[6]) ? 2'd0 : 2'd1);
        commit_cost = header_q[6] ? 9'((declared_words + 11'd3) >> 2) : 9'b0;
        octet = 0;
        older = 0;
        k = 0;
        distance = 0;
        payload_index = 0;
        for (j = 0; j < 2; j = j + 1) begin
            octet = symbols_i[j*8+:8];
            k     = control_i[j];
            if (valid_i) begin
                if (error_i) begin
                    if (mode_n == 1) begin
                        emit_response = 1;
                        emit_nak      = 1;
                    end
                    mode_n     = 0;
                    emit_error = 1;
                end else if (k && (octet == 8'hfb || octet == 8'h5c)) begin
                    if (mode_n != 0) begin
                        emit_error = 1;
                        if (mode_n == 1) begin
                            emit_response = 1;
                            emit_nak      = 1;
                        end
                    end
                    mode_n     = octet == 8'hfb ? 1 : 2;
                    body_n     = 0;
                    tail_n     = 0;
                    crc_n      = 32'hffffffff;
                    crc16_n    = 16'hffff;
                    drop_n     = occupied_q == (S + 1)'(DEPTH);
                    word_n     = 0;
                    header_n   = 0;
                    sequence_n = 0;
                end else if (k && (octet == 8'hfd || octet == 8'hfe)) begin
                    if (mode_n == 1) begin
                        if (octet == 8'hfe &&
                            tail_n == crc_n) begin  /* valid nullified TLP: no ACK/NAK */
                        end else
                            if (octet != 8'hfd || tail_n != ~crc_n || body_n < 18 || 13'(body_n) !=
                                expected_bytes || (header_q[6] && declared_words > 32)) begin
                            emit_response = 1;
                            emit_nak      = 1;
                            emit_error    = 1;
                        end else if (sequence_n == expected_n) begin
                            if (drop_n) begin
                                emit_response = 1;
                                emit_nak      = 1;
                                emit_error    = 1;
                            end else begin
                                commit_packet     = 1;
                                commit_words      = (W + 1)'(body_n >> 2) - 1'b1;
                                emit_response     = 1;
                                emit_nak          = 0;
                                response_sequence = expected_n;
                                expected_n        = expected_n + 1'b1;
                            end
                        end else begin
                            distance      = expected_n - sequence_n;
                            emit_response = 1;
                            if (distance > 2048) begin
                                emit_nak   = 1;
                                emit_error = 1;
                            end
                        end
                    end else if (mode_n == 2) begin
                        if (octet == 8'hfd && body_n == 6 && tail_n[31:16] == ~crc16_n) begin
                            emit_dllp = 1;
                            dllp_body = word_n;
                        end else emit_error = 1;
                    end
                    mode_n = 0;
                end else if (k) begin
                    // Ordered sets/idle K codes outside frames are handled by the PHY layer.
                    if (mode_n != 0) begin
                        if (mode_n == 1) begin
                            emit_response = 1;
                            emit_nak      = 1;
                        end
                        mode_n     = 0;
                        emit_error = 1;
                    end
                end else if (mode_n != 0) begin
                    if (mode_n == 1) begin
                        if (body_n == 0) sequence_n[11:8] = octet[3:0];
                        if (body_n == 1) sequence_n[7:0] = octet;
                        if (body_n >= 4) begin
                            older = tail_n[7:0];
                            crc_n = crc32_byte(crc_n, older);
                            if (body_n >= 6) begin
                                payload_index                     = body_n - BC'(6);
                                word_n[8*(payload_index[1:0])+:8] = older;
                                if (payload_index[1:0] == 3) begin
                                    if (payload_index < BC'(MAX_DWORDS * 4)) begin
                                        write_word  = 1;
                                        write_index = payload_index[W+1:2];
                                        write_data  = word_n;
                                        if (payload_index == 3) header_n = word_n;
                                    end else drop_n = 1;
                                end
                            end
                        end
                    end else if (body_n < 4) begin
                        word_n[body_n*8+:8] = octet;
                        crc16_n             = crc16_byte(crc16_n, octet);
                    end
                    tail_n = {octet, tail_n[31:8]};
                    if (body_n != {BC{1'b1}}) body_n = body_n + 1'b1;
                    else drop_n = 1;
                end
            end
        end
    end
    always @(posedge clk) begin
        if (write_word && !drop_n && rst_n && !link_reset_i)
            memory[{write_slot_q, write_index}] <= write_data;
        if (commit_packet && rst_n && !link_reset_i) begin
            lengths[write_slot_q] <= commit_words;
            classes[write_slot_q] <= commit_class;
            costs[write_slot_q]   <= commit_cost;
        end
        if (!rst_n || link_reset_i) begin
            mode_q              <= 0;
            body_q              <= 0;
            tail_q              <= 0;
            crc_q               <= 0;
            crc16_q             <= 0;
            word_q              <= 0;
            header_q            <= 0;
            sequence_q          <= 0;
            expected_q          <= 0;
            drop_q              <= 0;
            write_slot_q        <= 0;
            read_slot_q         <= 0;
            read_word_q         <= 0;
            occupied_q          <= 0;
            response_o          <= 0;
            nak_o               <= 0;
            response_sequence_o <= 12'hfff;
            dllp_o              <= 0;
            dllp_body_o         <= 0;
            packet_error_o      <= 0;
        end else begin
            mode_q              <= mode_n;
            body_q              <= body_n;
            tail_q              <= tail_n;
            crc_q               <= crc_n;
            crc16_q             <= crc16_n;
            word_q              <= word_n;
            header_q            <= header_n;
            sequence_q          <= sequence_n;
            expected_q          <= expected_n;
            drop_q              <= drop_n;
            response_o          <= emit_response;
            nak_o               <= emit_nak;
            response_sequence_o <= response_sequence;
            dllp_o              <= emit_dllp;
            dllp_body_o         <= dllp_body;
            packet_error_o      <= emit_error;
            occupied_q          <= occupied_q + (S + 1)'(commit_packet) - (S + 1)'(release_packet);
            if (commit_packet) write_slot_q <= write_slot_q + 1'b1;
            if (tlp_valid_o && tlp_ready_i) begin
                if (tlp_last_o) begin
                    read_slot_q <= read_slot_q + 1'b1;
                    read_word_q <= 0;
                end else read_word_q <= read_word_q + 1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    initial
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0 || MAX_DWORDS < 36 ||
            (MAX_DWORDS & (MAX_DWORDS - 1)) != 0)
            $fatal(1, "Receiver geometry must use power-of-two slots/words and hold MPS128");
`endif
endmodule

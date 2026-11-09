// SPDX-License-Identifier: Apache-2.0
// Gen3 x2 aggregate stream: eight consecutive descrambled bytes per cycle.
// Upstream must remove SKP and validate both lanes' block/ordered-set epochs.
// position_i identifies the eight-byte group in the 32-byte aggregate block.
// Buffered token decoder, registered packet events and single-port 64-bit RAM.
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
    localparam W = $clog2(WORDS), S = $clog2(SLOTS);
    localparam [1:0] TOKEN = 0, BODY = 1, AFTER = 2;
    reg [1:0] mode_q, mode_n, ingress_wr;
    reg [ 4:0] ingress_rd;
    reg [ 5:0] count_q;
    reg [63:0] ingress    [0:3];
    reg [ 1:0] positions  [0:3];
    // Classify each halfword at ingress, before the cursor/token feedback path.
    reg [ 7:0] metadata   [0:3];
    reg [12:0] remaining_q, remaining_n;
    wire [1:0] row0 = ingress_rd[4:3], row1 = row0 + 2'd1, row2 = row0 + 2'd2, row3 = row0 + 2'd3;
    wire [255:0] window = {ingress[row3], ingress[row2], ingress[row1], ingress[row0]} >>
        (8 * ingress_rd[2:0]);
    reg [3:0] prefix;
    reg bad_idle;
    reg [95:0] aligned;
    wire [31:0] meta_window = {metadata[row3], metadata[row2], metadata[row1], metadata[row0]} >>
        (2 * ingress_rd[2:1]);
    wire null_prefix = mode_q == AFTER && meta_window[1];
    wire [7:0] scan = null_prefix ? meta_window[11:4] : meta_window[7:0];
    wire [4:0] token_pointer = ingress_rd + 5'(prefix);
    wire [1:0] token_row0 = token_pointer[4:3], token_row1 = token_row0 + 2'd1,
        token_row2 = token_row0 + 2'd2;
    wire [191:0] token_window = {ingress[token_row2], ingress[token_row1], ingress[token_row0]} >>
        (8 * token_pointer[2:0]);
    reg [15:0] previous_input;
    // Metadata: [64:63] initial body last/two-word flags, [62:57] token
    // classification/validation, [56:25] CRC seed, [24:13] sequence,
    // [12:0] declared body bytes. Control never reduces the length bus.
    wire [64:0] token_info[0:3];
    // Three positions are wholly in this input beat. Position 6 straddles
    // beats and is filled on the next valid input, before four bytes can be
    // consumed there. Metadata and payload share the same circular epoch.
    for (genvar lane = 0; lane < 4; lane = lane + 1) begin : predecode
        wire [31:0] raw_token;
        if (lane == 3) begin : cross_beat
            assign raw_token = {data_i[15:0], previous_input};
        end else begin : in_beat
            assign raw_token = data_i[16*lane+:32];
        end
        wire [10:0] len = {raw_token[14:8], raw_token[7:4]};
        wire [3:0] check_crc = fcrc(len);
        wire [31:0] seed = crc_byte(
            crc_byte(32'hffffffff, {4'b0, raw_token[19:16]}), raw_token[31:24]
        );
        reg [64:0] info[0:3];
        always @(posedge clk)
            if (active_o && valid_i && !reset_i && !abort_i && !start_stream_i)
                info[lane == 3 ? ingress_wr - 2'd1 : ingress_wr] <= {
                    len <= 3,
                    len >= 3,
                    raw_token[7:0] == 0,
                    raw_token[3:0] == 4'hf,
                    raw_token[15:8] == 8'hac,
                    raw_token[7:0] == 8'hf0,
                    raw_token == 32'h0090801f,
                    len >= 2 && len < 1152 && raw_token[23:20] == check_crc &&
                        raw_token[15] == ^{len, check_crc},
                    seed,
                    {raw_token[19:16], raw_token[31:24]},
                    ({2'b0, len} - 13'd1) << 2
                };
        assign token_info[lane] = info[token_pointer[4:3]];
    end
    wire [64:0] decoded = token_info[token_pointer[2:1]];
    reg  [12:0] body_length;
    reg  [ 5:0] consumed;
    reg framing, eds, start, body_valid, body_last, finish, nullified, dllp;
    reg [63:0] body_data;
    reg        body_two;
    // Registered event boundary: no token decode in the CRC or RAM write path.
    reg ev_start, ev_body, ev_last, ev_two, ev_finish, ev_null, ev_dllp;
    reg [63:0] ev_data;
    reg [47:0] ev_dllp_data;
    reg [11:0] ev_sequence;
    reg [12:0] ev_length;
    reg [31:0] ev_seed;

    always @* begin
        prefix = 0;
        if (scan[0]) prefix = 2;
        if (scan[0] && scan[2]) prefix = 4;
        if (scan[0] && scan[2] && scan[4]) prefix = 6;
        if (scan[0] && scan[2] && scan[4] && scan[6]) prefix = 8;
        prefix = prefix + (null_prefix ? 4'd4 : 4'd0);
    end
    always @* begin
        aligned     = token_window[95:0];
        bad_idle    = decoded[62];
        body_length = decoded[12:0];
        mode_n      = mode_q;
        remaining_n = remaining_q;
        consumed    = 0;
        framing     = 0;
        eds         = 0;
        start       = 0;
        body_valid  = 0;
        body_last   = 0;
        finish      = 0;
        nullified   = 0;
        dllp        = 0;
        body_data   = 0;
        body_two    = 0;
        if (active_o && count_q >= 4) begin
            if (mode_q == BODY && (remaining_q <= 4 || count_q >= 8)) begin
                body_valid  = 1;
                body_data   = window[63:0];
                body_two    = remaining_q >= 8;
                body_last   = remaining_q <= 8;
                consumed    = body_two ? 6'd8 : 6'd4;
                remaining_n = remaining_q - 13'(consumed);
                if (body_last) mode_n = AFTER;
            end else if (mode_q != BODY) begin
                if (mode_q == AFTER) begin
                    finish = 1;
                    mode_n = TOKEN;
                end
                if (null_prefix) begin
                    nullified = 1;
                    consumed  = 4;
                    if (window[31:0] != 32'hc0c0c0c0) begin
                        framing = 1;
                        finish  = 0;
                    end
                end
                if (6'(prefix) >= count_q) consumed = count_q;
                else if (prefix == (null_prefix ? 12 : 8)) consumed = 6'(prefix);
                else
                if (count_q < 6'(prefix) + 4) begin
                end else if (bad_idle) framing = 1;
                else if (decoded[59]) begin
                    if (count_q >= 6'(prefix) + 8) begin
                        consumed = 6'(prefix) + 8;
                        if (!decoded[60]) framing = 1;
                        else dllp = 1;
                    end
                end else if (decoded[61]) begin
                    if (count_q >= 6'(prefix) + 4) begin
                        if (decoded[58]) begin
                            consumed = 6'(prefix) + 4;
                            if (token_pointer[2:0] != 4 || positions[token_pointer[4:3]] != 3)
                                framing = 1;
                            else eds = 1;
                        end else if (!decoded[57]) framing = 1;
                        else if (count_q >= 6'(prefix) + (decoded[63] ? 6'd12 : 6'd8)) begin
                            start       = 1;
                            body_valid  = 1;
                            body_two    = decoded[63];
                            body_last   = decoded[64];
                            body_data   = aligned[95:32];
                            consumed    = 6'(prefix) + (body_two ? 6'd12 : 6'd8);
                            remaining_n = body_length - (body_two ? 13'd8 : 13'd4);
                            mode_n      = body_last ? AFTER : BODY;
                        end
                    end
                end else framing = 1;
            end
        end
        // Arrival is eight bytes; all cursors/occupancies are even. Keep
        // overflow detection off a wide add/subtract/compare feedback chain.
        if (active_o) begin
            if (count_q > 32) framing = 1;
            if (valid_i)
                case (count_q)
                    6'd26:   if (consumed < 2) framing = 1;
                    6'd28:   if (consumed < 4) framing = 1;
                    6'd30:   if (consumed < 6) framing = 1;
                    6'd32:   if (consumed < 8) framing = 1;
                    default: ;
                endcase
        end
    end

    always @(posedge clk) begin
        // Ingress payload and metadata are deliberately unreset.
        if (active_o && valid_i && !reset_i && !abort_i && !start_stream_i) begin
            ingress[ingress_wr]   <= data_i;
            positions[ingress_wr] <= position_i;
            previous_input        <= data_i[63:48];
            for (integer k = 0; k < 4; k = k + 1)
            metadata[ingress_wr][2*k+:2] <= {data_i[16*k+:8] == 8'hc0, data_i[16*k+:16] == 0};
        end
        ev_data      <= body_data;
        ev_sequence  <= decoded[24:13];
        ev_length    <= body_length;
        ev_seed      <= decoded[56:25];
        ev_dllp_data <= aligned[63:16];
        if (reset_i || abort_i || start_stream_i) begin
            active_o    <= !reset_i && !abort_i && start_stream_i;
            ingress_wr  <= 0;
            ingress_rd  <= 0;
            count_q     <= 0;
            mode_q      <= TOKEN;
            remaining_q <= 0;
            ev_start    <= 0;
            ev_body     <= 0;
            ev_last     <= 0;
            ev_two      <= 0;
            ev_finish   <= 0;
            ev_null     <= 0;
            ev_dllp     <= 0;
            eds_o       <= 0;
        end else begin
            ev_start  <= start && !framing;
            ev_body   <= body_valid && !framing;
            ev_last   <= body_last;
            ev_two    <= body_two;
            ev_finish <= finish;
            ev_null   <= nullified;
            ev_dllp   <= dllp && !framing;
            eds_o     <= eds && !framing;
            if (active_o) begin
                if (valid_i) ingress_wr <= ingress_wr + 1'b1;
                ingress_rd  <= {ingress_rd[4:1] + consumed[4:1], 1'b0};
                count_q     <= count_q + (valid_i ? 6'd8 : 6'd0) - consumed;
                mode_q      <= mode_n;
                remaining_q <= remaining_n;
                if (framing || eds) active_o <= 0;
            end
        end
    end

    reg [31:0] crc_q, tail_q;
    wire unused_metadata = ^{aligned[15:0], window[255:64], scan[7], scan[5], scan[3], scan[1],
                             meta_window[31:12], token_window[191:96]};
    reg [31:0] header_q;
    wire unused_header = ^{header_q[22:18], header_q[15:7]};
    reg [12:0] packet_length_q;
    reg [11:0] sequence_q, expected_q;
    reg       drop_q;
    reg [W:0] written_q;
    reg [S-1:0] wr_q, rd_q;
    reg [  W-2:0] rd_beat_q;
    reg [    S:0] occupied_q;
    reg [    W:0] lengths     [          0:SLOTS-1];
    reg [    1:0] classes     [          0:SLOTS-1];
    reg [    8:0] costs       [          0:SLOTS-1];
    // One write and one synchronous read: no reset on payload RAM.
    reg [   63:0] memory      [0:SLOTS*(WORDS/2)-1];
    reg           ram_write;
    reg [S+W-2:0] ram_address;
    reg [63:0] ram_data, read_data;
    reg out_valid, out_last;
    reg [1:0] out_words, out_class;
    reg [8:0] out_cost;
    assign tlp_valid_o   = out_valid;
    assign tlp_last_o    = out_last;
    assign tlp_words_o   = out_words;
    assign tlp_data_o    = {out_words == 2 ? read_data[63:32] : 32'b0, read_data[31:0]};
    assign tlp_class_o   = out_class;
    assign tlp_credits_o = out_cost;
    wire accepted = out_valid && tlp_ready_i;
    wire release_packet = accepted && out_last;
    wire [S-1:0] read_slot = rd_q + S'(release_packet);
    wire [W-2:0] read_beat = release_packet ? {(W - 1) {1'b0}} : rd_beat_q + (W - 1)'(accepted);
    wire can_read = !out_valid || tlp_ready_i;
    wire read_available = occupied_q > (release_packet ? 1 : 0);
    wire [W:0] read_words = lengths[read_slot] - {read_beat, 1'b0};

    wire [10:0] payload = {header_q[17:16], header_q[31:24]} == 0 ?
        11'd1024 : {1'b0, header_q[17:16], header_q[31:24]};
    wire [12:0] expected_bytes = 13'd16 + {10'b0, header_q[5], 2'b0} + {10'b0, header_q[23], 2'b0} +
        (header_q[6] ? {payload, 2'b0} : 13'b0);
    wire [11:0] distance = expected_q - sequence_q;
    wire good_null = ev_null && tail_q == crc_q;
    wire bad_packet = ev_null || tail_q != ~crc_q || packet_length_q != expected_bytes ||
        packet_length_q < 16 || (header_q[6] && payload > 32);
    wire live = !reset_i && !abort_i && !start_stream_i;
    wire commit = live && ev_finish && !good_null && !bad_packet && sequence_q == expected_q &&
        !drop_q;
    wire [S-1:0] candidate_slot = wr_q + S'(commit);
    wire [31:0] crc_base = ev_start ? ev_seed : crc_q;
    wire [W:0] write_index = ev_start ? {(W + 1) {1'b0}} : written_q;
    wire [1:0] payload_words = ev_last ? (ev_two ? 2'd1 : 2'd0) : (ev_two ? 2'd2 : 2'd1);
    wire [31:0] crc_one = crc_byte(
        crc_byte(
            crc_byte(crc_byte(crc_base, ev_data[7:0]), ev_data[15:8]), ev_data[23:16]
        ),
        ev_data[31:24]
    );
    wire [31:0] crc_two = crc_byte(
        crc_byte(
            crc_byte(crc_byte(crc_one, ev_data[39:32]), ev_data[47:40]), ev_data[55:48]
        ),
        ev_data[63:56]
    );

    always @(posedge clk) begin
        if (ram_write && !reset_i) memory[ram_address] <= ram_data;
        if (can_read) read_data <= memory[{read_slot, read_beat}];
        ram_write <= live && ev_body && payload_words != 0 && write_index < (W + 1)'(WORDS) &&
            (ev_start ? (occupied_q + {{(S) {1'b0}}, commit} < (S + 1)'(SLOTS) &&
                         ev_length <= 13'(WORDS >= 2048 ? 8191 : WORDS * 4 + 4)) : !drop_q);
        ram_address <= {candidate_slot, write_index[W-1:1]};
        ram_data <= ev_data;
        if (commit) begin
            lengths[wr_q] <= written_q;
            classes[wr_q] <= header_q[4:0] == 5'h0a ?
                2'd2 : ((header_q[4:0] == 0 && header_q[6]) ? 2'd0 : 2'd1);
            costs[wr_q] <= header_q[6] ? 9'((payload + 11'd3) >> 2) : 9'd0;
        end
        response_o <= 0;
        nak_o      <= 0;
        dllp_o     <= 0;
        error_o    <= 0;
        if (reset_i) begin
            occupied_q <= 0;
            wr_q       <= 0;
            rd_q       <= 0;
            rd_beat_q  <= 0;
            expected_q <= 0;
            out_valid  <= 0;
            drop_q     <= 0;
            written_q  <= 0;
            ram_write  <= 0;
        end else begin
            if (can_read) begin
                out_valid <= read_available;
                out_words <= read_words > 1 ? 2'd2 : 2'd1;
                out_last  <= read_words <= 2;
                out_class <= classes[read_slot];
                out_cost  <= costs[read_slot];
            end
            if (accepted) begin
                rd_q      <= read_slot;
                rd_beat_q <= read_beat;
            end
            case ({
                commit, release_packet
            })
                2'b10:   occupied_q <= occupied_q + 1'b1;
                2'b01:   occupied_q <= occupied_q - 1'b1;
                default: ;
            endcase
            if (live) begin
                error_o <= framing;
                if (ev_dllp) begin
                    if (ev_dllp_data[47:32] != crc16(ev_dllp_data[31:0])) error_o <= 1;
                    else begin
                        dllp_o      <= 1;
                        dllp_body_o <= ev_dllp_data[31:0];
                    end
                end
                if (ev_finish && !good_null) begin
                    response_o          <= 1;
                    response_sequence_o <= expected_q - 1'b1;
                    if (bad_packet || (sequence_q == expected_q && drop_q) ||
                        (sequence_q != expected_q && distance > 2048)) begin
                        nak_o   <= 1;
                        error_o <= 1;
                    end else if (commit) begin
                        expected_q          <= expected_q + 1'b1;
                        response_sequence_o <= sequence_q;
                        wr_q                <= wr_q + 1'b1;
                    end
                end
                if (ev_body) begin
                    if (payload_words == 2) crc_q <= crc_two;
                    else if (payload_words == 1) crc_q <= crc_one;
                    else crc_q <= crc_base;
                    written_q <= write_index + (W + 1)'(payload_words);
                    if (ev_last) tail_q <= ev_two ? ev_data[63:32] : ev_data[31:0];
                    if (ev_start) begin
                        header_q <= ev_data[31:0];
                        sequence_q <= ev_sequence;
                        packet_length_q <= ev_length;
                        drop_q <= occupied_q + {{(S) {1'b0}}, commit} >= (S + 1)'(SLOTS) ||
                            ev_length > 13'(WORDS >= 2048 ? 8191 : WORDS * 4 + 4);
                    end
                end
            end
        end
    end
    initial
        if (WORDS < 36 || (WORDS & (WORDS - 1)) != 0 || SLOTS < 2 || (SLOTS & (SLOTS - 1)) != 0)
            $fatal(1, "Invalid x2 receive geometry");
endmodule

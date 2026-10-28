// SPDX-License-Identifier: Apache-2.0
// Native 32-bit PCS boundary. Packet bytes remain provisional downstream.
// Local disable/error aborts only a candidate; committed packets are not reset.
module gen3_native_rx (
    input wire clk, reset_i, enable_i,
    input wire [31:0] data_i,
    input wire valid_i, start_i,
    input wire [1:0] header_i,
    input wire eds_i, parser_error_i,
    output reg aligned_o, ts_event_o, ts1_valid_o, ts2_valid_o,
    output reg [1:0] ec_o,
    output reg [5:0] fs_o, lf_o,
    output reg [31:0] symbols6_9_o,
    output reg error_o, eios_o,
    output reg [127:0] last_ts_o,
    output reg stream_start_o, data_valid_o,
    output reg [31:0] data_o,
    output reg [1:0] position_o,
    output wire stream_o
);
    // Classify each incoming DWORD ahead of the descrambler. Payload and
    // sidebands advance together; valid is synchronously flushed on disable.
    // Parser feedback stays at the consumer stage, relative to decoded output.
    reg [31:0] rx_data;
    reg rx_valid, rx_start, rx_bad_header, rx_data_header, rx_skip_header;
    reg rx_ts1, rx_ts2, rx_eieos, rx_sds, rx_eios;
    reg rx_eieos_word, rx_sds_first, rx_sds_word, rx_eios_word;
    always @(posedge clk) begin
        if (reset_i || !enable_i) rx_valid <= 0;
        else rx_valid <= valid_i;
        rx_data        <= data_i;
        rx_start       <= start_i;
        rx_bad_header  <= header_i != 1 && header_i != 2;
        rx_data_header <= header_i == 2;
        rx_skip_header <= header_i == 1 && data_i[7:0] == 8'haa;
        rx_ts1         <= data_i[7:0] == 8'h1e;
        rx_ts2         <= data_i[7:0] == 8'h2d;
        rx_eieos       <= data_i[7:0] == 0;
        rx_sds         <= data_i[7:0] == 8'he1;
        rx_eios        <= data_i[7:0] == 8'h66;
        rx_eieos_word  <= data_i == 32'hff00ff00;
        rx_sds_first   <= data_i == 32'h555555e1;
        rx_sds_word    <= data_i == 32'h55555555;
        rx_eios_word   <= data_i == 32'h66666666;
    end
    reg [1:0] index;
    reg in_block, is_skip, is_data, stream, expect_data, eds_seen;
    reg parity, pending_eds;
    reg [2:0] skip_words;
    reg kind_ts1, kind_ts2, kind_eieos, kind_sds, kind_eios;
    reg eieos_match, sds_match, eios_match;
    reg ts_common_match, ts1_match, ts2_match, ts_parity;
    reg  [127:0] decoded;
    reg  [ 22:0] lfsr;
    wire [  1:0] at = rx_start ? 2'b0 : index;
    wire         this_ts1 = rx_start ? rx_ts1 : kind_ts1;
    wire         this_ts2 = rx_start ? rx_ts2 : kind_ts2;
    wire         this_eieos = rx_start ? rx_eieos : kind_eieos;
    wire         this_sds = rx_start ? rx_sds : kind_sds;
    wire         this_eios = rx_start ? rx_eios : kind_eios;
    wire         skip = rx_start ? rx_skip_header : is_skip;
    wire         data_block = rx_start ? rx_data_header : is_data;
    reg  [ 31:0] word_decoded;
    reg  [ 22:0] next_lfsr;
    reg  [ 22:0] advanced_lfsr;
    reg  [ 31:0] scramble_mask;
    reg  [127:0] assembled;
    integer j, b;
    assign stream_o = stream;
    always @* begin
        // Fixed linear transform: SKP controls one hold/advance selection,
        // not each step of the 32-bit unrolled recurrence.
        advanced_lfsr = lfsr;
        for (b = 0; b < 32; b = b + 1) begin
            scramble_mask[b] = advanced_lfsr[22];
            advanced_lfsr = {advanced_lfsr[21:0], 1'b0} ^ (advanced_lfsr[22] ? 23'h210125 : 23'b0);
        end
        next_lfsr    = skip ? lfsr : advanced_lfsr;
        word_decoded = rx_data;
        for (j = 0; j < 4; j = j + 1) begin
            for (b = 0; b < 8; b = b + 1) begin
                if (data_block || ((this_ts1 || this_ts2) && !(at == 0 && j == 0)))
                    word_decoded[8*j+b] = rx_data[8*j+b] ^ (skip ? lfsr[22] : scramble_mask[8*j+b]);
            end
        end
        assembled            = decoded;
        assembled[32*at+:32] = word_decoded;
    end
    task automatic fail;
        begin
            aligned_o      <= 0;
            stream         <= 0;
            expect_data    <= 0;
            in_block       <= 0;
            error_o        <= 1;
            data_valid_o   <= 0;
            stream_start_o <= 0;
            ts1_valid_o    <= 0;
            ts2_valid_o    <= 0;
        end
    endtask
    always @(posedge clk) begin
        if (reset_i || !enable_i) begin
            aligned_o       <= 0;
            in_block        <= 0;
            is_skip         <= 0;
            is_data         <= 0;
            index           <= 0;
            kind_ts1        <= 0;
            kind_ts2        <= 0;
            kind_eieos      <= 0;
            kind_sds        <= 0;
            kind_eios       <= 0;
            eieos_match     <= 0;
            sds_match       <= 0;
            eios_match      <= 0;
            ts_common_match <= 0;
            ts1_match       <= 0;
            ts2_match       <= 0;
            ts_parity       <= 0;
            skip_words      <= 0;
            lfsr            <= 23'h1dbfbc;
            ts_event_o      <= 0;
            ts1_valid_o     <= 0;
            ts2_valid_o     <= 0;
            error_o         <= 0;
            eios_o          <= 0;
            stream          <= 0;
            expect_data     <= 0;
            eds_seen        <= 0;
            parity          <= 0;
            pending_eds     <= 0;
            stream_start_o  <= 0;
            data_valid_o    <= 0;
        end else begin
            ts_event_o     <= 0;
            ts1_valid_o    <= 0;
            ts2_valid_o    <= 0;
            error_o        <= 0;
            eios_o         <= 0;
            stream_start_o <= 0;
            data_valid_o   <= 0;
            pending_eds    <= 0;
            if (eds_i) eds_seen <= 1;
            if (rx_valid) begin
                if (rx_start) begin
                    kind_ts1   <= rx_ts1;
                    kind_ts2   <= rx_ts2;
                    kind_eieos <= rx_eieos;
                    kind_sds   <= rx_sds;
                    kind_eios  <= rx_eios;
                    is_skip    <= skip;
                    is_data    <= data_block;
                    in_block   <= 1;
                    index      <= 1;
                    skip_words <= 1;
                    if (data_block) begin
                        expect_data <= 0;
                        eds_seen    <= 0;
                    end
                end else if (in_block && !is_skip) index <= index + 1'b1;
                if (rx_start || in_block) begin
                    lfsr    <= next_lfsr;
                    decoded <= assembled;
                    // Full ordered-set validation is accumulated as words
                    // arrive. A final word never bypasses earlier mismatches.
                    if (at == 0) begin
                        eieos_match     <= rx_eieos_word;
                        sds_match       <= rx_sds_first;
                        eios_match      <= rx_eios_word;
                        ts_common_match <= word_decoded[23:8] == 0;
                        ts1_match       <= 0;
                        ts2_match       <= 0;
                        ts_parity       <= 0;
                    end else begin
                        eieos_match <= eieos_match && rx_eieos_word;
                        sds_match   <= sds_match && rx_sds_word;
                        eios_match  <= eios_match && rx_eios_word;
                        if (at == 1) begin
                            ts_common_match <= ts_common_match && word_decoded[10:8] == 0;
                            ts_parity       <= ^word_decoded[31:16];
                            ts2_match       <= word_decoded[31:24] == 8'h45;
                        end
                        if (at == 2) begin
                            ts1_match <= word_decoded[31:16] == 16'h4a4a &&
                                ts_parity == (^word_decoded[15:0]);
                            ts2_match <= ts2_match && word_decoded == 32'h45454545;
                        end
                    end
                    if (data_block) begin
                        data_valid_o <= aligned_o && stream;
                        data_o       <= word_decoded;
                        position_o   <= at;
                        parity       <= parity ^ (^rx_data);
                        if (at == 3) in_block <= 0;
                    end else if (skip) begin
                        if (!rx_start) begin
                            skip_words <= skip_words + 1'b1;
                            if (rx_data[7:0] == 8'he1) begin
                                in_block <= 0;
                                is_skip  <= 0;
                                if (skip_words < 1 || skip_words > 5 || !aligned_o ||
                                    rx_data != {lfsr[7:0], lfsr[15:8],
                                                (stream ? parity : !lfsr[22]), lfsr[22:16], 8'he1})
                                    fail();
                                else if (stream) begin
                                    stream_start_o <= 1;
                                    expect_data    <= 1;
                                    parity         <= 0;
                                    pending_eds    <= !(eds_seen || eds_i);
                                    eds_seen       <= 0;
                                end
                            end else if (rx_data != 32'haaaaaaaa || skip_words >= 5) fail();
                        end
                    end else if (at == 3) begin
                        in_block <= 0;
                        if (this_eieos && eieos_match && rx_eieos_word) begin
                            if (stream && !(eds_seen || eds_i)) fail();
                            else begin
                                lfsr      <= 23'h1dbfbc;
                                aligned_o <= 1;
                                stream    <= 0;
                            end
                        end else if (this_ts1 || this_ts2) begin
                            ts_event_o   <= 1;
                            last_ts_o    <= assembled;
                            symbols6_9_o <= assembled[79:48];
                            ec_o         <= assembled[49:48];
                            fs_o         <= assembled[61:56];
                            lf_o         <= assembled[69:64];
                            if (stream) fail();
                            else begin
                                ts1_valid_o <= aligned_o && this_ts1 && ts_common_match &&
                                    ts1_match && word_decoded[15:0] == 16'h4a4a;
                                ts2_valid_o <= aligned_o && this_ts2 && ts_common_match &&
                                    ts2_match && word_decoded[15:0] == 16'h4545;
                            end
                        end else if (this_sds && sds_match && rx_sds_word) begin
                            if (!aligned_o || stream) fail();
                            else begin
                                stream         <= 1;
                                expect_data    <= 1;
                                stream_start_o <= 1;
                                parity         <= 0;
                                eds_seen       <= 0;
                            end
                        end else if (this_eios && eios_match && rx_eios_word) begin
                            if (stream && !(eds_seen || eds_i)) fail();
                            else begin
                                eios_o    <= 1;
                                aligned_o <= 0;
                                stream    <= 0;
                            end
                        end else fail();
                    end
                end
                // Structural failures override all provisional output pulses.
                if ((rx_start && (in_block || rx_bad_header || (expect_data && !data_block) ||
                                  (data_block && (!stream || !aligned_o ||
                                                  (!expect_data && (eds_seen || eds_i)))) ||
                                  (skip && rx_data != 32'haaaaaaaa))) || (!rx_start && !in_block))
                    fail();
            end
            if (parser_error_i || (pending_eds && !eds_i) ||
                (eds_i && rx_valid && data_block && !expect_data))
                fail();
        end
    end
endmodule

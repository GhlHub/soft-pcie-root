// SPDX-License-Identifier: Apache-2.0
// Gen1/Gen2 x2 receive symbols after 8b/10b decoding in a common user clock.
// Lane input words are time ordered. The first Logical Idle symbol after a
// validated final TS2 starts the same stream epoch on each lane.
module pcie_legacy_x2_rx #(
    parameter integer DESKEW_DEPTH = 16,
    parameter integer ALIGN_CYCLES = 12
) (
    input wire clk, rst_n,
    input wire align_enable_i, deliver_i,
    input wire [1:0] final_ts2_i,
    input wire [31:0] lane_data_i,
    input wire [3:0] lane_control_i,
    input wire [1:0] lane_valid_i, lane_error_i,
    output wire [1:0] idle_sample_o, idle_pair_o,
    output wire [31:0] symbols_o,
    output wire [3:0] control_o,
    output wire valid_o, aligned_o, fault_o
);
    wire [1:0] push, anchor, lane_fault;
    wire [35:0] source_words, lane_words;
    wire [3:0] source_tags;
    wire deskew_valid, deskew_fault;
    wire [1:0] unused_tag;

    // The peer may start InitFC before our LTSSM enters L0. Discard only
    // leading Logical Idle in that interval and retain its first packet.
    wire       discard_idle = control_o == 0 && symbols_o == 0;
    assign valid_o = deskew_valid && deliver_i && !(|lane_fault);
    assign fault_o = deskew_fault || (|lane_fault);
    pcie_lane_deskew #(
        .LANES       (2),
        .DATA_BITS   (18),
        .TAG_BITS    (2),
        .DEPTH       (DESKEW_DEPTH),
        .ALIGN_CYCLES(ALIGN_CYCLES)
    ) deskew (
        .clk      (clk),
        .reset_i  (!rst_n),
        .abort_i  (!align_enable_i),
        .valid_i  (push),
        .align_i  (anchor),
        .data_i   (source_words),
        .tag_i    (source_tags),
        .valid_o  (deskew_valid),
        .ready_i  (deliver_i || discard_idle),
        .data_o   (lane_words),
        .tag_o    (unused_tag),
        .fault_o  (deskew_fault),
        .aligned_o(aligned_o)
    );
    assign control_o = {lane_words[35], lane_words[17], lane_words[26], lane_words[8]};
    wire [31:0] unused_striped;
    pcie_lane_stripe #(
        .LANES  (2),
        .SYMBOLS(2)
    ) striping (
        .stream_i(32'b0),
        .lanes_o (unused_striped),
        .lanes_i ({lane_words[34:27], lane_words[25:18], lane_words[16:9], lane_words[7:0]}),
        .stream_o(symbols_o)
    );

    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : lanes
        wire [15:0] raw_data = lane_data_i[16*lane+:16];
        wire [ 1:0] raw_control = lane_control_i[2*lane+:2];
        reg [3:0] os_remaining_q, os_remaining_n;
        reg [2:0] skp_count_q, skp_count_n;
        reg raw_phase_q, raw_phase_n;
        reg [1:0] ordinary, phase;
        reg malformed;
        reg [1:0] ordinary_q, phase_q;
        reg         invalid_q;
        wire [15:0] decoded;
        wire [1:0] decoded_control, unused_keep;
        wire decoded_valid, unused_ready;
        wire [15:0] unused_lfsr;

        // Remove ordered sets after the per-lane LFSR has seen every symbol.
        // A SKP can have one through five symbols after clock compensation.
        // Carry the SKP phase with subsequent data to detect unequal epochs.
        always @* begin
            os_remaining_n = os_remaining_q;
            skp_count_n    = skp_count_q;
            raw_phase_n    = raw_phase_q;
            ordinary       = 0;
            phase          = 0;
            malformed      = 0;
            for (integer symbol = 0; symbol < 2; symbol = symbol + 1) begin
                if (lane_valid_i[lane]) begin
                    if (raw_control[symbol] && raw_data[8*symbol+:8] == 8'hbc) begin
                        os_remaining_n = 15;
                        skp_count_n    = 0;
                    end else if (raw_control[symbol] && raw_data[8*symbol+:8] == 8'h1c) begin
                        if (os_remaining_n == 15) begin
                            raw_phase_n = !raw_phase_n;
                            skp_count_n = 1;
                        end else if (skp_count_n >= 1 && skp_count_n < 5)
                            skp_count_n = skp_count_n + 1'b1;
                        else malformed = 1;
                        os_remaining_n = 0;
                    end else begin
                        skp_count_n = 0;
                        if (os_remaining_n != 0) os_remaining_n = os_remaining_n - 1'b1;
                        else ordinary[symbol] = 1;
                    end
                    phase[symbol] = raw_phase_n;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n) begin
                os_remaining_q <= 0;
                skp_count_q    <= 0;
                raw_phase_q    <= 0;
                invalid_q      <= 0;
                ordinary_q     <= 0;
                phase_q        <= 0;
            end else begin
                os_remaining_q <= os_remaining_n;
                skp_count_q    <= skp_count_n;
                raw_phase_q    <= raw_phase_n;
                invalid_q      <= lane_error_i[lane] || malformed;
                ordinary_q     <= ordinary;
                phase_q        <= phase;
            end
        end
        pcie_soft_scrambler descrambler (
            .clk            (clk),
            .rst_n          (rst_n),
            .s_data_i       (raw_data),
            .s_ctrl_i       (raw_control),
            .s_keep_i       (2'b11),
            .data_scramble_i(ordinary),
            .s_valid_i      (lane_valid_i[lane]),
            .s_ready_o      (unused_ready),
            .m_data_o       (decoded),
            .m_ctrl_o       (decoded_control),
            .m_keep_o       (unused_keep),
            .m_valid_o      (decoded_valid),
            .m_ready_i      (1'b1),
            .lfsr_o         (unused_lfsr)
        );
        assign idle_sample_o[lane] = decoded_valid && (&ordinary_q) && !invalid_q;
        assign idle_pair_o[lane]   = idle_sample_o[lane] && decoded_control == 0 && decoded == 0;

        // Pack two surviving symbols per FIFO record. Odd SKP lengths can
        // leave half a record pending across one or more input beats.
        reg armed_q, capturing_q, capturing_n, emitted_q, emitted_n;
        reg phase_origin_q, phase_origin_n;
        reg pending_q, pending_n;
        reg [9:0] saved_q, saved_n;
        reg [17:0] record;
        reg [ 1:0] tag;
        reg push_word, first_word;
        reg [8:0] value;
        assign lane_fault[lane]          = align_enable_i && capturing_q && invalid_q;
        assign source_words[18*lane+:18] = record;
        assign source_tags[2*lane+:2]    = tag;
        assign push[lane]                = push_word;
        assign anchor[lane]              = first_word;
        always @* begin
            capturing_n    = capturing_q;
            emitted_n      = emitted_q;
            phase_origin_n = phase_origin_q;
            pending_n      = pending_q;
            saved_n        = saved_q;
            record         = 0;
            tag            = 0;
            push_word      = 0;
            first_word     = 0;
            value          = 0;
            for (integer symbol = 0; symbol < 2; symbol = symbol + 1) begin
                if (align_enable_i && decoded_valid && ordinary_q[symbol] && !invalid_q) begin
                    value = {decoded_control[symbol], decoded[8*symbol+:8]};
                    if (!capturing_n && (armed_q || final_ts2_i[lane]) && value == 0) begin
                        capturing_n    = 1;
                        phase_origin_n = phase_q[symbol];
                    end
                    if (capturing_n) begin
                        if (pending_n) begin
                            record     = {value, saved_n[8:0]};
                            tag        = {phase_q[symbol] ^ phase_origin_n, saved_n[9]};
                            push_word  = 1;
                            first_word = !emitted_n;
                            emitted_n  = 1;
                            pending_n  = 0;
                        end else begin
                            saved_n   = {phase_q[symbol] ^ phase_origin_n, value};
                            pending_n = 1;
                        end
                    end
                end
            end
        end
        always @(posedge clk) begin
            if (!rst_n || !align_enable_i) begin
                armed_q        <= 0;
                capturing_q    <= 0;
                emitted_q      <= 0;
                phase_origin_q <= 0;
                pending_q      <= 0;
                saved_q        <= 0;
            end else begin
                if (final_ts2_i[lane]) armed_q <= 1;
                capturing_q    <= capturing_n;
                emitted_q      <= emitted_n;
                phase_origin_q <= phase_origin_n;
                pending_q      <= pending_n;
                saved_q        <= saved_n;
            end
        end
    end
endmodule

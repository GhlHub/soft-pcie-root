// SPDX-License-Identifier: Apache-2.0
// Ordered-set and packet receive path for a fixed, logically ordered Gen3 x2
// link. The lane codecs validate their own ordered sets and SKP parity. Only
// the bonded parser decides whether a data stream contained an EDS token.
module gen3_x2_receive #(
    parameter integer LANE_DEPTH    = 16,
    parameter integer LANE_DEADLINE = 24,
    parameter integer EDS_DEADLINE  = 16
) (
    input wire clk, reset_i, enable_i, abort_i,
    input wire [63:0] lane_data_i,
    input wire [1:0] lane_valid_i, lane_start_i,
    input wire [3:0] lane_header_i,
    output wire [1:0] aligned_o, ts_event_o, ts1_o, ts2_o,
    output wire [255:0] ts_o,
    output wire stream_o, data_word_o, idle_word_o,
    output reg stream_start_o, stream_end_o, end_electrical_idle_o,
    output reg framing_fault_o,
    output wire [63:0] tlp_data_o,
    output wire [1:0] tlp_words_o,
    output wire tlp_valid_o, tlp_last_o,
    input wire tlp_ready_i,
    output wire [1:0] tlp_class_o,
    output wire [8:0] tlp_credits_o,
    output wire response_o, nak_o,
    output wire [11:0] response_sequence_o,
    output wire dllp_o,
    output wire [31:0] dllp_body_o,
    output wire packet_error_o
);
    localparam [2:0] SDS = 4, SKP = 5, EIEOS = 6, EIOS = 7;
    localparam integer TIMER_BITS = $clog2(EDS_DEADLINE);
    wire clear = reset_i || abort_i || !enable_i || framing_fault_o;
    wire [1:0] lane_error, record_valid, lane_data_valid, record_align;
    wire [5:0] lane_events, record_tags;
    wire [63:0] record_data;
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : lanes
        wire [1:0] position;
        wire [2:0] event_kind = lane_events[3*lane+:3];
        assign record_valid[lane]     = lane_data_valid[lane] || event_kind != 0;
        assign record_align[lane]     = event_kind == SDS;
        assign record_tags[3*lane+:3] = lane_data_valid[lane] ? {1'b0, position} : event_kind;
        gen3_native_rx #(
            .LANE_ID     (lane),
            .EXTERNAL_EDS(1)
        ) codec (
            .clk           (clk),
            .reset_i       (reset_i),
            .enable_i      (!clear),
            .data_i        (lane_data_i[32*lane+:32]),
            .valid_i       (lane_valid_i[lane]),
            .start_i       (lane_start_i[lane]),
            .header_i      (lane_header_i[2*lane+:2]),
            .eds_i         (1'b0),
            .parser_error_i(1'b0),
            .aligned_o     (aligned_o[lane]),
            .ts_event_o    (ts_event_o[lane]),
            .ts1_valid_o   (ts1_o[lane]),
            .ts2_valid_o   (ts2_o[lane]),
            .ec_o          (),
            .fs_o          (),
            .lf_o          (),
            .symbols6_9_o  (),
            .error_o       (lane_error[lane]),
            .eios_o        (),
            .last_ts_o     (ts_o[128*lane+:128]),
            .stream_start_o(),
            .data_valid_o  (lane_data_valid[lane]),
            .data_o        (record_data[32*lane+:32]),
            .position_o    (position),
            .stream_o      (),
            .block_event_o (lane_events[3*lane+:3])
        );
    end
    wire bond_valid, bond_fault, bond_ready;
    wire [2:0] bond_tag;
    wire [63:0] bond_data, aggregate;
    // Register the paired record before applying token parser controls.
    reg        head_valid_q;
    reg [ 2:0] head_tag_q;
    reg [63:0] head_data_q;
    reg stream_q, eds_seen_q;
    reg [TIMER_BITS-1:0] eds_timer_q;
    wire parser_active, parser_eds, parser_framing;
    wire data_head = head_valid_q && !head_tag_q[2];
    wire session_start = head_valid_q && head_tag_q == SDS && !stream_q;
    wire boundary_head = head_valid_q &&
        (head_tag_q == SKP || head_tag_q == EIEOS || head_tag_q == EIOS);
    wire boundary_ready = boundary_head && stream_q && eds_seen_q;
    wire stream_end = boundary_ready && head_tag_q != SKP;
    wire restart = boundary_ready && head_tag_q == SKP;
    wire wait_eds = boundary_head && stream_q && !eds_seen_q;
    wire stream_fault = (data_head && (!stream_q || !parser_active)) ||
        (head_valid_q && head_tag_q == SDS && stream_q) || (boundary_head && !stream_q) ||
        (wait_eds && eds_timer_q == TIMER_BITS'(EDS_DEADLINE - 1) && !parser_eds);
    wire retire = data_head || session_start || boundary_ready;
    assign stream_o    = stream_q && !clear;
    assign data_word_o = data_head && stream_o && parser_active;
    assign idle_word_o = data_word_o && head_data_q == 0;
    assign bond_ready  = !head_valid_q || retire;
    pcie_lane_deskew #(
        .LANES       (2),
        .TAG_BITS    (3),
        .DEPTH       (LANE_DEPTH),
        .ALIGN_CYCLES(LANE_DEADLINE),
        .SKEW_CYCLES (LANE_DEADLINE)
    ) deskew (
        .clk      (clk),
        .reset_i  (reset_i),
        .abort_i  (clear || stream_end),
        .valid_i  (record_valid),
        .align_i  (record_align),
        .data_i   (record_data),
        .tag_i    (record_tags),
        .valid_o  (bond_valid),
        .ready_i  (bond_ready),
        .data_o   (bond_data),
        .tag_o    (bond_tag),
        .fault_o  (bond_fault),
        .aligned_o()
    );
    pcie_lane_stripe #(
        .LANES  (2),
        .SYMBOLS(4)
    ) destripe (
        .stream_i(64'b0),
        .lanes_o (),
        .lanes_i (bond_data),
        .stream_o(aggregate)
    );
    always @(posedge clk) begin
        stream_start_o <= 0;
        stream_end_o   <= 0;
        if (reset_i || abort_i || !enable_i) begin
            framing_fault_o       <= 0;
            end_electrical_idle_o <= 0;
        end else if ((|lane_error) || bond_fault || parser_framing || stream_fault)
            framing_fault_o <= 1;
        if (clear) begin
            head_valid_q <= 0;
            stream_q     <= 0;
            eds_seen_q   <= 0;
            eds_timer_q  <= 0;
        end else begin
            if (bond_ready) begin
                head_valid_q <= bond_valid;
                head_tag_q   <= bond_tag;
                head_data_q  <= aggregate;
            end
            if (session_start) begin
                stream_q       <= 1;
                stream_start_o <= 1;
            end
            if (stream_end) begin
                stream_q              <= 0;
                stream_end_o          <= 1;
                end_electrical_idle_o <= head_tag_q == EIOS;
            end
            // Defer marker retirement for one clock after parser_eds, so
            // the prior block's registered finish event can still commit.
            if (boundary_ready) eds_seen_q <= 0;
            else if (parser_eds) eds_seen_q <= 1;
            if (!wait_eds || parser_eds) eds_timer_q <= 0;
            else if (!stream_fault) eds_timer_q <= eds_timer_q + 1'b1;
        end
    end
    gen3_data_rx_x2 #(
        .STRICT_EDS(1)
    ) parser (
        .clk                (clk),
        .reset_i            (reset_i),
        .start_stream_i     (session_start || restart),
        .abort_i            (clear),
        .valid_i            (data_word_o),
        .data_i             (head_data_q),
        .position_i         (head_tag_q[1:0]),
        .active_o           (parser_active),
        .eds_o              (parser_eds),
        .tlp_data_o         (tlp_data_o),
        .tlp_words_o        (tlp_words_o),
        .tlp_valid_o        (tlp_valid_o),
        .tlp_last_o         (tlp_last_o),
        .tlp_ready_i        (tlp_ready_i),
        .tlp_class_o        (tlp_class_o),
        .tlp_credits_o      (tlp_credits_o),
        .response_o         (response_o),
        .nak_o              (nak_o),
        .response_sequence_o(response_sequence_o),
        .dllp_o             (dllp_o),
        .dllp_body_o        (dllp_body_o),
        .error_o            (packet_error_o),
        .framing_error_o    (parser_framing)
    );
    initial if (EDS_DEADLINE < 2) $fatal(1, "Gen3 x2 EDS deadline must be at least two cycles");
endmodule

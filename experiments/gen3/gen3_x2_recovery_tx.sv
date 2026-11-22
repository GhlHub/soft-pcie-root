// SPDX-License-Identifier: Apache-2.0
// Matched 128b/130b transmit lanes. Data symbols and the
// EDS token stripe across lanes; each ordered set and LFSR belongs to its lane.
module gen3_x2_recovery_tx #(
    parameter bit INTEGRATED_EQ = 0
) (
    input wire clk, reset_i, enable_i, stop_i, ts2_i, stream_i,
    input wire [7:0] preset_i,
    input wire [11:0] first_i, second_i, post_i,
    input wire [63:0] packet_data_i,
    input wire [1:0] packet_words_i,
    input wire packet_valid_i, packet_last_i,
    output wire packet_ready_o, packet_sent_o,
    output wire [63:0] data_o,
    output wire [1:0] valid_o, start_o,
    output wire [3:0] header_o,
    output wire ts_done_o, ts2_done_o, eieos_done_o, stopped_o, idle_word_o,
    output wire [4:0] profile_events_o,
    output reg fault_o,
    input wire eq_active_i, eq_restart_interval_i,
    input wire [63:0] eq_fields_i
);
    wire [1:0] lane_ready, lane_sent, lane_fault, lane_stopped, lane_idle, lane_ts2, lane_eieos;
    wire [ 1:0] lane_ts;
    wire [ 9:0] events;
    wire [63:0] striped;
    wire        geometry_valid = packet_words_i == 2 || (packet_words_i == 1 && packet_last_i);
    wire [63:0] padded = {packet_words_i == 2 ? packet_data_i[63:32] : 32'b0, packet_data_i[31:0]};
    assign packet_ready_o   = (&lane_ready) && (!packet_valid_i || geometry_valid) && !fault_o;
    assign packet_sent_o    = &lane_sent;
    assign ts_done_o        = &lane_ts;
    assign ts2_done_o       = &lane_ts2;
    assign eieos_done_o     = &lane_eieos;
    assign stopped_o        = &lane_stopped;
    assign idle_word_o      = &lane_idle;
    assign profile_events_o = events[4:0] | events[9:5];
    pcie_lane_stripe #(
        .LANES  (2),
        .SYMBOLS(4)
    ) stripe (
        .stream_i(padded),
        .lanes_o (striped),
        .lanes_i (64'b0),
        .stream_o()
    );
    always @(posedge clk) begin
        if (reset_i) fault_o <= 0;
        else if ((|lane_fault) || lane_ready[0] != lane_ready[1] || lane_sent[0] != lane_sent[1] ||
                 valid_o[0] != valid_o[1] ||
                 ((&valid_o) && (start_o[0] != start_o[1] || header_o[1:0] != header_o[3:2])) ||
                 (packet_valid_i && (&lane_ready) && !geometry_valid))
            fault_o <= 1;
    end
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : lanes
        // The last four aggregate bytes are 1f 80 90 00. Lane 0 gets
        // bytes 1f and 90, lane 1 gets 80 and 00, at symbol times 14/15.
        wire [30:0] recovery_fields = {
            1'b0,
            post_i[6*lane+:6],
            2'b0,
            second_i[6*lane+:6],
            2'b0,
            first_i[6*lane+:6],
            1'b0,
            preset_i[4*lane+:4],
            3'b0
        };
        gen3_recovery_tx #(
            .REGISTER_MASK  (1'b1),
            .EXTERNAL_EQ    (int'(INTEGRATED_EQ)),
            .LANE_ID        (lane),
            .END_STREAM_WORD(lane == 0 ? 32'h901f0000 : 32'h00800000)
        ) tx (
            .clk(clk),
            .reset_i(reset_i),
            .enable_i(enable_i),
            .stop_i(stop_i),
            .ts2_i(ts2_i),
            .stream_i(stream_i),
            .ec_i(2'b0),
            .preset_i(preset_i[4*lane+:4]),
            .first_i(first_i[6*lane+:6]),
            .second_i(second_i[6*lane+:6]),
            .post_i(post_i[6*lane+:6]),
            .data_o(data_o[32*lane+:32]),
            .valid_o(valid_o[lane]),
            .start_o(start_o[lane]),
            .ts_done_o(lane_ts[lane]),
            .stopped_o(lane_stopped[lane]),
            .header_o(header_o[2*lane+:2]),
            .balance_o(),
            .ts2_done_o(lane_ts2[lane]),
            .eieos_done_o(lane_eieos[lane]),
            .idle_word_o(lane_idle[lane]),
            .initfc1_i(1'b0),
            .packet_data_i(striped[32*lane+:32]),
            .packet_valid_i(packet_valid_i && packet_ready_o),
            .packet_last_i(packet_last_i),
            .packet_ready_o(lane_ready[lane]),
            .packet_submit_o(lane_sent[lane]),
            .packet_fault_o(lane_fault[lane]),
            .profile_events_o(events[5*lane+:5]),
            .eq_fields_i(eq_active_i ?
                         eq_fields_i[32*lane+:32] : {^recovery_fields, recovery_fields}),
            // Keep the transmit lane ordered-set boundaries common, even
            // when only one lane requests a new equalization interval.
            .reset_interval_i(INTEGRATED_EQ && eq_active_i && eq_restart_interval_i)
        );
    end
endmodule

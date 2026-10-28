// SPDX-License-Identifier: Apache-2.0
// Reuse the Gen2 eight-slot BRAM replay store and cumulative ACK capture.
// The Gen3 PCS submission event substitutes only for the store's serializer
// progress input. Only a validated peer ACK/NAK can retire replay ownership.
// No ownership reset on pause/link loss; recovery exhaustion quarantines.
module gen3_tx_window #(
    parameter integer REPLAY_CYCLES = 384
) (
    input wire clk, reset_i, enable_i,
    input wire [31:0] data_i,
    input wire valid_i, last_i,
    output wire ready_o,
    output wire [31:0] data_o,
    output wire valid_o, last_o,
    input wire ready_i,
    input wire response_i, nak_i,
    input wire [11:0] response_sequence_i,
    output wire [3:0] pending_o, sent_o,
    output wire [11:0] acknowledged_o, next_sequence_o,
    output reg fault_o,
    output wire [11:0] profile_events_o
);
    wire captured, captured_ready, captured_nak, ack_error;
    wire [11:0] captured_seq;
    wire [15:0] captured_age;
    pcie_soft_ack_capture capture (
        clk,
        !reset_i,
        1'b0,
        response_i,
        nak_i,
        response_sequence_i,
        acknowledged_o,
        {7'b0, sent_o},
        captured,
        captured_ready,
        captured_nak,
        captured_seq,
        captured_age,
        ack_error
    );
    wire [31:0] payload;
    wire payload_valid, payload_last, payload_ready;
    wire [11:0] sequence_q, unused_wire_seq;
    wire submitted, formatter_fault, recovery, error, overflow;
    wire unused_replay, unused_wire_replay, unused_replaying, unused_event, unused_timeout;
    pcie_soft_replay #(
        .DEPTH                (8),
        .MAX_DWORDS           (64),
        .REPLAY_TIMEOUT_CYCLES(REPLAY_CYCLES)
    ) store (
        .clk                (clk),
        .rst_n              (!reset_i),
        .link_reset_i       (1'b0),
        .enable_i           (enable_i && !fault_o),
        .s_data_i           (data_i),
        .s_valid_i          (valid_i),
        .s_last_i           (last_i),
        .s_ready_o          (ready_o),
        .m_data_o           (payload),
        .m_valid_o          (payload_valid),
        .m_last_o           (payload_last),
        .m_sequence_o       (sequence_q),
        .m_replay_o         (unused_replay),
        .wire_sequence_o    (unused_wire_seq),
        .wire_replay_o      (unused_wire_replay),
        .m_ready_i          (payload_ready),
        .tx_allow_i         (enable_i && !fault_o),
        .tx_wire_done_i     (submitted),
        .phy_hold_i         (!enable_i || fault_o),
        .retrain_done_i     (1'b0),
        .response_valid_i   (captured),
        .response_ready_o   (captured_ready),
        .response_nak_i     (captured_nak),
        .response_sequence_i(captured_seq),
        .response_age_i     (captured_age),
        .pending_o          (pending_o),
        .sent_o             (sent_o),
        .replaying_o        (unused_replaying),
        .acknowledged_o     (acknowledged_o),
        .next_sequence_o    (next_sequence_o),
        .recovery_req_o     (recovery),
        .response_error_o   (error),
        .overflow_o         (overflow),
        .replay_event_o     (unused_event),
        .timeout_event_o    (unused_timeout),
        .profile_events_o   (profile_events_o[7:0])
    );
    gen3_tlp_source format_tlp (
        clk,
        reset_i,
        payload,
        payload_valid,
        payload_last,
        payload_ready,
        sequence_q,
        data_o,
        valid_o,
        last_o,
        ready_i,
        submitted,
        formatter_fault
    );
    always @(posedge clk) begin
        if (reset_i) fault_o <= 0;
        else if (ack_error || recovery || error || overflow || formatter_fault) fault_o <= 1;
    end
    assign profile_events_o[11:8] = {
        submitted,
        valid_o && !ready_i,
        payload_valid && !payload_ready,
        payload_valid && payload_ready
    };
    wire unused = ^{unused_wire_seq, unused_replay, unused_wire_replay, unused_replaying,
                    unused_event, unused_timeout};
endmodule

// SPDX-License-Identifier: Apache-2.0
// Fixed-width Gen3 x2 port. The optional equalization interface uses the
// same transmit lanes throughout Gen3 training, Recovery and packet traffic.
module gen3_x2_post_port #(
    parameter integer HANDSHAKE_CYCLES      = 6000000,
    parameter bit     INTEGRATED_EQ         = 0,
    parameter integer POSTED_HEADER_CREDITS = 4
) (
    input wire clk, reset_i, start_i,
    input wire [1:0] phy_ready_i,
    input wire [7:0] tx_preset_i,
    input wire [35:0] tx_coeff_i,
    input wire [63:0] rx_data_i,
    input wire [1:0] rx_valid_i, rx_start_i,
    input wire [3:0] rx_header_i,
    output wire [63:0] tx_data_o,
    output wire [1:0] tx_valid_o, tx_start_o,
    output wire [3:0] tx_header_o,
    output wire tx_idle_o, link_up_o, dl_active_o, epoch_o, failed_o, error_o,
    output wire [4:0] state_o,
    output wire [127:0] completion_debug_o,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire [2:0] cmd_op_i,
    input wire [63:0] cmd_address_i,
    input wire [15:0] cmd_bdf_i,
    input wire [31:0] cmd_data_i,
    input wire [3:0] cmd_be_i,
    output wire rsp_valid_o,
    input wire rsp_ready_i,
    output wire [31:0] rsp_data_o,
    output wire [2:0] rsp_status_o,
    input wire [63:0] app_tx_data_i,
    input wire [1:0] app_tx_words_i,
    input wire app_tx_valid_i, app_tx_last_i,
    output wire app_tx_ready_o,
    input wire [8:0] app_tx_credits_i,
    output wire [63:0] app_rx_data_o,
    output wire [1:0] app_rx_words_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i,
    input wire eq_active_i, eq_restart_interval_i, eq_failed_i,
    input wire [63:0] eq_fields_i
);
    wire [1:0] aligned, ts_event, ts1, ts2;
    wire [255:0] last_ts;
    wire rx_word, rx_idle_word, stream_end, end_idle, rx_fault, packet_error;
    wire send_ts, send_ts2, send_eieos, send_idle_word, tx_stopped, tx_fault;
    wire tx_enable, tx_stop, tx_ts2, tx_stream, recovery;
    wire [63:0] rx_tlp, tx_packet;
    wire [1:0] rx_words, rx_class, tx_words;
    wire [8:0] rx_credits;
    wire rx_valid, rx_last, rx_ready, tx_valid, tx_last, tx_ready;
    wire rx_ack, rx_nak, dllp_valid, flow_active, dl_error, command_ready;
    wire [11:0] rx_sequence;
    wire [31:0] dllp;
    wire [ 4:0] tx_profile;
    wire        pcs_enable = tx_enable || (INTEGRATED_EQ && (eq_active_i || start_i));
    wire        pcs_stop = tx_stop || (INTEGRATED_EQ && eq_failed_i);
    wire [1:0] receive_valid;
    if (INTEGRATED_EQ) begin : receive_acquisition
        reg [1:0] first_start_q;
        always @(posedge clk) begin
            if (reset_i || !pcs_enable || pcs_stop) first_start_q <= 0;
            else first_start_q <= first_start_q | (rx_valid_i & rx_start_i);
        end
        // Both receivers enter while the peer may be inside a block. Once a
        // lane supplies its first start, preserve all normal framing checks.
        assign receive_valid = rx_valid_i & (rx_start_i | first_start_q);
    end else begin : receive_already_framed
        assign receive_valid = rx_valid_i;
    end
    reg tx_seen_q, dl_fault_q;
    always @(posedge clk) begin
        if (reset_i) begin
            tx_seen_q  <= 0;
            dl_fault_q <= 0;
        end else begin
            if (|tx_valid_o) tx_seen_q <= 1;
            if (dl_error) dl_fault_q <= 1;
        end
    end
    assign tx_idle_o   = (!tx_seen_q || tx_stopped) && !(|tx_valid_o);
    assign dl_active_o = flow_active && (link_up_o || recovery);
    assign cmd_ready_o = command_ready && flow_active && link_up_o;
    assign error_o     = failed_o || packet_error || dl_error;

    gen3_x2_post_eq #(
        .HANDSHAKE_CYCLES(HANDSHAKE_CYCLES)
    ) control (
        .clk            (clk),
        .reset_i        (reset_i),
        .start_i        (start_i),
        .phy_ready_i    (phy_ready_i),
        .aligned_i      (aligned),
        .ts_event_i     (ts_event),
        .ts1_i          (ts1),
        .ts2_i          (ts2),
        .ts_i           (last_ts),
        .rx_data_word_i (rx_word),
        .rx_idle_word_i (rx_idle_word),
        .rx_stream_end_i(stream_end),
        .rx_end_idle_i  (end_idle),
        .tx_ts_i        (send_ts),
        .tx_ts2_i       (send_ts2),
        .tx_eieos_i     (send_eieos),
        .tx_idle_word_i (send_idle_word),
        // Publish the data-link fault immediately in error_o. Transfer the
        // sticky fault to the LTSSM on a local clock edge so it does not
        // feed back through its state decode into host packet backpressure.
        .rx_fault_i     (rx_fault || dl_fault_q),
        .tx_fault_i     (tx_fault),
        .tx_enable_o    (tx_enable),
        .tx_stop_o      (tx_stop),
        .tx_ts2_o       (tx_ts2),
        .tx_stream_o    (tx_stream),
        .l0_o           (link_up_o),
        .recovery_o     (recovery),
        .failed_o       (failed_o),
        .epoch_o        (epoch_o),
        .state_o        (state_o)
    );
    gen3_x2_receive receive (
        .clk                  (clk),
        .reset_i              (reset_i),
        .enable_i             (pcs_enable && !pcs_stop),
        .abort_i              (1'b0),
        .lane_data_i          (rx_data_i),
        .lane_valid_i         (receive_valid),
        .lane_start_i         (rx_start_i),
        .lane_header_i        (rx_header_i),
        .aligned_o            (aligned),
        .ts_event_o           (ts_event),
        .ts1_o                (ts1),
        .ts2_o                (ts2),
        .ts_o                 (last_ts),
        .stream_o             (),
        .data_word_o          (rx_word),
        .idle_word_o          (rx_idle_word),
        .stream_start_o       (),
        .stream_end_o         (stream_end),
        .end_electrical_idle_o(end_idle),
        .framing_fault_o      (rx_fault),
        .tlp_data_o           (rx_tlp),
        .tlp_words_o          (rx_words),
        .tlp_valid_o          (rx_valid),
        .tlp_last_o           (rx_last),
        .tlp_ready_i          (rx_ready),
        .tlp_class_o          (rx_class),
        .tlp_credits_o        (rx_credits),
        .response_o           (rx_ack),
        .nak_o                (rx_nak),
        .response_sequence_o  (rx_sequence),
        .dllp_o               (dllp_valid),
        .dllp_body_o          (dllp),
        .packet_error_o       (packet_error)
    );
    gen3_x2_recovery_tx #(
        .INTEGRATED_EQ(INTEGRATED_EQ)
    ) transmit (
        .clk                  (clk),
        .reset_i              (reset_i),
        .enable_i             (pcs_enable),
        .stop_i               (pcs_stop),
        .ts2_i                (tx_ts2),
        .stream_i             (tx_stream),
        .preset_i             (tx_preset_i),
        .first_i              ({tx_coeff_i[35:30], tx_coeff_i[17:12]}),
        .second_i             ({tx_coeff_i[29:24], tx_coeff_i[11:6]}),
        .post_i               ({tx_coeff_i[23:18], tx_coeff_i[5:0]}),
        .packet_data_i        (tx_packet),
        .packet_words_i       (tx_words),
        .packet_valid_i       (tx_valid),
        .packet_last_i        (tx_last),
        .packet_ready_o       (tx_ready),
        .packet_sent_o        (),
        .data_o               (tx_data_o),
        .valid_o              (tx_valid_o),
        .start_o              (tx_start_o),
        .header_o             (tx_header_o),
        .ts_done_o            (send_ts),
        .ts2_done_o           (send_ts2),
        .eieos_done_o         (send_eieos),
        .stopped_o            (tx_stopped),
        .idle_word_o          (send_idle_word),
        .profile_events_o     (tx_profile),
        .fault_o              (tx_fault),
        .eq_active_i          (eq_active_i),
        .eq_restart_interval_i(eq_restart_interval_i),
        .eq_fields_i          (eq_fields_i)
    );
    gen3_link_layer_x2 #(
        .POSTED_HEADER_CREDITS(POSTED_HEADER_CREDITS)
    ) link (
        .clk                (clk),
        .reset_i            (reset_i),
        .link_up_i          (epoch_o),
        .enable_i           (link_up_o),
        .rx_data_i          (rx_tlp),
        .rx_words_i         (rx_words),
        .rx_valid_i         (rx_valid),
        .rx_last_i          (rx_last),
        .rx_ready_o         (rx_ready),
        .rx_class_i         (rx_class),
        .rx_credits_i       (rx_credits),
        .response_i         (rx_ack),
        .nak_i              (rx_nak),
        .response_sequence_i(rx_sequence),
        .dllp_i             (dllp_valid),
        .dllp_body_i        (dllp),
        .tx_data_o          (tx_packet),
        .tx_words_o         (tx_words),
        .tx_valid_o         (tx_valid),
        .tx_last_o          (tx_last),
        .tx_ready_i         (tx_ready),
        .cmd_valid_i        (cmd_valid_i && flow_active && link_up_o),
        .cmd_ready_o        (command_ready),
        .cmd_op_i           (cmd_op_i),
        .cmd_address_i      (cmd_address_i),
        .cmd_bdf_i          (cmd_bdf_i),
        .cmd_data_i         (cmd_data_i),
        .cmd_be_i           (cmd_be_i),
        .rsp_valid_o        (rsp_valid_o),
        .rsp_ready_i        (rsp_ready_i),
        .rsp_data_o         (rsp_data_o),
        .rsp_status_o       (rsp_status_o),
        .app_tx_data_i      (app_tx_data_i),
        .app_tx_words_i     (app_tx_words_i),
        .app_tx_valid_i     (app_tx_valid_i),
        .app_tx_last_i      (app_tx_last_i),
        .app_tx_ready_o     (app_tx_ready_o),
        .app_tx_class_i     (2'd2),
        .app_tx_credits_i   (app_tx_credits_i),
        .app_rx_data_o      (app_rx_data_o),
        .app_rx_words_o     (app_rx_words_o),
        .app_rx_valid_o     (app_rx_valid_o),
        .app_rx_last_o      (app_rx_last_o),
        .app_rx_ready_i     (app_rx_ready_i),
        .active_o           (flow_active),
        .error_o            (dl_error),
        .pending_o          (),
        .completion_debug_o (completion_debug_o),
        .pcs_profile_i      (tx_profile),
        .recovery_i         (recovery)
    );
endmodule

// SPDX-License-Identifier: Apache-2.0
// Experimental Gen3 VC0 link layer. Whole validated RX packets arrive from
// gen3_data_rx. Eight outbound TLPs are retained until peer ACK; DLLPs may interleave
// only at packet boundaries. No reset of ownership on a physical pause.
module gen3_link_layer_x2 (
    input wire clk, reset_i, link_up_i, enable_i,
    input wire [63:0] rx_data_i,
    input wire [1:0] rx_words_i,
    input wire rx_valid_i, rx_last_i,
    output wire rx_ready_o,
    input wire [1:0] rx_class_i,
    input wire [8:0] rx_credits_i,
    input wire response_i, nak_i,
    input wire [11:0] response_sequence_i,
    input wire dllp_i,
    input wire [31:0] dllp_body_i,
    output wire [63:0] tx_data_o,
    output wire [1:0] tx_words_o,
    output wire tx_valid_o, tx_last_o,
    input wire tx_ready_i,
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
    input wire [1:0] app_tx_class_i,
    input wire [8:0] app_tx_credits_i,
    output wire [63:0] app_rx_data_o,
    output wire [1:0] app_rx_words_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i,
    output wire active_o, error_o, pending_o,
    output wire [127:0] completion_debug_o,
    input wire [4:0] pcs_profile_i,
    input wire recovery_i
);
    wire [31:0] profile_events;
    wire        profile_select = cmd_op_i == 3'd7;
    wire profile_ready, profile_valid, request_ready, request_valid;
    wire [31:0] profile_data, request_data;
    wire [2:0] profile_status, request_status;
    reg command_busy, command_profile;
    wire take_command = cmd_valid_i && cmd_ready_o;
    assign cmd_ready_o = !command_busy &&
        (profile_select ? profile_ready : (request_ready && enable_i));
    assign rsp_valid_o = command_busy && (command_profile ? profile_valid : request_valid);
    assign rsp_data_o = command_profile ? profile_data : request_data;
    assign rsp_status_o = command_profile ? profile_status : request_status;
    always @(posedge clk) begin
        if (reset_i) begin
            command_busy    <= 0;
            command_profile <= 0;
        end else begin
            if (take_command) begin
                command_busy    <= 1;
                command_profile <= profile_select;
            end
            if (rsp_valid_o && rsp_ready_i) command_busy <= 0;
        end
    end
    gen3_link_profile profile (
        clk,
        reset_i,
        profile_events,
        cmd_valid_i && !command_busy && profile_select,
        profile_ready,
        cmd_address_i,
        cmd_data_i,
        profile_valid,
        rsp_ready_i && command_busy && command_profile,
        profile_data,
        profile_status
    );
    wire [7:0] fc_type, fc_header;
    wire [11:0] fc_data;
    wire fc_valid, fc_ready, fc_credit, fc_error, reserve;
    wire [1:0] selected_class;
    wire [8:0] selected_cost;
    pcie_soft_flow_control flow (
        clk,
        !reset_i,
        link_up_i,
        enable_i,
        dllp_i && dllp_body_i[15:14] == 0 && dllp_body_i[21:20] == 0,
        dllp_body_i[7:0],
        {dllp_body_i[13:8], dllp_body_i[23:22]},
        {dllp_body_i[19:16], dllp_body_i[31:24]},
        fc_valid,
        fc_ready,
        fc_type,
        fc_header,
        fc_data,
        reserve,
        1'b0,
        selected_class,
        selected_cost,
        fc_credit,
        active_o,
        rx_valid_i && rx_ready_o && rx_last_i,
        rx_class_i,
        rx_credits_i,
        fc_error
    );
    reg ack_valid, ack_nak;
    reg [11:0] ack_sequence;
    wire body_ready;
    wire [31:0] body = ack_valid ?
        {ack_sequence[7:0], 4'b0, ack_sequence[11:8], 8'b0, ack_nak ? 8'h10 : 8'h00} :
        {fc_data[7:0], fc_header[1:0], 2'b0, fc_data[11:8], 2'b0, fc_header[7:2], fc_type};
    assign fc_ready = body_ready && !ack_valid;
    always @(posedge clk) begin
        if (reset_i) begin
            ack_valid    <= 0;
            ack_nak      <= 0;
            ack_sequence <= 12'hfff;
        end else begin
            if (ack_valid && body_ready) ack_valid <= 0;
            if (response_i) begin
                ack_valid <= 1;
                ack_sequence <= response_sequence_i;
                ack_nak <= nak_i || (ack_valid && ack_sequence == response_sequence_i && ack_nak);
            end
        end
    end
    wire [63:0] dllp_data;
    wire dllp_valid, dllp_last, dllp_ready;
    gen3_dllp_source_x2 format_dllp (
        clk,
        reset_i,
        body,
        ack_valid || fc_valid,
        body_ready,
        dllp_data,
        dllp_valid,
        dllp_last,
        dllp_ready
    );
    wire [31:0] cmd_data;
    wire [63:0] cmd_wide;
    wire [ 2:0] cmd_words;
    wire cmd_wide_valid, cmd_wide_last, cmd_wide_ready, cmd_pack_fault;
    wire [10:0] cmd_meta, unused_rx_meta;
    wire [31:0] completion_data;
    wire completion_valid, completion_last, completion_ready, completion_fault;
    wire [2:0] unused_completion_words;
    wire cmd_valid, cmd_last, cmd_ready, cmd_rx_ready;
    wire [1:0] cmd_class;
    wire [8:0] cmd_cost;
    wire request_unexpected, request_fault, confirmed, replay_fault;
    reg input_packet, input_app, cmd_pending, rx_packet, rx_completion;
    wire completion = rx_packet ? rx_completion : rx_data_i[4:0] == 5'h0a;
    // Completions may precede the confirming ACK. Hold them until requester WAIT;
    // validated storage and its ACK response remain live while output is stalled.
    wire [3:0] replay_pending, replay_sent;
    wire [11:0] acknowledged, next_sequence;
    reg  [11:0] cmd_sequence;
    wire [11:0] ack_distance = acknowledged - cmd_sequence;
    assign confirmed = cmd_pending && ack_distance < 12'd2048;
    wire completion_permit = !cmd_pending && !confirmed;
    assign rx_ready_o     = completion ? (cmd_rx_ready && completion_permit) : app_rx_ready_i;
    assign app_rx_data_o  = rx_data_i;
    assign app_rx_words_o = rx_words_i;
    assign app_rx_valid_o = rx_valid_i && !completion;
    assign app_rx_last_o  = rx_last_i;
    always @(posedge clk) begin
        if (reset_i) begin
            rx_packet     <= 0;
            rx_completion <= 0;
        end else if (rx_valid_i && rx_ready_o) begin
            rx_packet     <= !rx_last_i;
            rx_completion <= completion;
        end
    end
    reg tick;
    always @(posedge clk)
        if (reset_i) tick <= 0;
        else tick <= !tick;
    pcie_soft_requester requester (
        clk,
        !reset_i,
        active_o && (enable_i || recovery_i),
        cmd_valid_i && !command_busy && !profile_select && enable_i,
        request_ready,
        cmd_op_i,
        cmd_address_i,
        cmd_bdf_i,
        cmd_data_i,
        cmd_be_i,
        cmd_data,
        cmd_valid,
        cmd_last,
        cmd_ready,
        confirmed,
        cmd_class,
        cmd_cost,
        completion_data,
        completion_valid,
        completion_last,
        completion_ready,
        request_valid,
        rsp_ready_i && command_busy && !command_profile,
        request_data,
        request_status,
        request_unexpected,
        request_fault,
        completion_debug_o,
        tick && enable_i
    );
    pcie_packet_width #(
        .INPUT_DWORDS (1),
        .OUTPUT_DWORDS(2)
    ) command_pack (
        .clk      (clk),
        .rst_n    (!reset_i),
        .s_data_i (cmd_data),
        .s_words_i(3'd1),
        .s_meta_i ({cmd_class, cmd_cost}),
        .s_valid_i(cmd_valid),
        .s_last_i (cmd_last),
        .s_ready_o(cmd_ready),
        .m_data_o (cmd_wide),
        .m_words_o(cmd_words),
        .m_meta_o (cmd_meta),
        .m_valid_o(cmd_wide_valid),
        .m_last_o (cmd_wide_last),
        .m_ready_i(cmd_wide_ready),
        .fault_o  (cmd_pack_fault)
    );
    pcie_packet_width #(
        .INPUT_DWORDS (2),
        .OUTPUT_DWORDS(1)
    ) completion_unpack (
        .clk      (clk),
        .rst_n    (!reset_i),
        .s_data_i (rx_data_i),
        .s_words_i({1'b0, rx_words_i}),
        .s_meta_i (11'b0),
        .s_valid_i(rx_valid_i && completion && completion_permit),
        .s_last_i (rx_last_i),
        .s_ready_o(cmd_rx_ready),
        .m_data_o (completion_data),
        .m_words_o(unused_completion_words),
        .m_meta_o (unused_rx_meta),
        .m_valid_o(completion_valid),
        .m_last_o (completion_last),
        .m_ready_i(completion_ready),
        .fault_o  (completion_fault)
    );
    wire        choose_app = input_packet ? input_app : !cmd_wide_valid;
    wire [63:0] selected_data = choose_app ? app_tx_data_i : cmd_wide;
    wire [ 1:0] selected_words = choose_app ? app_tx_words_i : cmd_words[1:0];
    wire        selected_valid = choose_app ? app_tx_valid_i : cmd_wide_valid;
    wire        selected_last = choose_app ? app_tx_last_i : cmd_wide_last;
    assign selected_class = choose_app ? app_tx_class_i : cmd_meta[10:9];
    assign selected_cost  = choose_app ? app_tx_credits_i : cmd_meta[8:0];
    wire replay_ready;
    wire admission = replay_ready && (input_packet || fc_credit);
    assign app_tx_ready_o = admission && choose_app;
    assign cmd_wide_ready = admission && !choose_app;
    assign reserve        = selected_valid && admission && !input_packet;
    always @(posedge clk) begin
        if (reset_i) begin
            input_packet <= 0;
            input_app    <= 0;
            cmd_pending  <= 0;
            cmd_sequence <= 0;
        end else begin
            if (confirmed) cmd_pending <= 0;
            if (selected_valid && admission) begin
                input_packet <= !selected_last;
                input_app    <= choose_app;
                if (!input_packet && !choose_app) begin
                    cmd_pending  <= 1;
                    cmd_sequence <= next_sequence;
                end
            end
        end
    end
    wire [63:0] replay_data;
    wire [ 1:0] replay_words;
    wire replay_valid, replay_last, replay_output_ready;
    wire [11:0] replay_profile;
    gen3_tx_window_x2 replay (
        clk,
        reset_i,
        active_o && enable_i,
        selected_data,
        selected_words,
        selected_valid && (input_packet || fc_credit),
        selected_last,
        replay_ready,
        replay_data,
        replay_words,
        replay_valid,
        replay_last,
        replay_output_ready,
        dllp_i && (dllp_body_i[7:0] == 0 || dllp_body_i[7:0] == 8'h10),
        dllp_body_i[4],
        {dllp_body_i[19:16], dllp_body_i[31:24]},
        replay_pending,
        replay_sent,
        acknowledged,
        next_sequence,
        replay_fault,
        replay_profile
    );
    assign pending_o = replay_pending != 0 || input_packet;
    reg mux_locked, mux_dllp;
    wire choose_dllp = mux_locked ? mux_dllp : dllp_valid;
    assign tx_data_o           = choose_dllp ? dllp_data : replay_data;
    assign tx_words_o          = choose_dllp ? 2'd2 : replay_words;
    assign tx_valid_o          = choose_dllp ? dllp_valid : replay_valid;
    assign tx_last_o           = choose_dllp ? dllp_last : replay_last;
    assign dllp_ready          = tx_ready_i && choose_dllp;
    assign replay_output_ready = tx_ready_i && !choose_dllp;
    always @(posedge clk) begin
        if (reset_i) begin
            mux_locked <= 0;
            mux_dllp   <= 0;
        end else if (tx_valid_o) begin
            mux_locked <= !(tx_ready_i && tx_last_o);
            mux_dllp   <= choose_dllp;
        end
    end
    assign error_o = fc_error || replay_fault || request_fault || request_unexpected ||
        cmd_pack_fault || completion_fault;
    assign profile_events[0] = 1'b1;
    assign profile_events[1] = active_o;
    assign profile_events[2] = app_tx_valid_i;
    assign profile_events[3] = app_tx_valid_i && app_tx_ready_o;
    assign profile_events[4] = app_tx_valid_i && choose_app && !input_packet && !fc_credit;
    assign profile_events[5] = app_tx_valid_i && choose_app && (input_packet || fc_credit) &&
        !replay_ready;
    assign profile_events[6] = replay_pending == 8;
    assign profile_events[14:7] = replay_profile[7:0];
    assign profile_events[15] = replay_profile[8];
    assign profile_events[16] = replay_profile[9];
    assign profile_events[17] = replay_valid;
    assign profile_events[18] = replay_valid && !replay_output_ready;
    assign profile_events[19] = replay_valid && replay_output_ready;
    assign profile_events[20] = replay_profile[11];
    assign profile_events[21] = dllp_valid && dllp_ready;
    assign profile_events[22] = dllp_valid && !dllp_ready;
    assign profile_events[27:23] = pcs_profile_i;
    assign profile_events[28] = replay_pending != 0;
    assign profile_events[29] = replay_sent != 0;
    assign profile_events[30] = error_o;
    assign profile_events[31] = app_tx_valid_i && !choose_app;
    wire unused = ^{replay_profile[10], cmd_words[2], unused_rx_meta, unused_completion_words};
endmodule

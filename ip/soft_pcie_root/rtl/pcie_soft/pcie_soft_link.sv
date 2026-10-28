// Gen1/Gen2 x1 downstream port on a decoded16-bit GTH symbol interface.
// All local ports use link clk125/250MHz; host-domain CDC lives in the shell.
module pcie_soft_link #(
    parameter integer GEN2_ENABLE        = 0,
    parameter integer QUIET_CYCLES       = 1500000,
                      POLL_CYCLES        = 3000000,
                      CONFIG_CYCLES      = 250000,
    parameter integer COMPLETION_TIMEOUT = 6250000
) (
    input wire clk,
    // The shell supplies async assertion and three-edge synchronous release.
    // Native RATE alone must reset without an edge; datapath state resets on clk.
    /* verilator lint_off SYNCASYNCNET */
    input wire rst_n,
    /* verilator lint_on SYNCASYNCNET */
    input wire enable_i, phy_ready_i, rx_idle_i, detect_done_i, receiver_present_i,
    output wire detect_o, electrical_idle_o, polarity_o,
    input wire [15:0] phy_rx_data_i,
    input wire [1:0] phy_rx_ctrl_i,
    input wire phy_rx_valid_i, phy_rx_error_i,
    output wire [15:0] phy_tx_data_o,
    output wire [1:0] phy_tx_ctrl_o,
    output wire link_up_o, dl_active_o,
    output wire [4:0] state_o,
    input wire retrain_i,
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
    input wire [31:0] app_tx_data_i,
    input wire app_tx_valid_i, app_tx_last_i,
    output wire app_tx_ready_o,
    input wire [1:0] app_tx_class_i,
    input wire [8:0] app_tx_credits_i,
    output wire [31:0] app_rx_data_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i,
    output wire error_o,
    output wire [127:0] completion_debug_o,
    input wire force_gen1_i, phy_gen2_i, phy_rate_ready_i,
    output wire target_gen2_o, speed_idle_o, fallback_o, deemphasis_o
);
    wire l0, timer_hold, retrain_done, training_failed;
    wire wire_busy, serializer_idle, wire_done, serializer_overflow;

    wire [1:0] train_kind, train_sent_kind;
    wire [7:0] train_link, train_lane;
    wire train_lp, train_np, train_valid, train_done, train_boundary, train_ready;
    wire [15:0] train_data;
    wire [ 1:0] train_ctrl;
    wire ts_valid, ts2, ts_inv, ts_bad;
    wire [7:0] ts_link, ts_lane, ts_rate, ts_control;
    wire ts_lp, ts_np;
    wire [7:0] train_rate;
    wire eios_request, eios_done;
    wire       current_gen2 = GEN2_ENABLE != 0 && phy_gen2_i;
    wire       force_gen1 = GEN2_ENABLE == 0 || force_gen1_i;
    reg  [2:0] eios_word_q;
    wire       eios_active = eios_request && train_boundary && !wire_busy;
    assign eios_done = eios_active && eios_word_q == (current_gen2 ? 3'd3 : 3'd1);
    always @(posedge clk) begin
        if (!rst_n || !eios_request) eios_word_q <= 0;
        else if (eios_active) eios_word_q <= eios_word_q + 1'b1;
    end
    reg [5:0] eieos_count_q;
    reg training_seen_q, ts2_seen_q;
    wire training_state = state_o == 11 || state_o == 12 || state_o == 4;
    wire eieos_due = current_gen2 && training_state && !(
        state_o == 12 && ts2_seen_q && train_rate[7]) && (!training_seen_q || eieos_count_q >= 32);
    wire [1:0] codec_kind = eieos_due && train_boundary ? 2'd3 : train_kind;
    always @(posedge clk) begin
        if (!rst_n || !training_state) begin
            eieos_count_q   <= 0;
            training_seen_q <= 0;
            ts2_seen_q      <= 0;
        end else begin
            if (train_done && train_sent_kind == 3) begin
                training_seen_q <= 1;
                eieos_count_q   <= 0;
            end else if (train_done && eieos_count_q < 32) eieos_count_q <= eieos_count_q + 1'b1;
            if (state_o == 12 && ts_valid && ts2 && !ts2_seen_q) begin
                ts2_seen_q    <= 1;
                eieos_count_q <= 0;
            end
        end
    end
    wire [15:0] decoded;
    wire [1:0] decoded_ctrl, decoded_keep;
    wire decoded_valid;
    wire [15:0] unused_tx_state, unused_rx_state;
    wire unused_tx_ready, unused_tx_valid, unused_rx_ready;
    wire [1:0] unused_tx_keep;
    wire skp_start, skp_active;
    reg         skp_tail_q;
    reg  [10:0] skp_count_q;
    wire        replay_retrain;
    wire [15:0] serial_symbols;
    wire [ 1:0] serial_control;
    wire        rx_idle_pair = decoded_valid && decoded == 0 && decoded_ctrl == 0;
    wire        tx_idle_pair = !wire_busy && !train_valid && !skp_active;
    pcie_soft_ltssm #(
        .GEN2_ENABLE  (GEN2_ENABLE),
        .QUIET_CYCLES (QUIET_CYCLES),
        .POLL_CYCLES  (POLL_CYCLES),
        .CONFIG_CYCLES(CONFIG_CYCLES)
    ) ltssm (
        clk,
        rst_n,
        enable_i,
        phy_ready_i,
        rx_idle_i,
        detect_done_i,
        receiver_present_i,
        detect_o,
        electrical_idle_o,
        (retrain_i || replay_retrain) && !retrain_done,
        retrain_done,
        ts_valid,
        ts2,
        ts_inv,
        ts_bad,
        ts_link,
        ts_lane,
        ts_rate,
        ts_control,
        ts_lp,
        ts_np,
        train_done,
        train_sent_kind,
        rx_idle_pair,
        tx_idle_pair,
        phy_rx_error_i,
        train_kind,
        train_link,
        train_lane,
        train_lp,
        train_np,
        link_up_o,
        l0,
        timer_hold,
        polarity_o,
        training_failed,
        state_o,
        force_gen1,
        current_gen2,
        phy_rate_ready_i,
        eios_done,
        train_rate,
        eios_request,
        speed_idle_o,
        target_gen2_o,
        fallback_o,
        deemphasis_o
    );
    pcie_soft_training training (
        clk,
        rst_n,
        train_ready,
        codec_kind,
        train_link,
        train_lane,
        8'b0,
        train_lp,
        train_np,
        train_data,
        train_ctrl,
        train_valid,
        train_done,
        train_boundary,
        train_sent_kind,
        phy_rx_data_i,
        phy_rx_ctrl_i,
        phy_rx_valid_i,
        phy_rx_error_i,
        ts_valid,
        ts2,
        ts_inv,
        ts_bad,
        ts_link,
        ts_lane,
        ts_rate,
        ts_control,
        ts_lp,
        ts_np,
        train_rate
    );
    assign skp_start = !skp_tail_q && skp_count_q >= 1200 && !wire_busy && train_boundary &&
        !electrical_idle_o && !eios_request;
    assign skp_active = skp_start || skp_tail_q;
    assign train_ready = !wire_busy && !skp_active && !eios_active;
    always @(posedge clk) begin
        if (!rst_n || electrical_idle_o) begin
            skp_count_q <= 0;
            skp_tail_q  <= 0;
        end else if (skp_start) skp_tail_q <= 1;
        else if (skp_tail_q) begin
            skp_tail_q  <= 0;
            skp_count_q <= 0;
        end else if (skp_count_q < 1600) skp_count_q <= skp_count_q + 2;
    end
    wire [15:0]
        tx_symbols = eios_active ? (eios_word_q[0] ? 16'h7c7c : 16'h7cbc) : skp_start ? 16'h1cbc :
        skp_tail_q ? 16'h1c1c : wire_busy ? serial_symbols : train_valid ? train_data : 16'b0;
    wire [1:0] tx_control = eios_active ? 2'b11 :
        skp_active ? 2'b11 : wire_busy ? serial_control : train_valid ? train_ctrl : 2'b0;
    pcie_soft_scrambler tx_scramble (
        clk,
        rst_n,
        tx_symbols,
        tx_control,
        2'b11,
        train_valid && !wire_busy ? 2'b00 : 2'b11,
        1'b1,
        unused_tx_ready,
        phy_tx_data_o,
        phy_tx_ctrl_o,
        unused_tx_keep,
        unused_tx_valid,
        1'b1,
        unused_tx_state
    );
    // A COM followed by SKP is a SKP set; other COM sequences contain 15
    // unscrambled training symbols. Identification is on raw decoded K codes.
    reg [4:0] rx_training_q, rx_training_next;
    reg     [1:0] rx_xor;
    integer       j;
    always @* begin
        rx_training_next = rx_training_q;
        rx_xor           = 0;
        for (j = 0; j < 2; j = j + 1) begin
            if (phy_rx_valid_i) begin
                if (phy_rx_ctrl_i[j] && phy_rx_data_i[j*8+:8] == 8'hbc) rx_training_next = 15;
                else if (phy_rx_ctrl_i[j] && phy_rx_data_i[j*8+:8] == 8'h1c) rx_training_next = 0;
                else if (rx_training_next != 0) rx_training_next = rx_training_next - 1'b1;
                else rx_xor[j] = 1;
            end
        end
    end
    always @(posedge clk)
        if (!rst_n) rx_training_q <= 0;
        else rx_training_q <= rx_training_next;
    pcie_soft_scrambler rx_descramble (
        clk,
        rst_n,
        phy_rx_data_i,
        phy_rx_ctrl_i,
        2'b11,
        rx_xor,
        phy_rx_valid_i,
        unused_rx_ready,
        decoded,
        decoded_ctrl,
        decoded_keep,
        decoded_valid,
        1'b1,
        unused_rx_state
    );
    reg rx_error_q;
    always @(posedge clk) rx_error_q <= phy_rx_error_i;
    wire [31:0] rx_tlp, rx_dllp;
    wire rx_tlp_valid, rx_tlp_last, rx_tlp_ready, rx_response, rx_nak, rx_dllp_valid,
        rx_packet_error;
    wire [11:0] rx_response_seq;
    wire [ 1:0] rx_class;
    wire [ 8:0] rx_credits;
    pcie_soft_packet_rx receiver (
        clk,
        rst_n,
        !link_up_o,
        decoded,
        decoded_ctrl,
        decoded_valid && link_up_o,
        rx_error_q,
        rx_tlp,
        rx_tlp_valid,
        rx_tlp_last,
        rx_tlp_ready,
        rx_class,
        rx_credits,
        rx_response,
        rx_nak,
        rx_response_seq,
        rx_dllp_valid,
        rx_dllp,
        rx_packet_error
    );
    wire [7:0] fc_type, fc_header;
    wire [11:0] fc_data;
    wire fc_dllp_valid, fc_dllp_ready, fc_ready, fc_error, fc_reserve;
    wire [1:0] selected_class;
    wire [8:0] selected_cost;
    pcie_soft_flow_control flow (
        clk,
        rst_n,
        link_up_o,
        l0,
        rx_dllp_valid,
        rx_dllp[7:0],
        {rx_dllp[13:8], rx_dllp[23:22]},
        {rx_dllp[19:16], rx_dllp[31:24]},
        fc_dllp_valid,
        fc_dllp_ready,
        fc_type,
        fc_header,
        fc_data,
        fc_reserve,
        1'b0,
        selected_class,
        selected_cost,
        fc_ready,
        dl_active_o,
        rx_tlp_valid && rx_tlp_ready && rx_tlp_last,
        rx_class,
        rx_credits,
        fc_error
    );
    reg tx_ack_valid_q, tx_ack_nak_q;
    reg [11:0] tx_ack_seq_q;
    wire tx_dllp_ready;
    wire choose_ack = tx_ack_valid_q;
    wire [31:0] tx_dllp = choose_ack ?
        {tx_ack_seq_q[7:0], 4'b0, tx_ack_seq_q[11:8], 8'b0, tx_ack_nak_q ? 8'h10 : 8'h00} :
        {fc_data[7:0], fc_header[1:0], 2'b0, fc_data[11:8], 2'b0, fc_header[7:2], fc_type};
    assign fc_dllp_ready = tx_dllp_ready && !choose_ack;
    always @(posedge clk) begin
        if (!rst_n || !link_up_o) begin
            tx_ack_valid_q <= 0;
            tx_ack_nak_q   <= 0;
            tx_ack_seq_q   <= 12'hfff;
        end else begin
            if (choose_ack && tx_dllp_ready) tx_ack_valid_q <= 0;
            if (rx_response) begin
                tx_ack_valid_q <= 1;
                tx_ack_seq_q <= rx_response_seq;
                tx_ack_nak_q <= rx_nak ||
                    (tx_ack_valid_q && tx_ack_seq_q == rx_response_seq && tx_ack_nak_q);
            end
        end
    end
    wire [31:0] cmd_tlp;
    wire cmd_tlp_valid, cmd_tlp_last, cmd_tlp_ready, cmd_sent, cmd_rx_ready, request_error,
        request_fault;
    wire [1:0] cmd_class;
    wire [8:0] cmd_cost;
    reg rx_packet_q, rx_completion_q;
    wire rx_is_completion = rx_packet_q ? rx_completion_q : rx_tlp[4:0] == 5'h0a;
    assign app_rx_data_o  = rx_tlp;
    assign app_rx_valid_o = rx_tlp_valid && !rx_is_completion;
    assign app_rx_last_o  = rx_tlp_last;
    assign rx_tlp_ready   = rx_is_completion ? cmd_rx_ready : app_rx_ready_i;
    always @(posedge clk) begin
        if (!rst_n || !link_up_o) begin
            rx_packet_q     <= 0;
            rx_completion_q <= 0;
        end else if (rx_tlp_valid && rx_tlp_ready) begin
            rx_packet_q     <= !rx_tlp_last;
            rx_completion_q <= rx_is_completion;
        end
    end
    reg timeout_phase_q;
    always @(posedge clk)
        if (!rst_n) timeout_phase_q <= 0;
        else timeout_phase_q <= !timeout_phase_q;
    wire requester_tick = !timer_hold && (!current_gen2 || timeout_phase_q);
    pcie_soft_requester #(
        .COMPLETION_TIMEOUT(COMPLETION_TIMEOUT)
    ) requester (
        clk,
        rst_n,
        dl_active_o,
        cmd_valid_i,
        cmd_ready_o,
        cmd_op_i,
        cmd_address_i,
        cmd_bdf_i,
        cmd_data_i,
        cmd_be_i,
        cmd_tlp,
        cmd_tlp_valid,
        cmd_tlp_last,
        cmd_tlp_ready,
        cmd_sent,
        cmd_class,
        cmd_cost,
        rx_tlp,
        rx_tlp_valid && rx_is_completion,
        rx_tlp_last,
        cmd_rx_ready,
        rsp_valid_o,
        rsp_ready_i,
        rsp_data_o,
        rsp_status_o,
        request_error,
        request_fault,
        completion_debug_o,
        requester_tick
    );
    reg input_packet_q, input_app_q;
    wire        selected_app = input_packet_q ? input_app_q : !cmd_tlp_valid;
    wire [31:0] selected_data = selected_app ? app_tx_data_i : cmd_tlp;
    wire        selected_valid = selected_app ? app_tx_valid_i : cmd_tlp_valid;
    wire        selected_last = selected_app ? app_tx_last_i : cmd_tlp_last;
    assign selected_class = selected_app ? app_tx_class_i : cmd_class;
    assign selected_cost  = selected_app ? app_tx_credits_i : cmd_cost;
    wire replay_input_ready;
    wire admission_ready = replay_input_ready && (input_packet_q || fc_ready);
    assign cmd_tlp_ready  = admission_ready && !selected_app;
    assign app_tx_ready_o = admission_ready && selected_app;
    assign fc_reserve     = selected_valid && admission_ready && !input_packet_q;
    wire [11:0] next_sequence, acknowledged, replay_sequence;
    reg owner[0:7];
    always @(posedge clk) begin
        if (selected_valid && admission_ready && !input_packet_q)
            owner[next_sequence[2:0]] <= selected_app;
        if (!rst_n || !link_up_o) begin
            input_packet_q <= 0;
            input_app_q    <= 0;
        end else if (selected_valid && admission_ready) begin
            input_packet_q <= !selected_last;
            input_app_q    <= selected_app;
        end
    end
    wire captured_valid, captured_ready, captured_nak, ack_error;
    wire [11:0] captured_seq;
    wire [15:0] captured_age;
    wire [3:0] replay_pending, replay_sent;
    pcie_soft_ack_capture capture (
        clk,
        rst_n,
        !link_up_o,
        rx_dllp_valid && (rx_dllp[7:0] == 0 || rx_dllp[7:0] == 8'h10),
        rx_dllp[4],
        {rx_dllp[19:16], rx_dllp[31:24]},
        acknowledged,
        {7'b0, replay_sent},
        captured_valid,
        captured_ready,
        captured_nak,
        captured_seq,
        captured_age,
        ack_error
    );
    wire [31:0] replay_data;
    wire replay_valid, replay_last, replay_is_replay, replay_ready;
    wire replay_error, replay_overflow, replaying, replay_event, timeout_event;
    wire [ 7:0] unused_profile;
    reg         wire_done_q;
    wire [11:0] wire_sequence;
    wire        wire_is_replay;
    always @(posedge clk)
        if (!rst_n) wire_done_q <= 0;
        else wire_done_q <= wire_done;
    assign cmd_sent = wire_done_q && !wire_is_replay && !owner[wire_sequence[2:0]];
    pcie_soft_replay replay_store (
        .clk                (clk),
        .rst_n              (rst_n),
        .link_reset_i       (!link_up_o),
        .enable_i           (dl_active_o),
        .s_data_i           (selected_data),
        .s_valid_i          (selected_valid && (input_packet_q || fc_ready)),
        .s_last_i           (selected_last),
        .s_ready_o          (replay_input_ready),
        .m_data_o           (replay_data),
        .m_valid_o          (replay_valid),
        .m_last_o           (replay_last),
        .m_sequence_o       (replay_sequence),
        .m_replay_o         (replay_is_replay),
        .m_ready_i          (replay_ready),
        .wire_sequence_o    (wire_sequence),
        .wire_replay_o      (wire_is_replay),
        .tx_allow_i         (l0),
        .tx_wire_done_i     (wire_done_q),
        .phy_hold_i         (timer_hold),
        .retrain_done_i     (retrain_done),
        .response_valid_i   (captured_valid),
        .response_ready_o   (captured_ready),
        .response_nak_i     (captured_nak),
        .response_sequence_i(captured_seq),
        .response_age_i     (captured_age),
        .pending_o          (replay_pending),
        .sent_o             (replay_sent),
        .replaying_o        (replaying),
        .acknowledged_o     (acknowledged),
        .next_sequence_o    (next_sequence),
        .recovery_req_o     (replay_retrain),
        .response_error_o   (replay_error),
        .overflow_o         (replay_overflow),
        .replay_event_o     (replay_event),
        .timeout_event_o    (timeout_event),
        .profile_events_o   (unused_profile)
    );
    pcie_soft_packet_tx transmitter (
        clk,
        rst_n && link_up_o,
        !l0 || skp_active || train_valid,
        replay_data,
        replay_valid,
        replay_last,
        replay_ready,
        replay_sequence,
        tx_ack_valid_q || fc_dllp_valid,
        tx_dllp_ready,
        tx_dllp,
        serial_symbols,
        serial_control,
        wire_done,
        serializer_idle,
        wire_busy,
        serializer_overflow
    );
    assign error_o = training_failed || request_error || request_fault || ack_error || fc_error ||
        rx_packet_error || replay_error || replay_overflow || serializer_overflow;
    wire unused_debug = ^{unused_profile, wire_sequence[11:3], rx_dllp[21:20], rx_dllp[15:14],
                          next_sequence[11:3], decoded_keep, replay_pending, replay_is_replay,
                          replaying, replay_event, timeout_event, serializer_idle};
endmodule

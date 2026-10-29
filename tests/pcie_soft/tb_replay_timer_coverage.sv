// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module tb_replay_timer_coverage;
    parameter integer HALF_PERIOD = 4;
    parameter integer TIMEOUT = 32;
    parameter integer ACK_EDGE = 0;
    parameter integer WORDS = 8;
    parameter integer SEED = 32'h631ba421;
    localparam integer D = 4, W = WORDS;
    reg clk = 0;
    always #(HALF_PERIOD) clk = ~clk;
    reg rst_n = 0, link_reset = 0, enable = 1, tx_allow = 0, retrain_done = 0, phy_hold = 0;
    reg [31:0] s_data = 0;
    reg s_valid = 0, s_last = 0;
    wire        s_ready;
    wire [31:0] m_data;
    wire m_valid, m_last, m_replay;
    wire [11:0] m_seq;
    reg allow_ready = 1, random_ready = 0;
    reg  [31:0] noise = SEED;
    wire        m_ready = allow_ready && (!random_ready || noise[0] || noise[3]);
    reg rsp_valid = 0, rsp_nak = 0;
    reg  [11:0] rsp_seq = 0;
    wire        rsp_ready;
    wire [2:0] pending, sent;
    wire replaying, recovery, rsp_error, overflow, replay_event, timeout_event;
    pcie_soft_replay #(
        .DEPTH                (D),
        .MAX_DWORDS           (W),
        .REPLAY_TIMEOUT_CYCLES(TIMEOUT),
        .MAX_REPLAYS          (3)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .link_reset_i       (link_reset),
        .enable_i           (enable),
        .s_data_i           (s_data),
        .s_valid_i          (s_valid),
        .s_last_i           (s_last),
        .s_ready_o          (s_ready),
        .m_data_o           (m_data),
        .m_valid_o          (m_valid),
        .m_last_o           (m_last),
        .m_sequence_o       (m_seq),
        .m_replay_o         (m_replay),
        .m_ready_i          (m_ready),
        .tx_allow_i         (tx_allow),
        .tx_wire_done_i     (m_valid && m_ready && m_last),
        .phy_hold_i         (phy_hold),
        .retrain_done_i     (retrain_done),
        .response_age_i     (16'b0),
        .response_valid_i   (rsp_valid),
        .response_ready_o   (rsp_ready),
        .response_nak_i     (rsp_nak),
        .response_sequence_i(rsp_seq),
        .pending_o          (pending),
        .sent_o             (sent),
        .replaying_o        (replaying),
        .recovery_req_o     (recovery),
        .response_error_o   (rsp_error),
        .overflow_o         (overflow),
        .replay_event_o     (replay_event),
        .timeout_event_o    (timeout_event)
    );
    integer        expected_words[0:4095];
    reg     [31:0] expected_base [0:4095];
    reg            was_sent      [0:4095];
    reg [11:0] input_sequence = 0, first_sequence = 0, active_sequence;
    reg active_replay;
    integer out_word = 0, tx_packets = 0, new_packets = 0, replay_packets = 0;
    integer error_count = 0, overflow_count = 0, replay_count = 0, timeout_count = 0;
    integer i, j, goal, errors_before, retained_packets;
    reg        stalled = 0;
    reg [45:0] held_output;

    always @(negedge clk) noise <= {noise[30:0], noise[31] ^ noise[21] ^ noise[1] ^ noise[0]};

    // Packet-level scoreboard: data and ordering, independent of RAM/FSM latency.
    always @(posedge clk) begin
        if (!rst_n || link_reset) begin
            out_word       = 0;
            tx_packets     = 0;
            new_packets    = 0;
            replay_packets = 0;
            error_count    = 0;
            overflow_count = 0;
            replay_count   = 0;
            timeout_count  = 0;
            first_sequence = 0;
            stalled        = 0;
            for (integer k = 0; k < 4096; k = k + 1) was_sent[k] = 0;
        end else begin
            if (pending > D || sent > pending) $fatal(1, "Ownership/credit bound");
            if (stalled && (!m_valid || {m_data, m_last, m_seq, m_replay} !== held_output))
                $fatal(1, "Output changed under backpressure");
            stalled     = m_valid && !m_ready;
            held_output = {m_data, m_last, m_seq, m_replay};
            if (m_valid && m_ready) begin
                if (out_word == 0) begin
                    active_sequence = m_seq;
                    active_replay   = m_replay;
                    if (m_replay && !was_sent[m_seq]) $fatal(1, "Replayed unsent sequence");
                    if (!m_replay && m_seq !== first_sequence)
                        $fatal(1, "New packet order %0d expected %0d", m_seq, first_sequence);
                end
                if (m_seq !== active_sequence || m_replay !== active_replay)
                    $fatal(1, "Packet metadata changed");
                if (m_data !== expected_base[m_seq] + 32'(out_word))
                    $fatal(
                        1, "Payload mismatch seq %0d word %0d got %08x", m_seq, out_word, m_data
                    );
                if (m_last !== (out_word == expected_words[m_seq] - 1))
                    $fatal(1, "Packet length mismatch");
                if (m_last) begin
                    tx_packets      = tx_packets + 1;
                    was_sent[m_seq] = 1;
                    if (m_replay) replay_packets = replay_packets + 1;
                    else begin
                        new_packets    = new_packets + 1;
                        first_sequence = first_sequence + 12'd1;
                    end
                    out_word = 0;
                end else out_word = out_word + 1;
            end
            #0.1;
            if (rsp_error) error_count = error_count + 1;
            if (overflow) overflow_count = overflow_count + 1;
            if (replay_event) replay_count = replay_count + 1;
            if (timeout_event) timeout_count = timeout_count + 1;
        end
    end

    task automatic cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task automatic word(input reg [31:0] value, input reg last);
        @(negedge clk);
        s_data  = value;
        s_last  = last;
        s_valid = 1;
        do begin
            @(posedge clk);
        end while (!s_ready);
        @(negedge clk);
        s_valid = 0;
    endtask
    task automatic packet(input integer length, input reg [31:0] base);
        integer n;
        begin
            expected_words[input_sequence] = length;
            expected_base[input_sequence]  = base;
            for (n = 0; n < length; n = n + 1) word(base + 32'(n), n == length - 1);
            if (length <= W) input_sequence = input_sequence + 12'd1;
        end
    endtask
    task automatic response(input reg nak, input reg [11:0] seq);
        @(negedge clk);
        rsp_nak   = nak;
        rsp_seq   = seq;
        rsp_valid = 1;
        do begin
            @(posedge clk);
        end while (!rsp_ready);
        @(negedge clk);
        rsp_valid = 0;
        cycles(1);
    endtask
    task automatic wait_packets(input integer target);
        integer n;
        begin
            n = 0;
            while (tx_packets < target && n < 10000) begin
                cycles(1);
                n = n + 1;
            end
            if (tx_packets != target)
                $fatal(1, "Expected %0d packets, got %0d", target, tx_packets);
        end
    endtask
    task automatic reset_link;
        @(negedge clk);
        link_reset = 1;
        s_valid    = 0;
        rsp_valid  = 0;
        cycles(2);
        @(negedge clk);
        link_reset     = 0;
        input_sequence = 0;
        cycles(1);
        if (pending !== 0 || sent !== 0 || recovery) $fatal(1, "Reset left valid ownership");
    endtask

    integer tick;
    initial begin
        cycles(3);
        @(negedge clk);
        rst_n = 1;
        packet(3, 32'habcd0000);
        cycles(TIMEOUT + 5);
        if (replay_count || timeout_count || sent != 0 || pending != 1)
            $fatal(1, "Unsent packet started replay timer");
        @(negedge clk);
        tx_allow = 1;
        wait_packets(1);
        // Freeze immediately after the original's final wire handshake.
        @(negedge clk);
        phy_hold = 1;
        cycles(TIMEOUT + 5);
        if (replay_count || timeout_count || sent != 1 || pending != 1)
            $fatal(1, "PHY hold advanced timer or lost ownership");
        @(negedge clk);
        phy_hold = 0;
        for (tick = 1; tick <= TIMEOUT + 1; tick = tick + 1) begin
            // ACK_EDGE selects expiry or the following service edge.
            if (ACK_EDGE != 0 && tick == TIMEOUT + ACK_EDGE - 1) begin
                rsp_valid = 1;
                rsp_seq   = 0;
                rsp_nak   = 0;
                if (!rsp_ready) $fatal(1, "Normal ACK stalled at boundary");
            end
            cycles(1);
            if (tick <= TIMEOUT && (timeout_count || replay_count))
                $fatal(1, "Early replay tick=%0d", tick);
            @(negedge clk);
            rsp_valid = 0;
        end
        if (ACK_EDGE == 0) begin
            if (timeout_count != 1 || replay_count != 1 || pending != 1 || sent != 1)
                $fatal(1, "Replay deadline or ownership mismatch");
            wait_packets(2);
            if (replay_packets != 1) $fatal(1, "Timeout did not replay original");
            response(0, 0);
        end else if (timeout_count || replay_count)
            $fatal(1, "Retired packet replayed on expiry edge");
        cycles(TIMEOUT + 5);
        if (pending || sent || recovery || rsp_error || overflow)
            $fatal(1, "ACK did not retire replay ownership cleanly");
        $display("PASS replay deadline T=%0d ACK_EDGE=%0d HALF_PERIOD=%0d", TIMEOUT, ACK_EDGE,
                 HALF_PERIOD);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Replay boundary watchdog");
    end
endmodule

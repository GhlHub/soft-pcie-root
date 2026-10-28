`timescale 1ns / 1ps
// Ideal-source Gen2 TX service ceiling, not a PCIe link/SSD model.
// Uses production replay+serializer and the production wire-done register.
module tb_completion_tx_profile #(
    parameter integer ACK_EVERY = 1
);
    reg clk = 0;
    always #2 clk = ~clk;
    reg        rst = 0;
    reg [31:0] sdata = 0;
    reg sv = 0, sl = 0;
    wire        sr;
    wire [31:0] data;
    wire valid, last, ready, is_replay;
    wire [11:0] seq;
    wire [11:0] wire_seq;
    wire        wire_replay;
    wire        wire_done;
    reg done_q = 0, ack_valid = 0;
    reg  [11:0] ack_seq = 0;
    wire        ack_ready;
    wire error, overflow, recovery, replay_event, timeout_event, serializer_overflow;
    wire [3:0] pending, sent;
    pcie_soft_replay replay_store (
        .clk                (clk),
        .rst_n              (rst),
        .link_reset_i       (1'b0),
        .enable_i           (1'b1),
        .s_data_i           (sdata),
        .s_valid_i          (sv),
        .s_last_i           (sl),
        .s_ready_o          (sr),
        .m_data_o           (data),
        .m_valid_o          (valid),
        .m_last_o           (last),
        .m_sequence_o       (seq),
        .m_replay_o         (is_replay),
        .m_ready_i          (ready),
        .wire_sequence_o    (wire_seq),
        .wire_replay_o      (wire_replay),
        .tx_allow_i         (1'b1),
        .tx_wire_done_i     (done_q),
        .phy_hold_i         (1'b0),
        .retrain_done_i     (1'b0),
        .response_valid_i   (ack_valid),
        .response_ready_o   (ack_ready),
        .response_nak_i     (1'b0),
        .response_sequence_i(ack_seq),
        .response_age_i     (16'b0),
        .pending_o          (pending),
        .sent_o             (sent),
        .recovery_req_o     (recovery),
        .response_error_o   (error),
        .overflow_o         (overflow),
        .replay_event_o     (replay_event),
        .timeout_event_o    (timeout_event)
    );
    pcie_soft_packet_tx transmitter (
        .clk          (clk),
        .rst_n        (rst),
        .hold_i       (1'b0),
        .tlp_data_i   (data),
        .tlp_valid_i  (valid),
        .tlp_last_i   (last),
        .tlp_ready_o  (ready),
        .sequence_i   (seq),
        .dllp_valid_i (1'b0),
        .dllp_body_i  (32'b0),
        .packet_done_o(wire_done),
        .overflow_o   (serializer_overflow)
    );
    function [31:0] word(input integer packet, index);
        case (index)
            0: word = 32'h1000004a;  // CplD 16 DWORD payload, wire byte order.
            1: word = 32'h40000000;
            2: word = 32'h00000001;
            default: word = 32'(packet * 32 + index);
        endcase
    endfunction
    integer cycle = 0, completed = 0, start_cycle = 0, rx_packet = 0, rx_word = 0;
    integer read_cycles = 0, offer_cycles = 0, wire_cycles = 0, idle_cycles = 0, serial_cycles = 0;
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!rst) begin
            done_q    <= 0;
            ack_valid <= 0;
        end else begin
            done_q <= wire_done;
            if (ack_valid && ack_ready) ack_valid <= 0;
            if (done_q && completed % ACK_EVERY == 0) begin
                // Cumulative progress replaces an older ACK while the pipeline drains,
                // as in production pcie_soft_ack_capture.
                ack_valid <= 1;
                ack_seq   <= wire_seq;
            end
            if (error || overflow || recovery || replay_event || timeout_event ||
                serializer_overflow || is_replay)
                $fatal(1, "Unexpected TX/replay failure");
            if (sent > pending || pending > 8) $fatal(1, "Replay ownership");
            if (valid && ready) begin
                if (data !== word(
                        rx_packet, rx_word
                    ) || seq != rx_packet || last != (rx_word == 18))
                    $fatal(1, "TX payload/order");
                if (last) begin
                    rx_packet = rx_packet + 1;
                    rx_word   = 0;
                end else rx_word = rx_word + 1;
            end
            if (completed >= 16 && completed < 1000) begin
                case (replay_store.tx_state_q)
                    0: idle_cycles = idle_cycles + 1;
                    1: read_cycles = read_cycles + 1;
                    2: offer_cycles = offer_cycles + 1;
                    3: wire_cycles = wire_cycles + 1;
                endcase
                if (transmitter.transmitting_o) serial_cycles = serial_cycles + 1;
            end
            if (wire_done) begin
                completed = completed + 1;
                if (completed == 16) start_cycle = cycle;
                if (completed == 1000) begin
                    $display(
                        "PROFILE_TX packets=984 cycles=%0d cycles_per_packet=%0f payload_MB_s=%0f replay_read=%0d replay_offer=%0d replay_wire=%0d replay_idle=%0d serial=%0d",
                        cycle - start_cycle, real'(cycle - start_cycle) / 984.0,
                        984.0 * 64.0 * 250.0 / real'(cycle - start_cycle), read_cycles,
                        offer_cycles, wire_cycles, idle_cycles, serial_cycles);
                    $display(
                        "PASS COMPLETION TX: ideal source, bounded cumulative ACKs, no DLLP/SKP/credit stalls; checked payload/sequence"
                            );
                    $finish;
                end
            end
        end
    end
    initial begin
        repeat (4) @(negedge clk);
        rst = 1;
        for (integer p = 0; p < 1000; p = p + 1)
        for (integer w = 0; w < 19; w = w + 1) begin
            @(negedge clk);
            sdata = word(p, w);
            sv    = 1;
            sl    = w == 18;
            do @(posedge clk); while (!sr);
        end
        @(negedge clk);
        sv = 0;
        sl = 0;
    end
    initial begin
        #1000000;
        $fatal(1, "TX profile timeout");
    end
endmodule

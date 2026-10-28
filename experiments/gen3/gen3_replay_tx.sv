// SPDX-License-Identifier: Apache-2.0
// Conservative single-packet replay ownership. Payload remains until a validated
// peer ACK proves receipt; native PCS submission alone NEVER retires ownership.
// Fatal/recovery quarantine retains RAM and metadata. Cold reset only.
module gen3_replay_tx #(
    parameter integer WORDS         = 64,
                      REPLAY_CYCLES = 384
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
    output reg confirmed_o, retry_o, fault_o,
    output wire pending_o,
    output wire [11:0] sequence_o
);
    localparam integer W = $clog2(WORDS), T = $clog2(REPLAY_CYCLES + 1);
    (* ram_style="distributed" *) reg [31:0] memory[0:WORDS-1];
    reg [W:0] written, length, index_q;
    reg full, sent, submitted, sending, ack_pending, retry_pending;
    reg [11:0] sequence_q;
    reg [31:0] crc, lcrc;
    reg  [T-1:0] timer;
    reg  [  1:0] retries;
    wire [ 31:0] stp;
    wire unused_stp, unused_eds;
    wire [10:0] unused_length;
    wire [11:0] unused_sequence;
    gen3_stp token (
        11'(length) + 11'd2,
        sequence_q,
        stp,
        32'b0,
        unused_stp,
        unused_eds,
        unused_length,
        unused_sequence
    );
    function automatic [31:0] crc_byte(input [31:0] old, input [7:0] value);
        reg [31:0] c;
        begin
            c = old;
            for (integer b = 0; b < 8; b = b + 1)
            c = (c >> 1) ^ ((c[0] ^ value[b]) ? 32'hedb88320 : 0);
            crc_byte = c;
        end
    endfunction
    wire [31:0] seed = written == 0 ? crc_byte(
        crc_byte(32'hffffffff, {4'b0, sequence_q[11:8]}), sequence_q[7:0]
    ) : crc;
    wire [31:0] next_crc = crc_byte(
        crc_byte(crc_byte(crc_byte(seed, data_i[7:0]), data_i[15:8]), data_i[23:16]), data_i[31:24]
    );
    wire transfer = valid_o && ready_i;
    wire last_transfer = transfer && last_o;
    wire ack_current = response_i && response_sequence_i == sequence_q && full && submitted;
    wire nak_previous = response_i && nak_i && response_sequence_i == sequence_q - 1'b1 && full &&
        sent;
    assign pending_o = full || written != 0;
    assign sequence_o = sequence_q;
    assign ready_o = !reset_i && !fault_o && !full && written < (W + 1)'(WORDS) &&
        (enable_i || written != 0);
    assign valid_o = full && !sent && (!ack_pending || sending) && (!fault_o || sending) &&
        (enable_i || sending);
    assign last_o = index_q == length + 1'b1;
    assign data_o = index_q == 0 ? stp : last_o ? lcrc : memory[W'(index_q-1'b1)];
    always @(posedge clk) begin
        if (reset_i) begin
            written       <= 0;
            length        <= 0;
            index_q       <= 0;
            full          <= 0;
            sent          <= 0;
            submitted     <= 0;
            sending       <= 0;
            ack_pending   <= 0;
            retry_pending <= 0;
            sequence_q    <= 0;
            crc           <= 0;
            lcrc          <= 0;
            timer         <= 0;
            retries       <= 0;
            confirmed_o   <= 0;
            retry_o       <= 0;
            fault_o       <= 0;
        end else begin
            confirmed_o <= 0;
            retry_o     <= 0;
            if (valid_i && ready_o) begin
                memory[W'(written)] <= data_i;
                crc                 <= next_crc;
                if (last_i) begin
                    full    <= 1;
                    length  <= written + 1'b1;
                    written <= 0;
                    lcrc    <= ~next_crc;
                    index_q <= 0;
                end else if (written == (W + 1)'(WORDS - 1)) begin
                    written <= written + 1'b1;
                    fault_o <= 1;
                end else written <= written + 1'b1;
            end
            if (transfer) begin
                sending <= !last_o;
                if (last_o) begin
                    index_q   <= 0;
                    sent      <= 1;
                    submitted <= 1;
                    timer     <= 0;
                end else index_q <= index_q + 1'b1;
            end
            // ACKs arriving during a retransmission cannot truncate that frame.
            if (ack_current) ack_pending <= 1;
            if (response_i && !ack_current && !nak_previous &&
                response_sequence_i != sequence_q - 1'b1)
                fault_o <= 1;
            if (nak_previous) retry_pending <= 1;
            if (full && sent && enable_i && !fault_o && !ack_pending) begin
                if (timer == T'(REPLAY_CYCLES - 1)) retry_pending <= 1;
                else timer <= timer + 1'b1;
            end
            if (ack_pending && !sending && !transfer && !fault_o) begin
                full          <= 0;
                sent          <= 0;
                submitted     <= 0;
                ack_pending   <= 0;
                retry_pending <= 0;
                timer         <= 0;
                retries       <= 0;
                sequence_q    <= sequence_q + 1'b1;
                confirmed_o   <= 1;
            end else if (retry_pending && sent && !sending && !ack_current && !ack_pending &&
                         !fault_o) begin
                if (retries == 3) fault_o <= 1;
                else begin
                    retries       <= retries + 1'b1;
                    sent          <= 0;
                    retry_pending <= 0;
                    timer         <= 0;
                    index_q       <= 0;
                    retry_o       <= 1;
                end
            end
            // No local reset on enable loss; a partial/accepted bank survives.
        end
    end
    wire unused = ^{unused_stp, unused_eds, unused_length, unused_sequence, last_transfer};
`ifndef SYNTHESIS
    initial
        if (WORDS < 36 || (WORDS & (WORDS - 1)) != 0 || REPLAY_CYCLES < 8)
            $fatal(1, "Invalid replay geometry");
`endif
endmodule

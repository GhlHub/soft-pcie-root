// Lossless cumulative ACK/NAK coalescing at validated DLLP arrival rate.
// Input has no READY. Newer cumulative progress supersedes older events;
// equal-sequence NAK remains effective until later forward progress.
module pcie_soft_ack_capture (
    input wire clk, rst_n, link_reset_i,
    input wire event_i, nak_i,
    input wire [11:0] sequence_i, acknowledged_i,
    input wire [10:0] sent_i,
    output wire valid_o,
    input wire ready_i,
    output wire nak_o,
    output wire [11:0] sequence_o,
    output wire [15:0] age_o,
    output reg protocol_error_o
);
    reg valid_q, nak_q;
    reg [11:0] sequence_q;
    reg [31:0] clock_q, stamp_q;
    wire [11:0] distance = sequence_i - acknowledged_i;
    wire        allowed = distance == 0 || distance <= {1'b0, sent_i};
    wire [11:0] newer = sequence_i - sequence_q;
    wire [31:0] elapsed = clock_q - stamp_q;
    assign valid_o    = valid_q;
    assign nak_o      = nak_q;
    assign sequence_o = sequence_q;
    assign age_o      = (|elapsed[31:16]) ? 16'hffff : elapsed[15:0];
    always @(posedge clk) begin
        if (!rst_n || link_reset_i) begin
            valid_q          <= 0;
            nak_q            <= 0;
            sequence_q       <= 0;
            clock_q          <= 0;
            stamp_q          <= 0;
            protocol_error_o <= 0;
        end else begin
            clock_q          <= clock_q + 1'b1;
            protocol_error_o <= 0;
            if (valid_q && ready_i) valid_q <= 0;
            if (event_i) begin
                if (!allowed) protocol_error_o <= 1;
                else if (!valid_q || ready_i || newer == 0 || newer < 2048) begin
                    valid_q    <= 1;
                    sequence_q <= sequence_i;
                    if (valid_q && !ready_i && newer == 0) begin
                        nak_q <= nak_q || nak_i;
                        // A duplicate ACK is not forward progress: preserve the original age.
                    end else begin
                        nak_q   <= nak_i;
                        stamp_q <= clock_q;
                    end
                end
            end
        end
    end
endmodule

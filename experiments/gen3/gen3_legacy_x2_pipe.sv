// SPDX-License-Identifier: Apache-2.0
// Legacy low-rate data mapping and receiver detection for the native x2 PIPE.
// A common TXDETECTRX and PowerDown command is independently acknowledged
// by both lanes. This adapter owns only the initial P1-to-P0 transition.
module gen3_legacy_x2_pipe #(
    parameter integer TIMEOUT_CYCLES = 3000000
) (
    input wire clk, rst_n, detect_i,
    input wire [1:0] ready_i, phystatus_i, rxvalid_i,
    input wire [5:0] rxstatus_i,
    input wire [127:0] rxdata_i,
    input wire [31:0] txdata_i,
    output wire [31:0] rxdata_o,
    output wire [127:0] txdata_o,
    output wire [1:0] rxvalid_o, rxerror_o,
    output wire detect_o,
    output wire [1:0] powerdown_o,
    output reg [1:0] detect_done_o, receiver_present_o,
    output wire failed_o
);
    localparam integer TIMER_BITS = $clog2(TIMEOUT_CYCLES + 1);
    localparam [2:0] ARM = 0, DETECT = 1, DRAIN = 2, ENTER_P0 = 3, P0 = 4, FAILED = 5;
    reg  [           2:0] state_q;
    reg  [           1:0] seen_q;
    reg  [TIMER_BITS-1:0] timer_q;
    wire [           1:0] fresh = phystatus_i & ~seen_q;
    wire [           1:0] present = {rxstatus_i[5:3] == 3, rxstatus_i[2:0] == 3};
    wire [           1:0] detected = receiver_present_o | (fresh & present);
    wire                  all_replies = &(seen_q | fresh);
    wire                  attempting = state_q != P0 && state_q != FAILED && detect_i;
    assign detect_o    = state_q == DETECT && (&ready_i) && detect_i;
    assign powerdown_o = state_q == ENTER_P0 || state_q == P0 ? 2'b00 : 2'b10;
    assign failed_o    = state_q == FAILED;
    assign rxdata_o    = {rxdata_i[79:64], rxdata_i[15:0]};
    assign txdata_o    = {48'b0, txdata_i[31:16], 48'b0, txdata_i[15:0]};
    assign rxvalid_o   = state_q == P0 ? rxvalid_i & ready_i : 2'b00;
    assign rxerror_o   = rxvalid_o & {rxstatus_i[5], rxstatus_i[2]};
    wire unused_rx_upper = ^{rxdata_i[127:80], rxdata_i[63:16]};

    always @(posedge clk) begin
        if (!rst_n) begin
            state_q            <= ARM;
            seen_q             <= 0;
            timer_q            <= 0;
            detect_done_o      <= 0;
            receiver_present_o <= 0;
        end else begin
            detect_done_o <= 0;
            if (attempting && timer_q != TIMER_BITS'(TIMEOUT_CYCLES)) timer_q <= timer_q + 1'b1;
            else if (!attempting) timer_q <= 0;

            if (attempting && timer_q == TIMER_BITS'(TIMEOUT_CYCLES - 1)) begin
                state_q <= FAILED;
            end else if (state_q != P0 && state_q != FAILED && !detect_i) begin
                state_q            <= ARM;
                seen_q             <= 0;
                receiver_present_o <= 0;
            end else begin
                case (state_q)
                    ARM:     if ((&ready_i) && phystatus_i == 0) state_q <= DETECT;
                    DETECT: begin
                        if (!(&ready_i)) state_q <= FAILED;
                        else begin
                            seen_q             <= seen_q | fresh;
                            receiver_present_o <= detected;
                            if (all_replies) begin
                                if (&detected) state_q <= DRAIN;
                                else begin
                                    state_q       <= FAILED;
                                    detect_done_o <= 2'b11;
                                end
                            end
                        end
                    end
                    DRAIN: begin
                        if (!(&ready_i)) state_q <= FAILED;
                        else if (phystatus_i == 0) begin
                            state_q <= ENTER_P0;
                            seen_q  <= 0;
                        end
                    end
                    ENTER_P0: begin
                        if (!(&ready_i)) state_q <= FAILED;
                        else begin
                            seen_q <= seen_q | fresh;
                            if (all_replies) begin
                                state_q       <= P0;
                                detect_done_o <= 2'b11;
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
    initial if (TIMEOUT_CYCLES < 2) $fatal(1, "Detect timeout must allow a handshake");
endmodule

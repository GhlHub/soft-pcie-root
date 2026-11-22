// SPDX-License-Identifier: Apache-2.0
// A shared native PIPE Rate command with independent lane acknowledgements.
// The LTSSM owns packet drain and transmission of EIOS before requesting a
// change. This block preserves PHY ownership and never resets the datapath.
module gen3_native_x2_rate #(
    parameter integer IDLE_CYCLES    = 250,
    parameter integer TIMEOUT_CYCLES = 6000000
) (
    input wire clk,
    // Global cold reset with clock-local release.
    input wire rst_n,
    input wire request_i,
    input wire [1:0] target_i,
    output wire request_ready_o,
    input wire tx_idle_i,
    input wire [1:0] rx_idle_i, phy_ready_i, phystatus_i,
    output reg [1:0] phy_rate_o, applied_rate_o,
    output wire rate_ready_o, busy_o, failed_o
);
    localparam [1:0] RUN = 0, GUARD = 1, ACK = 2, FAILED = 3;
    localparam integer TW = $clog2(TIMEOUT_CYCLES);
    localparam integer GW = $clog2(IDLE_CYCLES + 1);
    reg [1:0] state_q, target_q, acknowledged_q;
    reg  [TW-1:0] elapsed_q;
    reg  [GW-1:0] idle_q;
    wire [   1:0] received = acknowledged_q | phystatus_i;
    wire          idle_confirmed = (&rx_idle_i) && (&phy_ready_i);
    wire          timed_out = elapsed_q == TW'(TIMEOUT_CYCLES - 1);
    assign rate_ready_o    = rst_n && state_q == RUN && (&phy_ready_i);
    assign request_ready_o = rate_ready_o && tx_idle_i;
    assign busy_o          = state_q == GUARD || state_q == ACK;
    assign failed_o        = state_q == FAILED;

    // Cold reset restores Gen1 even if PCLK has stopped. A local link Recovery
    // does not reach this reset input or any of the packet owners.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= RUN;
            target_q       <= 0;
            phy_rate_o     <= 0;
            applied_rate_o <= 0;
            elapsed_q      <= 0;
            idle_q         <= 0;
            acknowledged_q <= 0;
        end else if (busy_o && (!tx_idle_i || timed_out)) begin
            state_q <= FAILED;
        end else begin
            if (busy_o) elapsed_q <= elapsed_q + 1'b1;
            case (state_q)
                RUN:
                if (request_i && request_ready_o) begin
                    if (target_i == 3) state_q <= FAILED;
                    else if (target_i != applied_rate_o) begin
                        state_q        <= GUARD;
                        target_q       <= target_i;
                        elapsed_q      <= 0;
                        idle_q         <= 0;
                        acknowledged_q <= 0;
                    end
                end
                GUARD: begin
                    if (!idle_confirmed) idle_q <= 0;
                    else if (idle_q != GW'(IDLE_CYCLES)) idle_q <= idle_q + 1'b1;
                    else if (phystatus_i == 0) begin
                        phy_rate_o <= target_q;
                        state_q    <= ACK;
                    end
                end
                ACK: begin
                    acknowledged_q <= received;
                    if ((&received) && (&phy_ready_i)) begin
                        applied_rate_o <= target_q;
                        state_q        <= RUN;
                    end
                end
                default: ;
            endcase
        end
    end
    initial
        if (IDLE_CYCLES < 1 || TIMEOUT_CYCLES <= IDLE_CYCLES + 1)
            $fatal(1, "Invalid native x2 rate sequencing timing");
endmodule

// SPDX-License-Identifier: Apache-2.0
// Gen3 Phase 0 PHY commands at the legacy rate. RATE may change only after
// both lanes apply their initial preset and return a fresh coefficient query.
module gen3_x2_initial_eq #(
    parameter integer GUARD_CYCLES   = 125,
    parameter integer TIMEOUT_CYCLES = 3000000
) (
    input wire clk, reset_i, request_i, tx_idle_i,
    input wire [1:0] rx_idle_i, phy_ready_i, txeq_done_i,
    input wire [11:0] phy_fs_i, phy_lf_i,
    input wire [35:0] phy_coeff_i,
    output wire [3:0] txeq_ctrl_o,
    output wire ready_o, failed_o,
    output reg [11:0] local_fs_o, local_lf_o,
    output reg [35:0] initial_coeff_o
);
    localparam [2:0] IDLE = 0, GUARD = 1, APPLY = 2, GAP = 3, QUERY = 4, READY = 5, FAILED = 6;
    localparam integer TIMER_BITS = $clog2(TIMEOUT_CYCLES);
    localparam integer GUARD_BITS = $clog2(GUARD_CYCLES + 1);
    reg [2:0] state_q;
    reg [TIMER_BITS-1:0] timer_q;
    reg [GUARD_BITS-1:0] idle_q;
    reg [1:0] seen_q;
    wire [1:0] observed = seen_q | txeq_done_i;
    wire idle_confirmed = (&rx_idle_i) && (&phy_ready_i);
    wire running = state_q == GUARD || state_q == APPLY || state_q == GAP || state_q == QUERY;
    assign ready_o  = state_q == READY;
    assign failed_o = state_q == FAILED;
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : commands
        assign txeq_ctrl_o[2*lane+:2] = seen_q[lane] ? 2'b00 :
            state_q == APPLY ? 2'b01 : state_q == QUERY ? 2'b11 : 2'b00;
    end
    always @(posedge clk) begin
        if (reset_i) begin
            state_q         <= IDLE;
            timer_q         <= 0;
            idle_q          <= 0;
            seen_q          <= 0;
            local_fs_o      <= 0;
            local_lf_o      <= 0;
            initial_coeff_o <= 0;
        end else if (running && (!tx_idle_i || timer_q == TIMER_BITS'(TIMEOUT_CYCLES - 1))) begin
            state_q <= FAILED;
        end else begin
            if (running) timer_q <= timer_q + 1'b1;
            case (state_q)
                IDLE:    if (request_i && tx_idle_i) state_q <= GUARD;
                GUARD: begin
                    if (!idle_confirmed) idle_q <= 0;
                    else if (idle_q != GUARD_BITS'(GUARD_CYCLES)) idle_q <= idle_q + 1'b1;
                    else if (txeq_done_i == 0) state_q <= APPLY;
                end
                APPLY: begin
                    seen_q <= observed;
                    if (&observed) begin
                        state_q <= GAP;
                        idle_q  <= 0;
                    end
                end
                GAP: begin
                    if (!idle_confirmed || txeq_done_i != 0) idle_q <= 0;
                    else if (idle_q != GUARD_BITS'(GUARD_CYCLES)) idle_q <= idle_q + 1'b1;
                    else begin
                        state_q <= QUERY;
                        seen_q  <= 0;
                    end
                end
                QUERY: begin
                    seen_q <= observed;
                    if ((&observed) && (&phy_ready_i)) state_q <= READY;
                    for (integer lane = 0; lane < 2; lane = lane + 1) begin
                        if (!seen_q[lane] && txeq_done_i[lane]) begin
                            local_fs_o[6*lane+:6]        <= phy_fs_i[6*lane+:6];
                            local_lf_o[6*lane+:6]        <= phy_lf_i[6*lane+:6];
                            initial_coeff_o[18*lane+:18] <= phy_coeff_i[18*lane+:18];
                        end
                    end
                end
                default: ;
            endcase
        end
    end
    initial
        if (GUARD_CYCLES < 1 || TIMEOUT_CYCLES < 2 * (GUARD_CYCLES + 2))
            $fatal(1, "Invalid Gen3 x2 Phase 0 timeout geometry");
endmodule

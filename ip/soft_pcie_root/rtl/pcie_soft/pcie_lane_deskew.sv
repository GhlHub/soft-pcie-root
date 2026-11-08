// SPDX-License-Identifier: Apache-2.0
// Candidate-only receive deskew, after per-lane OS validation/descrambling and
// SKP removal. Every lane supplies an identical logical record sequence; tag
// identifies record kind and position. align_i marks the FIRST record of the
// same validated SDS epoch on each lane. Never feed raw PIPE or partial OS here.
// No ingress backpressure: overflow, missing alignment or tag mismatch latches
// fault and suppresses output. Recovery may discard these provisional records;
// committed packet/replay/credit and AXI ownership must remain outside this unit.
// Lane order/reversal must be resolved before this interface. Payload RAM unreset.
module pcie_lane_deskew #(
    parameter integer LANES        = 2,
    parameter integer DATA_BITS    = 32,
    parameter integer TAG_BITS     = 4,
    parameter integer DEPTH        = 8,
    parameter integer ALIGN_CYCLES = 16
) (
    input wire clk, reset_i, abort_i,
    input wire [LANES-1:0] valid_i, align_i,
    input wire [LANES*DATA_BITS-1:0] data_i,
    input wire [LANES*TAG_BITS-1:0] tag_i,
    output wire valid_o,
    input wire ready_i,
    output wire [LANES*DATA_BITS-1:0] data_o,
    output wire [TAG_BITS-1:0] tag_o,
    output reg fault_o,
    output wire aligned_o
);
    localparam integer PTR_BITS   = $clog2(DEPTH);
    localparam integer TIMER_BITS = $clog2(ALIGN_CYCLES + 1);
    reg [DATA_BITS+TAG_BITS-1:0] memory[0:LANES-1][0:DEPTH-1];
    reg [PTR_BITS-1:0] wr[0:LANES-1], rd[0:LANES-1];
    reg [    PTR_BITS:0] count [0:LANES-1];
    reg [     LANES-1:0] seen;
    reg [TIMER_BITS-1:0] timer;
    wire [LANES-1:0] nonempty, push, overflow, repeated_align, tag_match;
    wire heads_ready = (&seen) && (&nonempty);
    wire pop = valid_o && ready_i;
    // Overflow depends on the potential pop, avoiding a combinational loop
    // through valid_o. A fault on any lane cancels the whole candidate beat.
    wire would_pop = heads_ready && (&tag_match) && ready_i && !fault_o && !reset_i && !abort_i;
    wire timeout_fault = (|seen) && !(&seen) && timer == TIMER_BITS'(ALIGN_CYCLES - 1);
    wire candidate_fault = (|overflow) || (|repeated_align) || (heads_ready && !(&tag_match)) ||
        timeout_fault;
    assign aligned_o = (&seen) && !fault_o && !candidate_fault && !reset_i && !abort_i;
    assign valid_o   = heads_ready && !fault_o && !candidate_fault && !reset_i && !abort_i;
    assign tag_o     = memory[0][rd[0]][DATA_BITS+:TAG_BITS];
    for (genvar lane = 0; lane < LANES; lane = lane + 1) begin : lanes
        assign nonempty[lane] = count[lane] != 0;
        assign push[lane] = valid_i[lane] && (seen[lane] || align_i[lane]);
        assign overflow[lane] = push[lane] && count[lane] == (PTR_BITS + 1)'(DEPTH) && !would_pop;
        assign repeated_align[lane] = valid_i[lane] && align_i[lane] && seen[lane];
        assign tag_match[lane] = memory[lane][rd[lane]][DATA_BITS+:TAG_BITS] == tag_o;
        assign data_o[lane*DATA_BITS+:DATA_BITS] = memory[lane][rd[lane]][DATA_BITS-1:0];
        always @(posedge clk) begin
            if (!reset_i && !abort_i && !fault_o && !candidate_fault && push[lane])
                memory[lane][wr[lane]] <= {
                    tag_i[lane*TAG_BITS+:TAG_BITS], data_i[lane*DATA_BITS+:DATA_BITS]
                };
            if (reset_i || abort_i) begin
                wr[lane]    <= 0;
                rd[lane]    <= 0;
                count[lane] <= 0;
                seen[lane]  <= 0;
            end else if (!fault_o && !candidate_fault) begin
                if (push[lane]) begin
                    wr[lane]   <= wr[lane] + 1'b1;
                    seen[lane] <= 1;
                end
                if (pop) rd[lane] <= rd[lane] + 1'b1;
                case ({
                    push[lane], pop
                })
                    2'b10:   count[lane] <= count[lane] + 1'b1;
                    2'b01:   count[lane] <= count[lane] - 1'b1;
                    default: ;
                endcase
            end
        end
    end
    always @(posedge clk) begin
        if (reset_i || abort_i) begin
            fault_o <= 0;
            timer   <= 0;
        end else begin
            if (candidate_fault) fault_o <= 1;
            if ((|seen) && !(&seen) && !fault_o && !candidate_fault) timer <= timer + 1'b1;
        end
    end
    initial begin
        if (LANES != 1 && LANES != 2) $fatal(1, "LANES must be 1 or 2");
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) $fatal(1, "DEPTH must be a power of two >= 2");
        if (ALIGN_CYCLES < 2) $fatal(1, "ALIGN_CYCLES must be >= 2");
    end
endmodule

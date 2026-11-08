// SPDX-License-Identifier: Apache-2.0
// Data-stream symbols only; ordered sets are generated independently per lane.
// Byte zero is earliest in time. Logical lane zero occupies the low lane word.
module pcie_lane_stripe #(
    parameter integer LANES   = 1,
    parameter integer SYMBOLS = 4
) (
    input wire [8*LANES*SYMBOLS-1:0] stream_i,
    output wire [8*LANES*SYMBOLS-1:0] lanes_o,
    input wire [8*LANES*SYMBOLS-1:0] lanes_i,
    output wire [8*LANES*SYMBOLS-1:0] stream_o
);
    initial begin
        if (LANES != 1 && LANES != 2) $fatal(1, "LANES must be 1 or 2");
        if (SYMBOLS < 1) $fatal(1, "SYMBOLS must be positive");
    end
    for (genvar lane = 0; lane < LANES; lane = lane + 1) begin : lane_map
        for (genvar symbol = 0; symbol < SYMBOLS; symbol = symbol + 1) begin : symbol_map
            assign lanes_o[8*(lane*SYMBOLS+symbol)+:8] = stream_i[8*(symbol*LANES+lane)+:8];
            assign stream_o[8*(symbol*LANES+lane)+:8]  = lanes_i[8*(lane*SYMBOLS+symbol)+:8];
        end
    end
endmodule

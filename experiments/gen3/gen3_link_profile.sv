// SPDX-License-Identifier: Apache-2.0
// Link-clock passive counters accessed through the existing command mailbox.
// Operation 7 is local, never a PCIe TLP. Freeze before reading counter words.
// Replies are held until accepted; command/response CDC ownership is unchanged.
module gen3_link_profile #(
    parameter integer COUNTER_BITS = 32
) (
    input wire clk, reset_i,
    input wire [31:0] events_i,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire [63:0] address_i,
    input wire [31:0] data_i,
    output reg rsp_valid_o,
    input wire rsp_ready_i,
    output reg [31:0] rsp_data_o,
    output reg [2:0] rsp_status_o
);
    reg running;
    reg [31:0] events_q, overflow;
    reg  [COUNTER_BITS-1:0] counters                                                [0:31];
    wire                    command = cmd_valid_i && cmd_ready_o;
    wire                    control = command && address_i == 64'h10 && data_i <= 1;
    assign cmd_ready_o = !reset_i && !rsp_valid_o;
    always @(posedge clk) begin
        if (reset_i) begin
            running      <= 0;
            events_q     <= 0;
            overflow     <= 0;
            rsp_valid_o  <= 0;
            rsp_data_o   <= 0;
            rsp_status_o <= 0;
            for (integer i = 0; i < 32; i = i + 1) counters[i] <= 0;
        end else begin
            // Isolate observation fanout and counter carry from admission paths.
            events_q <= events_i;
            if (rsp_valid_o && rsp_ready_i) rsp_valid_o <= 0;
            if (control && data_i == 1) begin
                running  <= 1;
                overflow <= 0;
                for (integer i = 0; i < 32; i = i + 1) counters[i] <= 0;
            end else begin
                if (control) running <= 0;
                if (running)
                    for (integer i = 0; i < 32; i = i + 1)
                    if (events_q[i]) begin
                        counters[i] <= counters[i] + 1'b1;
                        if (&counters[i]) overflow[i] <= 1;
                    end
            end
            if (command) begin
                rsp_valid_o  <= 1;
                rsp_status_o <= 0;
                rsp_data_o   <= 0;
                case (address_i)
                    64'h00:
                    rsp_data_o <=
                        32'h4c505232;  // LPR2: ACK counters measure actual blocked responses
                    64'h04: rsp_data_o <= {31'b0, running};
                    64'h08: rsp_data_o <= 32'd250000000;
                    64'h0c: rsp_data_o <= overflow;
                    64'h10: if (data_i > 1) rsp_status_o <= 2;
                    default: begin
                        if (address_i >= 64'h100 && address_i < 64'h180 && address_i[1:0] == 0 &&
                            !running)
                            rsp_data_o <= 32'(counters[address_i[6:2]]);
                        else rsp_status_o <= 2;
                    end
                endcase
            end
        end
    end
    initial if (COUNTER_BITS < 1 || COUNTER_BITS > 32) $error("Invalid profiling width");
endmodule

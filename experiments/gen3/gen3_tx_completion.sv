// SPDX-License-Identifier: Apache-2.0
// Single-outstanding completion boundary. The downstream PHY must echo the
// submission token only after the entire packet has physically completed.
// Tokens are independent of caller packet IDs. No reset/abort on Recovery.
module gen3_tx_completion (
    input wire clk, reset_i,
    input wire last_i, input wire [15:0] packet_id_i,
    output wire submit_o, output wire [31:0] token_o,
    input wire complete_i, input wire [31:0] complete_token_i,
    output wire retire_o, output reg pending_o, fault_o,
    output reg [15:0] pending_packet_o
);
    reg [31:0] next_token, pending_token;
    assign submit_o=last_i && !pending_o && !fault_o && !reset_i && next_token!=32'hffffffff;
    assign token_o=next_token;
    // A zero-latency completion is intentionally illegal: the submission must
    // first be registered at this boundary. A bad completion cannot release RAM.
    assign retire_o=complete_i && pending_o && complete_token_i==pending_token &&
                    !fault_o && !reset_i;
    always @(posedge clk) begin
        if(reset_i) begin
            next_token<=0;pending_token<=0;pending_o<=0;fault_o<=0;
        end else begin
            if(last_i) begin
                if(pending_o || fault_o || next_token==32'hffffffff) fault_o<=1;
                else begin
                    pending_o<=1;pending_token<=next_token;
                    next_token<=next_token+1'b1;pending_packet_o<=packet_id_i;
                end
            end
            if(complete_i) begin
                if(retire_o) pending_o<=0;
                else fault_o<=1;
            end
        end
    end
endmodule

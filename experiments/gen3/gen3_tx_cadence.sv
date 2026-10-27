// SPDX-License-Identifier: Apache-2.0
// Experimental 32-bit, 250 MHz PIPE transmit scheduling at 8 GT/s.
// Intel PIPE rev 7.1 section 8.27: 16 blocks, then one invalid cycle.
// This is a scheduling helper, not a PHY or an elastic ready/valid interface.
// The producer must supply a DWORD (including idle/ordered sets) in every slot.
// Run may be removed only after PHY-specific drain/electrical-idle sequencing.
// Restart discards phase only; it must never discard packet/replay ownership.
module gen3_tx_cadence (
    input  wire clk,
    input  wire reset_i,
    input  wire run_i,
    output wire data_slot_o,
    output wire block_start_o
);
    reg [6:0] phase_q;
    assign data_slot_o = run_i && !reset_i && phase_q < 7'd64;
    assign block_start_o = data_slot_o && phase_q[1:0] == 2'b00;
    always @(posedge clk) begin
        if (reset_i || !run_i)
            phase_q <= 0;
        else if (phase_q == 7'd64)
            phase_q <= 0;
        else
            phase_q <= phase_q + 1'b1;
    end
endmodule

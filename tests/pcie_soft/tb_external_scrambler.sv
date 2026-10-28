`timescale 1ns / 1ps
// Exhaustive one-octet arithmetic test, not a reachable-state/link test.
module tb_external_scrambler;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, valid = 0;
    reg [15:0] state = 0;
    wire [15:0] expected_next, unchanged, registered_state, registered_hold;
    wire [7:0] expected_mask, next_mask, registered_mask, registered_hold_mask;
    wire [15:0] data, lfsr;
    wire ready, out_valid;
    wire [1:0] ctrl, keep;
    ScrambleCodec next_ref (
        clk,
        rst_n,
        1'b1,
        state,
        expected_next,
        registered_state,
        next_mask,
        registered_mask
    );
    ScrambleCodec mask_ref (
        clk,
        rst_n,
        1'b0,
        state,
        unchanged,
        registered_hold,
        expected_mask,
        registered_hold_mask
    );
    pcie_soft_scrambler dut (
        clk,
        rst_n,
        16'b0,
        2'b0,
        2'b01,
        2'b01,
        valid,
        ready,
        data,
        ctrl,
        keep,
        out_valid,
        1'b1,
        lfsr
    );
    reg     [15:0] saved_next;
    reg     [ 7:0] saved_mask;
    integer        i;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        valid = 1;
        for (i = 0; i < 65536; i = i + 1) begin
            @(negedge clk);
            state      = 16'(i);
            dut.lfsr_q = 16'(i);  // Test-only state injection for exhaustive arithmetic.
            #1;
            saved_next = expected_next;
            saved_mask = expected_mask;
            @(posedge clk);
            #1;
            if (!out_valid || !ready || lfsr !== saved_next || data !== {8'b0, saved_mask})
                $fatal(1, "External scrambler mismatch state=%04x", state);
        end
        $display("PASS external scrambler: all 65536 states, octet advance and outgoing mask");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "External scrambler watchdog");
    end
endmodule

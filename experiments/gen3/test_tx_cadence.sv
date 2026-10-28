// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_tx_cadence;
    reg clk = 0;
    always #2 clk = !clk;
    reg reset_i = 1, run_i = 0;
    wire slot, start;
    gen3_tx_cadence dut (
        clk,
        reset_i,
        run_i,
        slot,
        start
    );
    integer burst, block_no, word_no;
    task tick;
        input expected_slot, expected_start;
        begin
            #1;
            if (slot !== expected_slot || start !== expected_start)
                $fatal(1, "cadence mismatch slot=%b start=%b", slot, start);
            @(posedge clk);
            @(negedge clk);
        end
    endtask
    initial begin
        @(negedge clk);
        tick(0, 0);
        reset_i = 0;
        tick(0, 0);
        run_i = 1;
        // Independent block-level schedule, including the first bubble and wrap.
        repeat (3) begin
            for (burst = 0; burst < 64; burst = burst + 1) begin
                for (block_no = 0; block_no < 16; block_no = block_no + 1)
                for (word_no = 0; word_no < 4; word_no = word_no + 1) tick(1, word_no == 0);
                tick(0, 0);
            end
            run_i = 0;
            repeat (5) tick(0, 0);
            run_i = 1;
        end
        // Reset at a nonzero phase must restart with a complete first block.
        tick(1, 1);
        tick(1, 0);
        reset_i = 1;
        tick(0, 0);
        reset_i = 0;
        for (word_no = 0; word_no < 4; word_no = word_no + 1) tick(1, word_no == 0);
        $display("PASS: 192 cadence periods, idle restarts, synchronous state reset");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "timeout");
    end
endmodule

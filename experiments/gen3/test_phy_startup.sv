// SPDX-License-Identifier: Apache-2.0
// Actual generated reset sequencer, with a behavioral clock/PLL dependency.
// This checks the startup dependency; it is not a GT serial/compliance model.
`timescale 1ns / 1ps
module test_phy_startup;
    parameter integer STARTUP_REFERENCE = 0;
    reg refclk = 0, fastclk = 0, reset_n = 0, powergood = 0;
    always #5 refclk = ~refclk;
    always #2 fastclk = ~fastclk;
    wire cpllpd, cpllreset, qpllpd, qpllreset, divider_reset, gtreset, userrdy;
    wire [3:0] state;
    wire       cplllock = powergood && !cpllpd && !cpllreset;
    wire       qplllock = powergood && !qpllpd && !qpllreset;
    wire       divider_done = cplllock && !divider_reset;
    wire       normal_clock = divider_done ? fastclk : 1'b0;
    wire       txoutclk = (STARTUP_REFERENCE && cpllreset) ? refclk : normal_clock;
    wire       reset_done = !gtreset && userrdy && divider_done;
    wire       idle;
    gen3_reference_phy_gt_phy_rst #(
        .PHY_LANE     (1),
        .PHY_MAX_SPEED(3),
        .PHY_SIM_EN   ("FALSE")
    ) dut (
        .RST_REFCLK            (refclk),
        .RST_PCLK              (txoutclk),
        .RST_INTCLK            (txoutclk),
        .RST_N                 (reset_n),
        .RST_GTPOWERGOOD       (powergood),
        .RST_CPLLLOCK          (cplllock),
        .RST_QPLL0LOCK         (1'b0),
        .RST_QPLL1LOCK         (qplllock),
        .RST_TXPROGDIVRESETDONE(divider_done),
        .RST_TXRESETDONE       (reset_done),
        .RST_RXRESETDONE       (reset_done),
        .RST_TXSYNC_DONE       (state == 6 || state == 7 || idle),
        .RST_PHYSTATUS         (1'b0),
        .phy_rst_fsm           (state),
        .RST_CPLLPD            (cpllpd),
        .RST_CPLLRESET         (cpllreset),
        .RST_QPLLPD            (qpllpd),
        .RST_QPLLRESET         (qpllreset),
        .RST_TXPROGDIVRESET    (divider_reset),
        .RST_GTRESET           (gtreset),
        .RST_USERRDY           (userrdy),
        .RST_IDLE              (idle),
        .RST_RRST_N            (),
        .RST_PRST_N            (),
        .RST_TXSYNC_START      (),
        .RST_TXPISOPD          (),
        .RST_RCALENB           ()
    );
    initial begin
        #50;
        powergood = 1;
        #150;
        reset_n = 1;
        repeat (1000) @(posedge refclk);
        if (STARTUP_REFERENCE) begin
            if (!idle || !cplllock || !qplllock || !reset_done)
                $fatal(1, "Reference startup did not complete: state=%d", state);
            $display("PASS: reference-clock startup completes actual PHY reset sequencer");
        end else begin
            if (state !== 1 || cplllock !== 0 || cpllreset !== 1)
                $fatal(1, "Expected programmable-clock startup deadlock");
            $display("PASS: original programmable-clock startup deadlock reproduced");
        end
        $finish;
    end
endmodule

`timescale 1ns / 1ps
module tb_link_training;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst = 0, enable = 1, phyready = 1, eidle = 1, detect_done = 0, present = 1, retrain = 0;
    reg [15:0] rxdata = 0;
    reg [ 1:0] rxctrl = 0;
    reg rxvalid = 0, rxerr = 0;
    wire detect, txidle, done, up, l0, holdtimer, polarity, failed;
    wire [4:0] state;
    wire [1:0] kind;
    wire [7:0] link, lane;
    wire lp, np;
    wire [15:0] txdata;
    wire [ 1:0] txctrl;
    wire txvalid, txdone;
    wire [1:0] txkind;
    wire tsv, ts2, inv, bad;
    wire [7:0] rl, rn, rr, rc;
    wire rlp, rnp;
    wire idlepair = rxvalid && rxdata == 0 && rxctrl == 0;
    pcie_soft_training codec (
        clk,
        rst,
        1'b1,
        kind,
        link,
        lane,
        8'b0,
        lp,
        np,
        txdata,
        txctrl,
        txvalid,
        txdone
        ,,
        txkind,
        rxdata,
        rxctrl,
        rxvalid,
        rxerr,
        tsv,
        ts2,
        inv,
        bad,
        rl,
        rn,
        rr,
        rc,
        rlp,
        rnp,
        8'h02
    );
    pcie_soft_ltssm #(
        .QUIET_CYCLES (16),
        .POLL_CYCLES  (100000),
        .CONFIG_CYCLES(10000)
    ) dut (
        clk,
        rst,
        enable,
        phyready,
        eidle,
        detect_done,
        present,
        detect,
        txidle,
        retrain,
        done,
        tsv,
        ts2,
        inv,
        bad,
        rl,
        rn,
        rr,
        rc,
        rlp,
        rnp,
        txdone,
        txkind,
        idlepair,
        !txvalid,
        rxerr,
        kind,
        link,
        lane,
        lp,
        np,
        up,
        l0,
        holdtimer,
        polarity,
        failed,
        state,
        1'b1,
        1'b0,
        1'b1,
        1'b0
        ,,,,,,
    );
    integer tx_ts1 = 0, transitions = 0, i, j, previous = -1, done_count = 0;
    always @(posedge clk) begin
        if (rst && txdone && txkind == 1) tx_ts1 = tx_ts1 + 1;
        if (rst && state != previous) begin
            transitions = transitions + 1;
            previous    = state;
        end
        if (done) done_count = done_count + 1;
    end
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task ts(input is2, input linkpad, input lanepad, input [7:0] ctl, input corrupt);
        reg [15:0] value;
        reg [ 1:0] ctrl;
        for (integer n = 0; n < 8; n = n + 1) begin
            value = is2 ? 16'h4545 : 16'h4a4a;
            ctrl  = 0;
            case (n)
                0: begin
                    value = {linkpad ? 8'hf7 : 8'h00, 8'hbc};
                    ctrl  = {linkpad, 1'b1};
                end
                1: begin
                    value = {8'd32, lanepad ? 8'hf7 : 8'h00};
                    ctrl  = {1'b0, lanepad};
                end
                2: value = {ctl, 8'h02};
                5: if (corrupt) value = 16'h55aa;
            endcase
            @(negedge clk);
            rxdata  = value;
            rxctrl  = ctrl;
            rxvalid = 1;
        end
    endtask
    task advance(input integer wanted, input is2, input linkpad, input lanepad);
        integer guard;
        begin
            guard = 0;
            while (state != wanted && guard < 2000) begin
                ts(is2, linkpad, lanepad, 0, 0);
                guard = guard + 1;
            end
            if (state != wanted) $fatal(1, "LTSSM expected state %0d got %0d", wanted, state);
        end
    endtask
    initial begin
        cycles(3);
        @(negedge clk);
        rst = 1;
        wait (detect);
        if (!txidle || up) $fatal(1, "Detect control");
        @(negedge clk);
        detect_done = 1;
        @(negedge clk);
        detect_done = 0;
        eidle       = 0;
        wait (state == 2);
        // Malformed identifiers cannot build a consecutive-TS count.
        for (i = 0; i < 10; i = i + 1) ts(0, 1, 1, 0, 1);
        cycles(2);
        if (dut.good_q != 0 || state != 2) $fatal(1, "Malformed TS accepted");
        advance(3, 0, 1, 1);
        if (tx_ts1 < 1024) $fatal(1, "Polling minimum TS1 count");
        advance(4, 1, 1, 1);
        advance(6, 0, 0, 1);
        advance(8, 0, 0, 0);
        advance(9, 1, 0, 0);
        @(negedge clk);
        rxdata  = 0;
        rxctrl  = 0;
        rxvalid = 1;
        wait (l0);
        cycles(3);
        if (!up || holdtimer || failed) $fatal(1, "L0 qualification");
        @(negedge clk);
        retrain = 1;
        @(negedge clk);
        retrain = 0;
        wait (state == 11);
        if (!up || !holdtimer) $fatal(1, "Recovery lost link ownership");
        advance(12, 0, 0, 0);
        advance(13, 1, 0, 0);
        @(negedge clk);
        rxdata = 0;
        rxctrl = 0;
        wait (l0);
        cycles(3);
        if (done_count != 1 || !up) $fatal(1, "Recovery completion");
        // Unsupported loopback request must close the port rather than claim L0.
        ts(0, 0, 0, 8'h04, 0);
        cycles(4);
        if (l0 || up || !failed || !txidle) $fatal(1, "Unsupported control did not fail closed");
        $display(
            "PASS training: symbols, invalid identifiers, Detect, 1024 TS1, PAD/link/lane negotiation, TS2/Idle, Recovery, unsupported control"
                );
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Training watchdog state %0d", state);
    end
endmodule

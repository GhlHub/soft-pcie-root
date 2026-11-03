// SPDX-License-Identifier: Apache-2.0
module test_eq_adapt;
    parameter integer CASE = 0;
    reg clk = 0;
    always #2 clk = ~clk;
    reg
        reset = 1,
        enter = 0,
        cancel = 0,
        ready = 1,
        event_ts = 0,
        valid = 1,
        aligned = 1,
        rxerror = 0;
    reg [31:0] rxfields = 0;
    reg txdone = 0, rxdone = 0, adapted = 0, preset_sel = 1;
    reg [17:0] proposal = 7, coeff = {6'd0, 6'd40, 6'd0};
    wire [1:0] txctrl, rxctrl;
    wire [3:0] txpreset, rxpreset, reason, attempts, applied_preset;
    wire [ 5:0] txcoeff;
    wire [31:0] fields;
    wire interval_reset, active, done, failed;
    wire [17:0] applied_coeff;
    gen3_eq_adapt #(
        .PHASE2_CYCLES  (1000),
        .PHASE3_CYCLES  (2500),
        .REQUEST_CYCLES (120),
        .SETTLE_CYCLES  (8),
        .EVALUATE_CYCLES(CASE >= 10 ? 100 : 24),
        .APPLY_CYCLES   (40)
    ) dut (
        clk,
        reset,
        enter,
        cancel,
        ready,
        event_ts,
        valid,
        aligned,
        rxerror,
        rxfields,
        4'd4,
        {6'd0, 6'd40, 6'd0},
        6'd40,
        6'd12,
        6'd40,
        6'd12,
        txdone,
        coeff,
        rxdone,
        adapted,
        preset_sel,
        proposal,
        txctrl,
        rxctrl,
        txpreset,
        rxpreset,
        txcoeff,
        fields,
        interval_reset,
        active,
        done,
        failed,
        reason,
        attempts,
        applied_preset,
        applied_coeff
    );
    task step;
        begin
            @(posedge clk);
            #1;
            @(negedge clk);
        end
    endtask
    function automatic [31:0] ts(input [1:0] ec, input bit usepreset, input [3:0] preset,
                                 input [17:0] c, input bit reject_bit, reset_bit);
        reg [30:0] b;
        begin
            b = {
                reject_bit, c[5:0], 2'b0, c[11:6], 2'b0, c[17:12], usepreset, preset, reset_bit, ec
            };
            ts = {^b, b};
        end
    endfunction
    task send(input [31:0] f);
        begin
            rxfields = f;
            event_ts = 1;
            step();
            event_ts = 0;
            step();
        end
    endtask
    task pair(input [31:0] f);
        begin
            send(f);
            send(f);
        end
    endtask
    integer rx_wait_cycles = 0;
    integer tx_count = 0, rx_count = 0, serial = 0, cycles = 0;
    reg [1:0] oldctrl = 0;
    reg       injected = 0;
    always @(negedge clk) begin
        if (!reset) begin
            cycles = cycles + 1;
            if (cycles > 5000) $fatal(1, "watchdog case %0d state %0d", CASE, dut.state);
            if (txctrl != 0 && oldctrl == 0) begin
                tx_count = tx_count + 1;
                serial   = 0;
            end
            if (txctrl == 2 && serial < 3) begin
                if (txcoeff !== (serial == 0 ? 6'd4 : serial == 1 ? 6'd32 : 6'd4))
                    $fatal(1, "coefficient serialization %0d %0d", serial, txcoeff);
                serial = serial + 1;
            end
            oldctrl = txctrl;
        end
    end
    initial begin
        repeat (3) step();
        reset = 0;
        enter = 1;
        step();
        enter = 0;
        step();
        // Broken pair cannot request a PHY update.
        send(ts(2, 1, 6, 0, 0, 0));
        valid = 0;
        send(ts(2, 1, 6, 0, 0, 0));
        valid = 1;
        send(ts(2, 1, 6, 0, 0, 0));
        if (txctrl != 0) $fatal(1, "broken pair accepted");
        if (CASE == 1) begin
            pair(ts(2, 1, 15, 0, 0, 0));
            if (!fields[30] || txctrl != 0) $fatal(1, "illegal preset not rejected");
        end else if (CASE == 2) begin
            pair(ts(2, 0, 4, {6'd11, 6'd29, 6'd0}, 0, 0));
            if (!fields[30] || txctrl != 0) $fatal(1, "illegal coefficients not rejected");
        end
        pair(ts(2, CASE != 3, 6, CASE == 3 ? {6'd4, 6'd32, 6'd4} : 18'b0, 0, 1));
        if (txctrl != (CASE == 3 ? 2 : 1)) $fatal(1, "apply not requested");
        if (fields[6:3] != (CASE == 1 ? 15 : 4)) $fatal(1, "unapplied request advertised");
        if (CASE == 4) begin
            wait (failed);
            if (reason != 3) $fatal(1, "missing apply ack");
            $display("PASS: missing PHY acknowledgement");
            $finish;
        end
        repeat (4) step();
        txdone = 1;
        step();
        txdone = 0;
        step();
        wait (txctrl == 3);
        coeff = CASE == 3 ? {6'd4, 6'd32, 6'd4} : {6'd0, 6'd36, 6'd4};
        step();
        txdone = 1;
        step();
        txdone = 0;
        step();
        if (fields[30] || applied_coeff != coeff) $fatal(1, "query not applied");
        if (CASE == 5) begin
            wait (failed);
            if (reason != 2) $fatal(1, "phase2 timeout");
            $display("PASS: phase2 timeout");
            $finish;
        end
        pair(ts(3, 0, 4, {6'd0, 6'd40, 6'd0}, 0, 0));
        if (CASE == 6) begin
            ready = 0;
            step();
            if (!failed || reason != 1) $fatal(1, "PHY loss");
            $display("PASS: PHY loss");
            $finish;
        end
        if (CASE == 7) begin
            cancel = 1;
            step();
            if (active || txctrl || rxctrl) $fatal(1, "cancel");
            $display("PASS: cancellation");
            $finish;
        end
        // Independent peer reflects each request; RX PHY proposes preset7,
        // then acknowledges adaptation. Case8 rejects every setting.
        while (active) begin
            if (fields[1:0] == 3) begin
                rxfields = ts(3, 0, fields[6:3], {6'd0, 6'd40, 6'd0}, CASE == 8, 0);
                event_ts = 1;
            end
            if (rxctrl == 2) rx_wait_cycles = rx_wait_cycles + 1;
            else rx_wait_cycles = 0;
            if (rxctrl == 2 && !rxdone && (CASE != 9 || rx_wait_cycles > 150)) begin
                rx_count = rx_count + 1;
                adapted  = rx_count > 1;
                rxdone   = 1;
            end else if (rxctrl == 0) rxdone = 0;
            if (CASE >= 10 && dut.state == 9 && dut.clean_pairs >= 8 && !injected) begin
                if (CASE == 10) valid = 0;
                if (CASE == 11) rxfields = ts(2, 0, fields[6:3], coeff, 0, 0);
                if (CASE == 12) rxfields = ts(3, 0, fields[6:3] + 1'b1, coeff, 0, 0);
                if (CASE == 13) rxfields = ts(3, 0, fields[6:3], coeff, 1, 0);
                if (CASE <= 13) begin
                    step();
                    if (done || dut.state != 10) $fatal(1, "bad TS did not invalidate evaluation");
                    valid    = 1;
                    injected = 1;
                end else if (CASE == 14) begin
                    event_ts = 0;
                    repeat (105) begin
                        step();
                        if (done) $fatal(1, "evaluation succeeded without fresh training");
                    end
                    injected = 1;
                end else if (dut.operation_timer >= 100) begin
                    if (CASE == 17) begin
                        force dut.request_timer = 119;
                        force dut.extended_count = 2;
                        step();
                        if (done || failed || !active || dut.state != 10)
                            $fatal(1, "request deadline lost retry ownership");
                        release dut.request_timer;
                        release dut.extended_count;
                        injected = 1;
                    end else begin
                        if (CASE == 15) ready = 0;
                        // Boundary injection: collide absolute deadline with a good pair.
                        if (CASE == 16) force dut.phase_timer = 2499;
                        step();
                        if (done || !failed || active || reason != (CASE == 15 ? 1 : 2))
                            $fatal(1, "failure did not dominate successful evaluation");
                        if (CASE == 16) release dut.phase_timer;
                        $display("PASS: completion/failure collision %0d", CASE);
                        $finish;
                    end
                end
            end
            step();
        end
        if (CASE == 8) begin
            if (!failed || reason != 4 || attempts != 11) $fatal(1, "retry bound");
        end else
            if (!done || failed || attempts != ((CASE >= 10 && CASE <= 13) || CASE == 17 ? 3 : 2) ||
                rx_count != ((CASE >= 10 && CASE <= 13) || CASE == 17 ? 3 : 2))
            $fatal(
                1,
                "adaptive completion done %b fail %b reason %d tries %d rx %d",
                done,
                failed,
                reason,
                attempts,
                rx_count
            );
        $display("PASS: adaptive case %0d", CASE);
        $finish;
    end
endmodule

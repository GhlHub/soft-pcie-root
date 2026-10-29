// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module tb_requester_coverage;
    parameter integer HALF_PERIOD = 4;
    parameter integer CASE = 0;
    reg clk = 0;
    always #(HALF_PERIOD) clk = ~clk;
    reg        timeout_tick = 0;
    reg        reserved_bits = 0;
    reg [15:0] completer_id = 16'h0100;
    reg rst = 0, up = 1, cv = 0, txready = 1, sent = 0, rv = 0, rlast = 0, rspready = 0;
    reg [ 2:0] op = 0;
    reg [63:0] addr = 0;
    reg [15:0] bdf = 16'h0100;
    reg [31:0] wrdata = 0, rxdata = 0;
    reg [3:0] be = 15;
    wire cmdready, tv, tlast, rxready, rspvalid, unexpected, fault;
    wire [31:0] td, rspdata;
    wire [127:0] debug_packet;
    wire [  1:0] cls;
    wire [  8:0] credits;
    wire [  2:0] status;
    pcie_soft_requester #(
        .COMPLETION_TIMEOUT(64)
    ) dut (
        clk,
        rst,
        up,
        cv,
        cmdready,
        op,
        addr,
        bdf,
        wrdata,
        be,
        td,
        tv,
        tlast,
        txready,
        sent,
        cls,
        credits,
        rxdata,
        rv,
        rlast,
        rxready,
        rspvalid,
        rspready,
        rspdata,
        status,
        unexpected,
        fault,
        debug_packet,
        timeout_tick
    );
    reg [31:0] packet[0:7];
    integer count = 0, packets = 0, errors = 0, i;
    always @(posedge clk)
        if (rst) begin
            if (tv && txready) begin
                packet[count] = td;
                count         = count + 1;
                if (tlast) begin
                    count   = 0;
                    packets = packets + 1;
                end
            end
            if (unexpected) errors = errors + 1;
        end
    function [31:0] swap(input [31:0] x);
        swap = {x[7:0], x[15:8], x[23:16], x[31:24]};
    endfunction
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task reset;
        @(negedge clk);
        rst      = 0;
        cv       = 0;
        rv       = 0;
        sent     = 0;
        up       = 1;
        rspready = 0;
        cycles(3);
        @(negedge clk);
        rst = 1;
        cycles(1);
    endtask
    task command(input [2:0] kind, input [63:0] a, input [31:0] data);
        wait (cmdready);
        @(negedge clk);
        op     = kind;
        addr   = a;
        wrdata = data;
        cv     = 1;
        @(negedge clk);
        cv = 0;
    endtask
    task packet_sent;
        wait (dut.state_q == 2);
        cycles(3);
        @(negedge clk);
        sent = 1;
        @(negedge clk);
        sent = 0;
        cycles(1);
    endtask
    task dw(input [31:0] value, input last);
        @(negedge clk);
        rv     = 1;
        rxdata = value;
        rlast  = last;
        @(negedge clk);
        rv = 0;
    endtask
    task completion(input [7:0] tag, input [2:0] st, input hasdata, input [31:0] data,
                    input [6:0] lower);
        dw(swap((hasdata ? 32'h4a000001 : 32'h0a000000) | (reserved_bits ? 32'h008f0c00 : 0)), 0);
        dw(swap({completer_id, st, 1'b0, 12'd4}), 0);
        dw(swap({16'h0000, tag, reserved_bits, lower}), !hasdata);
        if (hasdata) dw(data, 1);
        cycles(2);
    endtask
    task response(input [2:0] wanted, input [31:0] value);
        wait (rspvalid);
        if (status !== wanted || rspdata !== value)
            $fatal(1, "Response got %d/%08x expected %d/%08x", status, rspdata, wanted, value);
        cycles(7);
        if (cmdready || !rspvalid || status !== wanted || rspdata !== value)
            $fatal(1, "Held response changed");
        @(negedge clk);
        rspready = 1;
        @(negedge clk);
        rspready = 0;
        cycles(1);
    endtask
    reg [31:0] h0, h1, h2;
    integer expected_status, mask, first, last, ticks;
    initial begin
        reset();
        if (CASE == 0) begin
            // Independent byte-enable span/lower-address sweep, including holes.
            for (mask = 1; mask < 16; mask = mask + 1) begin
                reset();
                be    = 4'(mask);
                first = 0;
                while (!(mask & (1 << first))) first = first + 1;
                last = 3;
                while (!(mask & (1 << last))) last = last - 1;
                command(0, 64'h107c, 0);
                packet_sent();
                dw(swap(32'h4a000001), 0);
                dw(swap(32'h01000000 | 32'(last - first + 1)), 0);
                dw(swap(32'(124 + first)), 0);
                dw(32'hcafe1234, 1);
                response(0, 32'hcafe1234);
                if (fault || !cmdready) $fatal(1, "Valid BE completion quarantined mask=%h", mask);
            end
        end else if (CASE == 1) begin
            // Start counting only after physical transmission. Disabled ticks
            // and the unsent interval must never consume the timeout budget.
            timeout_tick = 1;
            command(0, 64'h1000, 0);
            wait (dut.state_q == 2);
            cycles(80);
            if (rspvalid || fault) $fatal(1, "Unsent request timed out");
            timeout_tick = 0;
            packet_sent();
            cycles(80);
            if (rspvalid || fault) $fatal(1, "Disabled ticks advanced timeout");
            for (ticks = 1; ticks <= 64; ticks = ticks + 1) begin
                @(negedge clk);
                timeout_tick = 1;
                cycles(1);
                if (ticks < 64 && (rspvalid || fault)) $fatal(1, "Early timeout tick=%0d", ticks);
                if (ticks == 64 && (!rspvalid || status != 3 || !fault))
                    $fatal(1, "Missing timeout at deadline");
                @(negedge clk);
                timeout_tick = 0;
                cycles(2);
            end
            response(3, 0);
            completion(0, 0, 1, 32'hdeadbeef, 0);
            if (rspvalid || cmdready || !fault) $fatal(1, "Late completion escaped quarantine");
        end else if (CASE >= 21) begin
            // Exercise completion/timeout arbitration at the acceptance edge.
            // CASE 24/25 also cover the separate header-only completion path.
            command(CASE == 24 ? 3 : 0, CASE == 24 ? 64'h0 : 64'h1000, 0);
            packet_sent();
            dw(swap(
               CASE == 23 ? 32'h4a004001 : (CASE == 24 || CASE == 25) ? 32'h0a000000 : 32'h4a000001
               ), 0);
            dw(swap(CASE == 25 ? 32'h01002000 : 32'h01000004), 0);
            if (CASE != 24 && CASE != 25) dw(swap(CASE == 26 ? 32'h00000100 : 0), 0);
            @(negedge clk);
            timeout_tick = 1;
            cycles(CASE == 21 ? 62 : 63);
            if (rspvalid || fault) $fatal(1, "Timeout before completion edge");
            if (CASE == 27) up = 0;
            dw(CASE == 24 || CASE == 25 ? 0 : 32'h12345678, 1);
            timeout_tick = 0;
            if (CASE == 23 || CASE == 26 || CASE == 27) begin
                response(CASE == 23 ? 6 : CASE == 26 ? 3 : 4, 0);
                if (!fault || cmdready) $fatal(1, "Invalid deadline completion escaped");
            end else begin
                response(CASE == 25 ? 1 : 0, CASE == 24 || CASE == 25 ? 0 : 32'h12345678);
                if (fault || !cmdready) $fatal(1, "Completion at deadline left timeout quarantine");
            end
        end else begin
            command(0, 64'h1000, 0);
            packet_sent();
            h0              = 32'h4a000001;
            h1              = 32'h01000004;
            h2              = 0;
            expected_status = 6;
            case (CASE)
                2:       h0 = h0 | 32'h00100000;  // TC
                3:       h0 = h0 | 32'h00008000;  // TD / unsupported ECRC
                4:       h0 = h0 | 32'h00004000;  // Poison
                5:       h0 = h0 | 32'h00002000;  // Relaxed ordering
                6:       h0 = h0 | 32'h00001000;  // No snoop
                7:       h1 = h1 | 32'h00001000;  // BCM
                8:       h0 = 32'h4a000002;  // Declared length mismatch
                9:       h1 = 32'h01000003;  // Byte count mismatch
                10:      h2 = 32'h00000001;  // Lower address mismatch
                11:      h0 = h0 | 32'h20000000;  // Invalid completion format
                12:      h0 = h0 | 32'h80000000;
                13:      h2 = 32'h00000100;  // Wrong tag: ignore, retain request
                14:      h2 = 32'h00010000;  // Wrong requester: ignore
                15:      h0 = 32'h40000001;  // Not a completion: ignore
                16:      ;  // Extra data beat
                17:      h0 = 32'h0a000000;  // Missing read data
                18: begin
                    h0              = 32'h0a000000;
                    h1              = 32'h01002000;
                    expected_status = 1;
                end
                19: begin
                    h0              = 32'h0a000000;
                    h1              = 32'h01008000;
                    expected_status = 2;
                end
                20: begin
                    h0              = 32'h0a000000;
                    h1              = 32'h01004000;
                    expected_status = 2;
                end
                default: $fatal(1, "Unknown CASE");
            endcase
            dw(swap(h0), 0);
            dw(swap(h1), 0);
            dw(swap(h2), CASE >= 17);
            if (CASE < 17) dw(32'hdeadbeef, CASE != 16);
            if (CASE == 16) dw(32'hbadc0ffe, 1);
            cycles(2);
            if (CASE >= 13 && CASE <= 15) begin
                if (rspvalid || fault || errors == 0)
                    $fatal(1, "Unmatched packet consumed request");
                completion(0, 0, 1, 32'h12345678, 0);
                response(0, 32'h12345678);
                if (fault || !cmdready) $fatal(1, "Valid completion after unmatched packet lost");
            end else begin
                response(3'(expected_status), 0);
                if (expected_status == 6) begin
                    if (!fault || cmdready) $fatal(1, "Malformed completion not quarantined");
                    completion(0, 0, 1, 32'h12345678, 0);
                    if (rspvalid || cmdready || !fault) $fatal(1, "Malformed tag reused");
                end else if (fault || !cmdready) $fatal(1, "Error completion leaked ownership");
            end
        end
        $display("PASS requester coverage CASE=%0d HALF_PERIOD=%0d", CASE, HALF_PERIOD);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Requester coverage watchdog");
    end
endmodule

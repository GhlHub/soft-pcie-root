// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
// File-driven decoded-symbol fault injection. CRC and expected payloads are
// constructed independently in Python; no DUT state is used by the checker.
module tb_rx_fault_matrix;
    parameter integer HALF_PERIOD = 4;
    reg clk = 0;
    always #(HALF_PERIOD) clk = ~clk;
    reg rst_n = 0, valid = 0, phy_error = 0, ready = 0;
    reg [15:0] symbols = 0;
    reg [ 1:0] control = 0;
    wire [31:0] data, dllp_body;
    wire tv, last, response, nak, dllp_valid, packet_error;
    wire [ 1:0] cls;
    wire [ 8:0] credits;
    wire [11:0] sequence_number;
    pcie_soft_packet_rx dut (
        clk,
        rst_n,
        1'b0,
        symbols,
        control,
        valid,
        phy_error,
        data,
        tv,
        last,
        ready,
        cls,
        credits,
        response,
        nak,
        sequence_number,
        dllp_valid,
        dllp_body,
        packet_error
    );
    integer dllps = 0, acks = 0, naks = 0;
    reg [11:0] last_sequence = 0;
    reg [31:0] last_dllp = 0;
    always @(posedge clk) begin
        if (rst_n && response) begin
            if (nak) naks = naks + 1;
            else acks = acks + 1;
            last_sequence = sequence_number;
        end
        if (rst_n && dllp_valid) begin
            dllps     = dllps + 1;
            last_dllp = dllp_body;
        end
    end
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    reg [4095:0] path;
    integer fd, rc, operation, a, b, c, d, row = 0;
    initial begin
        if (!$value$plusargs("VECTORS=%s", path)) $fatal(1, "Missing vectors");
        fd = $fopen(path, "r");
        if (!fd) $fatal(1, "Cannot open vectors");
        cycles(3);
        @(negedge clk);
        rst_n = 1;
        while (!$feof(
            fd
        )) begin
            rc = $fscanf(fd, "%d %h %h %h %h\n", operation, a, b, c, d);
            if (rc != 5) $fatal(1, "Bad vector row %0d", row);
            row = row + 1;
            @(negedge clk);
            valid     = 0;
            ready     = 0;
            phy_error = 0;
            case (operation)
                0: begin
                    symbols   = 16'(a);
                    control   = 2'(b);
                    valid     = 1;
                    phy_error = c != 0;
                    cycles(1);
                end
                1: cycles(a);
                2: begin
                    cycles(2);
                    if (tv) $fatal(1, "Rejected/duplicate packet became visible row=%0d", row);
                end
                3: begin
                    // Hold every beat before consumption and verify metadata.
                    repeat (3) begin
                        cycles(1);
                        if (!tv || data !== 32'(a) || last !== (b != 0) || cls !== 2'(c) ||
                            credits !== 9'(d))
                            $fatal(1, "Payload/ownership changed row=%0d got=%h", row, data);
                    end
                    @(negedge clk);
                    ready = 1;
                    cycles(1);
                end
                4: begin
                    cycles(2);
                    if (dllps != a || (a != 0 && last_dllp !== 32'(b)))
                        $fatal(1, "DLLP delivery mismatch row=%0d count=%0d", row, dllps);
                end
                5: begin
                    cycles(2);
                    if (acks != a || naks != b || last_sequence !== 12'(c))
                        $fatal(
                            1,
                            "ACK/NAK/sequence mismatch row=%0d got=%0d/%0d/%h",
                            row,
                            acks,
                            naks,
                            last_sequence
                        );
                end
                default: $fatal(1, "Unknown vector opcode");
            endcase
        end
        $fclose(fd);
        $display("PASS RX fault matrix HALF_PERIOD=%0d rows=%0d", HALF_PERIOD, row);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "RX fault matrix watchdog");
    end
endmodule

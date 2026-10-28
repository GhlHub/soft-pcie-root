`timescale 1ns / 1ps
module tb_requester;
    reg clk = 0;
    always #4 clk = ~clk;
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
        1'b1
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
    initial begin
        reset();
        completer_id = 0;
        command(2, 64'h10, 0);
        packet_sent();
        if (packet[0] !== 32'h01000004 || packet[1] !== 32'h0f000000 || packet[2] !== 32'h10000001)
            $fatal(1, "CfgRd0 wire layout");
        completion(8'h77, 0, 1, 32'hbad, 0);
        if (rspvalid) $fatal(1, "Wrong tag completed request");
        completion(0, 0, 1, 32'h12348086, 0);
        response(0, 32'h12348086);
        completer_id = 16'h0100;
        command(3, 64'h4, 32'h00000006);
        packet_sent();
        if (packet[0] !== 32'h01000044 || packet[3] !== 6) $fatal(1, "CfgWr payload");
        completion(1, 0, 0, 0, 0);
        response(0, 0);
        command(0, 64'h00000001_00001000, 0);
        packet_sent();
        if (packet[0] !== 32'h01000020 || packet[2] !== 32'h01000000 || packet[3] !== 32'h00100000)
            $fatal(1, "MRd64 address");
        reserved_bits = 1;
        completion(2, 0, 1, 32'hcafef00d, 0);
        response(0, 32'hcafef00d);
        reserved_bits = 0;
        command(1, 64'h1000, 32'hdeadbeef);
        packet_sent();
        if (packet[0] !== swap(
                32'h40000001
            ) || packet[2] !== swap(
                32'h1000
            ) || packet[3] !== 32'hdeadbeef)
            $fatal(1, "Below4GiB must use3DW header");
        response(0, 0);
        command(4, 64'h100, 0);
        packet_sent();
        if (packet[0] !== 32'h01000005) $fatal(1, "Cfg1 type");
        completion(4, 1, 0, 0, 0);
        response(1, 0);
        command(2, 64'h1, 0);
        response(5, 0);
        // Matching malformed completion must not return unvalidated data.
        command(0, 64'h1000, 0);
        packet_sent();
        completion(6, 0, 1, 32'hbadf00d, 7'h20);
        response(6, 0);
        if (!fault || cmdready) $fatal(1, "Malformed completion did not quarantine");
        if (debug_packet !== 128'h4a000001_01000004_00000620_0badf00d)
            $fatal(1, "Malformed completion capture lost");
        reset();
        command(0, 64'h1000, 0);
        packet_sent();
        cycles(66);
        response(3, 0);
        if (!fault || cmdready) $fatal(1, "Timed-out tag reused");
        reset();
        command(0, 64'h1000, 0);
        packet_sent();
        up = 0;
        cycles(2);
        response(4, 0);
        reset();
        txready = 0;
        command(2, 0, 0);
        cycles(10);
        if (!tv || td !== 32'h01000004) $fatal(1, "TLP stall changed header");
        txready = 1;
        packet_sent();
        completion(0, 0, 1, 32'h12345678, 0);
        response(0, 32'h12345678);
        reset();
        command(2, 0, 0);
        packet_sent();
        completion(0, 2, 0, 0, 0);
        response(7, 0);
        if (fault || !cmdready) $fatal(1, "Configuration CRS incorrectly quarantined");
        command(2, 0, 0);
        packet_sent();
        completion(1, 0, 1, 32'h12348086, 0);
        response(0, 32'h12348086);
        reset();
        completer_id = 0;
        command(2, 0, 0);
        packet_sent();
        completion(0, 0, 1, 32'h12348086, 0);
        response(0, 32'h12348086);
        completer_id = 16'h0100;
        command(3, 4, 0);
        packet_sent();
        completion(1, 0, 0, 0, 0);
        response(0, 0);
        completer_id = 0;
        command(2, 0, 0);
        packet_sent();
        completion(2, 0, 1, 32'h12348086, 0);
        response(6, 0);
        if (!fault) $fatal(1, "Post-configuration Completer ID mismatch not quarantined");
        $display(
            "PASS requester: Cfg0/1, MRd64/MWr64, tag validation, completion errors, malformed/drop, stalls, timeout quarantine and link loss"
                );
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Requester watchdog");
    end
endmodule

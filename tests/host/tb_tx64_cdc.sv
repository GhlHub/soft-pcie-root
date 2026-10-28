`timescale 1ns / 1ps
// Independent scoreboard across host125/link250 clocks and rate fallback.
module tb_tx64_cdc;
    reg host = 0, link = 0, rst = 0, run_link = 1;
    integer half_link = 2;
    always #4 host = ~host;
    always begin
        #(half_link);
        if (run_link) link = ~link;
    end
    reg [2:0] release_q = 0;
    always @(posedge link)
        if (!rst) release_q <= 0;
        else release_q <= {release_q[1:0], 1'b1};
    reg [67:0] data = 0;
    reg valid = 0, last = 0, ready = 0;
    wire accept, cv, cl, cr, fault, ov, ol;
    wire [67:0] cd;
    wire [42:0] od;
    pcie_cdc_packet #(
        .WIDTH(68),
        .WORDS(32),
        .SLOTS(4)
    ) crossing (
        host,
        link,
        rst,
        data,
        valid,
        last,
        accept,
        fault,
        cd,
        cv,
        cl,
        cr
    );
    pcie_tx_unpack unpack (
        link,
        release_q[2],
        cd,
        cv,
        cl,
        cr,
        od,
        ov,
        ol,
        ready
    );
    integer sent = 0, received = 0, index = 0, blocked = 0, cycle = 0;
    integer lengths[0:255];
    function [31:0] value(input integer packet, word_index);
        value = 32'hac000000 ^ (packet << 8) ^ word_index;
    endfunction
    reg        stalled = 0;
    reg [43:0] held;
    always @(posedge link) begin
        if (rst && stalled && (!ov || {od, ol} !== held)) $fatal(1, "Unpack changed during stall");
        stalled <= rst && ov && !ready;
        held    <= {od, ol};
        if (rst && ov && ready) begin
            if (received >= sent) $fatal(1, "Partial packet published");
            if (od !== {2'd2, 9'(received % 5), value(received, index)})
                $fatal(1, "DWORD/credits/order mismatch");
            if (ol !== (index == lengths[received] - 1)) $fatal(1, "Wrong final DWORD");
            if (ol) begin
                received = received + 1;
                index    = 0;
            end else index = index + 1;
        end
    end
    always @(posedge host) if (rst && valid && !accept) blocked = blocked + 1;
    task packet(input integer p);
        for (integer i = 0; i < lengths[p]; i = i + 2) begin
            @(negedge host);
            data  = {3'(p % 5), i + 1 == lengths[p], value(p, i + 1), value(p, i)};
            valid = 1;
            last  = i + 2 >= lengths[p];
            do @(posedge host); while (!accept);
            if (last) sent = sent + 1;
        end
        @(negedge host);
        valid = 0;
    endtask
    initial begin
        for (integer p = 0; p < 256; p = p + 1) lengths[p] = p % 64 + 1;
        #19;
        rst = 1;
        repeat (10) @(negedge host);
        @(negedge link);
        run_link = 0;
        fork
            begin
                for (integer p = 0; p < 256; p = p + 1) packet(p);
            end
            begin
                repeat (100) @(negedge host);
                run_link = 1;
                while (received < 256) begin
                    @(negedge link);
                    cycle = cycle + 1;
                    ready = cycle % 11 > 2;
                    if (received >= 80 && received < 160) half_link = 4;
                    else half_link = 2;
                end
            end
        join
        if (fault || blocked == 0) $fatal(1, "CDC fault/missing backpressure");
        $display(
            "PASS TX64 CDC: DWORD order, lengths 1..64, credit metadata, stalls, stopped destination, fallback clock, wrap"
                );
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "TX64 watchdog");
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_tx_window;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, enable = 1, valid = 0, last = 0, ready = 0, response = 0, nak = 0;
    reg [31:0] data = 0;
    reg [11:0] response_seq = 0;
    wire accept, ov, ol, fault;
    wire [31:0] od;
    wire [3:0] pending, sent;
    wire [11:0] acknowledged, next_seq;
    gen3_tx_window #(
        .REPLAY_CYCLES(1024)
    ) dut (
        clk,
        reset,
        enable,
        data,
        valid,
        last,
        accept,
        od,
        ov,
        ol,
        ready,
        response,
        nak,
        response_seq,
        pending,
        sent,
        acknowledged,
        next_seq,
        fault,
    );
    integer frames = 0, word_index = 0, fd, max_banks = 0;
    reg          held = 0;
    reg [  32:0] previous;
    reg [1023:0] path;
    always @(posedge clk) begin
        if (reset) begin
            held       = 0;
            word_index = 0;
        end else begin
            if (held && (!ov || {ol, od} !== previous)) $fatal(1, "Stalled output changed");
            held     = ov && !ready;
            previous = {ol, od};
            if (dut.format_tlp.count > max_banks) max_banks = dut.format_tlp.count;
            if (ov && ready) begin
                $fdisplay(fd, "%0d %0d %08x", frames, word_index, od);
                if (ol) begin
                    frames     = frames + 1;
                    word_index = 0;
                end else word_index = word_index + 1;
            end
        end
    end
    task tick(input integer n);
        repeat (n) @(negedge clk);
    endtask
    task beat(input [31:0] d, input bit l);
        @(negedge clk);
        valid = 1;
        data  = d;
        last  = l;
        do @(posedge clk); while (!accept);
        @(negedge clk);
        valid = 0;
    endtask
    task packet(input [11:0] seq);
        for (integer j = 0; j < 4; j = j + 1) beat(32'ha5000000 + 32'(seq) * 4 + 32'(j), j == 3);
    endtask
    task ack(input [11:0] seq, input bit is_nak);
        @(negedge clk);
        response     = 1;
        response_seq = seq;
        nak          = is_nak;
        @(negedge clk);
        response = 0;
    endtask
    task cold_reset;
        @(negedge clk);
        reset    = 1;
        valid    = 0;
        response = 0;
        ready    = 1;
        enable   = 1;
        tick(3);
        reset = 0;
        tick(2);
    endtask
    integer base;
    initial begin
        if (!$value$plusargs("OUT=%s", path)) $fatal(1, "Missing OUT");
        fd = $fopen(path, "w");
        tick(3);
        reset = 0;
        for (integer j = 0; j < 8; j = j + 1) packet(12'(j));
        tick(30);
        if (pending != 8 || accept || max_banks != 2 || dut.store.inflight_q != 2)
            $fatal(1, "Capacity mismatch pending=%d banks=%d", pending, max_banks);
        enable = 0;
        tick(20);
        if (pending != 8) $fatal(1, "Pause lost ownership");
        enable = 1;
        ready  = 1;
        wait (sent == 8);
        tick(2);
        if (pending != 8 || frames != 8) $fatal(1, "Submission retired ownership");
        ack(3, 0);
        wait (pending == 4);
        ack(7, 0);
        wait (pending == 0);
        for (integer j = 8; j < 12; j = j + 1) packet(12'(j));
        wait (sent == 4);
        base = frames;
        ack(9, 1);
        wait (frames == base + 2);
        tick(2);
        if (pending != 2 || fault) $fatal(1, "Partial NAK replay failed");
        ack(11, 0);
        wait (pending == 0);
        // ACK arrives while the formatter is stalled on an already-sent retry.
        base = frames;
        packet(12);
        wait (frames == base + 1);
        wait (dut.store.replaying_q);
        wait (ov);
        ready = 0;
        ack(12, 0);
        tick(10);
        if (pending != 1) $fatal(1, "ACK freed a staged retransmission");
        ready = 1;
        wait (pending == 0);
        if (frames != base + 2 || fault) $fatal(1, "ACK during replay failed");
        // Wrap sequence numbers through the shared store, checking every retirement.
        for (integer j = 13; j < 4101; j = j + 1) begin
            packet(12'(j));
            wait (sent == 1);
            ack(12'(j), 0);
            wait (pending == 0);
        end
        if (next_seq != 5 || fault) $fatal(1, "Sequence wrap failed");
        // A paused partial packet survives; an impossible future ACK quarantines it.
        beat(32'ha5000014, 0);
        beat(32'ha5000015, 0);
        enable = 0;
        tick(20);
        if (!dut.store.writing_q) $fatal(1, "Partial packet lost on pause");
        enable = 1;
        beat(32'ha5000016, 0);
        beat(32'ha5000017, 1);
        wait (sent == 1);
        ack(7, 0);
        wait (fault);
        tick(5);
        if (pending != 1 || accept) $fatal(1, "Future ACK did not quarantine");
        cold_reset();
        base = frames;
        packet(0);
        wait (fault);
        if (pending != 1 || frames != base + 4) $fatal(1, "Retry exhaustion lost ownership");
        $fclose(fd);
        $display(
            "PASS: eight replay slots, two staging banks, cumulative ACK, partial NAK, timeout, ACK during replay, wrap, pause and quarantine"
                );
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "Window timeout pending=%d sent=%d fault=%b frames=%d", pending, sent, fault,
               frames);
    end
endmodule

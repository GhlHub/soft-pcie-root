// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_packet_gate;
    parameter integer WORD_INPUT = 0;
    reg clk = 0;
    always #2 clk = !clk;
    reg reset_i = 1, abort_i = 0, start = 0, last_in = 0, finish = 0, nullified = 0, ready = 0;
    reg  [10:0] length_in = 0;
    reg  [11:0] sequence_in = 0;
    reg  [31:0] body = 0;
    reg  [ 2:0] body_count = 0;
    wire [31:0] data;
    wire valid, last_out, response, nak, error;
    wire [ 1:0] packet_class;
    wire [ 8:0] credits;
    wire [11:0] response_sequence;
    reg  [64:0] inputs            [0:19999];
    reg  [15:0] expected          [0:19999];
    reg  [43:0] words             [ 0:9999];
    reg [1023:0] ipath, epath, wpath;
    integer count, word_count, i, read_index = 0, commits = 0;
    gen3_packet_gate #(
        .SLOTS     (2),
        .WORD_INPUT(WORD_INPUT)
    ) dut (
        clk,
        reset_i,
        abort_i,
        start,
        length_in,
        sequence_in,
        body,
        body_count,
        last_in,
        finish,
        nullified,
        data,
        valid,
        last_out,
        ready,
        packet_class,
        credits,
        response,
        nak,
        error,
        response_sequence
    );
    always @(posedge clk) begin
        if (!reset_i && valid && ready) begin
            if (commits == 0 || read_index >= word_count) $fatal(1, "premature packet release");
            if ({last_out, packet_class, credits, data} !== words[read_index])
                $fatal(1, "packet data/metadata mismatch at %0d", read_index);
            if (last_out) commits = commits - 1;
            read_index = read_index + 1;
        end
    end
    initial begin
        if (!$value$plusargs(
                "inputs=%s", ipath
            ) || !$value$plusargs(
                "expected=%s", epath
            ) || !$value$plusargs(
                "words=%s", wpath
            ) || !$value$plusargs(
                "count=%d", count
            ) || !$value$plusargs(
                "word_count=%d", word_count
            ))
            $fatal(1, "missing vectors");
        $readmemh(ipath, inputs, 0, count - 1);
        $readmemh(epath, expected, 0, count - 1);
        $readmemh(wpath, words, 0, word_count - 1);
        @(negedge clk);
        for (i = 0; i < count; i = i + 1) begin
            {reset_i, abort_i, start, last_in, finish, nullified, ready, length_in, sequence_in,
             body_count, body} = inputs[i];
            @(posedge clk);
            #1;
            if ({response, nak, error} != {expected[i][14:12]})
                $fatal(
                    1,
                    "response flags at %0d got=%b expected=%b",
                    i,
                    {
                        response, nak, error
                    },
                    expected[i][14:12]
                );
            if (response && response_sequence !== expected[i][11:0])
                $fatal(1, "ACK/NAK sequence mismatch at %0d", i);
            if (expected[i][15]) commits = commits + 1;
            @(negedge clk);
        end
        if (read_index != word_count || commits != 0) $fatal(1, "missing packets");
        $display(
            "PASS: whole-packet CRC/length/sequence gate, delayed commit, nullification, overflow, recovery ownership"
                );
        $finish;
    end
endmodule

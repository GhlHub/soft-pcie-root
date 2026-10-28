// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_native_rx;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, valid = 0, start = 0, ready = 0;
    reg [31:0] data = 0;
    reg [ 1:0] header = 0;
    wire aligned, event_ts, ts1, ts2, error_rx, eios, stream_start, data_valid, stream;
    wire [1:0] ec, pos;
    wire [5:0] fs, lf;
    wire [31:0] symbols, decoded;
    wire [127:0] last_ts;
    wire active, eds, tlp_valid, tlp_last, response, nak, dllp, packet_error;
    wire [31:0] tlp_data, dllp_body;
    wire [ 1:0] packet_class;
    wire [ 8:0] credits;
    wire [11:0] seq;
    gen3_native_rx rx (
        clk,
        reset,
        1'b1,
        data,
        valid,
        start,
        header,
        eds,
        packet_error,
        aligned,
        event_ts,
        ts1,
        ts2,
        ec,
        fs,
        lf,
        symbols,
        error_rx,
        eios,
        last_ts,
        stream_start,
        data_valid,
        decoded,
        pos,
        stream
    );
    gen3_data_rx #(
        .BUFFERED(1)
    ) packets (
        clk,
        reset,
        stream_start,
        error_rx,
        data_valid,
        decoded,
        pos,
        active,
        eds,
        tlp_data,
        tlp_valid,
        tlp_last,
        ready,
        packet_class,
        credits,
        response,
        nak,
        seq,
        dllp,
        dllp_body,
        packet_error,
    );
    reg [  35:0] inputs[0:19999];
    reg [1023:0] path;
    integer
        count, i, expected_errors, errors = 0, dllps = 0, acks = 0, words = 0, ts1s = 0, ts2s = 0;
    reg [31:0] expected[0:3];
    always @(posedge clk)
        if (!reset) begin
            if (error_rx || packet_error) errors = errors + 1;
            if (ts1) ts1s = ts1s + 1;
            if (ts2) ts2s = ts2s + 1;
            if (response) begin
                if (nak || seq != 0) $fatal(1, "ACK mismatch");
                acks = acks + 1;
            end
            if (dllp) begin
                if (dllp_body != 32'h12345678) $fatal(1, "DLLP mismatch");
                dllps = dllps + 1;
            end
            if (tlp_valid && ready) begin
                if (words >= 4 || tlp_data !== expected[words] || tlp_last != (words == 3))
                    $fatal(1, "committed packet lost/corrupted");
                words = words + 1;
            end
        end
    initial begin
        expected[0] = 32'h01000040;
        expected[1] = 32'h12345678;
        expected[2] = 32'h00000000;
        expected[3] = 32'hdeadbeef;
        if (!$value$plusargs(
                "inputs=%s", path
            ) || !$value$plusargs(
                "count=%d", count
            ) || !$value$plusargs(
                "errors=%d", expected_errors
            ))
            $fatal(1, "missing vectors");
        $readmemh(path, inputs, 0, count - 1);
        repeat (3) @(negedge clk);
        reset = 0;
        for (i = 0; i < count; i = i + 1) begin
            {valid, start, header, data} = inputs[i];
            @(negedge clk);
        end
        valid = 0;
        repeat (12) @(negedge clk);
        ready = 1;
        repeat (12) @(negedge clk);
        if (words != 4 || acks != 1 || dllps != 1 || ts1s != 1 || ts2s != 1 ||
            (expected_errors == 0 ? errors != 0 : errors == 0))
            $fatal(
                1,
                "counts words=%0d ACK=%0d DLLP=%0d TS=%0d/%0d errors=%0d",
                words,
                acks,
                dllps,
                ts1s,
                ts2s,
                errors
            );
        $display("PASS: native RX, committed packet survives stalls/recovery; expected_error=%0d",
                 expected_errors);
        $finish;
    end
endmodule

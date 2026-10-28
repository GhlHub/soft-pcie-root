// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_stp;
    reg  [10:0] length_in;
    reg  [11:0] sequence_in;
    reg  [31:0] token_in;
    wire [31:0] token_out;
    wire valid_stp, valid_eds;
    wire [  10:0] length_out;
    wire [  11:0] sequence_out;
    reg  [  88:0] vectors      [0:9999];
    reg  [1023:0] path;
    integer count, i;
    gen3_stp dut (
        length_in,
        sequence_in,
        token_out,
        token_in,
        valid_stp,
        valid_eds,
        length_out,
        sequence_out
    );
    initial begin
        if (!$value$plusargs("vectors=%s", path) || !$value$plusargs("count=%d", count))
            $fatal(1, "missing vectors");
        if (count > 10000) $fatal(1, "too many vectors");
        $readmemh(path, vectors, 0, count - 1);
        for (i = 0; i < count; i = i + 1) begin
            {length_in, sequence_in, token_in} = vectors[i][54:0];
            #1;
            if ({valid_eds, valid_stp, token_out} !== vectors[i][88:55])
                $fatal(1, "STP vector %0d mismatch got=%h", i, {valid_eds, valid_stp, token_out});
            if (length_out !== {token_in[14:8], token_in[7:4]} ||
                sequence_out !== {token_in[19:16], token_in[31:24]})
                $fatal(1, "decode fields");
        end
        $display("PASS: exhaustive length coding and protected-field corruptions");
        $finish;
    end
endmodule

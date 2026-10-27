// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_scrambler;
    reg clk=0;
    always #2 clk=!clk;
    reg reset_i=1, valid=0, ready=1, reseed=0;
    reg [31:0] data=0;
    reg [3:0] advance=15, xormask=15;
    wire in_ready, out_valid;
    wire [31:0] result;
    wire [22:0] state;
    reg [7:0] masks[0:127];
    reg [22:0] states[0:127];
    reg [31:0] expected, held;
    reg [22:0] held_state;
    reg [1023:0] mask_path, state_path;
    integer i, pass;
    gen3_scrambler dut(clk,reset_i,data,advance,xormask,reseed,valid,
                      in_ready,result,out_valid,ready,state);
    task send_word;
        input [31:0] word_in, word_expected;
        input [22:0] state_expected;
        begin
            data=word_in; valid=1;
            #1;
            if (!in_ready) $fatal(1,"input unexpectedly blocked");
            @(posedge clk); #1;
            if (!out_valid || result !== word_expected || state !== state_expected)
                $fatal(1,"word mismatch got=%h expected=%h state=%h expected=%h",
                       result,word_expected,state,state_expected);
            @(negedge clk); valid=0;
        end
    endtask
    initial begin
        if (!$value$plusargs("masks=%s",mask_path) || !$value$plusargs("states=%s",state_path))
            $fatal(1,"missing independent vectors");
        $readmemh(mask_path,masks); $readmemh(state_path,states);
        @(negedge clk); reset_i=0;
        // Check independent published data and state values, then inverse XOR
        // and mixed per-symbol bypass. Last word reseeds, avoiding a guessed
        // 129th state absent from the reference table.
        for (pass=0;pass<3;pass=pass+1) begin
            for (i=0;i<128;i=i+4) begin
                expected={masks[i+3],masks[i+2],masks[i+1],masks[i]};
                reseed=(i==124);
                xormask=(pass==2)?4'b0101:4'b1111;
                if (pass==0) send_word(0,expected,reseed?states[0]:states[i+4]);
                else if (pass==1) send_word(expected,0,reseed?states[0]:states[i+4]);
                else send_word(32'h12345678,32'h12345678^(expected & 32'h00ff00ff),
                               reseed?states[0]:states[i+4]);
                // Hold an occupied output under backpressure. Input activity
                // and reseed must not change data or state without acceptance.
                ready=0; valid=1; held=result; held_state=state;
                repeat (3) begin
                    data=~data;
                    @(posedge clk); #1;
                    if (in_ready || !out_valid || result!==held || state!==held_state)
                        $fatal(1,"backpressure changed ownership/state");
                    @(negedge clk);
                end
                ready=1; valid=0;
            end
        end
        reseed=0; xormask=0; advance=0;
        repeat (4) send_word(32'haabbccdd,32'haabbccdd,states[0]);
        // Bypassed symbols still advance; then EIEOS reseeds after its word.
        advance=15;
        send_word(32'h76543210,32'h76543210,states[4]);
        reseed=1;
        send_word(32'hff00ff00,32'hff00ff00,states[0]);
        reset_i=1;
        @(posedge clk); #1;
        if (out_valid || state!==states[0]) $fatal(1,"reset failed");
        $display("PASS: independent scrambler vectors, inverse, masks, stalls, SKP hold, bypass, reseed");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_stream_rx;
    reg clk=0;
    always #2 clk=!clk;
    reg reset_i=1, start_stream=0, abort_i=0, valid=0;
    reg [31:0] data=0;
    reg [1:0] position=0;
    wire active, error, eds, start, last, finish, nullified, dllp;
    wire [10:0] length_out;
    wire [11:0] sequence_out;
    wire [31:0] body;
    wire [2:0] body_count;
    wire [47:0] dllp_bytes;
    reg [37:0] inputs[0:19999];
    reg [113:0] expected[0:19999];
    wire [113:0] actual={active,error,eds,start,start?length_out:11'b0,
        start?sequence_out:12'b0,body_count!=0?body:32'b0,body_count,last,finish,
        finish?nullified:1'b0,dllp,dllp?dllp_bytes:48'b0};
    reg [1023:0] input_path, expected_path;
    integer count,i;
    gen3_stream_rx dut(clk,reset_i,start_stream,abort_i,valid,data,position,
        active,error,eds,start,length_out,sequence_out,body,body_count,last,
        finish,nullified,dllp,dllp_bytes);
    initial begin
        if(!$value$plusargs("inputs=%s",input_path) ||
           !$value$plusargs("expected=%s",expected_path) || !$value$plusargs("count=%d",count))
            $fatal(1,"missing vectors");
        if(count>20000) $fatal(1,"too many vectors");
        $readmemh(input_path,inputs,0,count-1); $readmemh(expected_path,expected,0,count-1);
        @(negedge clk);
        for(i=0;i<count;i=i+1) begin
            {reset_i,abort_i,start_stream,valid,position,data}=inputs[i];
            @(posedge clk); #1;
            if(actual!==expected[i]) $fatal(1,"stream vector %0d got=%h expected=%h",i,actual,expected[i]);
            @(negedge clk);
        end
        $display("PASS: stream token/body boundaries, deferred completion, nullification, DLLP and errors");
        $finish;
    end
endmodule

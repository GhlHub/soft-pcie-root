// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_rx_blocks;
    reg clk=0;
    always #2 clk=!clk;
    reg reset_i=1, restart_i=0, valid=0;
    reg [31:0] data=0;
    wire aligned, locked, block_valid, error;
    wire [1:0] header;
    wire [191:0] payload;
    wire [4:0] symbols;
    reg [33:0] inputs[0:19999];
    reg [202:0] expected[0:19999];
    reg [1023:0] input_path, expected_path;
    integer size, i;
    reg [202:0] want;
    gen3_rx_blocks dut(clk,reset_i,restart_i,valid,data,aligned,locked,
                       block_valid,error,header,payload,symbols);
    initial begin
        if(!$value$plusargs("inputs=%s",input_path) ||
           !$value$plusargs("expected=%s",expected_path) ||
           !$value$plusargs("size=%d",size)) $fatal(1,"missing test vectors");
        if(size>20000) $fatal(1,"too many vectors");
        $readmemh(input_path,inputs,0,size-1);
        $readmemh(expected_path,expected,0,size-1);
        @(negedge clk);
        for(i=0;i<size;i=i+1) begin
            // Alternate global reset and local acquisition restart.
            reset_i=inputs[i][32] && !i[0];
            restart_i=inputs[i][32] && i[0];
            data=inputs[i][31:0]; valid=inputs[i][33];
            want=(i==0 || inputs[i][32])?203'b0:expected[i-1];
            @(posedge clk); #1;
            if({aligned,locked,error,block_valid}!==want[202:199])
                $fatal(1,"status at %0d got=%b expected=%b",i,
                       {aligned,locked,error,block_valid},want[202:199]);
            if(block_valid && {symbols,header,payload}!==want[198:0])
                $fatal(1,"block at %0d got length=%d header=%b payload=%h expected=%h",
                       i,symbols,header,payload,want[198:0]);
            @(negedge clk);

        end
        $display("PASS: RX acquisition, SDS lock, SKP lengths, errors, restart and gaps");
        $finish;
    end
endmodule

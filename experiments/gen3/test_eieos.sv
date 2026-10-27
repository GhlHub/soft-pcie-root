// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_eieos;
    reg clk=0;
    always #2 clk=!clk;
    reg reset_i=1, search=1, valid=0;
    reg [31:0] data=0;
    wire found;
    wire [4:0] ending;
    reg [39:0] vectors[0:19999];
    reg [1023:0] vector_path;
    integer size, i;
    gen3_eieos_detect dut(clk,reset_i,search,valid,data,found,ending);
    initial begin
        if (!$value$plusargs("vectors=%s",vector_path) || !$value$plusargs("size=%d",size))
            $fatal(1,"missing vectors");
        if (size>20000) $fatal(1,"too many vectors");
        $readmemh(vector_path,vectors,0,size-1);
        @(negedge clk);
        for(i=0;i<size;i=i+1) begin
            data=vectors[i][31:0];
            search=vectors[i][38]; reset_i=vectors[i][39]; valid=1;
            @(posedge clk); #1;
            if (found!==vectors[i][37] || (found && ending!==vectors[i][36:32]))
                $fatal(1,"EIEOS vector %0d found=%b end=%d",i,found,ending);
            @(negedge clk);
            if (i%3==0) begin
                valid=0; data=~data; reset_i=0;
                @(posedge clk); #1;
                if(found) $fatal(1,"detected during invalid cycle");
                @(negedge clk);
            end
        end
        $display("PASS: EIEOS offsets, corruption, search gating, gaps and reset");
        $finish;
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_data_rx;
    parameter integer BUFFERED=1;
    reg clk=0;
    always #2 clk=!clk;
    reg reset_i=1, start_stream=0, abort_i=0, valid=0, ready=1;
    reg [31:0] data=0;
    reg [1:0] position=0;
    wire active,eds,tlp_valid,tlp_last,response,nak,dllp,error;
    wire [31:0] tlp_data,dllp_body;
    wire [1:0] packet_class;
    wire [8:0] credits;
    wire [11:0] seq;
    reg [37:0] inputs[0:19999];
    reg [43:0] words[0:9999];
    reg [1023:0] ipath,wpath;
    integer count,word_count,i,read_index=0,acks=0,dllps=0;
    gen3_data_rx #(.BUFFERED(BUFFERED)) dut(clk,reset_i,start_stream,abort_i,valid,data,position,
        active,eds,tlp_data,tlp_valid,tlp_last,ready,packet_class,credits,
        response,nak,seq,dllp,dllp_body,error,);
    always @(posedge clk) begin
        if(!reset_i) begin
            if(error || nak) $fatal(1,"unexpected receive error");
            if(response) begin
                if(seq!==12'(acks)) $fatal(1,"unexpected ACK sequence");
                acks=acks+1;
            end
            if(dllp) begin
                if(dllp_body!==32'h12345678) $fatal(1,"DLLP mismatch");
                dllps=dllps+1;
            end
            if(tlp_valid && ready) begin
                if(read_index>=word_count || {tlp_last,packet_class,credits,tlp_data}!==words[read_index])
                    $fatal(1,"integrated packet mismatch at %0d",read_index);
                read_index=read_index+1;
            end
        end
    end
    initial begin
        if(!$value$plusargs("inputs=%s",ipath) || !$value$plusargs("words=%s",wpath) ||
           !$value$plusargs("count=%d",count) || !$value$plusargs("word_count=%d",word_count))
            $fatal(1,"missing vectors");
        $readmemh(ipath,inputs,0,count-1); $readmemh(wpath,words,0,word_count-1);
        @(negedge clk);
        for(i=0;i<count;i=i+1) begin
            {reset_i,abort_i,start_stream,valid,position,data}=inputs[i];
            @(negedge clk);
        end
        valid=0; start_stream=0; abort_i=0;
        repeat(100) @(negedge clk);
        if(read_index!=word_count || acks!=40 || dllps!=40) $fatal(1,"missing integrated events");
        $display("PASS: 40 integrated TLP/DLLP frames, byte/block crossings and back-to-back packets");
        $finish;
    end
endmodule

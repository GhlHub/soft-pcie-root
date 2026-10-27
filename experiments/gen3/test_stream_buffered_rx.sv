// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_stream_buffered_rx;
    reg clk=0;always #2 clk=~clk;
    reg reset_i=1,start_stream=0,abort_i=0,valid=0;
    reg [31:0] data=0;reg [1:0] position=0;
    wire active,error,eds,start,last,finish,nullified,dllp;
    wire [10:0] length_out;wire [11:0] sequence_out;
    wire [31:0] body;wire [2:0] body_count;wire [47:0] dllp_bytes;
    reg [37:0] inputs[0:19999];reg [191:0] expected[0:1023];
    reg [1023:0] ipath,epath;
    integer count,cases,i,c=0,starts=0,lasts=0,finishes=0,nulls=0,dllps=0,ends=0,errors=0,bytes_seen=0;
    reg [31:0] hash=0;reg [22:0] stp;reg [47:0] received_dllp;
    gen3_stream_buffered_rx dut(clk,reset_i,start_stream,abort_i,valid,data,position,
        active,error,eds,start,length_out,sequence_out,body,body_count,last,finish,nullified,dllp,dllp_bytes);
    always @(posedge clk)if(!reset_i && !start_stream && !abort_i)begin
        if(start)begin starts=starts+1;stp={length_out,sequence_out};end
        for(integer b=0;b<body_count;b=b+1)begin hash=hash*33+body[8*b+:8];bytes_seen=bytes_seen+1;end
        if(last)lasts=lasts+1;
        if(finish)begin finishes=finishes+1;if(nullified)nulls=nulls+1;end
        if(dllp)begin dllps=dllps+1;received_dllp=dllp_bytes;end
        if(eds)ends=ends+1;
        if(error)errors=errors+1;
    end
    initial begin
        if(!$value$plusargs("inputs=%s",ipath) || !$value$plusargs("expected=%s",epath) ||
           !$value$plusargs("count=%d",count) || !$value$plusargs("cases=%d",cases))$fatal(1,"missing vectors");
        $readmemh(ipath,inputs,0,count-1);$readmemh(epath,expected,0,cases-1);
        @(negedge clk);
        for(i=0;i<count;i=i+1)begin
            if(inputs[i][36])begin
                valid=0;start_stream=0;repeat(8)@(negedge clk);
                if(expected[c][0])begin if(errors!=1)$fatal(1,"missing error case %0d",c);end
                else if(errors!=0 || {8'(starts),8'(lasts),8'(finishes),8'(nulls),8'(dllps),8'(ends),16'(bytes_seen),hash,stp,received_dllp,1'b0}!==expected[c][167:0])
                    $fatal(1,"buffered semantic mismatch case %0d",c);
                c=c+1;
            end
            {reset_i,abort_i,start_stream,valid,position,data}=inputs[i];
            if(start_stream)begin starts=0;lasts=0;finishes=0;nulls=0;dllps=0;ends=0;errors=0;bytes_seen=0;hash=0;end
            @(negedge clk);
        end
        if(c!=cases)$fatal(1,"missing cases");
        $display("PASS: %0d buffered parser cases, all byte offsets, nullification and malformed tokens",cases);$finish;
    end
endmodule

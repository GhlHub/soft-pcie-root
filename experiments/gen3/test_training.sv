// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_training;
    parameter integer FAULT=0;
    reg skip_block=0,injected=0;
    integer errors=0;
    reg clk=0;always #2 clk=~clk;
    reg reset=1,enable=0,stop=0;
    wire [31:0] data;wire valid,start,done,stopped;
    wire [1:0] header;wire signed [10:0] balance;
    gen3_training_tx tx(clk,reset,enable,stop,2'b01,4'd4,6'd40,6'd12,6'd0,
        data,valid,start,done,stopped,header,balance);
    wire aligned,event_ts,valid_ts,error_rx,eios;
    wire [1:0] ec;wire [5:0] fs,lf;wire [31:0] symbols;wire [127:0] last_ts;
    wire corrupt=FAULT!=0 && !injected && skip_block && valid && data[7:0]==8'he1;
    always @(posedge clk)begin
        if(valid && start)skip_block<=data[7:0]==8'haa;
        if(corrupt)injected<=1;
    end
    gen3_training_rx rx(clk,reset,enable,data^(corrupt?32'h100:32'b0),valid,start,header,aligned,event_ts,valid_ts,
        ec,fs,lf,symbols,error_rx,eios,last_ts);
    integer count=0,fd,cycle=0;
    reg [1023:0] path;
    always @(negedge clk)if(!reset)begin
        cycle=cycle+1;
        $fdisplay(fd,"%0d %0d %0d %08x %0d",cycle,valid,start,data,balance);
        if(error_rx)begin errors=errors+1;if(FAULT==0)$fatal(1,"RX framing error");end;
        if(event_ts && (valid_ts || aligned))begin
            if(!valid_ts || ec!=1 || fs!=40 || lf!=12 || symbols!=32'h000c2821)
                $fatal(1,"TS decode mismatch %08x",symbols);
            count=count+1;
        end
    end
    initial begin
        if(!$value$plusargs("OUT=%s",path))$fatal(1,"missing trace");
        fd=$fopen(path,"w");
        repeat(3)@(posedge clk);#1;reset=0;enable=1;
        wait(count==2048);@(posedge clk);#1;stop=1;
        wait(stopped);repeat(8)@(posedge clk);#1;
        if(!eios && aligned)$fatal(1,"missing EIOS");
        if(FAULT!=0 && (!injected || errors!=1))$fatal(1,"SKP corruption not detected exactly once");
        $display("PASS: training loopback, %0d TS1s, fault=%0d errors=%0d",count,FAULT,errors);$fclose(fd);$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule

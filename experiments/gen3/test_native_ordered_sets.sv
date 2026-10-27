// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_native_ordered_sets #(parameter integer GAPS=1);
    reg clk=0;always #2 clk=~clk;
    reg reset=1,enable=1,valid=0,start=0;
    reg [31:0] data=0;
    wire aligned,error_rx,eios,stream,ts1,ts2;
    gen3_native_rx dut(.clk(clk),.reset_i(reset),.enable_i(enable),
        .data_i(data),.valid_i(valid),.start_i(start),.header_i(2'b01),
        .eds_i(1'b0),.parser_error_i(1'b0),.aligned_o(aligned),
        .error_o(error_rx),.eios_o(eios),.stream_o(stream),
        .ts1_valid_o(ts1),.ts2_valid_o(ts2));
    localparam [127:0] EIEOS=128'hff00ff00ff00ff00ff00ff00ff00ff00;
    localparam [127:0] SDS=128'h555555555555555555555555555555e1;
    localparam [127:0] EIOS={4{32'h66666666}};
    task fresh;
        begin
            reset=1;valid=0;start=0;repeat(2)@(negedge clk);reset=0;
        end
    endtask
    task send_set(input [127:0] value);
        integer word_index;
        begin
            for(word_index=0;word_index<4;word_index=word_index+1)begin
                valid=1;start=word_index==0;data=value[32*word_index+:32];
                @(negedge clk);
                // Idle delivery cycles must preserve the preceding raw words.
                if(GAPS!=0 && word_index!=3)begin valid=0;@(negedge clk);end
            end
            valid=0;start=0;
            @(negedge clk); // Retire the classified final word.
        end
    endtask
    task send_training(input [127:0] value);
        reg [127:0] encoded;
        reg [22:0] state;
        integer bit_number;
        begin
            // Independent serial encoder, seeded by the preceding EIEOS.
            state=23'h1dbfbc;encoded=value;
            for(bit_number=0;bit_number<128;bit_number=bit_number+1)begin
                if(bit_number>=8)encoded[bit_number]=value[bit_number]^state[22];
                state={state[21:0],1'b0}^(state[22]?23'h210125:23'b0);
            end
            send_set(encoded);
        end
    endtask
    integer kind,bit_index;
    reg [127:0] candidate;
    reg expected_valid;
    initial begin
        @(negedge clk);
        // Every bit matters, including those in previously registered words.
        for(kind=0;kind<3;kind=kind+1)begin
            for(bit_index=-1;bit_index<128;bit_index=bit_index+1)begin
                fresh();
                if(kind!=0)begin
                    send_set(EIEOS);
                    if(!aligned || error_rx)$fatal(1,"initial EIEOS rejected");
                end
                candidate=kind==0?EIEOS:kind==1?SDS:EIOS;
                if(bit_index>=0)candidate=candidate^(128'b1<<bit_index);
                send_set(candidate);
                if(bit_index<0)begin
                    if(error_rx || (kind==0 && !aligned) ||
                       (kind==1 && !stream) || (kind==2 && (!eios || aligned)))
                        $fatal(1,"valid ordered set rejected: kind=%0d",kind);
                end else if(!error_rx || stream || eios || aligned)
                    $fatal(1,"corrupt ordered set accepted: kind=%0d bit=%0d",kind,bit_index);
            end
        end
        // Check every training bit, including deliberately unchecked fields.
        // The ranges describe the wire contract independently of word staging.
        for(kind=1;kind<=2;kind=kind+1)begin
            for(bit_index=-1;bit_index<128;bit_index=bit_index+1)begin
                fresh();send_set(EIEOS);
                candidate=kind==1?128'h4a4a4a4a4a4a000c2821000e2000001e:
                    128'h45454545454545454500000e2000002d;
                if(bit_index>=0)candidate=candidate^(128'b1<<bit_index);
                expected_valid=!(bit_index>=0 && (bit_index<24 ||
                    (bit_index>=40 && bit_index<=42) ||
                    (bit_index>=(kind==1?48:56) && bit_index<=111)));
                send_training(candidate);
                if((kind==1?ts1:ts2)!==expected_valid)
                    $fatal(1,"training validation mismatch: TS%0d bit=%0d",kind,bit_index);
            end
        end
        // A queued word must not emerge after synchronous disable/reset.
        fresh();valid=1;start=1;data=32'hff00ff00;@(negedge clk);
        reset=1;valid=0;@(negedge clk);reset=0;repeat(3)@(negedge clk);
        if(aligned || stream || ts1 || ts2 || error_rx)$fatal(1,"reset failed to flush pipeline");
        fresh();valid=1;start=1;data=32'hff00ff00;@(negedge clk);
        enable=0;valid=0;@(negedge clk);enable=1;repeat(3)@(negedge clk);
        if(aligned || stream || ts1 || ts2 || error_rx)$fatal(1,"disable failed to flush pipeline");
        $display("PASS: ordered-set bit validation, training fields, delivery gaps and pipeline reset");
        $finish;
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
// Native 32-bit PCS boundary. Packet bytes remain provisional downstream.
// Local disable/error aborts only a candidate; committed packets are not reset.
module gen3_native_rx (
    input wire clk, reset_i, enable_i,
    input wire [31:0] data_i,
    input wire valid_i, start_i,
    input wire [1:0] header_i,
    input wire eds_i, parser_error_i,
    output reg aligned_o, ts_event_o, ts1_valid_o, ts2_valid_o,
    output reg [1:0] ec_o,
    output reg [5:0] fs_o, lf_o,
    output reg [31:0] symbols6_9_o,
    output reg error_o, eios_o,
    output reg [127:0] last_ts_o,
    output reg stream_start_o, data_valid_o,
    output reg [31:0] data_o,
    output reg [1:0] position_o,
    output wire stream_o
);
    reg [1:0] index;
    reg in_block, is_skip, is_data, stream, expect_data, eds_seen;
    reg parity,pending_eds;
    reg [2:0] skip_words;
    reg [7:0] kind;
    reg [127:0] decoded;
    reg [22:0] lfsr;
    wire [1:0] at=start_i?2'b0:index;
    wire [7:0] this_kind=start_i?data_i[7:0]:kind;
    wire skip=start_i?(header_i==1 && data_i[7:0]==8'haa):is_skip;
    wire data_block=start_i?header_i==2:is_data;
    reg [31:0] word_decoded;
    reg [22:0] next_lfsr;
    reg [127:0] assembled;
    integer j,b;
    assign stream_o=stream;
    always @* begin
        word_decoded=data_i;next_lfsr=lfsr;
        for(j=0;j<4;j=j+1)begin
            for(b=0;b<8;b=b+1)begin
                if(data_block || ((this_kind==8'h1e || this_kind==8'h2d) && !(at==0 && j==0)))
                    word_decoded[8*j+b]=data_i[8*j+b]^next_lfsr[22];
                if(!skip)next_lfsr={next_lfsr[21:0],1'b0}^(next_lfsr[22]?23'h210125:23'b0);
            end
        end
        assembled=decoded;
        assembled[32*at+:32]=word_decoded;
    end
    task automatic fail;
        begin
            aligned_o<=0;stream<=0;expect_data<=0;in_block<=0;
            error_o<=1;data_valid_o<=0;stream_start_o<=0;
            ts1_valid_o<=0;ts2_valid_o<=0;
        end
    endtask
    always @(posedge clk)begin
        if(reset_i || !enable_i)begin
            aligned_o<=0;in_block<=0;is_skip<=0;is_data<=0;index<=0;kind<=0;skip_words<=0;
            lfsr<=23'h1dbfbc;ts_event_o<=0;ts1_valid_o<=0;ts2_valid_o<=0;error_o<=0;eios_o<=0;
            stream<=0;expect_data<=0;eds_seen<=0;parity<=0;pending_eds<=0;stream_start_o<=0;data_valid_o<=0;
        end else begin
            ts_event_o<=0;ts1_valid_o<=0;ts2_valid_o<=0;error_o<=0;eios_o<=0;
            stream_start_o<=0;data_valid_o<=0;
            pending_eds<=0;
            if(eds_i)eds_seen<=1;
            if(valid_i)begin
                if(start_i)begin
                    kind<=data_i[7:0];is_skip<=skip;is_data<=data_block;
                    in_block<=1;index<=1;skip_words<=1;
                    if(data_block)begin expect_data<=0;eds_seen<=0;end
                end else if(in_block && !is_skip)index<=index+1'b1;
                if(start_i || in_block)begin
                    lfsr<=next_lfsr;decoded<=assembled;
                    if(data_block)begin
                        data_valid_o<=aligned_o && stream;data_o<=word_decoded;position_o<=at;
                        parity<=parity^(^data_i);
                        if(at==3)in_block<=0;
                    end else if(skip)begin
                        if(!start_i)begin
                            skip_words<=skip_words+1'b1;
                            if(data_i[7:0]==8'he1)begin
                                in_block<=0;is_skip<=0;
                                if(skip_words<1 || skip_words>5 || !aligned_o ||
                                   data_i!={lfsr[7:0],lfsr[15:8],(stream?parity:!lfsr[22]),lfsr[22:16],8'he1})fail();
                                else if(stream)begin
                                    stream_start_o<=1;expect_data<=1;parity<=0;
                                    pending_eds<=!(eds_seen || eds_i);eds_seen<=0;
                                end
                            end else if(data_i!=32'haaaaaaaa || skip_words>=5)fail();
                        end
                    end else if(at==3)begin
                        in_block<=0;
                        if(this_kind==0 && assembled==128'hff00ff00ff00ff00ff00ff00ff00ff00)begin
                            if(stream && !(eds_seen || eds_i))fail();
                            else begin lfsr<=23'h1dbfbc;aligned_o<=1;stream<=0;end
                        end else if(this_kind==8'h1e || this_kind==8'h2d)begin
                            ts_event_o<=1;last_ts_o<=assembled;
                            symbols6_9_o<=assembled[79:48];ec_o<=assembled[49:48];
                            fs_o<=assembled[61:56];lf_o<=assembled[69:64];
                            if(stream)fail();
                            else begin
                                ts1_valid_o<=aligned_o && this_kind==8'h1e &&
                                    assembled[23:8]==0 && assembled[42:40]==0 &&
                                    assembled[111:80]==32'h4a4a4a4a && !(^assembled[79:48]);
                                ts2_valid_o<=aligned_o && this_kind==8'h2d &&
                                    assembled[23:8]==0 && assembled[42:40]==0 &&
                                    assembled[111:56]==56'h45454545454545;
                            end
                        end else if(this_kind==8'he1 && assembled==128'h555555555555555555555555555555e1)begin
                            if(!aligned_o || stream)fail();
                            else begin stream<=1;expect_data<=1;stream_start_o<=1;parity<=0;eds_seen<=0;end
                        end else if(this_kind==8'h66 && assembled=={4{32'h66666666}})begin
                            if(stream && !(eds_seen || eds_i))fail();
                            else begin eios_o<=1;aligned_o<=0;stream<=0;end
                        end else fail();
                    end
                end
                // Structural failures override all provisional output pulses.
                if((start_i && (in_block || (header_i!=1 && header_i!=2) ||
                    (expect_data && !data_block) || (data_block && (!stream || !aligned_o || (!expect_data && (eds_seen || eds_i)))) ||
                    (skip && data_i!=32'haaaaaaaa))) || (!start_i && !in_block))fail();
            end
            if(parser_error_i || (pending_eds && !eds_i) ||
               (eds_i && valid_i && data_block && !expect_data))fail();
        end
    end
endmodule

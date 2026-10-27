// SPDX-License-Identifier: Apache-2.0
// x1 32-bit Gen3 training-only PIPE source. No packet ownership or Data stream.
// Configuration changes take effect at TS boundaries. stop emits one full EIOS.
module gen3_training_tx (
    input wire clk, reset_i, enable_i, stop_i,
    input wire [1:0] ec_i,
    input wire [3:0] preset_i,
    input wire [5:0] first_i, second_i, post_i,
    output reg [31:0] data_o,
    output reg valid_o, start_o, ts_done_o, stopped_o,
    output wire [1:0] header_o,
    output reg signed [10:0] balance_o
);
    localparam [1:0] EIEOS=0,TS1=1,SKP=2,EIOS=3;
    reg [1:0] kind, word_index;
    reg [6:0] cadence;
    reg [5:0] ts_count;
    reg [8:0] skp_count;
    reg running;
    reg [22:0] lfsr;
    reg [31:0] fields;
    wire [7:0] symbol6={1'b0,preset_i,1'b0,ec_i};
    wire [23:0] low_fields={2'b0,second_i,2'b0,first_i,symbol6};
    wire [31:0] new_fields={^{1'b0,post_i,low_fields},1'b0,post_i,low_fields};
    wire [31:0] use_fields=word_index==0?new_fields:fields;
    reg [31:0] plain, encoded;
    reg [22:0] next_lfsr;
    reg signed [10:0] next_balance;
    reg [1:0] correction;
    reg [7:0] value;
    integer j,b;
    reg [5:0] ones;
    reg signed [11:0] dc_sum;
    function automatic [3:0] pop8(input [7:0] v);
        pop8=4'(v[0])+4'(v[1])+4'(v[2])+4'(v[3])+4'(v[4])+4'(v[5])+4'(v[6])+4'(v[7]);
    endfunction
    assign header_o=2'b01;
    always @* begin
        plain=32'hff00ff00;
        if(kind==EIOS)plain=32'h66666666;
        if(kind==SKP)plain=word_index==3?
            {lfsr[7:0],lfsr[15:8],!lfsr[22],lfsr[22:16],8'he1}:32'haaaaaaaa;
        if(kind==TS1)begin
            case(word_index)
                0:plain=32'h2000001e;
                1:plain={use_fields[15:0],16'h000e};
                2:plain={16'h4a4a,use_fields[31:16]};
                3:plain=32'h4a4a4a4a;
            endcase
            if(word_index==3)begin
                if(correction==2)plain[23:16]=balance_o>0?8'h20:8'hdf;
                if(correction!=0)plain[31:24]=balance_o>0?8'h08:8'hf7;
            end
        end
        encoded=plain;next_lfsr=lfsr;next_balance=balance_o;
        value=0;ones=0;dc_sum=0;
        for(j=0;j<4;j=j+1)begin
            value=plain[8*j+:8];
            for(b=0;b<8;b=b+1)begin
                if(kind==TS1 && !(word_index==0 && j==0) &&
                   !(word_index==3 && ((j==2 && correction==2)||(j==3 && correction!=0))))
                    value[b]=value[b]^next_lfsr[22];
                if(kind!=SKP)next_lfsr={next_lfsr[21:0],1'b0}^(next_lfsr[22]?23'h210125:23'b0);
            end
            encoded[8*j+:8]=value;
        end
        // Parallel word population count avoids a serial chain of four
        // saturating byte accumulators on the 250 MHz training path.
        ones={2'b0,pop8(encoded[7:0])}+{2'b0,pop8(encoded[15:8])}+
             {2'b0,pop8(encoded[23:16])}+{2'b0,pop8(encoded[31:24])};
        dc_sum=12'(balance_o)+$signed({5'b0,ones,1'b0})-12'sd32;
        if(kind==TS1)begin
            if(dc_sum>511)next_balance=11'sd511;
            else if(dc_sum< -511)next_balance=-11'sd511;
            else next_balance=dc_sum[10:0];
        end
        if(kind==EIEOS && word_index==3)next_lfsr=23'h1dbfbc;
    end
    always @(posedge clk)begin
        if(reset_i)begin
            running<=0;kind<=EIEOS;word_index<=0;cadence<=0;
            ts_count<=0;skp_count<=0;lfsr<=23'h1dbfbc;balance_o<=0;
            valid_o<=0;start_o<=0;ts_done_o<=0;stopped_o<=1;correction<=0;
        end else begin
            valid_o<=0;start_o<=0;ts_done_o<=0;
            if(!running)begin
                if(enable_i && !stop_i)begin
                    running<=1;stopped_o<=0;kind<=EIEOS;word_index<=0;
                    cadence<=0;ts_count<=0;skp_count<=0;balance_o<=0;lfsr<=23'h1dbfbc;
                end
            end else if(cadence==64)cadence<=0;
            else begin
                cadence<=cadence+1'b1;
                data_o<=encoded;valid_o<=1;start_o<=word_index==0;
                lfsr<=next_lfsr;balance_o<=next_balance;
                word_index<=word_index+1'b1;
                if(word_index==0)fields<=new_fields;
                if(kind==TS1 && word_index==2)begin
                    if(dc_sum>31 || dc_sum< -31)correction<=2;
                    else if(dc_sum>15 || dc_sum< -15)correction<=1;
                    else correction<=0;
                end
                if(word_index==3)begin
                    if(kind==TS1)begin ts_count<=ts_count+1'b1;ts_done_o<=1;end
                    if(kind==EIEOS)ts_count<=0;
                    if(kind==SKP)skp_count<=0;
                    else if(skp_count<371)skp_count<=skp_count+1'b1;
                    if(kind==EIOS)begin running<=0;stopped_o<=1;end
                    else if(stop_i || !enable_i)kind<=EIOS;
                    else if(skp_count==371 && kind!=SKP)kind<=SKP;
                    else if(kind!=EIEOS && (ts_count==32 || (ts_count==31 && kind==TS1)))kind<=EIEOS;
                    else kind<=TS1;
                end
            end
        end
    end
endmodule

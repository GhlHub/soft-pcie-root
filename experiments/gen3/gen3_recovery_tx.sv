// SPDX-License-Identifier: Apache-2.0
// Experimental x1 recovery source: TS1/TS2, SDS, idle and an optional bounded InitFC1 probe.
// Configuration changes take effect at TS boundaries. stop emits one full EIOS.
module gen3_recovery_tx (
    input wire clk, reset_i, enable_i, stop_i,
    input wire ts2_i, stream_i,
    input wire [1:0] ec_i,
    input wire [3:0] preset_i,
    input wire [5:0] first_i, second_i, post_i,
    output reg [31:0] data_o,
    output reg valid_o, start_o, ts_done_o, stopped_o,
    output wire [1:0] header_o,
    output reg signed [10:0] balance_o,
    output reg ts2_done_o, eieos_done_o, idle_word_o,
    input wire initfc1_i,
    // Complete preframed packet source; once started it must not underrun.
    input wire [31:0] packet_data_i,
    input wire packet_valid_i,packet_last_i,
    output wire packet_ready_o,
    output reg packet_submit_o,
    output reg packet_fault_o,
    output wire [4:0] profile_events_o
);
    localparam [2:0] EIEOS=0,TS1=1,SKP=2,EIOS=3,SDS=4,DATA=5;
    reg [2:0] kind;
    reg [1:0] word_index;
    reg ts2_block, stream_active, parity, close_stream;
    reg [6:0] cadence;
    reg [5:0] ts_count;
    reg [8:0] skp_count;
    reg running,packet_sending;
    wire packet_first=kind==DATA && word_index==0 && !close_stream &&
                      !initfc1_i && !stop_i && enable_i && skp_count<370;
    wire packet_emit=kind==DATA && (packet_sending || packet_first) && packet_valid_i;
    assign packet_ready_o=!reset_i && running && cadence!=64 && kind==DATA &&
                          (packet_sending || packet_first);
    assign profile_events_o={
        packet_valid_i && !packet_ready_o && kind==DATA && skp_count>=370 && !packet_sending,
        packet_valid_i && !packet_ready_o && kind==SKP,
        packet_valid_i && !packet_ready_o && cadence==64,
        packet_valid_i && !packet_ready_o && kind==DATA && !packet_sending && word_index!=0,
        idle_word_o};
    // Diagnostic only: never sends InitFC2 or issues requests. At 250 MHz,
    // 1024-cycle packet spacing repeats the P/NP/Cpl triplet in < 13 us.
    // PH=1/PD=8, NPH=1/NPD=1; Cpl infinite, with zero outstanding requests.
    reg [9:0] fc_delay;
    reg [1:0] fc_class;
    reg fc_second;
    reg [31:0] fc_tail;
    function automatic [63:0] fc_packet(input [31:0] body);
        reg [15:0] c;
        begin
            c=16'hffff;
            for(integer k=0;k<32;k=k+1)
                c=(c>>1)^((c[0]^body[k])?16'hd008:0);
            fc_packet={~c,body,16'hacf0};
        end
    endfunction
    wire [63:0] fc_bytes=fc_class==0?fc_packet(32'h08400040):
                        fc_class==1?fc_packet(32'h01400050):fc_packet(32'h00000060);
    wire fc_first=kind==DATA && word_index==0 && !close_stream &&
                  initfc1_i && fc_delay==0 && !stop_i && enable_i;
    reg [22:0] lfsr;
    reg [31:0] fields;
    wire [7:0] symbol6={1'b0,preset_i,1'b0,ec_i};
    wire [23:0] low_fields={2'b0,second_i,2'b0,first_i,symbol6};
    wire [31:0] new_fields={^{1'b0,post_i,low_fields},1'b0,post_i,low_fields};
    wire [31:0] use_fields=word_index==0?new_fields:fields;
    reg [31:0] plain, encoded, training_plain, training_encoded;
    reg [22:0] next_lfsr, advanced_lfsr;
    reg [31:0] scramble_mask;
    reg signed [10:0] next_balance;
    reg [1:0] correction;
    reg [7:0] value, training_value;
    integer j,b;
    reg [5:0] ones;
    reg signed [11:0] dc_sum;
    reg signed [6:0] half_delta;
    // Four-input truth tables map each nibble count directly into LUTs.
    // Balance the following adder tree instead of a serial sum of eight bits.
    function automatic [2:0] pop4(input [3:0] v);
        case(v)
            4'h0:pop4=0;
            4'h1,4'h2,4'h4,4'h8:pop4=1;
            4'h3,4'h5,4'h6,4'h9,4'ha,4'hc:pop4=2;
            4'h7,4'hb,4'hd,4'he:pop4=3;
            4'hf:pop4=4;
            default:pop4=3'bxxx;
        endcase
    endfunction
    function automatic [3:0] pop8(input [7:0] v);
        pop8={1'b0,pop4(v[3:0])}+{1'b0,pop4(v[7:4])};
    endfunction
    reg [1:0] header;
    assign header_o=header;
    always @* begin
        plain=32'hff00ff00;
        if(kind==EIOS)plain=32'h66666666;
        if(kind==SDS)plain=word_index==0?32'h555555e1:32'h55555555;
        if(kind==DATA)plain=(close_stream && word_index==3)?32'h0090801f:32'b0;
        if(packet_emit)plain=packet_data_i;
        if(fc_first)plain=fc_bytes[31:0];
        if(fc_second)plain=fc_tail;
        if(kind==SKP)plain=word_index==3?
            {lfsr[7:0],lfsr[15:8],(stream_active?parity:!lfsr[22]),lfsr[22:16],8'he1}:32'haaaaaaaa;
        // Keep training disparity independent of the packet-data mux.
        case(word_index)
            0:training_plain=ts2_i?32'h2000002d:32'h2000001e;
            1:training_plain=ts2_block?32'h4500000e:{use_fields[15:0],16'h000e};
            2:training_plain=ts2_block?32'h45454545:{16'h4a4a,use_fields[31:16]};
            3:training_plain=ts2_block?32'h45454545:32'h4a4a4a4a;
        endcase
        if(word_index==3)begin
            if(correction==2)training_plain[23:16]=balance_o>0?8'h20:8'hdf;
            if(correction!=0)training_plain[31:24]=balance_o>0?8'h08:8'hf7;
        end
        if(kind==TS1)plain=training_plain;
        // Fixed transform independent of SKP. Select hold/advance only after
        // generating the mask, rather than gating every unrolled bit step.
        advanced_lfsr=lfsr;
        for(b=0;b<32;b=b+1)begin
            scramble_mask[b]=advanced_lfsr[22];
            advanced_lfsr={advanced_lfsr[21:0],1'b0}^(advanced_lfsr[22]?23'h210125:23'b0);
        end
        encoded=plain;next_lfsr=kind==SKP?lfsr:advanced_lfsr;next_balance=balance_o;
        value=0;ones=0;dc_sum=0;
        for(j=0;j<4;j=j+1)begin
            value=plain[8*j+:8];
            training_value=training_plain[8*j+:8];
            for(b=0;b<8;b=b+1)begin
                if(kind==DATA || (kind==TS1 && !(word_index==0 && j==0) &&
                   !(word_index==3 && ((j==2 && correction==2)||(j==3 && correction!=0)))))
                    value[b]=value[b]^(kind==SKP?lfsr[22]:scramble_mask[8*j+b]);
                if(!(word_index==0 && j==0) &&
                   !(word_index==3 && ((j==2 && correction==2)||(j==3 && correction!=0))))
                    training_value[b]=training_value[b]^(kind==SKP?lfsr[22]:scramble_mask[8*j+b]);
            end
            encoded[8*j+:8]=value;
            training_encoded[8*j+:8]=training_value;
        end
        // Parallel word population count avoids a serial chain of four
        // saturating byte accumulators on the 250 MHz training path.
        ones=({2'b0,pop8(training_encoded[7:0])}+{2'b0,pop8(training_encoded[15:8])})+
             ({2'b0,pop8(training_encoded[23:16])}+{2'b0,pop8(training_encoded[31:24])});
        // Form the small signed word disparity before the running-balance add.
        // This avoids two serial wide carry chains; wire bytes are unchanged.
        half_delta=$signed({1'b0,ones})-7'sd16;
        dc_sum=12'(balance_o)+(12'(half_delta)<<<1);
        if(kind==TS1)begin
            if(dc_sum>511)next_balance=11'sd511;
            else if(dc_sum< -511)next_balance=-11'sd511;
            else next_balance=dc_sum[10:0];
        end
        if(kind==EIEOS && word_index==3)next_lfsr=23'h1dbfbc;
    end
    always @(posedge clk)begin
        if(reset_i)begin
            packet_sending<=0;packet_submit_o<=0;packet_fault_o<=0;
            fc_delay<=0;fc_class<=0;fc_second<=0;fc_tail<=0;
            running<=0;kind<=EIEOS;word_index<=0;cadence<=0;
            ts_count<=0;skp_count<=0;lfsr<=23'h1dbfbc;balance_o<=0;
            valid_o<=0;start_o<=0;ts_done_o<=0;stopped_o<=1;correction<=0;
            ts2_done_o<=0;eieos_done_o<=0;idle_word_o<=0;
            ts2_block<=0;stream_active<=0;parity<=0;close_stream<=0;header<=1;
        end else begin
            packet_submit_o<=0;
            if(fc_delay!=0)fc_delay<=fc_delay-1'b1;
            valid_o<=0;start_o<=0;ts_done_o<=0;
            ts2_done_o<=0;eieos_done_o<=0;idle_word_o<=0;
            if(!running)begin
                if(enable_i && !stop_i)begin
                    running<=1;stopped_o<=0;kind<=EIEOS;word_index<=0;
                    cadence<=0;ts_count<=0;skp_count<=0;balance_o<=0;lfsr<=23'h1dbfbc;
                end
            end else if(cadence==64)cadence<=0;
            else begin
                cadence<=cadence+1'b1;
                if(packet_sending && !packet_valid_i)packet_fault_o<=1;
                if(packet_emit)begin
                    packet_sending<=!packet_last_i;
                    packet_submit_o<=packet_last_i;
                end
                fc_second<=0;
                if(fc_first)begin
                    fc_tail<=fc_bytes[63:32];fc_second<=1;fc_delay<=1023;
                    fc_class<=fc_class==2?2'b0:fc_class+1'b1;
                end
                data_o<=encoded;valid_o<=1;start_o<=word_index==0;
                header<=kind==DATA?2'b10:2'b01;
                idle_word_o<=kind==DATA && !fc_first && !fc_second && !packet_emit && !(close_stream && word_index==3);
                if(kind==DATA)parity<=parity^(^encoded);
                lfsr<=next_lfsr;balance_o<=next_balance;
                word_index<=word_index+1'b1;
                if(word_index==0)begin fields<=new_fields;ts2_block<=ts2_i;end
                if(kind==TS1 && word_index==2)begin
                    if(dc_sum>31 || dc_sum< -31)correction<=2;
                    else if(dc_sum>15 || dc_sum< -15)correction<=1;
                    else correction<=0;
                end
                if(word_index==3)begin
                    if(kind==TS1)begin ts_count<=ts_count+1'b1;ts_done_o<=1;ts2_done_o<=ts2_block;end
                    if(kind==EIEOS)begin ts_count<=0;eieos_done_o<=1;end
                    if(kind==SDS)begin stream_active<=1;parity<=0;end
                    if(kind==SKP)parity<=0;
                    if(kind==SKP)skp_count<=0;
                    else if(skp_count<371)skp_count<=skp_count+1'b1;
                    if(kind==EIOS)begin running<=0;stopped_o<=1;stream_active<=0;end
                    else if(kind==DATA)begin
                        if(close_stream)begin
                            kind<=(stop_i || !enable_i)?EIOS:SKP;
                            close_stream<=0;
                        end else if((!packet_sending && !packet_emit) || (packet_emit && packet_last_i))begin
                            if(stop_i || !enable_i || skp_count>=370)close_stream<=1;
                        end
                    end else if(stream_active || kind==SDS)kind<=DATA;
                    else if(stop_i || !enable_i)kind<=EIOS;
                    else if(stream_i)kind<=SDS;
                    else if(skp_count==371 && kind!=SKP)kind<=SKP;
                    else if(kind!=EIEOS && (ts_count==32 || (ts_count==31 && kind==TS1)))kind<=EIEOS;
                    else kind<=TS1;
                end
            end
        end
    end
endmodule

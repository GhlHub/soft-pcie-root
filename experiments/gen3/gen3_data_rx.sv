// SPDX-License-Identifier: Apache-2.0
// Gen3 descrambled Data Block stream -> validated packet queue / DLLPs.
// Physical block/ordered-set transition validation is required upstream.
module gen3_data_rx #(parameter integer BUFFERED=0) (
    input wire clk, reset_i, start_stream_i, abort_i, valid_i,
    input wire [31:0] data_i,
    input wire [1:0] position_i,
    output wire active_o, eds_o,
    output wire [31:0] tlp_data_o,
    output wire tlp_valid_o, tlp_last_o,
    input wire tlp_ready_i,
    output wire [1:0] tlp_class_o,
    output wire [8:0] tlp_credits_o,
    output wire response_o, nak_o,
    output wire [11:0] response_sequence_o,
    output reg dllp_o,
    output reg [31:0] dllp_body_o,
    output wire error_o,
    output wire [3:0] diagnostic_o
);
    wire framing_error, gate_error, start, last, finish, nullified, raw_dllp;
    wire [10:0] length;
    wire [11:0] sequence_number;
    wire [31:0] body;
    wire [2:0] body_bytes;
    wire [47:0] dllp_bytes;
    reg dllp_error;
    function automatic [15:0] crc16(input [31:0] value);
        reg [15:0] c;
        begin
            c=16'hffff;
            for(integer b=0;b<32;b=b+1) c=(c>>1)^((c[0]^value[b])?16'hd008:0);
            crc16=~c;
        end
    endfunction
    generate if(BUFFERED!=0)begin: buffered
    gen3_stream_buffered_rx framing(clk,reset_i,start_stream_i,abort_i,valid_i,data_i,position_i,
        active_o,framing_error,eds_o,start,length,sequence_number,body,body_bytes,
        last,finish,nullified,raw_dllp,dllp_bytes);
    end else begin: byte_parser
    gen3_stream_rx framing(clk,reset_i,start_stream_i,abort_i,valid_i,data_i,position_i,
        active_o,framing_error,eds_o,start,length,sequence_number,body,body_bytes,
        last,finish,nullified,raw_dllp,dllp_bytes);
    end endgenerate
    gen3_packet_gate #(.WORD_INPUT(BUFFERED)) packets(clk,reset_i,abort_i || start_stream_i || framing_error,
        start,length,sequence_number,body,body_bytes,last,finish,nullified,
        tlp_data_o,tlp_valid_o,tlp_last_o,tlp_ready_i,tlp_class_o,tlp_credits_o,
        response_o,nak_o,gate_error,response_sequence_o);
    assign diagnostic_o={dllp_error,gate_error,framing_error,raw_dllp};
    assign error_o=framing_error || gate_error || dllp_error;
    always @(posedge clk) begin
        if(reset_i || abort_i || start_stream_i) begin dllp_o<=0; dllp_error<=0; end
        else begin
            dllp_o<=0; dllp_error<=0;
            if(raw_dllp) begin
                if(dllp_bytes[47:32]==crc16(dllp_bytes[31:0])) begin
                    dllp_o<=1; dllp_body_o<=dllp_bytes[31:0];
                end else dllp_error<=1;
            end
        end
    end
endmodule

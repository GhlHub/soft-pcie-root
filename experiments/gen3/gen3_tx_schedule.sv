// SPDX-License-Identifier: Apache-2.0
// Common-reference, Gen3 x1 Data-stream scheduler. Framed DWORD input includes
// STP/SDP and CRC (and EDB when nullified). A complete frame is buffered before
// transmission. Does not create TLP headers/CRCs or training sequences.
// Output is a non-stallable 32-bit PCS stream, 64 valid cycles per 65 clocks.
// PCS acceptance is NOT wire completion: retire_i must come from a downstream
// physical completion tracker. Recovery/stop never frees accepted ownership.
module gen3_tx_schedule #(
    parameter integer SKP_INTERVAL=372,
    parameter integer PACKET_WORDS=64
)(
    input wire clk, reset_i, enable_i, stop_i,
    input wire [31:0] packet_data_i,
    input wire packet_valid_i, packet_last_i,
    input wire [15:0] packet_id_i,
    output wire packet_ready_o,
    input wire retire_i, wire_drained_i,
    output reg packet_done_o, output reg [15:0] packet_done_id_o,
    output wire [31:0] tx_data_o,
    output wire tx_valid_o, output reg [1:0] tx_header_o,
    output reg tx_start_o, tx_packet_last_o,
    output wire [15:0] tx_packet_id_o,
    output wire stopped_o, output reg fault_o,
    output reg [7:0] skp_pending_o
);
    localparam [2:0] OFF=0,SDS=1,DATA=2,SKP=3,EXIT_OS=4,DRAIN=5;
    localparam integer AW=(PACKET_WORDS>1)?$clog2(PACKET_WORDS):1;
    localparam integer CW=$clog2(PACKET_WORDS+1);
    localparam integer IW=(SKP_INTERVAL>1)?$clog2(SKP_INTERVAL):1;
    (* ram_style="distributed" *) reg [31:0] memory [0:PACKET_WORDS-1];
    reg [2:0] state;
    reg [1:0] position;
    reg [CW-1:0] written, length;
    reg [AW-1:0] read_index;
    reg full, issued, sending, submitted;
    reg [15:0] packet_id;
    reg closing, exiting;
    reg [IW-1:0] interval_count;
    reg parity;
    wire slot, block_start;
    wire running=state!=OFF && state!=DRAIN;
    gen3_tx_cadence cadence(clk,reset_i,running,slot,block_start);
    wire new_packet=state==DATA && position==0 && full && !issued && skp_pending_o==0;
    wire emit_packet=state==DATA && (sending || new_packet);
    wire packet_end=emit_packet && CW'(read_index)==length-1'b1;
    wire close_block=closing || (state==DATA && position==0 && !emit_packet &&
                      (skp_pending_o!=0 || (stop_i && written==0 && (!full || issued))));
    wire exit_block=exiting || (position==0 && stop_i && written==0 && (!full || issued) && !emit_packet);
    wire block_end=slot && position==3;
    wire schedule_skp=block_end && interval_count==IW'(SKP_INTERVAL-1);
    wire sent_skp=block_end && state==SKP;
    wire consume=packet_valid_i && packet_ready_o;
    assign packet_ready_o=!reset_i && !fault_o && !full &&
                          written<CW'(PACKET_WORDS) && state==DATA &&
                          (!stop_i || written!=0);
    assign stopped_o=state==OFF && !full && written==0;
    assign tx_packet_id_o=packet_id;
    reg [31:0] plain;
    reg [3:0] advance_mask,xor_mask;
    wire [22:0] lfsr;
    wire reseed=state==EXIT_OS && position==3;
    wire unused_ready;
    always @* begin
        plain=0; advance_mask=4'hf; xor_mask=0;
        case(state)
            SDS: plain=(position==0)?32'h555555e1:32'h55555555;
            DATA: begin
                xor_mask=4'hf;
                if(emit_packet) plain=memory[read_index];
                else if(close_block && position==3) plain=32'h0090801f;
            end
            SKP: begin
                advance_mask=0;
                plain=(position==3)?{lfsr[7:0],lfsr[15:8],parity,lfsr[22:16],8'he1}:32'haaaaaaaa;
            end
            EXIT_OS: plain=32'hff00ff00; // EIEOS: Recovery (not power management)
            default: plain=0;
        endcase
    end
    gen3_scrambler scramble(clk,reset_i,plain,advance_mask,xor_mask,reseed,
        slot,unused_ready,tx_data_o,tx_valid_o,1'b1,lfsr);
    initial begin
        if(PACKET_WORDS<2 || SKP_INTERVAL<2) $fatal(1,"Invalid scheduler configuration");
    end
    always @(posedge clk) begin
        if(reset_i) begin
            state<=OFF;position<=0;written<=0;length<=0;read_index<=0;
            full<=0;issued<=0;sending<=0;submitted<=0;
            closing<=0;exiting<=0;interval_count<=0;parity<=0;
            packet_done_o<=0;tx_header_o<=0;tx_start_o<=0;tx_packet_last_o<=0;
            fault_o<=0;skp_pending_o<=0;
        end else begin
            packet_done_o<=0;
            tx_start_o<=slot && block_start;
            tx_packet_last_o<=slot && packet_end;
            if(slot) tx_header_o<=(state==DATA)?2'b10:2'b01;
            // This observes the scrambler's output, including the EDS DWORD.
            if(tx_valid_o && tx_header_o==2'b10) parity<=parity^(^tx_data_o);
            if(tx_packet_last_o && tx_valid_o) submitted<=1;
            if(retire_i) begin
                if(full && (submitted || (tx_packet_last_o && tx_valid_o))) begin
                    full<=0;issued<=0;submitted<=0;
                    packet_done_o<=1;packet_done_id_o<=packet_id;
                end else fault_o<=1;
            end
            if(consume) begin
                memory[AW'(written)]<=packet_data_i;
                if(written==0) packet_id<=packet_id_i;
                if(packet_last_i) begin
                    length<=written+1'b1;written<=0;full<=1;read_index<=0;
                end else if(written==CW'(PACKET_WORDS-1)) begin
                    // Preserve the partial bank; cannot invent a packet end.
                    written<=written+1'b1;fault_o<=1;
                end else written<=written+1'b1;
            end
            if(state==OFF) begin
                interval_count<=0;skp_pending_o<=0;position<=0;
                if(enable_i && !stop_i && !fault_o) state<=SDS;
            end else if(state==DRAIN) begin
                if(wire_drained_i && !tx_valid_o && !full && written==0) state<=OFF;
            end else if(slot) begin
                position<=position+1'b1;
                if(emit_packet) begin
                    issued<=1;
                    if(packet_end) begin sending<=0;read_index<=0; end
                    else begin sending<=1;read_index<=read_index+1'b1; end
                end
                if(state==DATA && position==0) begin closing<=close_block;exiting<=exit_block; end
                if(block_end) begin
                    if(schedule_skp) interval_count<=0;
                    else interval_count<=interval_count+1'b1;
                    case({schedule_skp,sent_skp})
                        2'b10: if(skp_pending_o==255) fault_o<=1;
                               else skp_pending_o<=skp_pending_o+1'b1;
                        2'b01: skp_pending_o<=skp_pending_o-1'b1;
                        default: begin end
                    endcase
                    case(state)
                        SDS: begin state<=DATA;parity<=0; end
                        DATA: if(close_block) begin
                            state<=exit_block?EXIT_OS:SKP; closing<=0;exiting<=0;
                        end
                        SKP: begin state<=DATA;parity<=0; end
                        EXIT_OS: state<=DRAIN;
                        default: begin end
                    endcase
                end
            end
        end
    end
endmodule

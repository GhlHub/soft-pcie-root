// SPDX-License-Identifier: Apache-2.0
// Two-bank Gen3 STP/body/LCRC formatter. Collection overlaps transmission.
// Downstream acceptance is PCS submission, not proof of wire completion.
module gen3_tlp_source # (parameter integer WORDS=64)(
 input wire clk,reset_i,
 input wire [31:0] data_i,input wire valid_i,last_i,output wire ready_o,
 input wire [11:0] sequence_i,
 output wire [31:0] data_o,output wire valid_o,last_o,input wire ready_i,
 output wire submitted_o,output reg fault_o
);
 localparam integer W=$clog2(WORDS);
 (* ram_style="distributed" *) reg [31:0] memory[0:2*WORDS-1];
 reg [W:0] lengths[0:1];reg [31:0] checksums[0:1];reg [11:0] sequences[0:1];
 reg write_bank,read_bank,collecting,dropping;
 reg [1:0] count;
 reg [W-1:0] write_index;
 reg [W:0] read_index;
 reg [31:0] crc;reg [11:0] collect_sequence;
 wire [W-1:0] index_i=collecting?write_index:W'(0);
 wire take=valid_i && ready_o;
 wire commit_packet=take && last_i && !dropping;
 wire [31:0] stp;
 wire unused_stp,unused_eds;wire [10:0] unused_length;wire [11:0] unused_seq;
 gen3_stp token(11'(lengths[read_bank])+11'd2,sequences[read_bank],stp,
  32'b0,unused_stp,unused_eds,unused_length,unused_seq);
 function automatic [31:0] crc_byte(input [31:0] old,input [7:0] value);
  reg [31:0] c;begin
   c=old;for(integer b=0;b<8;b=b+1)c=(c>>1)^((c[0]^value[b])?32'hedb88320:0);
   crc_byte=c;
  end
 endfunction
 wire [31:0] seed=collecting?crc:crc_byte(crc_byte(32'hffffffff,{4'b0,sequence_i[11:8]}),sequence_i[7:0]);
 wire [31:0] next_crc=crc_byte(crc_byte(crc_byte(crc_byte(seed,data_i[7:0]),data_i[15:8]),data_i[23:16]),data_i[31:24]);
 assign ready_o=!reset_i && (collecting || dropping || (!fault_o && count<2));
 assign valid_o=!reset_i && count!=0;
 assign last_o=read_index==lengths[read_bank]+1'b1;
 assign data_o=read_index==0?stp:last_o?checksums[read_bank]:memory[{read_bank,W'(read_index-1'b1)}];
 assign submitted_o=valid_o && ready_i && last_o;
 always @(posedge clk)begin
  if(take && !dropping)memory[{write_bank,index_i}]<=data_i;
  if(commit_packet)begin
   lengths[write_bank]<={1'b0,index_i}+1'b1;
   checksums[write_bank]<=~next_crc;
   sequences[write_bank]<=collecting?collect_sequence:sequence_i;
  end
  if(reset_i)begin
   write_bank<=0;read_bank<=0;collecting<=0;dropping<=0;count<=0;
   write_index<=0;read_index<=0;fault_o<=0;
  end else begin
   count<=count+2'(commit_packet)-2'(submitted_o);
   if(take)begin
    if(last_i)begin
     collecting<=0;dropping<=0;write_index<=0;
     if(!dropping)write_bank<=!write_bank;
    end else begin
     collecting<=1;write_index<=index_i+1'b1;
     if(index_i==W'(WORDS-1))begin dropping<=1;fault_o<=1;end
    end
    if(!collecting)collect_sequence<=sequence_i;
    crc<=next_crc;
   end
   if(valid_o && ready_i)begin
    if(last_o)begin read_index<=0;read_bank<=!read_bank;end
    else read_index<=read_index+1'b1;
   end
  end
 end
 wire unused=^{unused_stp,unused_eds,unused_length,unused_seq};
endmodule

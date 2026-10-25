// Two-bank store-and-forward Gen1/Gen2 x1 serializer: two symbols/cycle.
// Collection/CRC of the next packet overlaps wire transmission of the head.
// Caller muxes this only in L0; hold_i pauses only between complete packets.
module pcie_soft_packet_tx #(
 parameter integer MAX_DWORDS=64
)(
 input wire clk,rst_n,hold_i,
 input wire [31:0] tlp_data_i,
 input wire tlp_valid_i,tlp_last_i,
 output wire tlp_ready_o,
 input wire [11:0] sequence_i,
 input wire dllp_valid_i,
 output wire dllp_ready_o,
 input wire [31:0] dllp_body_i,
 output reg [15:0] symbols_o,
 output reg [1:0] control_o,
 output wire packet_done_o,idle_o,transmitting_o,
 output reg overflow_o
);
 localparam integer W=$clog2(MAX_DWORDS);
 localparam [1:0] IDLE=0,SEND=1,DLLP=2;
 reg [1:0] state_q;
 reg collecting_q,dropping_q,write_bank_q,read_bank_q;
 reg [1:0] count_q;
 (* ram_style="distributed" *) reg [31:0] payload[0:2*MAX_DWORDS-1];
 reg [W:0] bank_words[0:1];
 reg [11:0] bank_sequence[0:1];
 reg [31:0] bank_crc[0:1];
 wire [W:0] words_q=bank_words[read_bank_q];
 reg [W-1:0] write_q;
 reg [W+3:0] symbol_q;
 reg [11:0] collect_sequence_q;
 wire [11:0] sequence_q=bank_sequence[read_bank_q];
 reg [31:0] collect_crc_q,body_q;
 wire [31:0] crc_q=bank_crc[read_bank_q];
 reg [15:0] dllp_crc_q;
 function automatic [31:0] crc32_byte(input [31:0] old,input [7:0] octet);
  reg [31:0] c;begin c=old;for(integer b=0;b<8;b=b+1)c=(c>>1)^((c[0]^octet[b])?32'hedb88320:0);crc32_byte=c;end
 endfunction
 function automatic [31:0] crc32_dword(input [31:0] old,input [31:0] data);
  reg [31:0] c;begin c=old;for(integer b=0;b<4;b=b+1)c=crc32_byte(c,data[b*8+:8]);crc32_dword=c;end
 endfunction
 function automatic [15:0] crc16_body(input [31:0] body);
  reg [15:0] c;begin c=16'hffff;for(integer b=0;b<32;b=b+1)c=(c>>1)^((c[0]^body[b])?16'hd008:0);crc16_body=~c;end
 endfunction
 function automatic [7:0] byte_at(input integer pos);
  integer payload_index;
  begin
   payload_index=pos-3;
   if(pos==0) byte_at=8'hfb;
   else if(pos==1) byte_at={4'b0,sequence_q[11:8]};
   else if(pos==2) byte_at=sequence_q[7:0];
   else if(pos<3+4*int'(words_q)) byte_at=payload[int'(read_bank_q)*MAX_DWORDS+payload_index/4][8*(payload_index%4)+:8];
   else if(pos<7+4*int'(words_q)) byte_at=8'((~crc_q)>>(8*(pos-3-4*int'(words_q))));
   else byte_at=8'hfd;
  end
 endfunction
 // A bank is owned from first input beat through final wire symbol. No RAM
 // reset: complete-count and collecting/drop state establish validity.
 assign tlp_ready_o=rst_n && (collecting_q || dropping_q || (!hold_i && count_q<2));
 assign dllp_ready_o=rst_n && state_q==IDLE&&!hold_i;
 assign packet_done_o=state_q==SEND && symbol_q==(W+4)'(4*int'(words_q)+6);
 assign idle_o=state_q==IDLE && count_q==0 && !collecting_q && !dropping_q;
 assign transmitting_o=state_q==SEND || state_q==DLLP;
 wire input_fire=tlp_valid_i&&tlp_ready_o;
 wire commit_packet=input_fire&&tlp_last_i&&!dropping_q;
 wire [W-1:0] input_word=collecting_q?write_q:W'(0);
 wire [31:0] next_crc=crc32_dword(collecting_q?collect_crc_q:
   crc32_byte(crc32_byte(32'hffffffff,{4'b0,sequence_i[11:8]}),sequence_i[7:0]),tlp_data_i);
 always @(posedge clk) begin
  if(rst_n && input_fire && !dropping_q) payload[{write_bank_q,input_word}]<=tlp_data_i;
  if(rst_n && commit_packet) begin
   bank_words[write_bank_q]<={1'b0,input_word}+1'b1;
   bank_sequence[write_bank_q]<=collecting_q?collect_sequence_q:sequence_i;
   bank_crc[write_bank_q]<=next_crc;
  end
 end
 always @* begin
  symbols_o=0;control_o=0;
  if(state_q==SEND) begin
   symbols_o={byte_at(int'(symbol_q)+1),byte_at(int'(symbol_q))};
   if(symbol_q==0) control_o[0]=1;
   if(packet_done_o) control_o[1]=1;
  end else if(state_q==DLLP) begin
   case(symbol_q)
    0:begin symbols_o={body_q[7:0],8'h5c};control_o=1;end
    2:symbols_o=body_q[23:8];
    4:symbols_o={dllp_crc_q[7:0],body_q[31:24]};
    default:begin symbols_o={8'hfd,dllp_crc_q[15:8]};control_o=2;end
   endcase
  end
 end
 always @(posedge clk) begin
  if(!rst_n) begin
   state_q<=IDLE;write_q<=0;symbol_q<=0;
   collecting_q<=0;dropping_q<=0;write_bank_q<=0;read_bank_q<=0;count_q<=0;
   collect_sequence_q<=0;collect_crc_q<=32'hffffffff;
   body_q<=0;dllp_crc_q<=0;overflow_o<=0;
  end else begin
   overflow_o<=0;
   count_q<=count_q+2'(commit_packet)-2'(packet_done_o);
   if(input_fire) begin
    if(!dropping_q) begin
     collect_crc_q<=next_crc;
     if(!collecting_q) collect_sequence_q<=sequence_i;
     write_q<=input_word+1'b1;
    end
    if(tlp_last_i) begin
     collecting_q<=0;dropping_q<=0;write_q<=0;
     if(!dropping_q) write_bank_q<=!write_bank_q;
    end else if(!dropping_q && input_word==W'(MAX_DWORDS-1)) begin
     collecting_q<=0;dropping_q<=1;overflow_o<=1;
    end else if(!dropping_q) collecting_q<=1;
   end
   case(state_q)
    IDLE: if(!hold_i) begin
     symbol_q<=0;
     // ACK/FC DLLPs have priority at packet boundaries, even with queued TLPs.
     if(dllp_valid_i) begin
      body_q<=dllp_body_i;dllp_crc_q<=crc16_body(dllp_body_i);state_q<=DLLP;
     end else if(count_q!=0) state_q<=SEND;
    end
    SEND: if(packet_done_o) begin
     read_bank_q<=!read_bank_q;state_q<=IDLE;
    end else symbol_q<=symbol_q+2;
    DLLP: if(symbol_q==6) state_q<=IDLE;else symbol_q<=symbol_q+2;
    default:state_q<=IDLE;
   endcase
  end
 end
endmodule

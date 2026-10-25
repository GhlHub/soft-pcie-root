// Original restricted-profile PCIe completer. All signals use clk (125 MHz).
// Incoming TLPs are already link/LCRC/sequence validated. Wire header bytes
// are reversed relative to a conventional DWORD; payload is little-endian.
// Four whole requests may wait behind preparation and independent write execution.
// Two same-ID AXI bursts may be outstanding; 64-bit beats carry two DWORDs.
// Reads/MSI fence all prior B responses. No accepted ownership is cancelled.
module pcie_ddr_bridge(
 input wire clk,rst_n,link_active_i,dma_enable_i,
 input wire [31:0] rx_data_i,input wire rx_valid_i,rx_last_i,output wire rx_ready_o,
 output reg [31:0] tx_data_o,output wire tx_valid_o,tx_last_o,input wire tx_ready_i,
 output wire [8:0] tx_credits_o,
 output reg msi_valid_o,output reg [4:0] msi_vector_o,
 output reg fault_o,output wire idle_o,
 output wire [31:0] perf_events_o,
 output wire [31:0] m_axi_awaddr,output wire [7:0] m_axi_awlen,
 output wire [2:0] m_axi_awsize,output wire [1:0] m_axi_awburst,
 output wire [3:0] m_axi_awcache,output wire [2:0] m_axi_awprot,
 output wire m_axi_awvalid,input wire m_axi_awready,
 output reg [63:0] m_axi_wdata,output reg [7:0] m_axi_wstrb,
 output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
 input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,output wire m_axi_bready,
 output wire [31:0] m_axi_araddr,output wire [7:0] m_axi_arlen,
 output wire [2:0] m_axi_arsize,output wire [1:0] m_axi_arburst,
 output wire [3:0] m_axi_arcache,output wire [2:0] m_axi_arprot,
 output wire m_axi_arvalid,input wire m_axi_arready,
 input wire [63:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
 input wire m_axi_rlast,m_axi_rvalid,output wire m_axi_rready
);
 localparam [3:0] RX=0,CHECK=1,DRAIN=4,RA=5,PREP=7,TX=8;
 localparam [1:0] W_IDLE=0,W_ADDR=1,W_DATA=2;
 reg [3:0] state_q;
 // No reset on packet storage. State/counts alone establish validity.
 reg [31:0] packet_q[0:35],read_q[0:31];
 reg [5:0] count_q,write_index_q,tx_index_q;
 reg overflow_q,lost_q;
 // Independent execution buffer: preparation may overwrite packet_q only
 // after the validated write payload/metadata have transferred here. The
 // buffer is owned through WLAST; B ownership remains in write_out_q.
 reg [31:0] write_data_q[0:31];
 reg [1:0] write_state_q;
 reg [31:2] write_address_q;
 reg [5:0] write_length_q;
 reg [3:0] write_first_be_q,write_last_be_q;
 wire write_busy=write_state_q!=W_IDLE;
 reg [31:0] address_q;
 reg [10:0] remaining_q;
 reg [4:0] chunk_q;
 reg [12:0] byte_count_q;
 reg [15:0] requester_q;reg [7:0] tag_q;
 reg [3:0] first_be_q,last_be_q;
 reg [2:0] status_q;
 reg [6:0] lower_q;
 // Two completion slots, each one RCB64 burst. Address issuance, R capture
 // and completion transmission have independent ownership. Same AXI ID keeps
 // responses ordered. A held AR offer is drained even after link loss/error.
 reg [1:0] write_out_q,read_slots_q,read_pending_q;
 reg read_run_q,read_abort_q,ar_offer_q,read_issue_q,read_response_q,read_tx_q;
 reg [31:0] issue_address_q;
 reg [10:0] issue_remaining_q;
 reg [4:0] slot_chunk_q[0:1];
 reg slot_offset_q[0:1];
 reg [1:0] slot_done_q,slot_bad_q;
 reg [4:0] read_index_q;
 wire [4:0] issue_chunk=issue_remaining_q<(11'd16-{7'b0,issue_address_q[5:2]})?
     issue_remaining_q[4:0]:(5'd16-{1'b0,issue_address_q[5:2]});
 wire [4:0] issue_beats=(issue_chunk+{4'b0,issue_address_q[2]}+5'd1)>>1;
 wire [4:0] response_beats=(slot_chunk_q[read_response_q]+{4'b0,slot_offset_q[read_response_q]}+5'd1)>>1;
 wire aw_accept=m_axi_awvalid&&m_axi_awready;
 wire b_accept=m_axi_bvalid&&m_axi_bready;
 wire ar_accept=m_axi_arvalid&&m_axi_arready;
 wire r_accept=m_axi_rvalid&&m_axi_rready;
 wire r_end=r_accept&&m_axi_rlast;
 wire r_error=r_accept&&(m_axi_rresp!=0||m_axi_rlast!=(read_index_q==response_beats-1'b1));
 wire read_pop=read_run_q&&((state_q==TX&&tx_valid_o&&tx_ready_i&&tx_last_o)||
     (state_q==DRAIN&&read_slots_q!=0&&slot_done_q[read_tx_q]));
 wire read_finish=state_q==DRAIN&&read_slots_q==0&&read_pending_q==0&&!ar_offer_q;

 function automatic [31:0] swap(input [31:0] v);swap={v[7:0],v[15:8],v[23:16],v[31:24]};endfunction
 function automatic [1:0] last(input [3:0] v);last=v[3]?3:v[2]?2:v[1]?1:v[0]?0:0;endfunction
 function automatic [1:0] first(input [3:0] v);first=v[0]?0:v[1]?1:v[2]?2:v[3]?3:0;endfunction
 wire [31:0] h0=swap(packet_q[0]),h1=swap(packet_q[1]);
 wire four=h0[29],write_req=h0[30],memory_req=h0[28:24]==0;
 wire [10:0] length_dw=h0[9:0]==0?11'd1024:{1'b0,h0[9:0]};
 wire [63:0] addr=four?{swap(packet_q[2]),swap(packet_q[3])}:{32'b0,swap(packet_q[2])};
 wire [3:0] fbe=h1[3:0],lbe=h1[7:4];
 wire [2:0] single_span=fbe[3]?3'd4-{1'b0,first(fbe)}:fbe[2]?3'd3-{1'b0,first(fbe)}:fbe[1]?3'd2-{1'b0,first(fbe)}:3'd1;
 wire [12:0] bytes_req=length_dw==1?{10'b0,single_span}:({2'b0,length_dw}<<2)-{11'b0,first(fbe)}-(13'd3-{11'b0,last(lbe)});
 wire be_bad=length_dw==1?lbe!=0:
  (fbe==0||lbe==0||(!(length_dw==2&&addr[2]==0)&&!((fbe==8||fbe==12||fbe==14||fbe==15)&&(lbe==1||lbe==3||lbe==7||lbe==15))));
 wire unused_header=^{h0[23],h0[19],h0[17:16]};
 wire semantic_bad=h0[31]||h0[22:20]!=0||h0[18]||h0[15:12]!=0||h0[11:10]!=0||addr[1:0]!=0||be_bad;
 wire [12:0] end_page={1'b0,addr[11:0]}+({2'b0,length_dw}<<2);
 wire ddr_range=addr[63:31]==0 && ({1'b0,addr[30:0]}+({21'b0,length_dw}<<2))<=32'h80000000;
 wire [5:0] header_dw=four?6'd4:6'd3;
 wire shape_bad=overflow_q || (write_req?({5'b0,count_q}!=({5'b0,header_dw}+length_dw)):count_q!=header_dw);
 wire msi_address=addr==64'hfee00000;
 wire [31:0] msi_data=four?packet_q[4]:packet_q[3];
 wire check_ready=!link_active_i||(!write_busy&&
     (write_out_q==0||(memory_req&&write_req&&!msi_address&&write_out_q<2)));
 wire write_launch=state_q==CHECK&&check_ready&&link_active_i&&
     !semantic_bad&&!shape_bad&&end_page<=4096&&memory_req&&write_req&&
     !msi_address&&ddr_range&&dma_enable_i&&!fault_o&&
     !(b_accept&&m_axi_bresp!=0)&&length_dw<=32;
 wire [12:0] chunk_bytes=({8'b0,chunk_q}<<2)-{11'b0,first(first_be_q)} -
                    (remaining_q=={6'b0,chunk_q} && remaining_q!=1?(13'd3-{11'b0,last(last_be_q)}):13'd0);
 // Four bounded whole-packet slots. Oversize packets are drained and replayed
 // to the validator as 37 DWORDs, which can never pass its length check.
 // Storage is deliberately unreset; pointers/lengths establish validity.
 reg [31:0] pending_data_q[0:143];
 reg [5:0] pending_length_q[0:3];
 reg [1:0] pending_wr_q,pending_rd_q;
 reg [2:0] pending_count_q;
 reg [5:0] pending_fill_q,pending_send_q;
 wire pending_push=rx_valid_i&&rx_ready_o&&rx_last_i;
 wire engine_valid=pending_count_q!=0&&link_active_i;
 wire engine_ready=state_q==RX&&link_active_i;
 wire engine_last=pending_send_q==pending_length_q[pending_rd_q]-1'b1;
 wire pending_pop=engine_valid&&engine_ready&&engine_last;
 wire [31:0] engine_data=pending_send_q<36?
     pending_data_q[{6'b0,pending_rd_q}*8'd36+{2'b0,pending_send_q}]:32'b0;
 // Passive host-clock profiling. Events overlap; see the DBR1 contract.
 // No event or counter feeds transaction admission, ordering or reset.
 assign perf_events_o[0]=1'b1;
 assign perf_events_o[1]=read_run_q;
 assign perf_events_o[2]=state_q==RA&&!slot_done_q[read_tx_q];
 assign perf_events_o[3]=state_q==RA&&slot_done_q[read_tx_q];
 assign perf_events_o[4]=tx_valid_o&&!tx_ready_i;
 assign perf_events_o[5]=tx_valid_o&&tx_ready_i;
 assign perf_events_o[6]=tx_valid_o&&tx_ready_i&&tx_index_q>=3&&status_q==0;
 assign perf_events_o[7]=tx_valid_o&&tx_ready_i&&tx_last_o;
 assign perf_events_o[8]=ar_accept;
 assign perf_events_o[9]=m_axi_arvalid&&!m_axi_arready;
 assign perf_events_o[10]=r_accept;
 assign perf_events_o[11]=r_end;
 assign perf_events_o[12]=m_axi_rready&&!m_axi_rvalid;
 assign perf_events_o[13]=m_axi_rready&&!m_axi_rvalid&&read_index_q==0;
 assign perf_events_o[14]=read_pending_q==1;
 assign perf_events_o[15]=read_pending_q==2;
 assign perf_events_o[16]=read_slots_q==2;
 assign perf_events_o[17]=read_run_q&&issue_remaining_q!=0&&read_slots_q==2;
 assign perf_events_o[18]=state_q==RX&&!engine_valid;
 assign perf_events_o[19]=state_q==RX&&engine_valid;
 assign perf_events_o[20]=state_q==CHECK&&!check_ready;
 assign perf_events_o[21]=state_q==PREP;
 assign perf_events_o[22]=state_q==DRAIN;
 assign perf_events_o[23]=r_accept&&read_index_q==0;
 assign perf_events_o[24]=pending_count_q!=0&&state_q!=RX;
 assign perf_events_o[25]=rx_valid_i&&!rx_ready_o;
 assign perf_events_o[26]=write_busy;
 assign perf_events_o[27]=write_out_q!=0;
 assign perf_events_o[28]=fault_o;
 assign perf_events_o[29]=link_active_i;
 assign perf_events_o[30]=state_q==CHECK;
 assign perf_events_o[31]=msi_valid_o;
 assign idle_o=state_q==RX&&count_q==0&&pending_count_q==0&&pending_fill_q==0&&write_out_q==0&&!write_busy&&!read_run_q&&!ar_offer_q;
 assign rx_ready_o=pending_count_q<4&&link_active_i;
 always @(posedge clk) begin
  if(rx_valid_i&&rx_ready_o&&pending_fill_q<36)
   pending_data_q[{6'b0,pending_wr_q}*8'd36+{2'b0,pending_fill_q}]<=rx_data_i;
  if(!rst_n||!link_active_i)begin
   pending_wr_q<=0;pending_rd_q<=0;pending_count_q<=0;
   pending_fill_q<=0;pending_send_q<=0;
  end else begin
   case({pending_push,pending_pop})
    2'b10:pending_count_q<=pending_count_q+1'b1;
    2'b01:pending_count_q<=pending_count_q-1'b1;
    default:begin end
   endcase
   if(rx_valid_i&&rx_ready_o)begin
    if(rx_last_i)begin
     pending_length_q[pending_wr_q]<=pending_fill_q+1'b1;
     pending_wr_q<=pending_wr_q+1'b1;pending_fill_q<=0;
    end else if(pending_fill_q<36)pending_fill_q<=pending_fill_q+1'b1;
   end
   if(engine_valid&&engine_ready)begin
    if(engine_last)begin pending_rd_q<=pending_rd_q+1'b1;pending_send_q<=0;end
    else pending_send_q<=pending_send_q+1'b1;
   end
  end
 end
 assign tx_valid_o=state_q==TX&&link_active_i&&!lost_q;
 assign tx_last_o=status_q!=0?tx_index_q==2:tx_index_q==({1'b0,chunk_q}+2);
 assign tx_credits_o=status_q!=0?0:({4'b0,chunk_q}+3)>>2;
 always @* begin
  case(tx_index_q)
   0:tx_data_o=swap(status_q!=0?32'h0a000000:(32'h4a000000|{27'b0,chunk_q}));
   1:tx_data_o=swap({16'b0,status_q,1'b0,byte_count_q[11:0]});
   2:tx_data_o=swap({requester_q,tag_q,1'b0,lower_q});
   default:tx_data_o=remaining_q==1&&first_be_q==0?32'b0:read_q[{read_tx_q,(tx_index_q[3:0]-4'd3)}];
  endcase
 end
 // Align DDR bursts to eight bytes, masking unused write lanes. Validation
 // precedes rounding, so aligned reads stay inside DDR and the same 4KiB page.
 wire [6:0] write_beats=({1'b0,write_length_q}+{6'b0,write_address_q[2]}+7'd1)>>1;
 integer lane,dword_index;
 always @* begin
  m_axi_wdata=0;m_axi_wstrb=0;dword_index=0;
  for(lane=0;lane<2;lane=lane+1)begin
   dword_index=2*int'(write_index_q)+lane-int'(write_address_q[2]);
   if(dword_index>=0&&dword_index<int'(write_length_q)&&dword_index<32)begin
    m_axi_wdata[lane*32+:32]=write_data_q[dword_index];
    m_axi_wstrb[lane*4+:4]=dword_index==0?write_first_be_q:
        dword_index==int'(write_length_q)-1?write_last_be_q:4'hf;
   end
  end
 end
 assign m_axi_awaddr={write_address_q[31:3],3'b0};assign m_axi_awlen={1'b0,write_beats}-1'b1;
 assign m_axi_awsize=3;assign m_axi_awburst=1;assign m_axi_awcache=4'b0011;assign m_axi_awprot=0;
 assign m_axi_awvalid=write_state_q==W_ADDR;
 assign m_axi_wlast={1'b0,write_index_q}==write_beats-1'b1;
 assign m_axi_wvalid=write_state_q==W_DATA;assign m_axi_bready=write_out_q!=0;
 assign m_axi_araddr={issue_address_q[31:3],3'b0};assign m_axi_arlen={3'b0,issue_beats}-1'b1;
 assign m_axi_arsize=3;assign m_axi_arburst=1;assign m_axi_arcache=4'b0011;assign m_axi_arprot=0;
 assign m_axi_arvalid=ar_offer_q;assign m_axi_rready=read_pending_q!=0;
 integer read_lane;
 wire [5:0] read_base={read_index_q,1'b0}-{5'b0,slot_offset_q[read_response_q]};
 always @(posedge clk) begin
  if(engine_valid&&engine_ready&&count_q<36)packet_q[count_q]<=engine_data;
  if(m_axi_rvalid&&m_axi_rready)begin
   for(read_lane=0;read_lane<2;read_lane=read_lane+1)begin
    if((read_index_q!=0||!slot_offset_q[read_response_q]||read_lane!=0)&&
       6'(read_base+6'(read_lane))<{1'b0,slot_chunk_q[read_response_q]})
     read_q[{read_response_q,4'(read_base+6'(read_lane))}]<=m_axi_rdata[read_lane*32+:32];
   end
  end
  if(!rst_n)begin
   state_q<=RX;count_q<=0;overflow_q<=0;tx_index_q<=0;
   address_q<=0;remaining_q<=0;chunk_q<=0;byte_count_q<=0;
   requester_q<=0;tag_q<=0;first_be_q<=0;last_be_q<=0;status_q<=0;lower_q<=0;
   lost_q<=0;msi_valid_o<=0;msi_vector_o<=0;fault_o<=0;
  end else begin
   msi_valid_o<=0;
   // A link loss never withdraws an accepted AXI request. Finish that request,
   // then discard its completion and latch a fatal recovery requirement.
   if(!link_active_i&&(state_q!=RX||pending_count_q!=0||pending_fill_q!=0||write_out_q!=0||write_busy||read_run_q))begin lost_q<=1;fault_o<=1;end
   if((b_accept&&m_axi_bresp!=0)||r_error)fault_o<=1;
   case(state_q)
    RX:if(!link_active_i)begin
     if(count_q!=0)fault_o<=1;count_q<=0;overflow_q<=0;
    end else if(engine_valid&&engine_ready)begin
     if(count_q<36)count_q<=count_q+1'b1;else overflow_q<=1;
     if(engine_last)state_q<=CHECK;
    end
    CHECK:if(check_ready)begin
     requester_q<=h1[31:16];tag_q<=h1[15:8];address_q<=addr[31:0];remaining_q<=length_dw;
     first_be_q<=fbe;last_be_q<=lbe;lower_q<=addr[6:0]+{5'b0,first(fbe)};
     byte_count_q<=bytes_req==0?13'd4:bytes_req;status_q<=0;lost_q<=!link_active_i;
     // Unsupported requests get UR; malformed/poisoned requests are dropped.
     if(!link_active_i||semantic_bad||shape_bad||end_page>4096)begin fault_o<=1;state_q<=RX;count_q<=0;overflow_q<=0;end
     else if(memory_req&&write_req&&msi_address&&length_dw==1&&fbe==15&&msi_data<32)begin
      if(!fault_o)begin msi_valid_o<=1;msi_vector_o<=msi_data[4:0];end
      state_q<=RX;count_q<=0;
     end else if(memory_req&&ddr_range&&dma_enable_i&&!fault_o&&!(b_accept&&m_axi_bresp!=0)&&(!write_req||length_dw<=32))begin
      if(!write_req&&length_dw==1&&fbe==0)begin
       chunk_q<=1;tx_index_q<=0;lower_q<=addr[6:0];state_q<=TX;
      end else if(write_req)begin
        // Ownership transfers to the independent writer on write_launch.
        state_q<=RX;count_q<=0;
       end else state_q<=PREP;
     end else begin
      fault_o<=1;
      if(!write_req)begin status_q<=1;byte_count_q<=0;lower_q<=0;tx_index_q<=0;state_q<=TX;end
      else begin state_q<=RX;count_q<=0;end
     end
    end
    PREP:state_q<=RA;
    RA:begin
     if(lost_q||!link_active_i)state_q<=DRAIN;
     else if(slot_done_q[read_tx_q])begin
      chunk_q<=slot_chunk_q[read_tx_q];tx_index_q<=0;state_q<=TX;
      if(slot_bad_q[read_tx_q])begin status_q<=4;byte_count_q<=0;lower_q<=0;end
     end
    end
    DRAIN:if(read_finish)begin state_q<=RX;count_q<=0;end
    TX:begin
     if(lost_q||!link_active_i)begin state_q<=read_run_q?DRAIN:RX;count_q<=0;end
     else if(tx_ready_i)begin
      if(tx_last_o)begin
       if(status_q==0&&remaining_q>{6'b0,chunk_q})begin
        remaining_q<=remaining_q-{6'b0,chunk_q};address_q<=address_q+({27'b0,chunk_q}<<2);
        byte_count_q<=byte_count_q-chunk_bytes;lower_q<=(address_q[6:0]+({2'b0,chunk_q}<<2));
        first_be_q<=15;state_q<=RA;
       end else begin state_q<=read_run_q?DRAIN:RX;count_q<=0;end
      end else tx_index_q<=tx_index_q+1'b1;
     end
    end
    default:state_q<=RX;
   endcase
  end
 end
 // Whole-packet validation precedes this transfer. RAM has no reset.
 // Once offered, AW and W must drain even if link, admission or fault changes.
 integer write_copy;
 always @(posedge clk)begin
  if(write_launch)begin
   for(write_copy=0;write_copy<32;write_copy=write_copy+1)
    write_data_q[write_copy]<=four?packet_q[write_copy+4]:packet_q[write_copy+3];
  end
  if(!rst_n)begin
   write_state_q<=W_IDLE;write_index_q<=0;write_address_q<=0;
   write_length_q<=0;write_first_be_q<=0;write_last_be_q<=0;
  end else case(write_state_q)
   W_IDLE:if(write_launch)begin
    write_state_q<=W_ADDR;write_index_q<=0;write_address_q<=addr[31:2];
    write_length_q<=length_dw[5:0];write_first_be_q<=fbe;write_last_be_q<=lbe;
   end
   W_ADDR:if(m_axi_awready)write_state_q<=W_DATA;
   W_DATA:if(m_axi_wready)begin
    if(m_axi_wlast)write_state_q<=W_IDLE;
    else write_index_q<=write_index_q+1'b1;
   end
   default:write_state_q<=W_IDLE;
  endcase
 end
 // AXI ownership is reset only by the system/global reset, never link/PERST.
 always @(posedge clk)begin
  if(!rst_n)begin
   write_out_q<=0;read_slots_q<=0;read_pending_q<=0;
   read_run_q<=0;read_abort_q<=0;ar_offer_q<=0;
   read_issue_q<=0;read_response_q<=0;read_tx_q<=0;
   issue_address_q<=0;issue_remaining_q<=0;read_index_q<=0;
   slot_done_q<=0;slot_bad_q<=0;
  end else begin
   case({aw_accept,b_accept})
    2'b10:write_out_q<=write_out_q+1'b1;
    2'b01:write_out_q<=write_out_q-1'b1;
    default:begin end
   endcase
   case({ar_accept,read_pop})
    2'b10:read_slots_q<=read_slots_q+1'b1;
    2'b01:read_slots_q<=read_slots_q-1'b1;
    default:begin end
   endcase
   case({ar_accept,r_end})
    2'b10:read_pending_q<=read_pending_q+1'b1;
    2'b01:read_pending_q<=read_pending_q-1'b1;
    default:begin end
   endcase
   if(state_q==PREP)begin
    read_run_q<=1;read_abort_q<=0;issue_address_q<=address_q;issue_remaining_q<=remaining_q;
   end
   if(read_finish)read_run_q<=0;
   if(read_run_q&&(!link_active_i||r_error))read_abort_q<=1;
   if(!ar_offer_q&&read_run_q&&!read_abort_q&&!r_error&&link_active_i&&
      state_q!=DRAIN&&issue_remaining_q!=0&&read_slots_q<2)ar_offer_q<=1;
   if(ar_accept)begin
    ar_offer_q<=0;
    slot_chunk_q[read_issue_q]<=issue_chunk;slot_offset_q[read_issue_q]<=issue_address_q[2];
    slot_done_q[read_issue_q]<=0;slot_bad_q[read_issue_q]<=0;
    read_issue_q<=!read_issue_q;
    issue_address_q<=issue_address_q+({27'b0,issue_chunk}<<2);
    issue_remaining_q<=issue_remaining_q-{6'b0,issue_chunk};
   end
   if(r_accept)begin
    if(r_error)slot_bad_q[read_response_q]<=1;
    if(m_axi_rlast)begin
     slot_done_q[read_response_q]<=1;read_response_q<=!read_response_q;read_index_q<=0;
    end else if(read_index_q<16)read_index_q<=read_index_q+1'b1;
   end
   if(read_pop)begin slot_done_q[read_tx_q]<=0;read_tx_q<=!read_tx_q;end
  end
 end
endmodule

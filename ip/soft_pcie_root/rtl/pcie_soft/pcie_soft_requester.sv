// Bounded root-port requester: one DWORD per command, one non-posted tag.
// TLP stream bytes are in wire order, earliest byte in bits[7:0]. Payload
// DWORDs retain host little-endian order. No implicit access to host memory.
module pcie_soft_requester #(
    parameter [15:0] REQUESTER_ID=16'h0000,
    parameter integer COMPLETION_TIMEOUT=6250000
)(
    input wire clk,rst_n,link_up_i,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    // 0=MRd,1=MWr (3DW below4GiB, otherwise4DW),2=CfgRd0,3=CfgWr0,4=CfgRd1,5=CfgWr1.
    input wire [2:0] cmd_op_i,
    input wire [63:0] cmd_address_i,
    input wire [15:0] cmd_bdf_i,
    input wire [31:0] cmd_data_i,
    input wire [3:0] cmd_be_i,
    output wire [31:0] tx_data_o,
    output wire tx_valid_o,tx_last_o,
    input wire tx_ready_i,tx_sent_i,
    output wire [1:0] tx_class_o,
    output wire [8:0] tx_data_credits_o,
    input wire [31:0] rx_data_i,
    input wire rx_valid_i,rx_last_i,
    output wire rx_ready_o,
    output reg rsp_valid_o,
    input wire rsp_ready_i,
    output reg [31:0] rsp_data_o,
    // 0=success,1=UR,2=CA/other completion error,3=timeout,
    // 4=link loss,5=invalid command,6=malformed matching completion,7=configuration CRS.
    output reg [2:0] rsp_status_o,
    output reg unexpected_o,
    output reg fault_o,
    output reg [127:0] completion_debug_o,
    input wire timeout_tick_i
);
    localparam integer TW=$clog2(COMPLETION_TIMEOUT+1);
    localparam [2:0] IDLE=0,SEND=1,SENT=2,WAIT=3,HOLD=4;
    reg [2:0] state_q,index_q,op_q;
    reg [63:0] address_q;
    reg [15:0] bdf_q,configured_bdf_q;
    reg completer_id_valid_q;
    reg [31:0] data_q;
    reg [3:0] be_q;
    reg [7:0] tag_q,next_tag_q;
    reg [TW-1:0] timer_q;
    reg [31:0] h0_q,h1_q,h2_q;
    reg [7:0] rx_index_q;
    reg rx_oversize_q;
    wire write_cmd=op_q[0];
    wire config_cmd=op_q>=2;
    wire four_address=!config_cmd&&address_q[63:32]!=0;
    wire [2:0] last_index= config_cmd?(write_cmd?3:2):(four_address?(write_cmd?4:3):(write_cmd?3:2));
    function automatic [31:0] swap(input [31:0] value);
        swap={value[7:0],value[15:8],value[23:16],value[31:24]};
    endfunction
    function automatic [2:0] first_byte(input [3:0] mask);
        first_byte=mask[0]?0:mask[1]?1:mask[2]?2:mask[3]?3:0;
    endfunction
    function automatic [2:0] byte_span(input [3:0] mask);
        reg [2:0] last_byte;
        begin
            last_byte=mask[3]?3:mask[2]?2:mask[1]?1:0;
            byte_span=last_byte-first_byte(mask)+1'b1;
        end
    endfunction
    reg [31:0] header;
    always @* begin
        header=0;
        case(index_q)
            0: header={config_cmd?(op_q[2]? (write_cmd?8'h45:8'h05):(write_cmd?8'h44:8'h04)):
                                    (four_address?(write_cmd?8'h60:8'h20):(write_cmd?8'h40:8'h00)),24'h000001};
            1: header={REQUESTER_ID,tag_q,4'b0,be_q};
            2: header=config_cmd?{bdf_q,4'b0,address_q[11:2],2'b0}:(four_address?address_q[63:32]:address_q[31:0]);
            3: header=address_q[31:0];
            default: header=0;
        endcase
    end
    assign tx_data_o=write_cmd && index_q==last_index?data_q:swap(header);
    assign tx_valid_o=state_q==SEND && link_up_i;
    assign tx_last_o=index_q==last_index;
    assign tx_class_o=config_cmd||!write_cmd?2'd1:2'd0;
    assign tx_data_credits_o=write_cmd?9'd1:9'd0;
    assign cmd_ready_o=state_q==IDLE && link_up_i && !fault_o;
    assign rx_ready_o=1'b1; // Completion slot was reserved at command acceptance.
    wire [31:0] incoming=swap(rx_data_i);
    wire completion_type=h0_q[28:24]==5'b01010;
    wire response_matches=h2_q[31:16]==REQUESTER_ID && h2_q[15:8]==tag_q;
    wire has_data=h0_q[30];
    wire [11:0] expected_bytes=config_cmd?12'd4:{9'b0,byte_span(be_q)};
    wire [6:0] expected_lower=address_q[6:0]+{4'b0,first_byte(be_q)};
    wire unused_reserved=^{h0_q[23],h0_q[19:16],h0_q[11:10],h2_q[7]};
    // Reserved fields are ignored on receive. This profile uses TC0, Attr0,
    // no ECRC and rejects poison/BCM; these are semantic fields, not reserved.
    wire common_bad=rx_oversize_q || h0_q[22:20]!=0 || h0_q[15:12]!=0 || h1_q[12] ||
                    (config_cmd && completer_id_valid_q && bdf_q==configured_bdf_q && h1_q[31:16]!=bdf_q);
    wire bad_completion=common_bad || h0_q[31] || h0_q[29] ||
        (h1_q[15:13]==0 &&
         ((write_cmd && (has_data || h0_q[9:0]!=0 || rx_index_q!=2)) ||
          (!write_cmd && (!has_data || h0_q[9:0]!=1 || rx_index_q!=3 ||
           h1_q[11:0]!=expected_bytes ||
           (!config_cmd && h2_q[6:0]!=expected_lower)))));
    always @(posedge clk) begin
        if(!rst_n) begin
            completion_debug_o<=0;completer_id_valid_q<=0;configured_bdf_q<=0;
            state_q<=IDLE;index_q<=0;op_q<=0;address_q<=0;bdf_q<=0;data_q<=0;be_q<=0;
            tag_q<=0;next_tag_q<=0;timer_q<=0;rx_index_q<=0;rx_oversize_q<=0;
            rsp_valid_o<=0;rsp_data_o<=0;rsp_status_o<=0;unexpected_o<=0;fault_o<=0;
        end else begin
            unexpected_o<=0;
            // PCIe2.0 section2.2.9: Completer ID is not meaningful before
            // software initializes the function with a configuration write.
            if(!link_up_i)completer_id_valid_q<=0;
            if(rsp_valid_o && rsp_ready_i && rsp_status_o==0 && config_cmd && write_cmd)begin
                completer_id_valid_q<=1;configured_bdf_q<=bdf_q;
            end
            if(rsp_valid_o && rsp_ready_i) begin rsp_valid_o<=0;state_q<=IDLE;end
            if(cmd_valid_i && cmd_ready_o) begin
                op_q<=cmd_op_i;address_q<=cmd_address_i;bdf_q<=cmd_bdf_i;data_q<=cmd_data_i;be_q<=cmd_be_i;
                tag_q<=next_tag_q;next_tag_q<=next_tag_q+1'b1;index_q<=0;timer_q<=0;
                if(cmd_op_i>5 || cmd_be_i==0 || cmd_address_i[1:0]!=0 ||
                   (cmd_op_i>=2 && cmd_address_i[63:12]!=0)) begin
                    rsp_status_o<=5;rsp_data_o<=0;rsp_valid_o<=1;state_q<=HOLD;
                end else state_q<=SEND;
            end
            if(tx_valid_o && tx_ready_i) begin
                if(tx_last_o) state_q<=SENT;
                else index_q<=index_q+1'b1;
            end
            if(tx_sent_i && (state_q==SENT || (tx_valid_o && tx_ready_i && tx_last_o))) begin
                if(write_cmd && !config_cmd) begin
                    rsp_status_o<=0;rsp_data_o<=0;rsp_valid_o<=1;state_q<=HOLD;
                end else begin state_q<=WAIT;timer_q<=0;end
            end
            if(state_q==WAIT&&timeout_tick_i) begin
                if(timer_q==TW'(COMPLETION_TIMEOUT-1)) begin
                    rsp_status_o<=3;rsp_data_o<=0;rsp_valid_o<=1;state_q<=HOLD;fault_o<=1;
                end else timer_q<=timer_q+1'b1;
            end
            if(rx_valid_i) begin
                case(rx_index_q)
                    0: h0_q<=incoming;
                    1: h1_q<=incoming;
                    2: h2_q<=incoming;
                    default: rx_oversize_q<=1;
                endcase
                if(rx_last_i) begin
                    // Informational last packet only; never bypasses validation.
                    completion_debug_o<={h0_q,h1_q,(rx_index_q==2?incoming:h2_q),rx_data_i};
                    rx_index_q<=0;rx_oversize_q<=0;
                    // Last header/data beat is current input, not the stale reg.
                    if(rx_index_q==2) begin
                        if(state_q==WAIT && completion_type && incoming[31:16]==REQUESTER_ID && incoming[15:8]==tag_q) begin
                            rsp_valid_o<=1;rsp_data_o<=0;state_q<=HOLD;
                            if(common_bad || h0_q[31:29]!=0 || h0_q[9:0]!=0) begin rsp_status_o<=6;fault_o<=1;end
                            else if(h1_q[15:13]!=0) rsp_status_o<=h1_q[15:13]==1?3'd1:(config_cmd&&h1_q[15:13]==2)?3'd7:3'd2;
                            else if(!write_cmd || h0_q[30:29]!=0 || h0_q[9:0]!=0 || rx_oversize_q) begin rsp_status_o<=6;fault_o<=1;end
                            else rsp_status_o<=0;
                        end else unexpected_o<=1;
                    end else if(state_q==WAIT && completion_type && response_matches) begin
                        rsp_valid_o<=1;state_q<=HOLD;
                        if(bad_completion) begin rsp_status_o<=6;rsp_data_o<=0;fault_o<=1;end
                        else if(h1_q[15:13]!=0) begin rsp_status_o<=h1_q[15:13]==1?3'd1:(config_cmd&&h1_q[15:13]==2)?3'd7:3'd2;rsp_data_o<=0;end
                        else begin rsp_status_o<=0;rsp_data_o<=rx_data_i;end
                    end else unexpected_o<=1;
                end else if(rx_index_q!=255) rx_index_q<=rx_index_q+1'b1;
                else rx_oversize_q<=1;
            end
            if(!link_up_i && (state_q==SEND || state_q==SENT || state_q==WAIT)) begin
                rsp_status_o<=4;rsp_data_o<=0;rsp_valid_o<=1;state_q<=HOLD;fault_o<=1;
            end
        end
    end
endmodule

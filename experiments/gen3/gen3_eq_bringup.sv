// SPDX-License-Identifier: Apache-2.0
// Experimental downstream x1 PHY/training integration and optional Data Link.
// Cold reset only: Recovery/stop must preserve accepted packet ownership.
// CONFIG_PROBE performs one bounded configuration read without PS/AXI effects.
module gen3_eq_bringup #(
    // 100 ms at Gen1 PCLK; covers 12 ms Detect quiet + 24/48 ms polling.
    parameter integer RECOVERY_ENABLE=0,
    parameter integer STARTUP_TIMEOUT=12500000,
    parameter integer HANDSHAKE_TIMEOUT=6000000,
    parameter integer EQ_TIMEOUT=6000000,
    parameter integer INITFC1_PROBE=0,
    parameter integer DATALINK_ENABLE=0,
    parameter integer CONFIG_PROBE=0,
    parameter integer OBSERVE_CYCLES=250000
) (
    input wire clk, reset_i, phy_ready_i,
    input wire [3:0] preset_i,
    input wire [31:0] rx_data_i,
    input wire [1:0] rx_k_i,
    input wire rx_valid_i, rx_data_valid_i, rx_start_i,
    input wire [1:0] rx_header_i,
    input wire rx_idle_i, phystatus_i,
    input wire [2:0] rx_status_i,
    input wire txeq_done_i,
    input wire [5:0] txeq_fs_i, txeq_lf_i,
    input wire [17:0] txeq_coeff_i,
    output wire [31:0] tx_data_o,
    output wire [1:0] tx_k_o,tx_header_o,
    output wire tx_valid_o,tx_start_o,
    output wire detect_o,
    output wire idle_o,
    output wire polarity_o,
    output reg [1:0] rate_o, txeq_ctrl_o,
    output wire [3:0] txeq_preset_o,
    output wire [127:0] last_ts_o,
    output wire [127:0] status_o,
    output wire [1:0] powerdown_o,
    input wire cmd_valid_i,output wire cmd_ready_o,input wire [2:0] cmd_op_i,
    input wire [63:0] cmd_address_i,input wire [15:0] cmd_bdf_i,
    input wire [31:0] cmd_data_i,input wire [3:0] cmd_be_i,
    output wire rsp_valid_o,input wire rsp_ready_i,output wire [31:0] rsp_data_o,
    output wire [2:0] rsp_status_o,
    input wire [31:0] app_tx_data_i,input wire app_tx_valid_i,app_tx_last_i,
    output wire app_tx_ready_o,input wire [1:0] app_tx_class_i,input wire [8:0] app_tx_credits_i,
    output wire [31:0] app_rx_data_o,output wire app_rx_valid_o,app_rx_last_o,input wire app_rx_ready_i,
    output wire dl_active_o,link_error_o
);
    reg [9:0] skp_pairs;
    reg [1:0] skp_phase;
    wire [1:0] tx_legacy_k,rx_unused_k,tx_keep,rx_keep;
    wire tx_ready,tx_v,rx_ready,rx_v;
    localparam [4:0] LEGACY=0,LOCK=1,CONFIG=2,EIOS=3,EI=4,PRESET=5,
        QUERY_GAP=6,QUERY=7,RATE_ARM=8,RATE_WAIT=9,EQ_START=10,EQ=11,
        OBSERVE=12,STOP=13,FINISHED=14,FAILED=15,RCFG=16,RIDLE=17,RL0=18;
    reg [4:0] state;
    reg reached_idle,reached_l0;
    reg [23:0] timer;
    reg [1:0] detect_phase;
    reg detect_complete,detected_present;
    reg [10:0] tx_count;
    reg [3:0] good;
    reg [7:0] last_rate;
    reg peer_eios;
    reg [3:0] failure;
    reg [3:0] preset;
    reg [5:0] local_fs,local_lf;
    reg [17:0] local_coeff;
    reg [15:0] previous_rx;
    reg [1:0] previous_k;
    wire ts_valid,ts2,inverted,ts_bad,link_pad,lane_pad;
    wire [7:0] rx_link,rx_lane,rx_rate,rx_control;
    wire [1:0] legacy_kind,legacy_txkind;
    wire [7:0] legacy_link,legacy_lane,legacy_rate;
    wire legacy_lp,legacy_np,legacy_l0,legacy_idle,legacy_detect,legacy_failed;
    wire [4:0] legacy_state;
    wire [15:0] training_data,tx_legacy_data,rx_descrambled;
    wire [1:0] training_k;
    wire training_valid,training_done,training_boundary;
    wire gen3_mode=rate_o==2 && state>=EQ_START;
    wire legacy_error=rx_valid_i && rx_status_i[2];
    wire unused_link,unused_hold,unused_retrain,unused_eios,unused_speed,unused_target,unused_fallback,unused_deemph;
    gen3_startup_ltssm #(.GEN2_ENABLE(0)) startup (
        .clk(clk),.rst_n(!reset_i),.enable_i(1'b1),.phy_ready_i(phy_ready_i),
        .rx_electrical_idle_i(rx_idle_i),.detect_done_i(detect_complete),
        .receiver_present_i(detected_present),.detect_o(legacy_detect),.electrical_idle_o(legacy_idle),
        .retrain_i(1'b0),.retrain_done_o(unused_retrain),.ts_valid_i(ts_valid),.ts2_i(ts2),
        .inverted_i(inverted),.ts_bad_i(ts_bad),.rx_link_i(rx_link),.rx_lane_i(rx_lane),
        .rx_rate_i(rx_rate),.rx_control_i(rx_control),.rx_link_pad_i(link_pad),.rx_lane_pad_i(lane_pad),
        .tx_ts_done_i(training_done),.tx_ts_kind_i(legacy_txkind),
        .rx_idle_pair_i(rx_v && rx_unused_k==0 && rx_descrambled==0),
        .tx_idle_pair_i(!training_valid && skp_phase==0),.rx_error_i(legacy_error),.tx_kind_o(legacy_kind),
        .tx_link_o(legacy_link),.tx_lane_o(legacy_lane),.tx_link_pad_o(legacy_lp),.tx_lane_pad_o(legacy_np),
        .link_up_o(unused_link),.l0_o(legacy_l0),.timer_hold_o(unused_hold),
        .polarity_o(polarity_o),.failed_o(legacy_failed),.state_o(legacy_state),
        .force_gen1_i(1'b1),.phy_gen2_i(1'b0),.phy_rate_ready_i(1'b1),.eios_done_i(1'b0),
        .tx_rate_o(legacy_rate),.eios_o(unused_eios),.speed_idle_o(unused_speed),
        .target_gen2_o(unused_target),.fallback_o(unused_fallback),.deemphasis_o(unused_deemph));
    always @(posedge clk)begin
        if(reset_i)begin skp_pairs<=0;skp_phase<=0;end
        else if(state<=CONFIG)begin
            if(skp_phase==1)skp_phase<=2;
            else if(skp_phase==2)begin skp_phase<=0;skp_pairs<=0;end
            else if(skp_pairs>=640 && training_boundary)skp_phase<=1;
            else if(skp_pairs<1023)skp_pairs<=skp_pairs+1'b1;
        end else skp_phase<=0;
    end
    wire [1:0] training_kind=state==LEGACY?legacy_kind:state==LOCK?2'd1:state==CONFIG?2'd2:2'd0;
    gen3_legacy_training legacy_codec (
        .clk(clk),.rst_n(!reset_i),.tx_ready_i(skp_phase==0),.tx_kind_i(training_kind),
        .tx_link_i(legacy_link),.tx_lane_i(legacy_lane),.tx_control_i(8'b0),
        .tx_link_pad_i(state==LEGACY && legacy_lp),.tx_lane_pad_i(state==LEGACY && legacy_np),
        .tx_data_o(training_data),.tx_ctrl_o(training_k),.tx_valid_o(training_valid),
        .tx_done_o(training_done),.tx_boundary_o(training_boundary),.tx_kind_o(legacy_txkind),
        .rx_data_i(rx_data_i[15:0]),.rx_ctrl_i(rx_k_i),
        .rx_valid_i(rx_valid_i && rate_o==0),.rx_error_i(legacy_error),
        .rx_ts_valid_o(ts_valid),.rx_ts2_o(ts2),.rx_inverted_o(inverted),.rx_bad_o(ts_bad),
        .rx_link_o(rx_link),.rx_lane_o(rx_lane),.rx_rate_o(rx_rate),.rx_control_o(rx_control),
        .rx_link_pad_o(link_pad),.rx_lane_pad_o(lane_pad),
        .tx_eq_i(state==LOCK || state==CONFIG),.tx_preset_i(preset),
        .tx_rate_i(state==LEGACY?8'h0e:8'h8e));
    wire [15:0] legacy_plain=state==EIOS?(timer[0]?16'h7c7c:16'h7cbc):
                                  skp_phase==1?16'h1cbc:skp_phase==2?16'h1c1c:training_valid?training_data:16'b0;
    wire [1:0] legacy_k=state==EIOS || skp_phase!=0?2'b11:training_valid?training_k:2'b0;
    wire [15:0] tx_lfsr,rx_lfsr;
    pcie_soft_scrambler legacy_tx(clk,!reset_i,legacy_plain,legacy_k,2'b11,
        {2{!training_valid && state!=EIOS}},1'b1,tx_ready,tx_legacy_data,tx_legacy_k,
        tx_keep,tx_v,1'b1,tx_lfsr);
    pcie_soft_scrambler legacy_rx(clk,!reset_i,rx_data_i[15:0],rx_k_i,2'b11,2'b11,
        rx_valid_i,rx_ready,rx_descrambled,rx_unused_k,rx_keep,rx_v,1'b1,rx_lfsr);
    wire [31:0] gen3_data;wire gen3_valid,gen3_start,gen3_done,gen3_stopped;
    wire [1:0] gen3_header;wire signed [10:0] balance;
    wire eq_active,eq_txvalid,eq_lock,eq_phase2,eq_speed,eq_success,eq_s2,eq_s3,eq_complete,eq_skip,eq_failed;
    wire [1:0] eq_ec;wire [3:0] eq_preset;
    wire [5:0] eq_fs,eq_lf,eq_post,peer_fs,peer_lf;
    wire [2:0] eq_reason;wire [15:0] eq_events;
    wire aligned,event_ts,valid_ts,error_rx,eios_rx;
    wire [1:0] rx_ec;wire [5:0] fs,lf;wire [31:0] symbols;
    wire [31:0] packet_tx_data;
    wire packet_tx_valid,packet_tx_last,packet_tx_ready,packet_submit,packet_tx_fault;
    wire [4:0] pcs_profile;
    wire dl_active,fc_error;
    wire tx_ts2_done,tx_eieos_done,tx_idle_word;
    generate if(RECOVERY_ENABLE!=0)begin: recovery_tx
    gen3_recovery_tx tx3(clk,reset_i,gen3_mode,(state==STOP || state==FAILED || state==FINISHED),
        state==RCFG,state==RIDLE || state==RL0,
        state==EQ || state==EQ_START?2'b01:2'b00,preset,
        state==EQ || state==EQ_START?local_fs:local_coeff[17:12],
        state==EQ || state==EQ_START?local_lf:local_coeff[11:6],local_coeff[5:0],
        gen3_data,gen3_valid,gen3_start,gen3_done,gen3_stopped,gen3_header,balance,tx_ts2_done,tx_eieos_done,tx_idle_word,INITFC1_PROBE!=0 && state==RL0,
        packet_tx_data,packet_tx_valid,packet_tx_last,packet_tx_ready,packet_submit,packet_tx_fault,pcs_profile);
    end else begin: eq_tx
    gen3_training_tx tx3(clk,reset_i,gen3_mode,(state==STOP || state==FAILED || state==FINISHED),
        state==EQ || state==EQ_START?2'b01:2'b00,preset,
        state==EQ || state==EQ_START?local_fs:local_coeff[17:12],
        state==EQ || state==EQ_START?local_lf:local_coeff[11:6],local_coeff[5:0],
        gen3_data,gen3_valid,gen3_start,gen3_done,gen3_stopped,gen3_header,balance);
        assign tx_ts2_done=0;assign tx_eieos_done=0;assign tx_idle_word=0;
        assign pcs_profile=0;
        assign packet_tx_ready=0;assign packet_submit=0;assign packet_tx_fault=0;
    end endgenerate
    reg [31:0] rx_pipe_data;
    reg [1:0] rx_pipe_header;
    reg rx_pipe_valid,rx_pipe_start;
    always @(posedge clk)begin
        if(reset_i)rx_pipe_valid<=0;
        else rx_pipe_valid<=gen3_mode && rx_data_valid_i && rx_valid_i;
        rx_pipe_data<=rx_data_i;rx_pipe_header<=rx_header_i;rx_pipe_start<=rx_start_i;
    end
    wire [3:0] packet_diagnostic;
    wire valid_ts2,stream_start,data_valid,rx_stream,parser_eds,parser_error;
    wire [31:0] decoded_data;wire [1:0] data_position;
    wire [127:0] native_last_ts;
    gen3_native_rx rx3(clk,reset_i,gen3_mode,rx_pipe_data,rx_pipe_valid,
        rx_pipe_start,rx_pipe_header,parser_eds,DATALINK_ENABLE!=0?packet_diagnostic[1]:parser_error,
        aligned,event_ts,valid_ts,valid_ts2,rx_ec,fs,lf,symbols,error_rx,eios_rx,native_last_ts,
        stream_start,data_valid,decoded_data,data_position,rx_stream);
    wire packet_active,tlp_valid,tlp_last,response,nak,dllp,tlp_ready;
    wire [31:0] tlp_data,dllp_body;wire [1:0] tlp_class;
    wire [8:0] credits;wire [11:0] sequence_number;
    gen3_data_rx #(.BUFFERED(1)) packets(clk,reset_i,stream_start,error_rx || !gen3_mode,
        data_valid,decoded_data,data_position,packet_active,parser_eds,
        tlp_data,tlp_valid,tlp_last,tlp_ready,tlp_class,credits,response,nak,sequence_number,
        dllp,dllp_body,parser_error,packet_diagnostic);

    wire [127:0] completion_debug;
    wire link_pending;
    reg probe_issued,probe_done;
    reg [31:0] probe_data;
    reg [2:0] probe_status;
    assign dl_active_o=dl_active && state==RL0 && !fc_error && !packet_tx_fault;
    assign link_error_o=fc_error || packet_tx_fault;
    always @(posedge clk)begin
        if(reset_i)begin probe_issued<=0;probe_done<=0;probe_data<=0;probe_status<=0;end
        else if(CONFIG_PROBE!=0)begin
            if(cmd_ready_o && !probe_issued)probe_issued<=1;
            if(rsp_valid_o)begin probe_done<=1;probe_data<=rsp_data_o;probe_status<=rsp_status_o;end
        end
    end
    generate if(DATALINK_ENABLE!=0)begin: data_link
        gen3_link_layer link(clk,reset_i,reached_l0,state==RL0,
            tlp_data,tlp_valid,tlp_last,tlp_ready,tlp_class,credits,response,nak,sequence_number,dllp,dllp_body,
            packet_tx_data,packet_tx_valid,packet_tx_last,packet_tx_ready,
            CONFIG_PROBE!=0?!probe_issued:cmd_valid_i,cmd_ready_o,
            CONFIG_PROBE!=0?3'd2:cmd_op_i,CONFIG_PROBE!=0?64'b0:cmd_address_i,
            CONFIG_PROBE!=0?16'h0100:cmd_bdf_i,CONFIG_PROBE!=0?32'b0:cmd_data_i,
            CONFIG_PROBE!=0?4'hf:cmd_be_i,rsp_valid_o,CONFIG_PROBE!=0?1'b1:rsp_ready_i,rsp_data_o,rsp_status_o,
            app_tx_data_i,app_tx_valid_i,app_tx_last_i,app_tx_ready_o,app_tx_class_i,app_tx_credits_i,
            app_rx_data_o,app_rx_valid_o,app_rx_last_o,app_rx_ready_i,
            dl_active,fc_error,link_pending,completion_debug,pcs_profile);
    end else begin: no_data_link
        assign packet_tx_data=0;assign packet_tx_valid=0;assign packet_tx_last=0;
        assign dl_active=0;assign fc_error=0;assign link_pending=0;assign completion_debug=0;
        assign tlp_ready=INITFC1_PROBE==0 || state==FINISHED;
        assign cmd_ready_o=0;assign rsp_valid_o=0;assign rsp_data_o=0;assign rsp_status_o=0;
        assign app_tx_ready_o=0;assign app_rx_data_o=0;assign app_rx_valid_o=0;assign app_rx_last_o=0;
    end endgenerate

`ifdef GEN3_RX_DIAGNOSTICS
    // Observe only; no feedback into protocol control. Counts cover RcvrCfg,
    // Recovery.Idle and L0, freeze at STOP, and reset synchronously per trial.
    reg [31:0] diag_rxvalid,diag_datavalid,diag_accepted,diag_decoded;
    reg [31:0] diag_blocks,diag_raw_dllp,diag_bad_crc;
    wire diag_window=state==RCFG || state==RIDLE || state==RL0;
    wire [31:0] diag_events={3'b0,packet_diagnostic,dllp,parser_error,error_rx,
        eios_rx,parser_eds,packet_active,rx_stream,data_valid,stream_start,aligned,
        rx_pipe_valid,rx_idle_i,phy_ready_i,rx_header_i,rx_start_i,
        rx_data_valid_i,rx_valid_i,rate_o,state};
    always @(posedge clk)begin
        if(reset_i)begin
            diag_rxvalid<=0;diag_datavalid<=0;diag_accepted<=0;diag_decoded<=0;
            diag_blocks<=0;diag_raw_dllp<=0;diag_bad_crc<=0;
        end else if(diag_window)begin
            if(rx_valid_i)diag_rxvalid<=diag_rxvalid+1'b1;
            if(rx_data_valid_i)diag_datavalid<=diag_datavalid+1'b1;
            if(rx_pipe_valid)diag_accepted<=diag_accepted+1'b1;
            if(data_valid)diag_decoded<=diag_decoded+1'b1;
            if(rx_pipe_valid && rx_pipe_start && rx_pipe_header==2'b10)diag_blocks<=diag_blocks+1'b1;
            if(packet_diagnostic[0])diag_raw_dllp<=diag_raw_dllp+1'b1;
            if(packet_diagnostic[3])diag_bad_crc<=diag_bad_crc+1'b1;
        end
    end
    // Native TX pins presented to the AMD PHY, not a serial-lane measurement.
    wire [31:0] diag_tx_events={packet_tx_fault,fc_error,packet_submit,dl_active,tlp_last,tlp_valid,rx_stream,aligned,valid_ts2,valid_ts,event_ts,
        eios_rx,parser_error,error_rx,stream_start,tx_idle_word,tx_eieos_done,
        tx_ts2_done,phy_ready_i,rate_o,state,reset_i,idle_o,tx_header_o,tx_start_o,tx_valid_o};
    wire [31:0] diag_state_cycles={8'b0,timer};
    gen3_rx_ila receive_trace(.clk(clk),.probe0(rx_data_i),.probe1(decoded_data),
        .probe2(diag_events),.probe3(diag_rxvalid),.probe4(diag_datavalid),
        .probe5(diag_accepted),.probe6(diag_decoded),.probe7(diag_blocks),
        .probe8(diag_raw_dllp),.probe9(diag_bad_crc),
        .probe10(tx_data_o),.probe11(diag_tx_events),.probe12(diag_state_cycles),.probe13(tlp_data));
`endif
    reg [15:0] dllp_count,receive_errors,ts2_count;
    reg [31:0] last_dllp;
    reg [7:0] rx_idle_symbols,tx_idle_symbols;
    reg [7:0] matched_rate;
    wire post_ts=(valid_ts && rx_ec==0) || valid_ts2;
    wire normal_rate=!native_last_ts[39] && native_last_ts[35];
    assign last_ts_o=CONFIG_PROBE!=0 && probe_done?{32'h43464733,probe_data,completion_debug[31:0],28'b0,link_pending,probe_status}:reached_idle?{32'h52454333,dllp_count,receive_errors,last_dllp,
        rx_idle_symbols,{5'b0,rx_stream,reached_l0,reached_idle},ts2_count}:native_last_ts;
    always @(posedge clk)begin
        if(reset_i)begin
            dllp_count<=0;receive_errors<=0;ts2_count<=0;last_dllp<=0;
            reached_idle<=0;reached_l0<=0;rx_idle_symbols<=0;tx_idle_symbols<=0;matched_rate<=0;
        end else begin
            if(state!=STOP && state!=FINISHED && state!=FAILED && dllp)begin last_dllp<=dllp_body;if(dllp_count!=65535)dllp_count<=dllp_count+1'b1;end
            if(state!=STOP && state!=FINISHED && state!=FAILED && (error_rx || parser_error) && receive_errors!=65535)receive_errors<=receive_errors+1'b1;
            if(valid_ts2 && ts2_count!=65535)ts2_count<=ts2_count+1'b1;
            if(state==RIDLE)reached_idle<=1;
            if(state==RL0)reached_l0<=1;
            if(state!=RIDLE)begin rx_idle_symbols<=0;tx_idle_symbols<=0;end
            else begin
                if(data_valid)begin
                    if(decoded_data==0)begin if(rx_idle_symbols<248)rx_idle_symbols<=rx_idle_symbols+4;end
                    else rx_idle_symbols<=0;
                end
                if(tx_idle_word && rx_idle_symbols!=0 && tx_idle_symbols<248)tx_idle_symbols<=tx_idle_symbols+4;
            end
            if(event_ts)matched_rate<=native_last_ts[39:32];
        end
    end
    gen3_eq_phase1 #(.TIMEOUT_CYCLES(EQ_TIMEOUT)) equalization (
        .clk(clk),.rst(reset_i),.enter(state==EQ_START),.cancel(state==FAILED),
        .skip_phase23(1'b1),.phy_gen3_ready(phy_ready_i && gen3_mode),
        .preset_applied(state==EQ),.applied_preset(preset),.applied_fs(local_fs),
        .applied_lf(local_lf),.applied_post(local_coeff[5:0]),.rx_aligned(aligned),
        .rx_ts_event(event_ts),.rx_ts1_valid(valid_ts),.rx_ec(rx_ec),.rx_fs(fs),.rx_lf(lf),
        .rx_symbols6_9(symbols),.active(eq_active),.tx_ts1_valid(eq_txvalid),.tx_ec(eq_ec),
        .tx_preset(eq_preset),.tx_fs(eq_fs),.tx_lf(eq_lf),.tx_post(eq_post),
        .peer_fs(peer_fs),.peer_lf(peer_lf),.go_rcvrlock(eq_lock),.go_phase2(eq_phase2),
        .go_speed(eq_speed),.phase1_success(eq_success),.phase2_success(eq_s2),.phase3_success(eq_s3),
        .complete(eq_complete),.phases23_skipped(eq_skip),.failed(eq_failed),
        .failure_reason(eq_reason),.ts_events(eq_events));
    assign tx_data_o=gen3_mode?gen3_data:{16'b0,tx_legacy_data};
    assign tx_k_o=gen3_mode?2'b0:tx_legacy_k;
    assign tx_valid_o=gen3_mode?gen3_valid:1'b1;
    assign tx_start_o=gen3_mode && gen3_start;
    assign tx_header_o=gen3_header;
    assign detect_o=state==LEGACY && legacy_detect && detect_phase==0;
    wire idle_request=state==LEGACY?legacy_idle:
        (state>=EI && state<=RATE_WAIT) || state==FINISHED || (state==FAILED && gen3_stopped);
    reg legacy_idle_q,gen3_seen;
    // Idle and data reach the PHY together: preserve the first EIEOS word and
    // keep the final EIOS word valid before asserting electrical idle.
    always @(posedge clk)begin
        if(reset_i)begin legacy_idle_q<=1;gen3_seen<=0;end
        else begin
            legacy_idle_q<=idle_request;
            if(!gen3_mode)gen3_seen<=0;
            else if(gen3_valid)gen3_seen<=1;
        end
    end
    assign idle_o=gen3_mode?((!gen3_seen || gen3_stopped) && !gen3_valid):legacy_idle_q;
    assign txeq_preset_o=preset;
    assign status_o={16'h4551,eq_events,last_rate,local_coeff,local_fs,local_lf,
        peer_fs,peer_lf,11'(balance),timer[7:0],good,failure,eq_reason,
        eq_failed,eq_success,aligned,phy_ready_i,rate_o,legacy_state,state};
    // Keep P1 through receiver detection. Return to P0 and wait for its
    // separate PHYSTATUS before telling the startup LTSSM detection succeeded.
    // This prevents a power-state acknowledgement being used as training-ready.
    always @(posedge clk)begin
        if(reset_i)begin detect_phase<=0;detect_complete<=0;detected_present<=0;end
        else begin
            detect_complete<=0;
            case(detect_phase)
                0:if(state==LEGACY && legacy_detect && phystatus_i)begin
                    detected_present<=rx_status_i==3;
                    if(rx_status_i==3)detect_phase<=1;
                    else begin detect_phase<=2;detect_complete<=1;end
                end
                1:if(phystatus_i)begin detect_phase<=2;detect_complete<=1;end
                2:if(!legacy_detect)detect_phase<=0;
                default:detect_phase<=0;
            endcase
        end
    end
    assign powerdown_o=(reset_i || (state==LEGACY &&
        (legacy_state==0 || (legacy_state==1 && detect_phase==0))))?2'b10:2'b00;
    // At Gen1 the native PHY electrical-idle indication is valid. Require a
    // fresh 1 us guard after either current Recovery EIOS or detected idle;
    // the elapsed state timer alone must not satisfy the post-peer-idle guard.
    reg [7:0] peer_idle_count;
    always @(posedge clk)begin
        if(reset_i || state!=EI)peer_idle_count<=0;
        else if(peer_eios || rx_idle_i)begin
            if(peer_idle_count<125)peer_idle_count<=peer_idle_count+1'b1;
        end else peer_idle_count<=0;
    end
    wire good_legacy=ts_valid && !inverted && !link_pad && !lane_pad && rx_link==0 && rx_lane==0 &&
        rx_control[4:0]==0 && rx_rate[7] && rx_rate[3:1]==3'b111;
    always @(posedge clk)begin
        if(reset_i)begin
            state<=LEGACY;timer<=0;tx_count<=0;good<=0;rate_o<=0;txeq_ctrl_o<=0;
            preset<=preset_i;failure<=0;peer_eios<=0;previous_rx<=0;previous_k<=0;last_rate<=0;
            local_fs<=0;local_lf<=0;local_coeff<=0;
        end else begin
            if(timer!=24'hffffff)timer<=timer+1'b1;
            if(state<CONFIG)peer_eios<=0;
            if(rx_valid_i && rate_o==0)begin
                previous_rx<=rx_data_i[15:0];previous_k<=rx_k_i;
                if((state==CONFIG || state==EIOS || state==EI) &&
                   previous_rx==16'h7cbc && previous_k==3 && rx_data_i[15:0]==16'h7c7c && rx_k_i==3)
                    peer_eios<=1;
            end
            if(ts_valid)last_rate<=rx_rate;
            if(state<=CONFIG && training_done && tx_count!=2047 && (state!=CONFIG || good!=0))tx_count<=tx_count+1'b1;
            if(state==LOCK || state==CONFIG)begin
                if(ts_bad || (ts_valid && (!good_legacy || (state==CONFIG && !ts2))))good<=0;
                else if(good_legacy && (state==LOCK || ts2) && good<8)good<=good+1'b1;
            end
            case(state)
                LEGACY:if(legacy_l0 && training_boundary)begin state<=LOCK;timer<=0;good<=0;tx_count<=0;end
                LOCK:if(good==8 && training_boundary)begin state<=CONFIG;timer<=0;good<=0;tx_count<=0;end
                CONFIG:if(good==8 && tx_count>=32 && training_boundary)begin state<=EIOS;timer<=0;end
                EIOS:if(timer==15)begin state<=EI;timer<=0;end
                EI:if(peer_idle_count>=125)begin
                    state<=PRESET;timer<=0;txeq_ctrl_o<=1;
                end
                PRESET:if(txeq_done_i)begin txeq_ctrl_o<=0;state<=QUERY_GAP;timer<=0;end
                QUERY_GAP:if(timer>=16 && !txeq_done_i)begin txeq_ctrl_o<=3;state<=QUERY;timer<=0;end
                QUERY:if(txeq_done_i)begin
                    txeq_ctrl_o<=0;local_fs<=txeq_fs_i;local_lf<=txeq_lf_i;
                    local_coeff<=txeq_coeff_i;state<=RATE_ARM;timer<=0;
                end
                RATE_ARM:if(timer>=16 && !phystatus_i)begin rate_o<=2;state<=RATE_WAIT;timer<=0;end
                RATE_WAIT:if(phystatus_i && phy_ready_i)begin state<=EQ_START;timer<=0;end
                EQ_START:begin state<=EQ;timer<=0;end
                EQ:if(eq_lock)begin state<=OBSERVE;timer<=0;good<=0;tx_count<=0;end
                   else if(eq_speed || eq_failed)begin state<=STOP;timer<=0;failure<=6;end
                OBSERVE:begin
                    if(event_ts)begin
                        if(post_ts && normal_rate && good<8)good<=good+1'b1;
                        else if(!post_ts || !normal_rate)good<=0;
                    end
                    if(RECOVERY_ENABLE!=0)begin
                        if(good==8)begin state<=RCFG;timer<=0;good<=0;tx_count<=0;end
                        else if(int'(timer)>=HANDSHAKE_TIMEOUT)begin state<=STOP;failure<=8;end
                    end else if(OBSERVE_CYCLES!=0 && int'(timer)>=OBSERVE_CYCLES)begin state<=STOP;timer<=0;end
                end
                RCFG:begin
                    if(event_ts)begin
                        if(valid_ts2 && normal_rate && !native_last_ts[55] &&
                           (good==0 || matched_rate==native_last_ts[39:32]))begin
                            if(good<8)good<=good+1'b1;
                        end else good<=0;
                    end
                    if(tx_eieos_done)tx_count<=0;
                    else if(tx_ts2_done && good!=0 && tx_count<2047)tx_count<=tx_count+1'b1;
                    if(good==8 && tx_count>=16)begin state<=RIDLE;timer<=0;end
                    else if(int'(timer)>=HANDSHAKE_TIMEOUT)begin state<=STOP;failure<=9;end
                end
                RIDLE:begin
                    if(rx_idle_symbols>=8 && tx_idle_symbols>=16)begin state<=RL0;timer<=0;end
                    else if(int'(timer)>=HANDSHAKE_TIMEOUT)begin state<=STOP;failure<=10;end
                end
                RL0:if(INITFC1_PROBE!=0 && response)begin state<=STOP;failure<=12;timer<=0;end
                    else if(OBSERVE_CYCLES!=0 && int'(timer)>=OBSERVE_CYCLES)begin state<=STOP;timer<=0;end
                STOP:if(gen3_stopped)begin state<=FINISHED;timer<=0;end
                default:begin end
            endcase
            if(RECOVERY_ENABLE!=0 && (state==RCFG || state==RIDLE || state==RL0) &&
               (error_rx || (DATALINK_ENABLE!=0?packet_diagnostic[1]:parser_error) || packet_tx_fault || fc_error || !phy_ready_i || eios_rx))begin state<=STOP;failure<=11;end
            if(state< EQ_START && int'(timer)>= (state==LEGACY?STARTUP_TIMEOUT:HANDSHAKE_TIMEOUT))begin
                state<=FAILED;failure<=state==LEGACY?4'd1:state<=CONFIG?4'd2:
                    state<=EI?4'd3:state<=QUERY?4'd4:4'd5;txeq_ctrl_o<=0;
            end
            if(state==LEGACY && legacy_failed)begin state<=FAILED;failure<=7;end
        end
    end
    wire unused=^{pcs_profile,completion_debug[127:32],cmd_valid_i,cmd_op_i,cmd_address_i,cmd_bdf_i,cmd_data_i,cmd_be_i,rsp_ready_i,app_tx_data_i,app_tx_valid_i,app_tx_last_i,app_tx_class_i,app_tx_credits_i,app_rx_ready_i,packet_tx_data,packet_tx_valid,packet_tx_last,packet_tx_ready,dl_active,packet_submit,packet_diagnostic,legacy_rate,unused_link,unused_hold,unused_retrain,unused_eios,unused_speed,
        unused_target,unused_fallback,unused_deemph,rx_unused_k,tx_keep,rx_keep,tx_ready,tx_v,
        rx_ready,rx_v,tx_lfsr,rx_lfsr,gen3_done,eq_active,eq_txvalid,eq_ec,eq_preset,eq_fs,eq_lf,
        eq_post,tlp_valid,tlp_last,tlp_data,tlp_class,credits,response,nak,sequence_number,packet_active,eq_phase2,eq_s2,eq_s3,eq_complete,eq_skip,error_rx,eios_rx};
endmodule

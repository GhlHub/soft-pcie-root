// SPDX-License-Identifier: Apache-2.0
// Native two-lane PHY binding for the selectable board stages.
// The host-facing packet interface stays two DWORDs wide at all link rates.
module gen3_native_x2 #(
    parameter integer GEN2_ENABLE = 0,
    parameter integer GEN3_ENABLE = 0,
    parameter integer TX_PRESET   = 4
) (
    input wire reset_i, enable_i,
    input wire refclk_p_i, refclk_n_i,
    input wire [1:0] rx_p_i, rx_n_i,
    output wire [1:0] tx_p_o, tx_n_o,
    output wire core_clk_o, perst_a_o, disable_ssd2_power_o,
    output wire link_up_o, dl_active_o,
    input wire force_gen1_i,
    output wire gen2_o, rate_busy_o,
    output wire [4:0] state_o,
    output wire [15:0] diagnostic_o,
    output wire [127:0] completion_debug_o,
    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire [2:0] cmd_op_i,
    input wire [63:0] cmd_address_i,
    input wire [15:0] cmd_bdf_i,
    input wire [31:0] cmd_data_i,
    input wire [3:0] cmd_be_i,
    output wire rsp_valid_o,
    input wire rsp_ready_i,
    output wire [31:0] rsp_data_o,
    output wire [2:0] rsp_status_o,
    input wire [63:0] app_tx_data_i,
    input wire [1:0] app_tx_words_i,
    input wire app_tx_valid_i, app_tx_last_i,
    output wire app_tx_ready_o,
    input wire [8:0] app_tx_credits_i,
    output wire [63:0] app_rx_data_o,
    output wire [1:0] app_rx_words_o,
    output wire app_rx_valid_o, app_rx_last_o,
    input wire app_rx_ready_i,
    output wire error_o
);
    wire gtref, rawref, refclk, pclk;
    IBUFDS_GTE4 #(
        .REFCLK_HROW_CK_SEL(2'b00)
    ) reference_clock (
        .I    (refclk_p_i),
        .IB   (refclk_n_i),
        .CEB  (1'b0),
        .O    (gtref),
        .ODIV2(rawref)
    );
    BUFG_GT management_clock (
        .I      (rawref),
        .CE     (1'b1),
        .CEMASK (1'b0),
        .CLR    (1'b0),
        .CLRMASK(1'b0),
        .DIV    (3'b0),
        .O      (refclk)
    );
    assign core_clk_o = pclk;

    (* ASYNC_REG="TRUE" *)reg [ 2:0] reset_sync = 7;
    (* ASYNC_REG="TRUE" *)reg [ 1:0] enable_sync = 0;
    reg        started = 0;
    reg [23:0] hold_count = 0;
    reg release_phy = 0, release_ssd = 0;
    always @(posedge refclk) begin
        reset_sync  <= {reset_sync[1:0], reset_i};
        enable_sync <= {enable_sync[0], enable_i};
        if (reset_sync[2]) begin
            started     <= 0;
            hold_count  <= 0;
            release_phy <= 0;
            release_ssd <= 0;
        end else begin
            if (enable_sync[1]) started <= 1;
            if (started && hold_count < 10000000) hold_count <= hold_count + 1'b1;
            release_phy <= started && hold_count >= 100000;
            release_ssd <= started && hold_count >= 10000000;
        end
    end
    assign perst_a_o            = !release_ssd;
    assign disable_ssd2_power_o = 1;

    wire phystatus_rst;
    wire [1:0] powergood, phystatus, rx_valid, rx_idle;
    (* ASYNC_REG="TRUE" *)reg [2:0] release_sync = 0;
    (* ASYNC_REG="TRUE" *)reg [1:0] ready_sync = 0;
    (* ASYNC_REG="TRUE" *) reg [1:0] idle_meta = 3, lane_idle_q = 3;
    // The PHY exports one TX power-ready bit replicated across the two lanes.
    (* ASYNC_REG="TRUE" *) reg [1:0] power_sync = 0;
    if (GEN2_ENABLE != 0) begin : rate_reset
        always @(posedge pclk or posedge reset_i) begin
            if (reset_i) release_sync <= 0;
            else release_sync <= {release_sync[1:0], release_ssd};
        end
    end else begin : fixed_rate_reset
        always @(posedge pclk) release_sync <= {release_sync[1:0], release_ssd};
    end
    always @(posedge pclk) begin
        ready_sync  <= {ready_sync[0], !phystatus_rst};
        idle_meta   <= rx_idle;
        lane_idle_q <= idle_meta;
        power_sync  <= {power_sync[0], powergood[0]};
    end
    wire       link_reset_n = release_sync[2];
    wire [1:0] lane_ready = {2{ready_sync[1] && power_sync[1]}};
    wire detect_request, phy_detect, tx_idle, pipe_failed;
    wire [1:0] powerdown, polarity, detect_done, receivers, legacy_valid, legacy_error;
    wire [5:0] rx_status;
    wire [3:0] rx_k, tx_k;
    wire [31:0] legacy_tx, legacy_rx;
    wire [127:0] rx_data, legacy_tx_bus;
    wire [1:0] phy_rate;
    wire force_gen1, rate_ready, speed_idle, target_gen2, rate_failed, changing_rate, deemphasis;
    wire [1:0] applied_rate;
    wire target_gen3, gen3_handoff, gen3_selected, gen3_rate_allowed;
    wire gen3_phase_zero = GEN3_ENABLE != 0 && target_gen3 && speed_idle && !gen3_selected;
    wire [1:0] phy_data_valid, gen3_tx_valid, gen3_tx_start;
    wire [3:0] phy_start, phy_header, gen3_tx_header;
    wire [3:0] txeq_control, rxeq_control;
    wire [7:0] txeq_presets, rxeq_presets;
    wire [11:0] txeq_taps;
    wire [5:0] phy_txeq_fs, phy_txeq_lf;
    wire [35:0] phy_txeq_coeff, phy_rxeq_proposal;
    wire [1:0] phy_tx_done, phy_rx_done, phy_rx_adapt_done, phy_rx_preset_sel;
    wire [63:0] gen3_tx_data, gen3_app_rx;
    wire [127:0] gen3_tx_bus = {32'b0, gen3_tx_data[63:32], 32'b0, gen3_tx_data[31:0]};
    wire [127:0] tx_bus = gen3_selected ? gen3_tx_bus : legacy_tx_bus;
    wire gen3_tx_idle, gen3_up, gen3_active, gen3_error;
    wire legacy_up, legacy_active;
    wire [4:0] legacy_state, gen3_state;
    wire gen3_cmd_ready, gen3_rsp_valid, gen3_app_tx_ready, gen3_app_rx_valid, gen3_app_rx_last;
    wire [1:0] gen3_app_words;
    wire legacy_cmd_ready, legacy_rsp_valid, legacy_app_tx_ready, legacy_app_rx_valid,
        legacy_app_rx_last;
    wire [63:0] legacy_app_rx;
    wire [31:0] legacy_rsp_data, gen3_rsp_data;
    wire [2:0] legacy_rsp_status, gen3_rsp_status;
    wire [127:0] legacy_debug, gen3_debug;
    wire [63:0] port_tx_data;
    wire [ 1:0] port_tx_words;
    wire [ 8:0] port_tx_credits;
    wire port_tx_last, port_tx_valid;
    reg legacy_owned_q;
    always @(posedge pclk) begin
        if (!link_reset_n) legacy_owned_q <= 0;
        else if (legacy_active) legacy_owned_q <= 1;
    end

    assign link_up_o = gen3_selected ? gen3_up : legacy_up;
    assign dl_active_o = gen3_selected ? gen3_active : legacy_active;
    assign state_o = gen3_selected ? gen3_state : legacy_state;
    assign rate_busy_o = (gen3_selected ? gen3_state != 18 : legacy_state != 10) || changing_rate ||
        gen3_phase_zero;
    assign cmd_ready_o = gen3_selected ? gen3_cmd_ready : legacy_cmd_ready;
    assign rsp_valid_o = gen3_selected ? gen3_rsp_valid : legacy_rsp_valid;
    assign rsp_data_o = gen3_selected ? gen3_rsp_data : legacy_rsp_data;
    assign rsp_status_o = gen3_selected ? gen3_rsp_status : legacy_rsp_status;
    if (GEN3_ENABLE != 0) begin : debug_source
        // Launch the selected diagnostic from PCLK registers. The CSR
        // sampler must see one registered source for each debug bit.
        (* DONT_TOUCH="TRUE" *) reg [127:0] debug_q = 0;
        always @(posedge pclk) begin
            if (!link_reset_n) debug_q <= 0;
            else debug_q <= gen3_selected ? gen3_debug : legacy_debug;
        end
        assign completion_debug_o = debug_q;
    end else begin : legacy_debug_source
        assign completion_debug_o = legacy_debug;
    end
    assign app_rx_data_o  = gen3_selected ? gen3_app_rx : legacy_app_rx;
    assign app_rx_valid_o = gen3_selected ? gen3_app_rx_valid : legacy_app_rx_valid;
    assign app_rx_last_o  = gen3_selected ? gen3_app_rx_last : legacy_app_rx_last;
    if (GEN3_ENABLE != 0) begin : tx_boundary
        // Two beats absorb downstream stalls without placing host ready
        // behind both the legacy and Gen3 link admission logic.
        reg [75:0] beats [0:1];
        reg [ 1:0] count;
        reg read_slot, write_slot;
        wire input_active = gen3_selected ? gen3_active : legacy_active;
        wire take_in = app_tx_valid_i && app_tx_ready_o;
        wire take_out = port_tx_valid && (gen3_selected ? gen3_app_tx_ready : legacy_app_tx_ready);
        assign app_tx_ready_o = link_reset_n && input_active && count != 2;
        assign port_tx_valid = link_reset_n && count != 0;
        assign {port_tx_credits, port_tx_last, port_tx_words, port_tx_data} = beats[read_slot];
        always @(posedge pclk) begin
            if (take_in)
                beats[write_slot] <= {
                    app_tx_credits_i, app_tx_last_i, app_tx_words_i, app_tx_data_i
                };
            if (!link_reset_n) begin
                count      <= 0;
                read_slot  <= 0;
                write_slot <= 0;
            end else begin
                count <= count + 2'(take_in) - 2'(take_out);
                if (take_in) write_slot <= !write_slot;
                if (take_out) read_slot <= !read_slot;
            end
        end
    end else begin : legacy_tx_boundary
        assign app_tx_ready_o = legacy_app_tx_ready;
        assign {port_tx_credits, port_tx_last, port_tx_words, port_tx_data, port_tx_valid} = {
            app_tx_credits_i, app_tx_last_i, app_tx_words_i, app_tx_data_i, app_tx_valid_i
        };
    end
    if (GEN2_ENABLE != 0) begin : programmable_rate
        (* ASYNC_REG="TRUE" *) reg [2:0] policy_sync_q = 0;
        always @(posedge pclk) policy_sync_q <= {policy_sync_q[1:0], force_gen1_i};
        assign force_gen1 = policy_sync_q[2];
        assign gen2_o     = applied_rate == 1;
        gen3_native_x2_rate rate_control (
            .clk            (pclk),
            .rst_n          (link_reset_n),
            .request_i      (speed_idle && !gen3_selected && (!target_gen3 || gen3_rate_allowed)),
            .target_i       (target_gen3 ? 2'd2 : {1'b0, target_gen2}),
            .request_ready_o(),
            .tx_idle_i      (speed_idle),
            .rx_idle_i      (lane_idle_q),
            .phy_ready_i    (lane_ready),
            .phystatus_i    (phystatus),
            .phy_rate_o     (phy_rate),
            .applied_rate_o (applied_rate),
            .rate_ready_o   (rate_ready),
            .busy_o         (changing_rate),
            .failed_o       (rate_failed)
        );
    end else begin : fixed_rate
        assign {gen2_o, rate_failed, changing_rate, phy_rate, applied_rate} = 0;
        assign {force_gen1, rate_ready}                                     = 2'b11;
        wire unused_policy = force_gen1_i;
    end
    reg mac_detect = 1;
    always @(posedge pclk) mac_detect <= !link_reset_n || legacy_state <= 1;

    gen3_legacy_x2_pipe pipe_adapter (
        .clk               (pclk),
        .rst_n             (link_reset_n),
        .detect_i          (detect_request),
        .ready_i           (lane_ready),
        .phystatus_i       (phystatus),
        .rxvalid_i         (rx_valid),
        .rxstatus_i        (rx_status),
        .rxdata_i          (rx_data),
        .txdata_i          (legacy_tx),
        .rxdata_o          (legacy_rx),
        .txdata_o          (legacy_tx_bus),
        .rxvalid_o         (legacy_valid),
        .rxerror_o         (legacy_error),
        .detect_o          (phy_detect),
        .powerdown_o       (powerdown),
        .detect_done_o     (detect_done),
        .receiver_present_o(receivers),
        .failed_o          (pipe_failed)
    );

    wire [31:0] link_rx_data;
    wire [ 3:0] link_rx_k;
    wire [1:0] link_rx_valid, link_rx_error;
    if (GEN2_ENABLE != 0) begin : pipe_rx_register
        // Register the wide PIPE word and lane status together before
        // decoded error fanout or ordered-set/deskew decisions at 250 MHz.
        reg [31:0] data_q;
        reg [ 3:0] k_q;
        reg [1:0] valid_q, error_q;
        always @(posedge pclk) begin
            data_q  <= legacy_rx;
            k_q     <= rx_k;
            valid_q <= legacy_valid & {2{link_reset_n && !speed_idle}};
            error_q <= legacy_error & {2{link_reset_n && !speed_idle}};
        end
        assign {link_rx_data, link_rx_k, link_rx_valid, link_rx_error} = {
            data_q, k_q, valid_q, error_q
        };
    end else begin : direct_pipe_rx
        assign {link_rx_data, link_rx_k, link_rx_valid, link_rx_error} = {
            legacy_rx, rx_k, legacy_valid, legacy_error
        };
    end

    wire [31:0] packet_tx, packet_rx;
    wire [10:0] packet_tx_meta;
    wire [ 2:0] rx_words;
    wire tx_valid, tx_last, tx_ready, rx_packet_valid, rx_last, rx_ready;
    wire rx_width_fault, tx_width_fault, link_error;
    assign app_rx_words_o = gen3_selected ? gen3_app_words : rx_words[1:0];
    assign error_o = pipe_failed || rate_failed || rx_width_fault || tx_width_fault ||
        (gen3_selected ? gen3_error : link_error || gen3_error);
    // Launch diagnostic bits directly from PCLK flops into the CSR sampler.
    (* DONT_TOUCH="TRUE" *) reg [15:0] diagnostic_q = 0;
    always @(posedge pclk)
        diagnostic_q <= {
            pipe_failed,
            ready_sync[1],
            power_sync[1],
            powerdown,
            polarity,
            lane_idle_q,
            receivers,
            state_o
        };
    assign diagnostic_o = diagnostic_q;

    pcie_packet_width #(
        .INPUT_DWORDS (2),
        .OUTPUT_DWORDS(1)
    ) narrow_tx (
        .clk      (pclk),
        .rst_n    (link_reset_n),
        .s_data_i (port_tx_data),
        .s_words_i({1'b0, port_tx_words}),
        .s_meta_i ({2'd2, port_tx_credits}),
        .s_valid_i(port_tx_valid && !gen3_selected),
        .s_last_i (port_tx_last),
        .s_ready_o(legacy_app_tx_ready),
        .m_data_o (packet_tx),
        .m_words_o(),
        .m_meta_o (packet_tx_meta),
        .m_valid_o(tx_valid),
        .m_last_o (tx_last),
        .m_ready_i(tx_ready),
        .fault_o  (tx_width_fault)
    );
    pcie_packet_width #(
        .INPUT_DWORDS (1),
        .OUTPUT_DWORDS(2)
    ) widen_rx (
        .clk      (pclk),
        .rst_n    (link_reset_n),
        .s_data_i (packet_rx),
        .s_words_i(3'd1),
        .s_meta_i (11'b0),
        .s_valid_i(rx_packet_valid),
        .s_last_i (rx_last),
        .s_ready_o(rx_ready),
        .m_data_o (legacy_app_rx),
        .m_words_o(rx_words),
        .m_meta_o (),
        .m_valid_o(legacy_app_rx_valid),
        .m_last_o (legacy_app_rx_last),
        .m_ready_i(app_rx_ready_i && !gen3_selected),
        .fault_o  (rx_width_fault)
    );
    pcie_soft_link #(
        .LINK_WIDTH (2),
        .GEN2_ENABLE(GEN2_ENABLE),
        .GEN3_ENABLE(GEN3_ENABLE),
        .TX_PRESET  (TX_PRESET)
    ) link (
        .clk               (pclk),
        .rst_n             (link_reset_n),
        .enable_i          (link_reset_n),
        .phy_ready_i       (lane_ready),
        .rx_idle_i         (lane_idle_q),
        .detect_done_i     (detect_done),
        .receiver_present_i(receivers),
        .detect_o          (detect_request),
        .electrical_idle_o (tx_idle),
        .polarity_o        (polarity),
        .phy_rx_data_i     (link_rx_data),
        .phy_rx_ctrl_i     (link_rx_k),
        .phy_rx_valid_i    (link_rx_valid),
        .phy_rx_error_i    (link_rx_error),
        .phy_tx_data_o     (legacy_tx),
        .phy_tx_ctrl_o     (tx_k),
        .link_up_o         (legacy_up),
        .dl_active_o       (legacy_active),
        .state_o           (legacy_state),
        .retrain_i         (1'b0),
        .cmd_valid_i       (cmd_valid_i && !gen3_selected),
        .cmd_ready_o       (legacy_cmd_ready),
        .cmd_op_i          (cmd_op_i),
        .cmd_address_i     (cmd_address_i),
        .cmd_bdf_i         (cmd_bdf_i),
        .cmd_data_i        (cmd_data_i),
        .cmd_be_i          (cmd_be_i),
        .rsp_valid_o       (legacy_rsp_valid),
        .rsp_ready_i       (rsp_ready_i && !gen3_selected),
        .rsp_data_o        (legacy_rsp_data),
        .rsp_status_o      (legacy_rsp_status),
        .app_tx_data_i     (packet_tx),
        .app_tx_valid_i    (tx_valid),
        .app_tx_last_i     (tx_last),
        .app_tx_ready_o    (tx_ready),
        .app_tx_class_i    (packet_tx_meta[10:9]),
        .app_tx_credits_i  (packet_tx_meta[8:0]),
        .app_rx_data_o     (packet_rx),
        .app_rx_valid_o    (rx_packet_valid),
        .app_rx_last_o     (rx_last),
        .app_rx_ready_i    (rx_ready),
        .error_o           (link_error),
        .completion_debug_o(legacy_debug),
        .force_gen1_i      (force_gen1),
        .phy_gen2_i        (gen2_o),
        .phy_rate_ready_i  (rate_ready),
        .target_gen2_o     (target_gen2),
        .speed_idle_o      (speed_idle),
        .fallback_o        (),
        .deemphasis_o      (deemphasis),
        .phy_gen3_i        (applied_rate == 2),
        .target_gen3_o     (target_gen3),
        .gen3_handoff_o    (gen3_handoff)
    );

    if (GEN3_ENABLE != 0) begin : gen3_port
        // RX starts are two bits per lane in the generated PHY. At the
        // 32-bit gearbox width, only start bit 0 of each lane is meaningful.
        reg [63:0] data_q;
        reg [ 3:0] header_q;
        reg [1:0] valid_q, start_q;
        always @(posedge pclk) begin
            data_q   <= {rx_data[95:64], rx_data[31:0]};
            header_q <= phy_header;
            start_q  <= {phy_start[2], phy_start[0]};
            valid_q  <= phy_data_valid & rx_valid & {2{link_reset_n && applied_rate == 2}};
        end
        gen3_x2_port #(
            .TX_PRESET(TX_PRESET)
        ) native_gen3 (
            .clk               (pclk),
            .reset_i           (!link_reset_n),
            .phase0_i          (gen3_phase_zero && !legacy_owned_q),
            .handoff_i         (gen3_handoff && !legacy_owned_q),
            .legacy_idle_i     (tx_idle),
            .phy_ready_i       (lane_ready),
            .rx_idle_i         (lane_idle_q),
            .rx_data_i         (data_q),
            .rx_valid_i        (valid_q),
            .rx_start_i        (start_q),
            .rx_header_i       (header_q),
            .phy_fs_i          (phy_txeq_fs),
            .phy_lf_i          (phy_txeq_lf),
            .phy_coeff_i       (phy_txeq_coeff),
            .phy_rx_proposal_i (phy_rxeq_proposal),
            .txeq_done_i       (phy_tx_done),
            .rxeq_done_i       (phy_rx_done),
            .rxeq_adapt_done_i (phy_rx_adapt_done),
            .rxeq_preset_sel_i (phy_rx_preset_sel),
            .txeq_ctrl_o       (txeq_control),
            .rxeq_ctrl_o       (rxeq_control),
            .txeq_preset_o     (txeq_presets),
            .rxeq_preset_o     (rxeq_presets),
            .txeq_coeff_o      (txeq_taps),
            .rate_allowed_o    (gen3_rate_allowed),
            .selected_o        (gen3_selected),
            .tx_data_o         (gen3_tx_data),
            .tx_valid_o        (gen3_tx_valid),
            .tx_start_o        (gen3_tx_start),
            .tx_header_o       (gen3_tx_header),
            .tx_idle_o         (gen3_tx_idle),
            .link_up_o         (gen3_up),
            .dl_active_o       (gen3_active),
            .error_o           (gen3_error),
            .state_o           (gen3_state),
            .completion_debug_o(gen3_debug),
            .cmd_valid_i       (cmd_valid_i && gen3_selected),
            .cmd_ready_o       (gen3_cmd_ready),
            .cmd_op_i          (cmd_op_i),
            .cmd_address_i     (cmd_address_i),
            .cmd_bdf_i         (cmd_bdf_i),
            .cmd_data_i        (cmd_data_i),
            .cmd_be_i          (cmd_be_i),
            .rsp_valid_o       (gen3_rsp_valid),
            .rsp_ready_i       (rsp_ready_i && gen3_selected),
            .rsp_data_o        (gen3_rsp_data),
            .rsp_status_o      (gen3_rsp_status),
            .app_tx_data_i     (port_tx_data),
            .app_tx_words_i    (port_tx_words),
            .app_tx_valid_i    (port_tx_valid && gen3_selected),
            .app_tx_last_i     (port_tx_last),
            .app_tx_ready_o    (gen3_app_tx_ready),
            .app_tx_credits_i  (port_tx_credits),
            .app_rx_data_o     (gen3_app_rx),
            .app_rx_words_o    (gen3_app_words),
            .app_rx_valid_o    (gen3_app_rx_valid),
            .app_rx_last_o     (gen3_app_rx_last),
            .app_rx_ready_i    (app_rx_ready_i && gen3_selected)
        );
        wire unused_start = ^{phy_start[3], phy_start[1]};
    end else begin : legacy_only
        assign {gen3_selected, gen3_rate_allowed, gen3_tx_data, gen3_tx_valid, gen3_tx_start,
                gen3_tx_header, gen3_tx_idle, gen3_up, gen3_active, gen3_error, gen3_state,
                gen3_debug, gen3_cmd_ready, gen3_rsp_valid, gen3_rsp_data, gen3_rsp_status,
                gen3_app_tx_ready, gen3_app_rx, gen3_app_words, gen3_app_rx_valid,
                gen3_app_rx_last} = 0;
        assign {txeq_control, rxeq_control, txeq_taps, rxeq_presets} = 0;
        assign txeq_presets = 8'h44;
        wire unused_eq = ^{legacy_owned_q, gen3_handoff, phy_data_valid, phy_start, phy_header,
                           phy_txeq_fs, phy_txeq_lf, phy_txeq_coeff, phy_rxeq_proposal, phy_tx_done,
                           phy_rx_done, phy_rx_adapt_done, phy_rx_preset_sel};
    end

    // The generated x2 core presents the higher GTH site in PIPE lane 0.
    // Wire DP0 (X1Y4) to logical lane 0 at the board and link interfaces.
    gen3_reference_phy_x2 phy (
        .eq_diag             (),
        .phy_refclk          (refclk),
        .phy_gtrefclk        (gtref),
        .phy_rst_n           (release_phy),
        .phy_txdata          ({tx_bus[63:0], tx_bus[127:64]}),
        .phy_txdatak         (gen3_selected ? 4'b0 : {tx_k[1:0], tx_k[3:2]}),
        .phy_txdata_valid    (gen3_selected ? {gen3_tx_valid[0], gen3_tx_valid[1]} : 2'b11),
        .phy_txstart_block   (gen3_selected ? {gen3_tx_start[0], gen3_tx_start[1]} : 2'b0),
        .phy_txsync_header   (gen3_selected ? {gen3_tx_header[1:0], gen3_tx_header[3:2]} : 4'b0),
        .phy_rxp             ({rx_p_i[0], rx_p_i[1]}),
        .phy_rxn             ({rx_n_i[0], rx_n_i[1]}),
        .phy_txp             ({tx_p_o[0], tx_p_o[1]}),
        .phy_txn             ({tx_n_o[0], tx_n_o[1]}),
        .phy_txdetectrx      (phy_detect),
        .phy_txelecidle      ({2{!link_reset_n || (gen3_selected ? gen3_tx_idle : tx_idle)}}),
        .phy_txcompliance    (2'b0),
        .phy_rxpolarity      ({polarity[0], polarity[1]}),
        .phy_powerdown       (powerdown),
        .phy_rate            (phy_rate),
        .phy_txmargin        (3'b0),
        .phy_txswing         (1'b0),
        .phy_txdeemph        (deemphasis),
        .phy_txeq_ctrl       ({txeq_control[1:0], txeq_control[3:2]}),
        .phy_txeq_preset     ({txeq_presets[3:0], txeq_presets[7:4]}),
        .phy_txeq_coeff      ({txeq_taps[5:0], txeq_taps[11:6]}),
        .phy_rxeq_ctrl       ({rxeq_control[1:0], rxeq_control[3:2]}),
        .phy_rxeq_txpreset   ({rxeq_presets[3:0], rxeq_presets[7:4]}),
        .as_mac_in_detect    (mac_detect),
        .as_cdr_hold_req     (1'b0),
        .phy_coreclk         (),
        .phy_userclk         (),
        .phy_mcapclk         (),
        .phy_pclk            (pclk),
        .phy_rxdata          ({rx_data[63:0], rx_data[127:64]}),
        .phy_rxdatak         ({rx_k[1:0], rx_k[3:2]}),
        .phy_rxdata_valid    ({phy_data_valid[0], phy_data_valid[1]}),
        .phy_rxstart_block   ({phy_start[1:0], phy_start[3:2]}),
        .phy_rxsync_header   ({phy_header[1:0], phy_header[3:2]}),
        .phy_rxvalid         ({rx_valid[0], rx_valid[1]}),
        .phy_phystatus       ({phystatus[0], phystatus[1]}),
        .phy_phystatus_rst   (phystatus_rst),
        .phy_rxelecidle      ({rx_idle[0], rx_idle[1]}),
        .phy_rxstatus        ({rx_status[2:0], rx_status[5:3]}),
        .phy_txeq_fs         (phy_txeq_fs),
        .phy_txeq_lf         (phy_txeq_lf),
        .phy_txeq_new_coeff  ({phy_txeq_coeff[17:0], phy_txeq_coeff[35:18]}),
        .phy_txeq_done       ({phy_tx_done[0], phy_tx_done[1]}),
        .phy_rxeq_preset_sel ({phy_rx_preset_sel[0], phy_rx_preset_sel[1]}),
        .phy_rxeq_new_txcoeff({phy_rxeq_proposal[17:0], phy_rxeq_proposal[35:18]}),
        .phy_rxeq_adapt_done ({phy_rx_adapt_done[0], phy_rx_adapt_done[1]}),
        .phy_rxeq_done       ({phy_rx_done[0], phy_rx_done[1]}),
        .gt_gtpowergood      ({powergood[0], powergood[1]})
    );
    wire unused_status = ^{rx_words[2], powergood[1]};
    initial
        if (GEN3_ENABLE != 0 && GEN2_ENABLE == 0) $fatal(1, "Gen3 requires programmable x2 RATE");
endmodule

// SPDX-License-Identifier: Apache-2.0
// Behavioral native PIPE peer setup for the Gen3 x2 port testbench.
// DP0 appears in the higher PIPE lane group of the generated PHY.
wire [3:0] tx_eq_ctrl, rx_eq_ctrl;
assign tx_eq_ctrl = {root.phy.phy_txeq_ctrl[1:0], root.phy.phy_txeq_ctrl[3:2]};
assign rx_eq_ctrl = {root.phy.phy_rxeq_ctrl[1:0], root.phy.phy_rxeq_ctrl[3:2]};
wire       selected = root.gen3_selected;
wire [1:0] rate = root.phy.phy_rate;
reg [1:0] tx_done = 0, rx_done = 0, rate_done = 0;
reg [1:0] saw_apply = 0, saw_query = 0, saw_rate = 0;
reg  [1:0] saw_p0 = 0;
wire [1:0] saw_phase_zero;
integer tx_ticks[0:1], rx_ticks[0:1], cadence_words = 0;
integer rate_ticks = 0, detect_ticks = 0, p0_ticks = 0;
integer eios_sets = 0;
reg saw_startup = 0;
wire peer_idle = saw_startup && root.phy.phy_txelecidle == 3 && !selected;
wire legacy_training = root.phy.phy_powerdown == 0 && saw_p0 == 3 && !peer_idle && !selected;
wire [15:0] peer_tx[0:1];
wire [1:0] peer_k[0:1];
wire [127:0] rx_bus = selected ?
    {32'b0, rx_data[31:0], 32'b0, rx_data[63:32]} : {48'b0, peer_tx[0], 48'b0, peer_tx[1]};
wire [3:0] rx_k_bus = selected ? 4'b0 : {peer_k[0], peer_k[1]};
wire [1:0] rx_wire_valid = selected ? 2'b11 : {2{legacy_training}};
assign tx_data   = {root.phy.phy_txdata[31:0], root.phy.phy_txdata[95:64]};
assign tx_header = {root.phy.phy_txsync_header[1:0], root.phy.phy_txsync_header[3:2]};
assign tx_valid  = selected ? {root.phy.phy_txdata_valid[0], root.phy.phy_txdata_valid[1]} : 2'b0;
assign tx_start  = {root.phy.phy_txstart_block[0], root.phy.phy_txstart_block[1]};
assign failed    = state == 31 || state == 14;
assign epoch     = root.gen3_port.native_gen3.data_link.epoch_o;

// Shorten only the fixture's board startup and PHY adaptation delays.
initial begin
    force root.release_phy = 1;
    force root.release_ssd = 1;
end
defparam root.gen3_port.native_gen3.GUARD_CYCLES = 3;
    defparam root.gen3_port.native_gen3.REQUEST_CYCLES = 400;
    defparam root.gen3_port.native_gen3.EVALUATE_CYCLES = 12;
    defparam root.gen3_port.native_gen3.APPLY_CYCLES = 20; defparam root.link.QUIET_CYCLES = 16;

always @(negedge clk) begin
    for (integer lane = 0; lane < 2; lane = lane + 1) begin
        if (reset || tx_eq_ctrl[2*lane+:2] == 0) tx_ticks[lane] = 0;
        else tx_ticks[lane] = tx_ticks[lane] + 1;
        tx_done[lane] = !reset && tx_ticks[lane] == 3 + 4 * lane;
        if (tx_done[lane] && tx_eq_ctrl[2*lane+:2] == 1) saw_apply[lane] = 1;
        if (tx_done[lane] && tx_eq_ctrl[2*lane+:2] == 3) saw_query[lane] = 1;
        if (reset || rx_eq_ctrl[2*lane+:2] != 2) rx_ticks[lane] = 0;
        else rx_ticks[lane] = rx_ticks[lane] + 1;
        rx_done[lane] = !reset && rx_ticks[lane] == 3 + 4 * lane;
    end
    if (reset) begin
        detect_ticks = 0;
        p0_ticks     = 0;
        rate_ticks   = 0;
        rate_done    = 0;
    end else if (root.phy.phy_rate == 2) begin
        rate_ticks = rate_ticks + 1;
        rate_done  = {rate_ticks == 7, rate_ticks == 3};
        saw_rate   = saw_rate | rate_done;
    end else if (root.phy.phy_txdetectrx) begin
        detect_ticks = detect_ticks + 1;
        rate_done    = {detect_ticks == 7, detect_ticks == 3};
    end else if (root.phy.phy_powerdown == 0) begin
        p0_ticks  = p0_ticks + 1;
        rate_done = {p0_ticks == 7, p0_ticks == 3};
        saw_p0    = saw_p0 | rate_done;
    end else rate_done = 0;
    if (root.legacy_state == 12) saw_startup = 1;
    if (root.target_gen3 && root.phy.phy_txdatak == 4'hf && root.phy.phy_txdata[15:0] == 16'h7cbc &&
        root.phy.phy_txdata[79:64] == 16'h7cbc)
        eios_sets = eios_sets + 1;
end
always @(posedge clk)
    if (!reset && root.link_reset_n) begin
        if (rate != 0 &&
            (saw_apply != 3 || saw_query != 3 || saw_phase_zero != 3 || eios_sets != 8))
            $fatal(1, "RATE preceded Gen1 Phase 0 / EIOS / PHY replies");
        if (selected && saw_rate != 3) $fatal(1, "Started Gen3 before both fresh RATE replies");
        if ((cmd_ready || root.app_tx_ready_o) && !active)
            $fatal(1, "Startup admitted a command/beat");
        if (&tx_valid) cadence_words <= cadence_words + 1;
        else if (cadence_words != 0) begin
            if (cadence_words != 64) $fatal(1, "PHY cadence changed after %d words", cadence_words);
            cadence_words <= 0;
        end
    end

for (genvar lane = 0; lane < 2; lane = lane + 1) begin : legacy_peer_lanes
    wire event_ts, is_ts2, link_pad, lane_pad, valid;
    wire [7:0] link_number, lane_number, rate_field;
    wire [15:0] encoded, phy_word;
    wire [1:0] k, phy_k;
    reg [1:0] kind = 1;
    reg send_link_pad = 1, send_lane_pad = 1;
    reg [7:0] send_rate = 'h0e, send_link = 0, send_lane = 0;
    reg [2:0] observed_word = 0;
    reg directed_speed_change = 0, observed_phase_zero = 0;
    integer completes = 0, last_ordered_set = 0;
    assign phy_word = lane == 0 ? root.phy.phy_txdata[79:64] : root.phy.phy_txdata[15:0];
    assign phy_k = lane == 0 ? root.phy.phy_txdatak[3:2] : root.phy.phy_txdatak[1:0];
    assign saw_phase_zero[lane] = observed_phase_zero;
    // Observe the actual un-scrambled symbol 6 on both lanes of the legacy
    // ordered set, independent of the peer decoder's TS-valid output.
    always @(posedge clk)
        if (!reset && legacy_training) begin
            if (phy_k[0] && phy_word[7:0] == 8'hbc) begin
                observed_word         <= 1;
                directed_speed_change <= 0;
            end else if (observed_word != 0) begin
                if (observed_word == 2 && phy_k == 0)
                    directed_speed_change <= phy_word[7:0] == 8'h8e;
                if (observed_word == 3 && directed_speed_change) begin
                    if (phy_k != 0 || phy_word[7:0] != 8'ha0)
                        $fatal(1, "Phase 0 preset 4 missing on lane %0d", lane);
                    observed_phase_zero <= 1;
                end
                observed_word <= observed_word + 1'b1;
            end
        end
    gen3_legacy_training endpoint (
        .clk          (clk),
        .rst_n        (!reset && legacy_training),
        .tx_ready_i   (1'b1),
        .tx_kind_i    (kind),
        .tx_link_i    (send_link),
        .tx_lane_i    (send_lane),
        .tx_control_i (8'b0),
        .tx_link_pad_i(send_link_pad),
        .tx_lane_pad_i(send_lane_pad),
        .tx_eq_i      (send_rate[7]),
        .tx_preset_i  (4'd4),
        .tx_rate_i    (send_rate),
        .tx_data_o    (encoded),
        .tx_ctrl_o    (k),
        .tx_valid_o   (valid),
        .rx_data_i    (phy_word),
        .rx_ctrl_i    (phy_k),
        .rx_valid_i   (legacy_training),
        .rx_error_i   (1'b0),
        .rx_ts_valid_o(event_ts),
        .rx_ts2_o     (is_ts2),
        .rx_link_o    (link_number),
        .rx_lane_o    (lane_number),
        .rx_rate_o    (rate_field),
        .rx_link_pad_o(link_pad),
        .rx_lane_pad_o(lane_pad)
    );
    pcie_soft_scrambler peer_scrambler (
        .clk            (clk),
        .rst_n          (!reset && legacy_training),
        .s_data_i       (valid ? encoded : 16'b0),
        .s_ctrl_i       (valid ? k : 2'b0),
        .s_keep_i       (2'b11),
        .data_scramble_i(valid ? 2'b0 : 2'b11),
        .s_valid_i      (1'b1),
        .m_data_o       (peer_tx[lane]),
        .m_ctrl_o       (peer_k[lane]),
        .m_ready_i      (1'b1)
    );
    always @(negedge clk)
        if (!reset && legacy_training) begin
            if (event_ts) begin
                last_ordered_set = 0;
                send_link        = link_number;
                send_lane        = lane_number;
                send_link_pad    = link_pad;
                send_lane_pad    = lane_pad;
                send_rate        = rate_field[7] ? 8'h8e : 8'h0e;
                if (!link_pad && !lane_pad && lane_number != 8'(lane))
                    $fatal(1, "reversed physical lane");
                if (!is_ts2) begin
                    kind      = 1;
                    completes = 0;
                end else if (link_pad || lane_pad || rate_field[7]) kind = 2;
                else begin
                    completes = completes + 1;
                    kind      = 2;
                end
            end else begin
                last_ordered_set = last_ordered_set + 1;
                if (completes >= 8 && last_ordered_set >= 12 && !send_rate[7]) kind = 0;
            end
        end
end

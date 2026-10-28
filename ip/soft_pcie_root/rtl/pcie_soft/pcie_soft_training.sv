// Gen1/Gen2 x1 ordered-set codec. Two symbols/cycle, earliest in bits[7:0].
// Training is not XOR-scrambled; the external scrambler must still advance.
module pcie_soft_training (
    input wire clk, rst_n, tx_ready_i,
    input wire [1:0] tx_kind_i,  // 0=none,1=TS1,2=TS2,3=EIEOS
    input wire [7:0] tx_link_i, tx_lane_i, tx_control_i,
    input wire tx_link_pad_i, tx_lane_pad_i,
    output reg [15:0] tx_data_o,
    output reg [1:0] tx_ctrl_o,
    output wire tx_valid_o, tx_done_o, tx_boundary_o,
    output wire [1:0] tx_kind_o,
    input wire [15:0] rx_data_i,
    input wire [1:0] rx_ctrl_i,
    input wire rx_valid_i, rx_error_i,
    output reg rx_ts_valid_o, rx_ts2_o, rx_inverted_o, rx_bad_o,
    output reg [7:0] rx_link_o, rx_lane_o, rx_rate_o, rx_control_o,
    output reg rx_link_pad_o, rx_lane_pad_o,
    input wire [7:0] tx_rate_i
);
    reg [2:0] word_q;
    reg [1:0] kind_q;
    reg [7:0] link_q, lane_q, control_q, tx_rate_q;
    reg link_pad_q, lane_pad_q;
    wire [1:0] effective_kind = word_q == 0 ? tx_kind_i : kind_q;
    wire [7:0] effective_link = word_q == 0 ? tx_link_i : link_q;
    wire [7:0] effective_lane = word_q == 0 ? tx_lane_i : lane_q;
    wire [7:0] effective_control = word_q == 0 ? tx_control_i : control_q;
    wire [7:0] effective_rate = word_q == 0 ? tx_rate_i : tx_rate_q;
    wire       effective_lp = word_q == 0 ? tx_link_pad_i : link_pad_q;
    wire       effective_np = word_q == 0 ? tx_lane_pad_i : lane_pad_q;
    assign tx_valid_o    = effective_kind != 0;
    assign tx_done_o     = tx_valid_o && word_q == 7 && tx_ready_i;
    assign tx_boundary_o = word_q == 0;
    assign tx_kind_o     = effective_kind;
    always @* begin
        tx_data_o = 0;
        tx_ctrl_o = 0;
        case (word_q)
            0: begin
                tx_data_o = {effective_lp ? 8'hf7 : effective_link, 8'hbc};
                tx_ctrl_o = {effective_lp, 1'b1};
            end
            1: begin
                tx_data_o = {8'd32, effective_np ? 8'hf7 : effective_lane};
                tx_ctrl_o = {1'b0, effective_np};
            end
            2: tx_data_o = {effective_control, effective_rate};
            default: tx_data_o = effective_kind == 1 ? 16'h4a4a : 16'h4545;
        endcase
        if (effective_kind == 3) begin
            tx_data_o = word_q == 0 ? 16'hfcbc : word_q == 7 ? 16'h4afc : 16'hfcfc;
            tx_ctrl_o = word_q == 7 ? 2'b01 : 2'b11;
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            word_q     <= 0;
            kind_q     <= 0;
            link_q     <= 0;
            lane_q     <= 0;
            control_q  <= 0;
            tx_rate_q  <= 2;
            link_pad_q <= 0;
            lane_pad_q <= 0;
        end else if (tx_valid_o && tx_ready_i) begin
            word_q <= word_q + 1'b1;
            if (word_q == 0) begin
                kind_q     <= tx_kind_i;
                link_q     <= tx_link_i;
                lane_q     <= tx_lane_i;
                control_q  <= tx_control_i;
                tx_rate_q  <= tx_rate_i;
                link_pad_q <= tx_link_pad_i;
                lane_pad_q <= tx_lane_pad_i;
            end
        end else if (!tx_valid_o) word_q <= 0;
    end
    reg [4:0] rx_index_q, rx_index_n;
    reg [7:0] rl_q, rn_q, rate_q, rc_q, id_q;
    reg [7:0] rl_n, rn_n, rate_n, rc_n, id_n;
    reg lp_q, np_q, lp_n, np_n;
    reg valid_n, ts2_n, inverted_n, bad_n;
    reg     [7:0] value;
    reg           is_k;
    integer       j;
    always @* begin
        rx_index_n = rx_index_q;
        rl_n       = rl_q;
        rn_n       = rn_q;
        rate_n     = rate_q;
        rc_n       = rc_q;
        id_n       = id_q;
        lp_n       = lp_q;
        np_n       = np_q;
        valid_n    = 0;
        ts2_n      = 0;
        inverted_n = 0;
        bad_n      = 0;
        value      = 0;
        is_k       = 0;
        for (j = 0; j < 2; j = j + 1) begin
            value = rx_data_i[j*8+:8];
            is_k  = rx_ctrl_i[j];
            if (rx_valid_i) begin
                if (rx_error_i) begin
                    rx_index_n = 0;
                    bad_n      = 1;
                end else if (is_k && value == 8'hbc) begin
                    if (rx_index_n != 0) bad_n = 1;
                    rx_index_n = 1;
                end else if (rx_index_n != 0) begin
                    if (rx_index_n == 1 && is_k && value == 8'h1c) rx_index_n = 0;
                    else begin
                        if (rx_index_n == 1) begin
                            rl_n = value;
                            lp_n = is_k && value == 8'hf7;
                        end
                        if (rx_index_n == 2) begin
                            rn_n = value;
                            np_n = is_k && value == 8'hf7;
                        end
                        if (rx_index_n == 4) rate_n = value;
                        if (rx_index_n == 5) rc_n = value;
                        if (rx_index_n == 6) id_n = value;
                        if ((is_k && !((rx_index_n == 1 || rx_index_n == 2) && value == 8'hf7)) ||
                            (rx_index_n >= 6 &&
                             (value != id_n || (id_n != 8'h4a && id_n != 8'h45 && id_n != 8'hb5 &&
                                                id_n != 8'hba)))) begin
                            rx_index_n = 0;
                            bad_n      = 1;
                        end else if (rx_index_n == 15) begin
                            valid_n    = 1;
                            ts2_n      = id_n == 8'h45 || id_n == 8'hba;
                            inverted_n = id_n == 8'hb5 || id_n == 8'hba;
                            rx_index_n = 0;
                        end else rx_index_n = rx_index_n + 1'b1;
                    end
                end else if (!is_k) bad_n = 1;
            end
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_index_q    <= 0;
            rl_q          <= 0;
            rn_q          <= 0;
            rate_q        <= 0;
            rc_q          <= 0;
            id_q          <= 0;
            lp_q          <= 0;
            np_q          <= 0;
            rx_ts_valid_o <= 0;
            rx_bad_o      <= 0;
            rx_ts2_o      <= 0;
            rx_inverted_o <= 0;
            rx_link_o     <= 0;
            rx_lane_o     <= 0;
            rx_rate_o     <= 0;
            rx_control_o  <= 0;
            rx_link_pad_o <= 0;
            rx_lane_pad_o <= 0;
        end else begin
            rx_index_q    <= rx_index_n;
            rl_q          <= rl_n;
            rn_q          <= rn_n;
            rate_q        <= rate_n;
            rc_q          <= rc_n;
            id_q          <= id_n;
            lp_q          <= lp_n;
            np_q          <= np_n;
            rx_ts_valid_o <= valid_n;
            rx_bad_o      <= bad_n;
            if (valid_n) begin
                rx_ts2_o      <= ts2_n;
                rx_inverted_o <= inverted_n;
                rx_link_o     <= rl_n;
                rx_lane_o     <= rn_n;
                rx_rate_o     <= rate_n;
                rx_control_o  <= rc_n;
                rx_link_pad_o <= lp_n;
                rx_lane_pad_o <= np_n;
            end
        end
    end
endmodule

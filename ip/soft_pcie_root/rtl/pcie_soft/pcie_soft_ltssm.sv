// Restricted downstream Gen1/Gen2 x1 LTSSM, Base 2.0 4.2.6. No
// crosslink, lane reversal/upconfiguration, ASPM or compliance-test mode.
// Unsupported training-control requests fail closed, never enter L0.
module pcie_soft_ltssm #(
    parameter integer GEN2_ENABLE   = 0,
    parameter integer QUIET_CYCLES  = 1500000,
    parameter integer POLL_CYCLES   = 3000000,
    parameter integer CONFIG_CYCLES = 250000
) (
    input wire clk, rst_n, enable_i, phy_ready_i, rx_electrical_idle_i,
    input wire detect_done_i, receiver_present_i,
    output wire detect_o, electrical_idle_o,
    input wire retrain_i,
    output reg retrain_done_o,
    input wire ts_valid_i, ts2_i, inverted_i, ts_bad_i,
    input wire [7:0] rx_link_i, rx_lane_i, rx_rate_i, rx_control_i,
    input wire rx_link_pad_i, rx_lane_pad_i,
    input wire tx_ts_done_i,
    input wire [1:0] tx_ts_kind_i,
    input wire rx_idle_pair_i, tx_idle_pair_i, rx_error_i,
    output reg [1:0] tx_kind_o,
    output wire [7:0] tx_link_o, tx_lane_o,
    output reg tx_link_pad_o, tx_lane_pad_o,
    output wire link_up_o, l0_o, timer_hold_o,
    output reg polarity_o,
    output reg failed_o,
    output wire [4:0] state_o,
    input wire force_gen1_i, phy_gen2_i, phy_rate_ready_i, eios_done_i,
    output wire [7:0] tx_rate_o,
    output wire eios_o, speed_idle_o,
    output reg target_gen2_o,
    output reg fallback_o,
    output reg deemphasis_o
);
    localparam [4:0] QUIET = 0, DETECT = 1, POLL_ACTIVE = 2, POLL_CONFIG = 3, WIDTH_START = 4,
        WIDTH_ACCEPT = 5, LANE_WAIT = 6, LANE_ACCEPT = 7, COMPLETE = 8, CONFIG_IDLE = 9, L0 = 10,
        REC_LOCK = 11, REC_CONFIG = 12, REC_IDLE = 13, DISABLED = 14, REC_EIOS = 15,
        REC_SPEED_IDLE = 16, REC_SPEED_WAIT = 17, REC_EIOS_DRAIN = 18;
    reg [4:0] state_q, next_state;
    reg [31:0] timer_q;
    reg [10:0] tx_count_q;
    reg [4:0] good_q, idle_q;
    reg first_q, ever_up_q;
    reg [7:0] rate_last_q;
    reg peer_gen2_q, auto_tried_q, directed_q, changed_q, old_gen2_q, next_gen2_q;
    reg [3:0] speed_good_q;
    reg time_phase_q, autonomous_q, next_deemphasis_q;
    wire time_tick = !phy_gen2_i || time_phase_q;
    wire auto_upgrade = GEN2_ENABLE != 0 && !force_gen1_i && peer_gen2_q && !phy_gen2_i &&
        !auto_tried_q;
    wire speed_state = state_q == REC_EIOS || state_q == REC_EIOS_DRAIN ||
        state_q == REC_SPEED_IDLE || state_q == REC_SPEED_WAIT;
    assign tx_rate_o = (GEN2_ENABLE != 0 && !force_gen1_i ? 8'h06 : 8'h02) |
        ((state_q == REC_LOCK || state_q == REC_CONFIG) && directed_q ? 8'h80 : 8'h00) |
        (state_q == REC_CONFIG && directed_q && autonomous_q ? 8'h40 : 8'h00);
    assign eios_o = state_q == REC_EIOS;
    assign speed_idle_o = state_q == REC_SPEED_IDLE || state_q == REC_SPEED_WAIT;

    wire unused_reserved = ^rx_control_i[7:5];
    wire polling_pad = rx_link_pad_i && rx_lane_pad_i;
    wire link_match = !rx_link_pad_i && rx_link_i == 0;
    wire lane_match = link_match && !rx_lane_pad_i && rx_lane_i == 0;
    wire ts_good = ts_valid_i && !inverted_i && rx_rate_i[1] && rx_control_i[4:0] == 0;
    reg  qualifies;
    assign tx_link_o = 0;
    assign tx_lane_o = 0;
    assign state_o = state_q;
    assign detect_o = state_q == DETECT;
    assign electrical_idle_o = state_q == QUIET || state_q == DETECT || state_q == DISABLED ||
        speed_idle_o;
    assign l0_o = state_q == L0;
    // Physical LinkUp remains asserted through Recovery so retry ownership
    // and FC state survive a successful retrain. Detect/disable clears it.
    assign link_up_o = ever_up_q || state_q == CONFIG_IDLE;
    assign timer_hold_o = state_q != L0;
    always @* begin
        tx_kind_o     = 0;
        tx_link_pad_o = 0;
        tx_lane_pad_o = 0;
        case (state_q)
            POLL_ACTIVE: begin
                tx_kind_o     = 1;
                tx_link_pad_o = 1;
                tx_lane_pad_o = 1;
            end
            POLL_CONFIG: begin
                tx_kind_o     = 2;
                tx_link_pad_o = 1;
                tx_lane_pad_o = 1;
            end
            WIDTH_START, WIDTH_ACCEPT: begin
                tx_kind_o     = 1;
                tx_lane_pad_o = 1;
            end
            LANE_WAIT, LANE_ACCEPT, REC_LOCK: tx_kind_o = 1;
            COMPLETE, REC_CONFIG: tx_kind_o = 2;
            default: tx_kind_o = 0;
        endcase
        qualifies = 0;
        case (state_q)
            POLL_ACTIVE: qualifies = ts_good && polling_pad;
            POLL_CONFIG: qualifies = ts_good && ts2_i && polling_pad;
            WIDTH_START, WIDTH_ACCEPT: qualifies = ts_good && !ts2_i && link_match && rx_lane_pad_i;
            LANE_WAIT, LANE_ACCEPT: qualifies = ts_good && !ts2_i && lane_match;
            COMPLETE, REC_CONFIG: qualifies = ts_good && ts2_i && lane_match;
            REC_LOCK: qualifies = ts_good && lane_match;
            default: qualifies = 0;
        endcase
        if ((state_q == COMPLETE || state_q == REC_CONFIG) && good_q != 0 &&
            rx_rate_i != rate_last_q)
            qualifies = 0;
        if (state_q == REC_LOCK && good_q != 0 && rx_rate_i[7] != rate_last_q[7]) qualifies = 0;
        next_state = state_q;
        case (state_q)
            QUIET:
            if (phy_ready_i && (timer_q >= QUIET_CYCLES - 1 || !rx_electrical_idle_i))
                next_state = DETECT;
            DETECT: if (detect_done_i) next_state = receiver_present_i ? POLL_ACTIVE : QUIET;
            POLL_ACTIVE: if (good_q >= 8 && tx_count_q >= 1024) next_state = POLL_CONFIG;
            POLL_CONFIG: if (good_q >= 8 && tx_count_q >= 16) next_state = WIDTH_START;
            WIDTH_START: if (good_q >= 2) next_state = WIDTH_ACCEPT;
            WIDTH_ACCEPT: next_state = LANE_WAIT;
            LANE_WAIT: if (good_q >= 2) next_state = LANE_ACCEPT;
            LANE_ACCEPT: if (good_q >= 2) next_state = COMPLETE;
            COMPLETE: if (good_q >= 8 && tx_count_q >= 16) next_state = CONFIG_IDLE;
            CONFIG_IDLE: if (idle_q >= 8 && tx_count_q >= 16) next_state = L0;
            L0: if (retrain_i || ts_valid_i || rx_error_i || auto_upgrade) next_state = REC_LOCK;
            REC_LOCK:
            if (good_q >= 8 && (GEN2_ENABLE == 0 || rate_last_q[7] == directed_q))
                next_state = REC_CONFIG;
            REC_CONFIG:
            if (good_q >= 8) begin
                if (GEN2_ENABLE != 0 && directed_q && rate_last_q[7] &&
                    (phy_gen2_i || (rate_last_q[2] && !force_gen1_i)) && tx_count_q >= 32)
                    next_state = REC_EIOS;
                else if ((!rate_last_q[7] ||
                          (!phy_gen2_i && (!rate_last_q[2] || force_gen1_i || GEN2_ENABLE == 0))) &&
                         tx_count_q >= 16)
                    next_state = REC_IDLE;
            end
            REC_EIOS: if (eios_done_i) next_state = REC_EIOS_DRAIN;
            REC_EIOS_DRAIN: if (timer_q >= 2) next_state = REC_SPEED_IDLE;
            REC_SPEED_IDLE:
            if (rx_electrical_idle_i && timer_q >= (fallback_o ? 750 : 100))
                next_state = REC_SPEED_WAIT;
            REC_SPEED_WAIT:
            if (phy_rate_ready_i && phy_gen2_i == target_gen2_o &&
                timer_q >= (fallback_o ? 750 : 100))
                next_state = REC_LOCK;
            REC_IDLE: if (idle_q >= 8 && tx_count_q >= 16) next_state = L0;
            default: next_state = state_q;
        endcase
        if (state_q == POLL_ACTIVE && timer_q >= POLL_CYCLES - 1) next_state = QUIET;
        if (state_q == REC_LOCK && timer_q >= POLL_CYCLES - 1) begin
            if (GEN2_ENABLE != 0 && good_q >= 8 && rate_last_q[7] &&
                (phy_gen2_i || (rate_last_q[2] && !force_gen1_i)))
                next_state = REC_CONFIG;
            else if (GEN2_ENABLE != 0 && (phy_gen2_i || changed_q)) next_state = REC_EIOS;
            else next_state = QUIET;
        end
        if ((state_q == POLL_CONFIG || state_q == REC_CONFIG) && timer_q >= 2 * POLL_CYCLES - 1)
            next_state = QUIET;
        if (GEN2_ENABLE != 0 && state_q == REC_CONFIG && (changed_q || phy_gen2_i) && !first_q &&
            rx_electrical_idle_i)
            next_state = REC_EIOS;
        if (speed_state && timer_q >= 2 * POLL_CYCLES - 1) next_state = QUIET;
        if (state_q >= WIDTH_START && state_q <= CONFIG_IDLE && timer_q >= CONFIG_CYCLES - 1)
            next_state = QUIET;
        if (state_q == REC_IDLE && timer_q >= CONFIG_CYCLES - 1) next_state = QUIET;
        if (!phy_ready_i && !speed_state) next_state = QUIET;
        if (!enable_i || (ts_valid_i && rx_control_i[2:0] != 0)) next_state = DISABLED;
        if (state_q == DISABLED && enable_i && phy_ready_i && !failed_o) next_state = QUIET;
    end
    // Native RATE must return to Gen1 even if the link clock is stopped.
    // rst_n is the root's async-assert, three-edge-release reset; rate ownership
    // otherwise changes only after peer electrical idle in Recovery.Speed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) target_gen2_o <= 0;
        else if (next_state == REC_SPEED_WAIT) target_gen2_o <= next_gen2_q;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state_q           <= QUIET;
            timer_q           <= 0;
            tx_count_q        <= 0;
            good_q            <= 0;
            idle_q            <= 0;
            first_q           <= 0;
            ever_up_q         <= 0;
            rate_last_q       <= 0;
            polarity_o        <= 0;
            failed_o          <= 0;
            retrain_done_o    <= 0;
            peer_gen2_q       <= 0;
            auto_tried_q      <= 0;
            directed_q        <= 0;
            changed_q         <= 0;
            old_gen2_q        <= 0;
            next_gen2_q       <= 0;
            fallback_o        <= 0;
            deemphasis_o      <= 1;
            speed_good_q      <= 0;
            time_phase_q      <= 0;
            autonomous_q      <= 0;
            next_deemphasis_q <= 1;
        end else begin
            state_q        <= next_state;
            retrain_done_o <= 0;
            time_phase_q   <= !time_phase_q;
            if (state_q == REC_LOCK && ts_valid_i) begin
                if (ts_good && lane_match && rx_rate_i[7]) begin
                    if (speed_good_q < 8) speed_good_q <= speed_good_q + 1'b1;
                end else speed_good_q <= 0;
            end
            if (GEN2_ENABLE != 0 && state_q == REC_LOCK && speed_good_q >= 8) directed_q <= 1;
            if (state_q == COMPLETE && qualifies) peer_gen2_q <= rx_rate_i[2];
            if (state_q == REC_LOCK && timer_q >= POLL_CYCLES - 1 && directed_q && !phy_gen2_i &&
                !changed_q) begin
                directed_q <= 0;
                fallback_o <= 1;
            end
            if (ts_valid_i) rate_last_q <= rx_rate_i;
            if (next_state != state_q) begin
                timer_q      <= 0;
                tx_count_q   <= 0;
                good_q       <= 0;
                idle_q       <= 0;
                first_q      <= 0;
                speed_good_q <= 0;
                if (state_q == L0 && next_state == REC_LOCK) begin
                    old_gen2_q   <= phy_gen2_i;
                    changed_q    <= 0;
                    autonomous_q <= auto_upgrade;
                    directed_q   <= auto_upgrade;
                    auto_tried_q <= auto_tried_q || auto_upgrade;
                end
                if (next_state == REC_EIOS) begin
                    if (state_q == REC_CONFIG && good_q >= 8 && rate_last_q[7] && directed_q) begin
                        next_gen2_q       <= rate_last_q[2] && !force_gen1_i;
                        changed_q         <= 1;
                        next_deemphasis_q <= rate_last_q[6];
                    end else begin
                        next_gen2_q <= changed_q ? old_gen2_q : 1'b0;
                        changed_q   <= 0;
                        fallback_o  <= 1;
                    end
                    directed_q <= 0;
                end
                if (next_state == REC_SPEED_WAIT) deemphasis_o <= next_deemphasis_q;
                if (next_state == REC_IDLE) begin
                    changed_q  <= 0;
                    directed_q <= 0;
                end
                if (next_state == QUIET || next_state == DISABLED) begin
                    if (ever_up_q) failed_o <= 1;
                    ever_up_q <= 0;
                end
                if (next_state == L0) begin
                    if (state_q == REC_IDLE) retrain_done_o <= 1;
                    ever_up_q <= 1;
                end
            end else begin
                if (time_tick && timer_q != 32'hffffffff) timer_q <= timer_q + 1'b1;
                if (ts_bad_i || (ts_valid_i && !qualifies)) good_q <= 0;
                else if (qualifies && good_q < 16) good_q <= good_q + 1'b1;
                if (qualifies) first_q <= 1;
                if (tx_ts_done_i && tx_ts_kind_i == tx_kind_o &&
                    (state_q == POLL_ACTIVE || first_q) && tx_count_q < 1024)
                    tx_count_q <= tx_count_q + 1'b1;
                if (state_q == CONFIG_IDLE || state_q == REC_IDLE) begin
                    if (rx_idle_pair_i) begin
                        if (idle_q < 16) idle_q <= idle_q + 2;
                        first_q <= 1;
                    end else idle_q <= 0;
                    if (first_q && tx_idle_pair_i && tx_count_q < 32) tx_count_q <= tx_count_q + 2;
                end
            end
            if (state_q == POLL_ACTIVE && ts_valid_i && inverted_i) polarity_o <= 1;
            if (ts_valid_i && rx_control_i[2:0] != 0) failed_o <= 1;
        end
    end
endmodule

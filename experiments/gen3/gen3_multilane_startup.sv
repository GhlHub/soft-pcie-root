// SPDX-License-Identifier: Apache-2.0
// Fixed-width downstream Gen1 training coordinator, before Gen3 speed change.
// One state/deadline for the link, independent qualification for every lane.
// Decoded TS inputs must come from full ordered-set validation. Detect done
// must be a fresh pulse for the current Detect request, not a PHY ready level.
// No lane reversal, width fallback, rate switching or packet reset is performed.
// Ownership history survives failed Recovery/enable loss until cold reset.
module gen3_multilane_startup #(
    parameter integer LINK_WIDTH      = 1,
    parameter integer QUIET_CYCLES    = 1500000,
    parameter integer POLL_CYCLES     = 3000000,
    parameter integer CONFIG_CYCLES   = 250000,
    parameter integer RECOVERY_CYCLES = 3000000,
    parameter integer POLL_TX_COUNT   = 1024
) (
    input wire clk, reset_i, enable_i,
    input wire [LINK_WIDTH-1:0] phy_ready_i, rx_electrical_idle_i,
    input wire [LINK_WIDTH-1:0] detect_done_i, receiver_present_i,
    input wire [LINK_WIDTH-1:0] ts_valid_i, ts2_i, inverted_i, ts_bad_i,
    input wire [LINK_WIDTH*8-1:0] rx_link_i, rx_lane_i, rx_rate_i, rx_control_i,
    input wire [LINK_WIDTH-1:0] rx_link_pad_i, rx_lane_pad_i,
    input wire [LINK_WIDTH-1:0] tx_ts_done_i,
    input wire [LINK_WIDTH*2-1:0] tx_ts_kind_i,
    input wire [LINK_WIDTH-1:0] rx_symbol_valid_i, rx_idle_pair_i, tx_idle_pair_i, rx_error_i,
    input wire retrain_i,
    output wire detect_o, electrical_idle_o,
    output reg [1:0] tx_kind_o,
    output wire [LINK_WIDTH*8-1:0] tx_lane_o,
    output reg tx_link_pad_o, tx_lane_pad_o,
    output reg [LINK_WIDTH-1:0] polarity_o,
    output wire l0_o, link_up_o,
    output reg epoch_started_o, failed_o, retrain_done_o,
    output wire [4:0] state_o
);
    localparam [4:0] QUIET = 0, DETECT = 1, POLL_ACTIVE = 2, POLL_CONFIG = 3, WIDTH_START = 4,
        WIDTH_ACCEPT = 5, LANE_WAIT = 6, LANE_ACCEPT = 7, COMPLETE = 8, CONFIG_IDLE = 9, L0 = 10,
        REC_LOCK = 11, REC_CONFIG = 12, REC_IDLE = 13, FAILED = 14;
    reg [4:0] state, next_state;
    reg [31:0] timer, recovery_timer;
    reg [LINK_WIDTH-1:0] detected, present, first_seen;
    reg [10:0] tx_count[0:LINK_WIDTH-1];
    reg [4:0] good[0:LINK_WIDTH-1], idle_count[0:LINK_WIDTH-1];
    reg [7:0] last_rate[0:LINK_WIDTH-1];
    reg [LINK_WIDTH-1:0] qualifies, rx_qualified, tx_qualified, idle_qualified;
    wire                  recovery = state == REC_LOCK || state == REC_CONFIG || state == REC_IDLE;
    wire                  all_ready = &phy_ready_i;
    wire                  unused_reserved = ^rx_control_i;
    reg                   rate_consistent;
    wire [LINK_WIDTH-1:0] control_bad;
    wire                  unsupported = |(ts_valid_i & control_bad);
    assign state_o = state;
    assign detect_o = state == DETECT;
    assign electrical_idle_o = state == QUIET || state == DETECT || state == FAILED;
    assign l0_o = state == L0 && all_ready && enable_i && !(|rx_error_i) && !unsupported &&
        !retrain_i && !(|ts_valid_i);
    assign link_up_o = epoch_started_o && state != FAILED && all_ready && enable_i;
    for (genvar lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin : lane_identity
        assign tx_lane_o[lane*8+:8] = 8'(lane);
        assign control_bad[lane]    = rx_control_i[lane*8+:5] != 0;
    end
    always @* begin
        tx_kind_o     = 0;
        tx_link_pad_o = 0;
        tx_lane_pad_o = 0;
        case (state)
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
            default: ;
        endcase
        qualifies       = '0;
        rx_qualified    = '0;
        tx_qualified    = '0;
        idle_qualified  = '0;
        rate_consistent = 1;
        for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
            if (ts_valid_i[lane] && !inverted_i[lane] && !ts_bad_i[lane] && !rx_error_i[lane] &&
                rx_rate_i[8*lane+1] && !control_bad[lane]) begin
                case (state)
                    POLL_ACTIVE: qualifies[lane] = rx_link_pad_i[lane] && rx_lane_pad_i[lane];
                    POLL_CONFIG:
                    qualifies[lane] = ts2_i[lane] && rx_link_pad_i[lane] && rx_lane_pad_i[lane];
                    WIDTH_START, WIDTH_ACCEPT:
                    qualifies[lane] = !ts2_i[lane] && !rx_link_pad_i[lane] &&
                        rx_link_i[8*lane+:8] == 0 && rx_lane_pad_i[lane];
                    LANE_WAIT, LANE_ACCEPT, COMPLETE, REC_LOCK, REC_CONFIG:
                    qualifies[lane] = !rx_link_pad_i[lane] && !rx_lane_pad_i[lane] &&
                        rx_link_i[8*lane+:8] == 0 && rx_lane_i[8*lane+:8] == 8'(lane) &&
                        ((state == REC_LOCK) ||
                         (ts2_i[lane] == (state == COMPLETE || state == REC_CONFIG)));
                    default: ;
                endcase
                if (recovery && rx_rate_i[8*lane+7]) qualifies[lane] = 0;
                if ((state == COMPLETE || state == REC_CONFIG) && good[lane] != 0 &&
                    rx_rate_i[8*lane+:8] != last_rate[lane])
                    qualifies[lane] = 0;
            end
            if (last_rate[lane] != last_rate[0]) rate_consistent = 0;
            rx_qualified[lane] =
                good[lane] >= ((state >= WIDTH_START && state <= LANE_ACCEPT) ? 2 : 8) &&
                !rx_error_i[lane] && !(ts_valid_i[lane] && !qualifies[lane]) &&
                !(ts_bad_i[lane] && state != COMPLETE && state != REC_CONFIG);
            tx_qualified[lane] = tx_count[lane] >= 11'(state == POLL_ACTIVE ? POLL_TX_COUNT : 16);
            idle_qualified[lane] = idle_count[lane] >= 8 &&
                !(rx_symbol_valid_i[lane] && !rx_idle_pair_i[lane]) && !rx_error_i[lane];
        end
        next_state = state;
        case (state)
            QUIET:
            if (all_ready && (timer >= QUIET_CYCLES - 1 || !(|rx_electrical_idle_i)))
                next_state = DETECT;
            DETECT:
            if (&(detected | detect_done_i))
                next_state = (&(present | (detect_done_i & receiver_present_i))) ? POLL_ACTIVE :
                    FAILED;
            POLL_ACTIVE: if ((&rx_qualified) && (&tx_qualified)) next_state = POLL_CONFIG;
            POLL_CONFIG: if ((&rx_qualified) && (&tx_qualified)) next_state = WIDTH_START;
            WIDTH_START: if (&rx_qualified) next_state = WIDTH_ACCEPT;
            WIDTH_ACCEPT: next_state = LANE_WAIT;
            LANE_WAIT: if (&rx_qualified) next_state = LANE_ACCEPT;
            LANE_ACCEPT: if (&rx_qualified) next_state = COMPLETE;
            COMPLETE:
            if ((&rx_qualified) && (&tx_qualified) && rate_consistent) next_state = CONFIG_IDLE;
            CONFIG_IDLE: if ((&idle_qualified) && (&tx_qualified)) next_state = L0;
            L0: if (retrain_i || (|ts_valid_i) || (|rx_error_i)) next_state = REC_LOCK;
            REC_LOCK: if (&rx_qualified) next_state = REC_CONFIG;
            REC_CONFIG:
            if ((&rx_qualified) && (&tx_qualified) && rate_consistent) next_state = REC_IDLE;
            REC_IDLE: if ((&idle_qualified) && (&tx_qualified)) next_state = L0;
            default: ;
        endcase
        // Fatal conditions have priority over old qualification and transitions.
        // A single absolute Recovery timer spans all three substates.
        if ((state == DETECT || state == POLL_ACTIVE) && timer >= POLL_CYCLES - 1)
            next_state = FAILED;
        if (state == POLL_CONFIG && timer >= 2 * POLL_CYCLES - 1) next_state = FAILED;
        if (state >= WIDTH_START && state <= CONFIG_IDLE && timer >= CONFIG_CYCLES - 1)
            next_state = FAILED;
        if (recovery && recovery_timer >= RECOVERY_CYCLES - 1) next_state = FAILED;
        if ((state != QUIET && !all_ready) || unsupported || !enable_i || state == FAILED)
            next_state = FAILED;
    end
    always @(posedge clk) begin
        if (reset_i) begin
            state           <= QUIET;
            timer           <= 0;
            recovery_timer  <= 0;
            detected        <= 0;
            present         <= 0;
            first_seen      <= 0;
            polarity_o      <= 0;
            epoch_started_o <= 0;
            failed_o        <= 0;
            retrain_done_o  <= 0;
            for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                tx_count[lane]   <= 0;
                good[lane]       <= 0;
                idle_count[lane] <= 0;
                last_rate[lane]  <= 0;
            end
        end else begin
            state          <= next_state;
            retrain_done_o <= 0;
            if (next_state == FAILED) failed_o <= 1;
            if (next_state == L0) begin
                epoch_started_o <= 1;
                if (state == REC_IDLE) retrain_done_o <= 1;
            end
            if (state == L0 && next_state == REC_LOCK) recovery_timer <= 0;
            else if (recovery && recovery_timer != 32'hffffffff)
                recovery_timer <= recovery_timer + 1'b1;
            if (state == DETECT) begin
                detected <= detected | detect_done_i;
                present  <= present | (detect_done_i & receiver_present_i);
            end
            if (state != next_state) begin
                timer      <= 0;
                first_seen <= 0;
                for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                    tx_count[lane]   <= 0;
                    good[lane]       <= 0;
                    idle_count[lane] <= 0;
                    last_rate[lane]  <= 0;
                end
            end else begin
                if (timer != 32'hffffffff) timer <= timer + 1'b1;
                for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                    if (state == POLL_ACTIVE && ts_valid_i[lane] && inverted_i[lane])
                        polarity_o[lane] <= 1;
                    if (rx_error_i[lane] || (ts_valid_i[lane] && !qualifies[lane]) ||
                        (ts_bad_i[lane] &&
                         !((state == COMPLETE || state == REC_CONFIG) && good[lane] >= 8)))
                        good[lane] <= 0;
                    else if (qualifies[lane] && good[lane] < 16) good[lane] <= good[lane] + 1'b1;
                    if (qualifies[lane]) begin
                        first_seen[lane] <= 1;
                        last_rate[lane]  <= rx_rate_i[8*lane+:8];
                    end
                    if (tx_ts_done_i[lane] && tx_ts_kind_i[2*lane+:2] == tx_kind_o && tx_kind_o !=
                        0 && (state == POLL_ACTIVE || first_seen[lane]) && tx_count[lane] < 1024)
                        tx_count[lane] <= tx_count[lane] + 1'b1;
                    if (state == CONFIG_IDLE || state == REC_IDLE) begin
                        if (rx_symbol_valid_i[lane]) begin
                            if (rx_idle_pair_i[lane] && !rx_error_i[lane]) begin
                                if (idle_count[lane] < 16) idle_count[lane] <= idle_count[lane] + 2;
                                first_seen[lane] <= 1;
                            end else idle_count[lane] <= 0;
                        end
                        if (first_seen[lane] && tx_idle_pair_i[lane] && tx_count[lane] < 32)
                            tx_count[lane] <= tx_count[lane] + 2;
                    end
                end
            end
        end
    end
    initial begin
        if (LINK_WIDTH != 1 && LINK_WIDTH != 2) $fatal(1, "LINK_WIDTH must be 1 or 2");
        if (QUIET_CYCLES < 1 || POLL_CYCLES < 2 || CONFIG_CYCLES < 2 || RECOVERY_CYCLES < 2 ||
            POLL_TX_COUNT < 1 || POLL_TX_COUNT > 1024)
            $fatal(1, "Invalid training timers/count");
    end
endmodule

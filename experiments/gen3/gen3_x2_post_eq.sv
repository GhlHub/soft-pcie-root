// SPDX-License-Identifier: Apache-2.0
// Complete the two-lane Gen3 Recovery handshake after adaptive equalization.
// The physical state can close while the data-link ownership epoch remains.
module gen3_x2_post_eq #(
    parameter integer HANDSHAKE_CYCLES = 6000000
) (
    input wire clk, reset_i, start_i,
    input wire [1:0] phy_ready_i, aligned_i, ts_event_i, ts1_i, ts2_i,
    input wire [255:0] ts_i,
    input wire rx_data_word_i, rx_idle_word_i, rx_stream_end_i, rx_end_idle_i,
    input wire tx_ts_i, tx_ts2_i, tx_eieos_i, tx_idle_word_i,
    input wire rx_fault_i, tx_fault_i,
    output wire tx_enable_o, tx_stop_o, tx_ts2_o, tx_stream_o,
    output wire l0_o, recovery_o, failed_o,
    output reg epoch_o,
    output reg [4:0] state_o
);
    localparam [4:0] OFF = 0, LOCK = 19, CONFIG = 16, IDLE = 17, L0 = 18, FAILED = 31;
    localparam integer TIMER_BITS = $clog2(HANDSHAKE_CYCLES);
    reg  [TIMER_BITS-1:0] timer_q;
    reg                   fresh_tx_q;
    reg  [           4:0] sent_q;
    reg  [           3:0] good_q                                                             [0:1];
    reg  [           7:0] rate_q                                                             [0:1];
    reg                   rx_idle_q;
    reg  [           1:0] tx_idle_q;
    wire                  training = state_o == LOCK || state_o == CONFIG || state_o == IDLE;
    wire [1:0] good_ts, qualified;
    wire matching_rates = rate_q[0] == rate_q[1];
    wire fatal = rx_fault_i || tx_fault_i || !(&phy_ready_i) ||
        (training && timer_q == TIMER_BITS'(HANDSHAKE_CYCLES - 1));
    assign tx_enable_o = state_o != OFF;
    assign tx_stop_o = state_o == FAILED;
    assign tx_ts2_o = state_o == CONFIG;
    assign tx_stream_o = state_o == IDLE || state_o == L0;
    assign l0_o = state_o == L0 && !rx_stream_end_i && !fatal;
    assign recovery_o = epoch_o &&
        (training || (state_o == L0 && rx_stream_end_i && !rx_end_idle_i && !fatal));
    assign failed_o = state_o == FAILED;
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : qualify_lanes
        wire [7:0] rate = ts_i[lane*128+32+:8];
        wire       no_speed_change = !rate[7] && !ts_i[lane*128+55];
        wire       ec_zero = ts_i[lane*128+48+:2] == 0;
        wire       appropriate_ts = ts2_i[lane] || (state_o == LOCK && ts1_i[lane] && ec_zero);
        assign good_ts[lane] = aligned_i[lane] && rate[3] && no_speed_change && appropriate_ts;
        assign qualified[lane] = good_q[lane] == 8 && aligned_i[lane] &&
            (!ts_event_i[lane] || (good_ts[lane] && rate == rate_q[lane]));
    end

    reg [4:0] next_state;
    always @* begin
        next_state = state_o;
        case (state_o)
            OFF: if (start_i) next_state = fatal ? FAILED : LOCK;
            LOCK:
            if (!tx_eieos_i && fresh_tx_q && (&qualified) && matching_rates && sent_q >= 8)
                next_state = CONFIG;
            CONFIG:
            if (!tx_eieos_i && (&qualified) && matching_rates && sent_q >= 16) next_state = IDLE;
            IDLE:
            if (rx_idle_q && tx_idle_q == 2 && (!rx_data_word_i || rx_idle_word_i)) next_state = L0;
            L0: if (rx_stream_end_i) next_state = rx_end_idle_i ? FAILED : LOCK;
            default: ;
        endcase
        if (state_o != OFF && (fatal || (training && rx_stream_end_i))) next_state = FAILED;
    end
    always @(posedge clk) begin
        if (reset_i) begin
            state_o    <= OFF;
            timer_q    <= 0;
            epoch_o    <= 0;
            fresh_tx_q <= 0;
            sent_q     <= 0;
            rx_idle_q  <= 0;
            tx_idle_q  <= 0;
            for (integer lane = 0; lane < 2; lane = lane + 1) begin
                good_q[lane] <= 0;
                rate_q[lane] <= 0;
            end
        end else begin
            state_o <= next_state;
            if (next_state == L0) epoch_o <= 1;
            if (next_state == LOCK && state_o != LOCK) timer_q <= 0;
            else if (training && !fatal) timer_q <= timer_q + 1'b1;
            if (next_state == LOCK && state_o != LOCK) fresh_tx_q <= 0;
            else if (state_o == LOCK && tx_eieos_i) fresh_tx_q <= 1;
            if (state_o != next_state || tx_eieos_i) sent_q <= 0;
            else if (((state_o == LOCK && fresh_tx_q && tx_ts_i) ||
                      (state_o == CONFIG && tx_ts2_i && good_q[0] != 0 && good_q[1] != 0)) &&
                     sent_q < 16)
                sent_q <= sent_q + 1'b1;
            for (integer lane = 0; lane < 2; lane = lane + 1) begin
                if (state_o != next_state || (state_o == LOCK && tx_eieos_i) || !aligned_i[lane])
                    good_q[lane] <= 0;
                else if ((state_o == LOCK || state_o == CONFIG) && ts_event_i[lane]) begin
                    if (!good_ts[lane]) good_q[lane] <= 0;
                    else if (good_q[lane] == 0 || rate_q[lane] != ts_i[128*lane+32+:8])
                        good_q[lane] <= 1;
                    else if (good_q[lane] < 8) good_q[lane] <= good_q[lane] + 1'b1;
                    rate_q[lane] <= ts_i[128*lane+32+:8];
                end
            end
            if (state_o != IDLE || (rx_data_word_i && !rx_idle_word_i)) begin
                rx_idle_q <= 0;
                tx_idle_q <= 0;
            end else begin
                if (rx_idle_word_i) rx_idle_q <= 1;
                if (rx_idle_q && tx_idle_word_i && tx_idle_q < 2) tx_idle_q <= tx_idle_q + 1'b1;
            end
        end
    end
    initial if (HANDSHAKE_CYCLES < 2) $fatal(1, "Invalid Gen3 x2 Recovery deadline");
endmodule

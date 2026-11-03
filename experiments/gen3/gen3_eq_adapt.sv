// SPDX-License-Identifier: Apache-2.0
// Downstream x1 Phase 2/3 engine. No packet ownership or packet resets here.
// Evaluation is a bounded PHY-adaptation + clean-training test, not a BER test.
module gen3_eq_adapt #(
    parameter integer PHASE2_CYCLES   = 8000000,
    parameter integer PHASE3_CYCLES   = 6000000,
    parameter integer REQUEST_CYCLES  = 375000,
    parameter integer SETTLE_CYCLES   = 250,
    parameter integer EVALUATE_CYCLES = 25000,
    parameter integer APPLY_CYCLES    = 125
) (
    input wire clk, reset_i, enter_i, cancel_i, phy_ready_i,
    input wire ts_event_i, ts_valid_i, aligned_i, rx_error_i,
    input wire [31:0] rx_fields_i,
    input wire [3:0] initial_preset_i,
    input wire [17:0] initial_coeff_i,
    input wire [5:0] local_fs_i, local_lf_i, peer_fs_i, peer_lf_i,
    input wire txeq_done_i,
    input wire [17:0] txeq_coeff_i,
    input wire rxeq_done_i, rxeq_adapt_done_i, rxeq_preset_sel_i,
    input wire [17:0] rxeq_proposal_i,
    output reg [1:0] txeq_ctrl_o, rxeq_ctrl_o,
    output reg [3:0] txeq_preset_o, rxeq_preset_o,
    output wire [5:0] txeq_coeff_o,
    output wire [31:0] tx_fields_o,
    output wire reset_interval_o,
    output reg active_o, done_o, failed_o,
    output reg [3:0] reason_o,
    output reg [3:0] attempts_o,
    output reg [3:0] applied_preset_o,
    output reg [17:0] applied_coeff_o
);
    localparam [3:0] IDLE = 0, P2 = 1, APPLY = 2, QUERY_GAP = 3, QUERY = 4, P3_WAIT = 5,
        RX_START = 6, RX_WAIT = 7, RX_GAP = 8, EVALUATE = 9, NEXT = 10;
    reg [3:0] state;
    reg [23:0] phase_timer, request_timer;
    reg [15:0] operation_timer;
    reg [31:0] previous, request;
    reg seen, handled, phase3, reject_request, use_preset;
    reg [3:0] advertised_preset, requested_preset;
    reg [17:0] advertised_coeff, requested_coeff;
    reg  [ 1:0] coeff_index;
    reg  [ 7:0] clean_pairs;
    reg         extended_request;
    reg  [ 1:0] extended_count;
    wire [ 1:0] ec = rx_fields_i[1:0];
    wire        pair = ts_event_i && ts_valid_i && aligned_i && seen && previous == rx_fields_i;
    wire [17:0] received_coeff = {rx_fields_i[13:8], rx_fields_i[21:16], rx_fields_i[29:24]};
    function automatic legal(input [17:0] c, input [5:0] fs, lf);
        reg [7:0] pre, main, post;
        begin
            pre = {2'b0, c[17:12]};
            main = {2'b0, c[11:6]};
            post = {2'b0, c[5:0]};
            legal = fs >= 24 && lf <= fs && pre <= {4'b0, fs[5:2]} &&
                pre + main + post == {2'b0, fs} && main >= pre + post + {2'b0, lf};
        end
    endfunction
    wire matches_request = use_preset ? rx_fields_i[6:3] == requested_preset :
        received_coeff == requested_coeff;
    wire [7:0] symbol6 = {
        phase3 && use_preset,
        phase3 ? requested_preset : advertised_preset,
        1'b0,
        phase3 ? 2'b11 : 2'b10
    };
    wire [17:0] fields_coeff = phase3 ? requested_coeff : advertised_coeff;
    wire [30:0] fields_low = {
        reject_request && !phase3,
        fields_coeff[5:0],
        2'b0,
        fields_coeff[11:6],
        2'b0,
        fields_coeff[17:12],
        symbol6
    };
    assign tx_fields_o = {^fields_low, fields_low};
    assign txeq_coeff_o = coeff_index == 0 ? requested_coeff[17:12] :
        coeff_index == 1 ? requested_coeff[11:6] : requested_coeff[5:0];
    assign reset_interval_o = active_o && !phase3 && pair && ec == 2 && rx_fields_i[2];
    task automatic fail(input [3:0] reason);
        begin
            active_o    <= 0;
            done_o      <= 0;
            failed_o    <= 1;
            reason_o    <= reason;
            state       <= IDLE;
            txeq_ctrl_o <= 0;
            rxeq_ctrl_o <= 0;
        end
    endtask
    always @(posedge clk) begin
        if (reset_i) begin
            extended_request  <= 0;
            extended_count    <= 0;
            state             <= IDLE;
            active_o          <= 0;
            done_o            <= 0;
            failed_o          <= 0;
            reason_o          <= 0;
            txeq_ctrl_o       <= 0;
            rxeq_ctrl_o       <= 0;
            txeq_preset_o     <= 0;
            rxeq_preset_o     <= 0;
            phase_timer       <= 0;
            request_timer     <= 0;
            extended_request  <= 0;
            operation_timer   <= 0;
            previous          <= 0;
            request           <= 0;
            seen              <= 0;
            handled           <= 0;
            phase3            <= 0;
            reject_request    <= 0;
            use_preset        <= 0;
            advertised_preset <= 0;
            requested_preset  <= 0;
            advertised_coeff  <= 0;
            requested_coeff   <= 0;
            coeff_index       <= 0;
            clean_pairs       <= 0;
            attempts_o        <= 0;
            applied_preset_o  <= 0;
            applied_coeff_o   <= 0;
        end else begin
            done_o <= 0;
            if (cancel_i) begin
                active_o    <= 0;
                state       <= IDLE;
                txeq_ctrl_o <= 0;
                rxeq_ctrl_o <= 0;
            end else if (enter_i && !active_o) begin
                extended_request  <= 0;
                extended_count    <= 0;
                active_o          <= 1;
                failed_o          <= 0;
                reason_o          <= 0;
                phase3            <= 0;
                state             <= P2;
                phase_timer       <= 0;
                request_timer     <= 0;
                extended_request  <= 0;
                operation_timer   <= 0;
                seen              <= 0;
                handled           <= 0;
                reject_request    <= 0;
                applied_preset_o  <= initial_preset_i;
                applied_coeff_o   <= initial_coeff_i;
                advertised_preset <= initial_preset_i;
                advertised_coeff  <= initial_coeff_i;
                attempts_o        <= 0;
                txeq_ctrl_o       <= 0;
                rxeq_ctrl_o       <= 0;
            end else if (active_o) begin
                phase_timer <= phase_timer + 1'b1;
                if (request_timer != 24'hffffff) request_timer <= request_timer + 1'b1;
                if (operation_timer != 65535) operation_timer <= operation_timer + 1'b1;
                if (!aligned_i || rx_error_i) seen <= 0;
                else if (ts_event_i) begin
                    seen     <= ts_valid_i;
                    previous <= rx_fields_i;
                end
                case (state)
                    P2: begin
                        if (pair && ec == 3) begin
                            phase3           <= 1;
                            phase_timer      <= 0;
                            request_timer    <= 0;
                            extended_request <= 0;
                            seen             <= 0;
                            state            <= P3_WAIT;
                            use_preset       <= 1;
                            requested_preset <= rx_fields_i[6:3];
                            requested_coeff  <= received_coeff;
                            reject_request   <= 0;
                            attempts_o       <= 1;
                        end else if (pair && ec == 2 && (!handled || request != rx_fields_i)) begin
                            request          <= rx_fields_i;
                            handled          <= 1;
                            requested_coeff  <= received_coeff;
                            requested_preset <= rx_fields_i[6:3];
                            if ((rx_fields_i[7] && rx_fields_i[6:3] > 10) ||
                                (!rx_fields_i[7] && !legal(
                                    received_coeff, local_fs_i, local_lf_i
                                ))) begin
                                reject_request   <= 1;
                                advertised_coeff <= received_coeff;
                                if (rx_fields_i[7]) advertised_preset <= rx_fields_i[6:3];
                            end else begin
                                // Echo only after the PHY has actually applied and queried the setting.
                                txeq_preset_o   <= rx_fields_i[6:3];
                                coeff_index     <= 0;
                                txeq_ctrl_o     <= rx_fields_i[7] ? 1 : 2;
                                operation_timer <= 0;
                                state           <= APPLY;
                            end
                        end
                    end
                    APPLY: begin
                        if (coeff_index != 2) coeff_index <= coeff_index + 1'b1;
                        if (txeq_done_i) begin
                            txeq_ctrl_o <= 0;
                            state       <= QUERY_GAP;
                        end
                    end
                    QUERY_GAP:
                    if (!txeq_done_i) begin
                        txeq_ctrl_o <= 3;
                        state       <= QUERY;
                    end
                    QUERY:
                    if (txeq_done_i) begin
                        txeq_ctrl_o      <= 0;
                        state            <= P2;
                        reject_request   <= 0;
                        advertised_coeff <= txeq_coeff_i;
                        applied_coeff_o  <= txeq_coeff_i;
                        if (request[7]) begin
                            advertised_preset <= requested_preset;
                            applied_preset_o  <= requested_preset;
                        end else advertised_preset <= applied_preset_o;
                    end
                    P3_WAIT: begin
                        // Fresh pair after the full settling guard. Ignore received Use Preset.
                        if (int'(request_timer) < SETTLE_CYCLES) seen <= 0;
                        else if (pair && ec == 3 && matches_request) begin
                            if (rx_fields_i[30]) state <= NEXT;
                            else begin
                                rxeq_preset_o <= rx_fields_i[6:3];
                                state         <= RX_START;
                            end
                        end
                        if (int'(request_timer) >= REQUEST_CYCLES - 1) state <= NEXT;
                    end
                    RX_START:
                    if (!rxeq_done_i) begin
                        rxeq_ctrl_o <= 2;
                        state       <= RX_WAIT;
                    end
                    RX_WAIT:
                    if (rxeq_done_i) begin
                        rxeq_ctrl_o <= 0;
                        if (rxeq_adapt_done_i) begin
                            state           <= EVALUATE;
                            operation_timer <= 0;
                            clean_pairs     <= 0;
                            seen            <= 0;
                        end else if ((rxeq_preset_sel_i && rxeq_proposal_i[3:0] <= 10) ||
                                     (!rxeq_preset_sel_i && legal(
                                rxeq_proposal_i, peer_fs_i, peer_lf_i
                            ))) begin
                            if (attempts_o >= 11) fail(4);
                            else begin
                                attempts_o <= attempts_o + 1'b1;
                                use_preset <= rxeq_preset_sel_i;
                                requested_preset <= rxeq_preset_sel_i ? rxeq_proposal_i[3:0] :
                                    requested_preset;
                                requested_coeff <= rxeq_proposal_i;
                                state <= RX_GAP;
                            end
                        end else state <= NEXT;
                    end
                    RX_GAP:
                    if (!rxeq_done_i && int'(request_timer) >= SETTLE_CYCLES) begin
                        request_timer    <= 0;
                        extended_request <= 0;
                        seen             <= 0;
                        state            <= P3_WAIT;
                    end
                    EVALUATE: begin
                        if (pair && ec == 3 && matches_request && !rx_fields_i[30] &&
                            clean_pairs != 255)
                            clean_pairs <= clean_pairs + 1'b1;
                        if (rx_error_i || !aligned_i ||
                            (ts_event_i &&
                             (!ts_valid_i || ec != 3 || !matches_request || rx_fields_i[30])))
                            state <= NEXT;
                        // Silence is not evidence of a clean link: finish on a fresh pair.
                        else if (pair && int'(operation_timer) >= EVALUATE_CYCLES &&
                                 clean_pairs >= 8 && int'(request_timer) >= SETTLE_CYCLES) begin
                            done_o   <= 1;
                            active_o <= 0;
                            state    <= IDLE;
                        end
                    end
                    NEXT:
                    if (!rxeq_done_i && int'(request_timer) >= SETTLE_CYCLES) begin
                        if (attempts_o >= 11) fail(4);
                        else begin
                            attempts_o <= attempts_o + 1'b1;
                            use_preset <= 1;
                            requested_preset <= requested_preset >= 10 ? 0 :
                                requested_preset + 1'b1;
                            requested_coeff <= 0;
                            state <= P3_WAIT;
                            request_timer <= 0;
                            extended_request <= 0;
                            seen <= 0;
                        end
                    end
                    default: state <= IDLE;
                endcase
                // Up to two final evaluations may exceed the ordinary request
                // budget. The absolute Phase 3 deadline still bounds a stuck PHY.
                if (phase3 && int'(request_timer) >= REQUEST_CYCLES - 1 && state != NEXT &&
                    !extended_request) begin
                    if ((state == RX_WAIT || state == EVALUATE) && extended_count < 2) begin
                        extended_request <= 1;
                        extended_count   <= extended_count + 1'b1;
                    end else begin
                        // A request deadline overrides a coincident evaluation success.
                        done_o <= 0;
                        if (state == EVALUATE) active_o <= 1;
                        rxeq_ctrl_o <= 0;
                        state       <= NEXT;
                    end
                end
                if ((state == APPLY || state == QUERY_GAP || state == QUERY) &&
                    int'(operation_timer) >= APPLY_CYCLES - 1)
                    fail(3);
                if (!phy_ready_i) fail(1);
                else if (int'(phase_timer) >= (phase3 ? PHASE3_CYCLES - 1 : PHASE2_CYCLES - 1))
                    fail(2);
            end
        end
    end
endmodule

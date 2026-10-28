// VC0 only, Base 2.0 sections 2.6/3.3. All events are validated DLLPs.
// P=0, NP=1, Cpl=2. Header counters wrap at 256, data counters at 4096.
// Root port without peer-to-peer advertises infinite Cpl credits. Requester
// MUST reserve its entire completion buffer before issuing a non-posted TLP.
module pcie_soft_flow_control #(
    parameter integer        UPDATE_CYCLES  = 1024,
    parameter         [ 7:0] RX_HEADERS     = 8'd2,
    parameter         [11:0] RX_DATA        = 12'd16,
    parameter         [ 7:0] POSTED_HEADERS = 8'd4,
    parameter         [11:0] POSTED_DATA    = 12'd32
) (
    input wire clk, rst_n, link_up_i, tx_enable_i,
    input wire rx_valid_i,
    input wire [7:0] rx_type_i, rx_header_i,
    input wire [11:0] rx_data_i,
    output wire dllp_valid_o,
    input wire dllp_ready_i,
    output wire [7:0] dllp_type_o, dllp_header_o,
    output wire [11:0] dllp_data_o,
    input wire reserve_i, replay_i,
    input wire [1:0] reserve_class_i,
    input wire [8:0] reserve_data_i,
    output wire reserve_ready_o, active_o,
    // Credits returned only after receive packet storage is released.
    input wire release_i,
    input wire [1:0] release_class_i,
    input wire [8:0] release_data_i,
    output reg error_o
);
    wire unused_reserved = rx_type_i[3];
    localparam integer T = $clog2(UPDATE_CYCLES + 1);
    reg [1:0] phase_q, class_q;
    reg [  2:0] seen_q;
    reg         seen2_q;
    reg [T-1:0] refresh_q;
    reg [7:0] limit_h[0:2], used_h[0:2], local_h[0:2];
    reg [11:0] limit_d[0:2], used_d[0:2], local_d[0:2];
    reg [2:0] infinite_h, infinite_d;
    reg offer_q;
    reg return_pending_q;
    reg [7:0] type_q, header_q;
    reg [11:0] data_q;
    wire is_init = (rx_type_i[7:6] == 2'b01 || rx_type_i[7:6] == 2'b11) && rx_type_i[2:0] == 0;
    wire is_update = rx_type_i[7:6] == 2'b10 && rx_type_i[2:0] == 0;
    wire [1:0] rx_class = rx_type_i[5:4] - 2'd0;  // Type subcodes 0=P,1=NP,2=Cpl.
    wire [7:0] updated_h = rx_header_i - used_h[rx_class == 3 ? 0 : rx_class];
    wire [11:0] updated_d = rx_data_i - used_d[rx_class == 3 ? 0 : rx_class];
    wire update_valid = (infinite_h[rx_class] || updated_h < 128) &&
        (infinite_d[rx_class] || updated_d < 2048);
    wire class_valid = rx_class < 3 && rx_type_i[5:4] != 3;
    // Compute each credit class in parallel. Class selection must not sit
    // ahead of subtraction/comparison on the 250MHz admission path.
    wire [2:0] class_ready;
    genvar c;
    generate
        for (c = 0; c < 3; c = c + 1) begin : credit_available
            wire [ 7:0] available_h = limit_h[c] - used_h[c];
            wire [11:0] available_d = limit_d[c] - used_d[c];
            assign class_ready[c] = (infinite_h[c] || available_h != 0) &&
                (reserve_data_i == 0 || infinite_d[c] || available_d >= {3'b0, reserve_data_i});
        end
    endgenerate
    assign active_o = phase_q == 2;
    assign reserve_ready_o = active_o && tx_enable_i && reserve_class_i < 3 &&
        (replay_i || class_ready[reserve_class_i]);
    assign dllp_valid_o = link_up_i && offer_q;
    assign dllp_type_o = type_q;
    assign dllp_header_o = header_q;
    assign dllp_data_o = data_q;
    integer i;
    always @(posedge clk) begin
        if (!rst_n || !link_up_i) begin
            phase_q          <= 0;
            class_q          <= 0;
            seen_q           <= 0;
            seen2_q          <= 0;
            refresh_q        <= 0;
            infinite_h       <= 0;
            infinite_d       <= 0;
            error_o          <= 0;
            offer_q          <= 0;
            return_pending_q <= 0;
            type_q           <= 0;
            header_q         <= 0;
            data_q           <= 0;
            for (i = 0; i < 3; i = i + 1) begin
                limit_h[i] <= 0;
                limit_d[i] <= 0;
                used_h[i]  <= 0;
                used_d[i]  <= 0;
                local_h[i] <= i == 0 ? POSTED_HEADERS : RX_HEADERS;
                local_d[i] <= i == 0 ? POSTED_DATA : RX_DATA;
            end
        end else begin
            error_o <= 0;
            if (phase_q == 2 && tx_enable_i && refresh_q != 0) refresh_q <= refresh_q - 1'b1;
            if (!offer_q && tx_enable_i &&
                (phase_q != 2 || refresh_q == 0 || return_pending_q)) begin
                offer_q <= 1;
                // A return starts a complete P/NP/Cpl refresh round. Keep
                // round-robin order and finish held offers without mutation.
                // Clear at the P snapshot, not acceptance: later returns must
                // survive backpressure and cause a subsequent fresh round.
                if (phase_q == 2 && class_q == 0) begin
                    return_pending_q <= 0;
                    refresh_q        <= 0;
                end
                type_q <= (phase_q == 0 ? 8'h40 : phase_q == 1 ? 8'hc0 : 8'h80) |
                    {2'b0, class_q, 4'b0};
                header_q <= class_q == 2 ? 8'b0 : local_h[class_q];
                data_q <= class_q == 2 ? 12'b0 : local_d[class_q];
            end
            if (dllp_valid_o && dllp_ready_i) begin
                offer_q <= 0;
                if (class_q == 2) begin
                    class_q <= 0;
                    if (phase_q == 0 && (&seen_q)) phase_q <= 1;
                    if (phase_q == 1 && seen2_q) phase_q <= 2;
                    if (phase_q == 2) refresh_q <= T'(UPDATE_CYCLES - 1);
                end else class_q <= class_q + 1'b1;
            end
            if (rx_valid_i && class_valid && (is_init || is_update)) begin
                if (phase_q == 0 && is_init && !seen_q[rx_class] && rx_header_i < 128 &&
                    rx_data_i < 2048) begin
                    limit_h[rx_class]    <= rx_header_i;
                    limit_d[rx_class]    <= rx_data_i;
                    infinite_h[rx_class] <= rx_header_i == 0;
                    infinite_d[rx_class] <= rx_data_i == 0;
                    seen_q[rx_class]     <= 1;
                end
                if (phase_q == 1 && (is_update || rx_type_i[7:6] == 2'b11)) seen2_q <= 1;
                if (phase_q == 2 && is_update && !update_valid) error_o <= 1;
                if (phase_q == 2 && is_update && update_valid) begin
                    // Infinite encoding is negotiated at initialization only.
                    if (!infinite_h[rx_class]) limit_h[rx_class] <= rx_header_i;
                    if (!infinite_d[rx_class]) limit_d[rx_class] <= rx_data_i;
                end
            end
            if (reserve_i) begin
                if (!reserve_ready_o) error_o <= 1;
                else if (!replay_i) begin
                    used_h[reserve_class_i] <= used_h[reserve_class_i] + 1'b1;
                    used_d[reserve_class_i] <= used_d[reserve_class_i] + {3'b0, reserve_data_i};
                end
            end
            if (release_i) begin
                if (release_class_i == 3) error_o <= 1;
                else if (release_class_i != 2) begin
                    local_h[release_class_i] <= local_h[release_class_i] + 1'b1;
                    local_d[release_class_i] <= local_d[release_class_i] + {3'b0, release_data_i};
                    // Last assignment wins over a simultaneous P snapshot, so
                    // that snapshot cannot lose the newly returned credit.
                    if (phase_q == 2) return_pending_q <= 1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial
        if (UPDATE_CYCLES < 3 || UPDATE_CYCLES > 4000 || RX_HEADERS == 0 || RX_HEADERS > 127 ||
            RX_DATA < 8 || RX_DATA > 2047 || POSTED_HEADERS == 0 || POSTED_HEADERS > 127 ||
            POSTED_DATA < 8 || POSTED_DATA > 2047)
            $fatal(1, "Invalid VC0 credit/timer geometry");
`endif
endmodule

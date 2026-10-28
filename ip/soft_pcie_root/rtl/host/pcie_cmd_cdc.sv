// Single-owner command/response bridge. FIFO ownership survives clock pauses.
// A command queued before link loss receives failure instead of being replayed
// when a later link becomes active. Global reset is the only ownership reset.
module pcie_cmd_cdc (
    input wire host_clk, link_clk, arst_n, link_active_i,
    input wire h_valid_i,
    output wire h_ready_o,
    input wire [118:0] h_payload_i,
    output wire h_rsp_valid_o,
    input wire h_rsp_ready_i,
    output wire [34:0] h_response_o,
    output wire l_valid_o,
    input wire l_ready_i,
    output wire [118:0] l_payload_o,
    input wire l_rsp_valid_i,
    output wire l_rsp_ready_o,
    input wire [34:0] l_response_i
);
    (* ASYNC_REG="TRUE", DONT_TOUCH="TRUE" *) reg [2:0] h_release_q, l_release_q;
    always @(posedge host_clk or negedge arst_n)
        if (!arst_n) h_release_q <= 0;
        else h_release_q <= {h_release_q[1:0], 1'b1};
    always @(posedge link_clk or negedge arst_n)
        if (!arst_n) l_release_q <= 0;
        else l_release_q <= {l_release_q[1:0], 1'b1};
    wire request_valid, request_ready, request_space, response_space;
    reg host_busy_q, link_busy_q, quarantine_q, reported_q;
    wire fail_request = l_release_q[2] && request_valid && (!link_active_i || quarantine_q) &&
        !link_busy_q;
    wire fail_active = l_release_q[2] && link_busy_q && !link_active_i && !l_rsp_valid_i &&
        !reported_q;
    wire response_valid = (l_release_q[2] && link_busy_q && l_rsp_valid_i && !reported_q) ||
        fail_request || fail_active;
    wire [34:0] response_data = (fail_request || fail_active) ? {3'd4, 32'b0} : l_response_i;
    assign h_ready_o = h_release_q[2] && request_space && !host_busy_q;
    assign l_valid_o = l_release_q[2] && request_valid && !link_busy_q && link_active_i &&
        !quarantine_q;
    assign request_ready = (l_valid_o && l_ready_i) || (fail_request && response_space);
    assign l_rsp_ready_o = l_release_q[2] && link_busy_q && (reported_q || response_space);
    pcie_cmd_fifo #(
        .WIDTH(119)
    ) requests (
        host_clk,
        link_clk,
        arst_n,
        h_payload_i,
        h_valid_i && !host_busy_q && h_release_q[2],
        request_space,
        l_payload_o,
        request_valid,
        request_ready
    );
    pcie_cmd_fifo #(
        .WIDTH(35)
    ) responses (
        link_clk,
        host_clk,
        arst_n,
        response_data,
        response_valid,
        response_space,
        h_response_o,
        h_rsp_valid_o,
        h_rsp_ready_i
    );
    always @(posedge host_clk) begin
        if (!h_release_q[2]) host_busy_q <= 0;
        else begin
            if (h_valid_i && h_ready_o) host_busy_q <= 1;
            if (h_rsp_valid_o && h_rsp_ready_i) host_busy_q <= 0;
        end
    end
    always @(posedge link_clk) begin
        if (!l_release_q[2]) begin
            link_busy_q  <= 0;
            quarantine_q <= 0;
            reported_q   <= 0;
        end else begin
            if (l_valid_o && l_ready_i) begin
                link_busy_q <= 1;
                reported_q  <= 0;
            end
            if (fail_active && response_space) begin
                reported_q   <= 1;
                quarantine_q <= 1;
            end
            // Retain the accepted link-side ownership until the real response drains.
            // A software PERST may prevent that response forever; global reset recovers.
            if (link_busy_q && l_rsp_valid_i && l_rsp_ready_o) link_busy_q <= 0;
        end
    end
endmodule

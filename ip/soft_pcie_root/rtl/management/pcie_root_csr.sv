// 50 MHz AXI-Lite command mailbox to the 125 MHz experimental root port.
// One command at a time. Payloads stay stable until the round trip completes.
// A timeout quarantines commands until global reset; it never cancels a TLP.
module pcie_root_csr #(
    parameter integer TIMEOUT_CYCLES      = 16777216,
    parameter integer CLOCK_WINDOW_CYCLES = 5000000,
    parameter integer HEARTBEAT_BITS      = 16
) (
    input wire aclk, aresetn,
    input wire [11:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [11:0] s_axi_araddr,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,
    output reg enable_o,
    input wire core_clk_i, core_reset_n_i,
    input wire link_up_i, dl_active_i, error_i,
    input wire [4:0] state_i,
    input wire [15:0] phy_status_i,
    input wire [127:0] completion_debug_i,
    output wire cmd_valid_o,
    input wire cmd_ready_i,
    output wire [2:0] cmd_op_o,
    output wire [63:0] cmd_address_o,
    output wire [15:0] cmd_bdf_o,
    output wire [31:0] cmd_data_o,
    output wire [3:0] cmd_be_o,
    input wire rsp_valid_i,
    output wire rsp_ready_o,
    input wire [31:0] rsp_data_i,
    input wire [2:0] rsp_status_i,
    output reg force_gen1_o,
    input wire [2:0] rate_status_i
);
    localparam integer TW = $clog2(TIMEOUT_CYCLES + 1);
    (* ASYNC_REG="TRUE" *) reg [2:0] rate_meta_q, rate_mid_q, rate_sync_q;
    reg aw_q, w_q;
    reg [11:0] awaddr_q;
    reg [31:0] wdata_q;
    reg [ 3:0] wstrb_q;
    reg [31:0] addrlo_q, addrhi_q, data_q, config_q;
    reg [118:0] request_payload_q;
    reg request_toggle_q, busy_q, done_q, fault_q;
    reg [  31:0] result_q;
    reg [   2:0] result_status_q;
    reg [TW-1:0] timer_q;
    (* ASYNC_REG="TRUE" *)reg [   2:0] reply_sync_q;
    (* ASYNC_REG="TRUE" *) reg [7:0] status_meta_q, status_sync_q;
    reg         reply_toggle_q;
    reg [ 34:0] reply_payload_q;
    reg [  7:0] status_source_q;
    (* ASYNC_REG="TRUE" *)reg [  2:0] request_sync_q;
    reg         request_seen_q;
    reg [118:0] core_payload_q;
    reg [  1:0] core_state_q;
    // Diagnostic-only levels: non-atomic, never used for request admission.
    (* ASYNC_REG="TRUE" *) reg [15:0] phy_meta_q, phy_sync_q;
    (* ASYNC_REG="TRUE" *) reg [127:0] debug_meta_q, debug_sync_q;
    reg [HEARTBEAT_BITS-1:0] heartbeat_q = 0;
    (* ASYNC_REG="TRUE" *)reg [               2:0] heartbeat_sync_q;
    reg                      heartbeat_seen_q;
    localparam integer CW = $clog2(CLOCK_WINDOW_CYCLES + 1);
    reg [CW-1:0] clock_window_q;
    reg [31:0] clock_edges_q, clock_sample_q;
    wire heartbeat_edge = heartbeat_sync_q[2] != heartbeat_seen_q;
    always @(posedge core_clk_i) begin
        if (!core_reset_n_i) heartbeat_q <= 0;
        else heartbeat_q <= heartbeat_q + 1'b1;
    end
    always @(posedge aclk) begin
        if (!aresetn) begin
            debug_meta_q     <= 0;
            debug_sync_q     <= 0;
            rate_meta_q      <= 0;
            rate_mid_q       <= 0;
            rate_sync_q      <= 0;
            phy_meta_q       <= 0;
            phy_sync_q       <= 0;
            heartbeat_sync_q <= 0;
            heartbeat_seen_q <= 0;
            clock_window_q   <= 0;
            clock_edges_q    <= 0;
            clock_sample_q   <= 0;
        end else begin
            rate_meta_q      <= rate_status_i;
            rate_mid_q       <= rate_meta_q;
            rate_sync_q      <= rate_mid_q;
            phy_meta_q       <= phy_status_i;
            phy_sync_q       <= phy_meta_q;
            debug_meta_q     <= completion_debug_i;
            debug_sync_q     <= debug_meta_q;
            heartbeat_sync_q <= {heartbeat_sync_q[1:0], heartbeat_q[HEARTBEAT_BITS-1]};
            heartbeat_seen_q <= heartbeat_sync_q[2];
            if (clock_window_q == CW'(CLOCK_WINDOW_CYCLES - 1)) begin
                clock_sample_q <= clock_edges_q + {31'b0, heartbeat_edge};
                clock_window_q <= 0;
                clock_edges_q  <= 0;
            end else begin
                clock_window_q <= clock_window_q + 1'b1;
                clock_edges_q  <= clock_edges_q + {31'b0, heartbeat_edge};
            end
        end
    end
    assign s_axi_awready                                              = !aw_q && !s_axi_bvalid;
    assign s_axi_wready                                               = !w_q && !s_axi_bvalid;
    assign s_axi_arready                                              = !s_axi_rvalid;
    assign cmd_valid_o                                                = core_state_q == 1;
    assign {cmd_op_o, cmd_address_o, cmd_bdf_o, cmd_data_o, cmd_be_o} = core_payload_q;
    assign rsp_ready_o                                                = core_state_q == 2;
    function automatic [31:0] merged(input [31:0] olddata, input [31:0] newdata,
                                     input [3:0] strobe);
        integer j;
        begin
            merged = olddata;
            for (j = 0; j < 4; j = j + 1) if (strobe[j]) merged[j*8+:8] = newdata[j*8+:8];
        end
    endfunction
    always @(posedge core_clk_i) begin
        if (!core_reset_n_i) begin
            request_sync_q  <= 0;
            request_seen_q  <= 0;
            core_state_q    <= 0;
            reply_toggle_q  <= 0;
            reply_payload_q <= 0;
            core_payload_q  <= 0;
            status_source_q <= 0;
        end else begin
            status_source_q <= {state_i, error_i, dl_active_i, link_up_i};
            request_sync_q  <= {request_sync_q[1:0], request_toggle_q};
            case (core_state_q)
                0:
                if (request_sync_q[2] != request_seen_q) begin
                    core_payload_q <= request_payload_q;
                    request_seen_q <= request_sync_q[2];
                    core_state_q   <= 1;
                end
                1: if (cmd_ready_i) core_state_q <= 2;
                2:
                if (rsp_valid_i) begin
                    reply_payload_q <= {rsp_status_i, rsp_data_i};
                    reply_toggle_q  <= request_seen_q;
                    core_state_q    <= 0;
                end
                default: core_state_q <= 0;
            endcase
        end
    end
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_q              <= 0;
            w_q               <= 0;
            awaddr_q          <= 0;
            wdata_q           <= 0;
            wstrb_q           <= 0;
            s_axi_bvalid      <= 0;
            s_axi_bresp       <= 0;
            s_axi_rvalid      <= 0;
            s_axi_rdata       <= 0;
            s_axi_rresp       <= 0;
            enable_o          <= 0;
            force_gen1_o      <= 0;
            addrlo_q          <= 0;
            addrhi_q          <= 0;
            data_q            <= 0;
            config_q          <= 32'h000000f2;
            request_payload_q <= 0;
            request_toggle_q  <= 0;
            busy_q            <= 0;
            done_q            <= 0;
            fault_q           <= 0;
            result_q          <= 0;
            result_status_q   <= 0;
            timer_q           <= 0;
            reply_sync_q      <= 0;
            status_meta_q     <= 0;
            status_sync_q     <= 0;
        end else begin
            reply_sync_q  <= {reply_sync_q[1:0], reply_toggle_q};
            status_meta_q <= status_source_q;
            status_sync_q <= status_meta_q;
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_awvalid && s_axi_awready) begin
                aw_q     <= 1;
                awaddr_q <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_q     <= 1;
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
            end
            if (busy_q) begin
                timer_q <= timer_q + 1'b1;
                if (reply_sync_q[2] == request_toggle_q) begin
                    {result_status_q, result_q} <= reply_payload_q;
                    busy_q                      <= 0;
                    done_q                      <= 1;
                end else if (timer_q == TW'(TIMEOUT_CYCLES - 1)) begin
                    busy_q          <= 0;
                    done_q          <= 1;
                    fault_q         <= 1;
                    result_status_q <= 3;
                    result_q        <= 32'hffffffff;
                end
            end
            if (aw_q && w_q && !s_axi_bvalid) begin
                aw_q         <= 0;
                w_q          <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp  <= 0;
                if (awaddr_q[1:0] != 0) s_axi_bresp <= 2;
                else
                    case (awaddr_q[11:2])
                        10'h004: begin
                            if (wstrb_q[0]) begin
                                if (busy_q || fault_q || (enable_o && wdata_q[1] != force_gen1_o))
                                    s_axi_bresp <= 2;
                                else begin
                                    enable_o     <= wdata_q[0];
                                    force_gen1_o <= wdata_q[1];
                                end
                            end
                        end
                        10'h008: addrlo_q <= merged(addrlo_q, wdata_q, wstrb_q);
                        10'h009: addrhi_q <= merged(addrhi_q, wdata_q, wstrb_q);
                        10'h00a: data_q <= merged(data_q, wdata_q, wstrb_q);
                        10'h00b: config_q <= merged(config_q, wdata_q, wstrb_q);
                        10'h00c:
                        if (wstrb_q[0] && wdata_q[0]) begin
                            if (busy_q || fault_q || !enable_o) s_axi_bresp <= 2;
                            else if (!status_sync_q[1]) begin
                                // A link can disappear between the driver's status check and submit.
                                // Return a command error through SRP1, never an ARM write abort.
                                done_q          <= 1;
                                fault_q         <= 1;
                                result_status_q <= 4;
                                result_q        <= 32'hffffffff;
                            end else begin
                                request_payload_q <= {
                                    config_q[2:0],
                                    addrhi_q,
                                    addrlo_q,
                                    config_q[31:16],
                                    data_q,
                                    config_q[7:4]
                                };
                                request_toggle_q <= !request_toggle_q;
                                busy_q <= 1;
                                done_q <= 0;
                                timer_q <= 0;
                            end
                        end
                        default: s_axi_bresp <= 2;
                    endcase
            end
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp  <= 0;
                s_axi_rdata  <= 0;
                if (s_axi_araddr[1:0] != 0) s_axi_rresp <= 2;
                else
                    case (s_axi_araddr[11:2])
                        10'h000: s_axi_rdata <= 32'h53525031;  // SRP1
                        10'h001: s_axi_rdata <= 32'h00010000;
                        10'h002:
                        s_axi_rdata <= {
                            24'b0, status_sync_q
                        };  // state is informational, not atomic
                        10'h003: s_axi_rdata <= {16'(HEARTBEAT_BITS), phy_sync_q};
                        10'h004: s_axi_rdata <= {30'b0, force_gen1_o, enable_o};
                        10'h006: s_axi_rdata <= clock_sample_q;
                        10'h007: s_axi_rdata <= 32'(CLOCK_WINDOW_CYCLES);
                        10'h008: s_axi_rdata <= addrlo_q;
                        10'h009: s_axi_rdata <= addrhi_q;
                        10'h00a: s_axi_rdata <= data_q;
                        10'h00b: s_axi_rdata <= config_q;
                        10'h00d:
                        s_axi_rdata <= {21'b0, result_status_q, 5'b0, fault_q, done_q, busy_q};
                        10'h00e: s_axi_rdata <= result_q;
                        10'h010: s_axi_rdata <= debug_sync_q[127:96];
                        10'h011: s_axi_rdata <= debug_sync_q[95:64];
                        10'h012: s_axi_rdata <= debug_sync_q[63:32];
                        10'h013: s_axi_rdata <= debug_sync_q[31:0];
                        10'h014:
                        s_axi_rdata <= {28'b0, 1'b1, rate_sync_q};  // capable, fallback, busy, Gen2
                        default: s_axi_rresp <= 2;
                    endcase
            end
        end
    end
endmodule

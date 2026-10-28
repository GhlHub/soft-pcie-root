// Original restricted-profile PCIe completer. All signals use clk (125 MHz).
// Incoming TLPs are already link/LCRC/sequence validated. Wire header bytes
// are reversed relative to a conventional DWORD; payload is little-endian.
// Four whole requests may wait behind preparation and independent write execution.
// Configurable same-ID AXI read window; 64-bit AXI beats carry two DWORDs.
// Reads/MSI fence all prior B responses. No accepted ownership is cancelled.
module pcie_ddr_bridge #(
    parameter integer RX_DWORDS       = 1,
                      TX_DWORDS       = 1,
                      READ_SLOTS      = 2,
    parameter integer PIPELINED_READS = 0
) (
    input wire clk, rst_n, link_active_i, dma_enable_i,
    input wire [32*RX_DWORDS-1:0] rx_data_i,
    input wire rx_valid_i, rx_last_i,
    output wire rx_ready_o,
    // In two-DWORD mode only: final beat contains just its low DWORD.
    input wire rx_last_single_i,
    output reg [32*TX_DWORDS-1:0] tx_data_o,
    output wire tx_valid_o, tx_last_o,
    input wire tx_ready_i,
    output wire [8:0] tx_credits_o,
    output wire tx_last_single_o,
    output reg msi_valid_o,
    output reg [4:0] msi_vector_o,
    output reg fault_o,
    output wire idle_o,
    output wire [31:0] perf_events_o,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output reg [63:0] m_axi_wdata,
    output reg [7:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [63:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready
);
    initial if (RX_DWORDS != 1 && RX_DWORDS != 2) $error("RX_DWORDS must be 1 or 2");
    initial begin
        if (TX_DWORDS != 1 && TX_DWORDS != 2) $error("TX_DWORDS must be 1 or 2");
        if (READ_SLOTS < 2 || READ_SLOTS > 16 || (READ_SLOTS & (READ_SLOTS - 1)) != 0)
            $error("READ_SLOTS must be 2, 4, 8 or 16");
    end
    localparam integer SLOT_BITS = $clog2(READ_SLOTS);
    localparam integer PENDING_BEATS = 36 / RX_DWORDS;
    localparam [3:0] RX = 0, CHECK = 1, DRAIN = 4, RA = 5, PREP = 7, TX = 8;
    localparam [1:0] W_IDLE = 0, W_ADDR = 1, W_DATA = 2;
    reg [ 3:0] state_q;
    // No reset on packet storage. State/counts alone establish validity.
    reg [31:0] packet_q[0:3];
    // One write port per parity bank permits RAM inference even when an
    // offset-four AXI response swaps the incoming low/high DWORD lanes.
    (* ram_style="distributed" *) reg [31:0]
        read_low_q[0:8*READ_SLOTS-1], read_high_q[0:8*READ_SLOTS-1];
    reg [31:0] first_payload_q;
    reg [5:0] count_q, write_index_q, tx_index_q;
    reg overflow_q, lost_q;
    // Preparation and writer own different banks. Payload is stored in its
    // final AXI lane; a 32-DWORD write at offset four needs 17 beat positions.
    // Pad each bank to 32 positions for simple addressing. RAM stays unreset.
    (* ram_style="distributed" *) reg [31:0] payload_low_q[0:63], payload_high_q[0:63];
    reg prepare_bank_q, write_bank_q;
    reg [63:0] write_payload_q;
    reg write_valid_q, write_last_q;
    reg [ 1:0] write_state_q;
    reg [31:2] write_address_q;
    reg [ 5:0] write_length_q;
    reg [3:0] write_first_be_q, write_last_be_q;
    wire        write_busy = write_state_q != W_IDLE;
    reg  [31:0] address_q;
    reg  [10:0] remaining_q;
    reg  [ 4:0] chunk_q;
    reg  [12:0] byte_count_q;
    reg  [15:0] requester_q;
    reg  [ 7:0] tag_q;
    reg [3:0] first_be_q, last_be_q;
    reg [2:0] status_q;
    reg [6:0] lower_q;
    // Configurable completion slots, each one RCB64 burst. Address issuance, R capture
    // and completion transmission have independent ownership. Same AXI ID keeps
    // responses ordered. A held AR offer is drained even after link loss/error.
    reg [1:0] write_out_q;
    reg [SLOT_BITS:0] read_slots_q, read_pending_q;
    reg read_run_q, read_abort_q, ar_offer_q;
    reg [SLOT_BITS-1:0] read_issue_q, read_response_q, read_tx_q;
    reg [31:0] issue_address_q;
    reg [10:0] issue_remaining_q;
    reg [ 4:0] slot_chunk_q      [0:READ_SLOTS-1];
    reg        slot_offset_q     [0:READ_SLOTS-1];
    reg [READ_SLOTS-1:0] slot_done_q, slot_bad_q;
    // Per-completion metadata survives admission of the following request.
    // These arrays, like packet RAM, are deliberately not reset.
    reg [15:0] slot_requester_q [0:READ_SLOTS-1];
    reg [ 7:0] slot_tag_q       [0:READ_SLOTS-1];
    reg [12:0] slot_bytes_q     [0:READ_SLOTS-1];
    reg [ 6:0] slot_lower_q     [0:READ_SLOTS-1];
    reg [12:0] issue_bytes_q;
    reg [ 3:0] issue_first_be_q;
    reg completion_active_q, completion_drain_q;
    reg [5:0] completion_index_q;
    wire normal_tx = PIPELINED_READS != 0 && completion_active_q;
    wire pipeline_drain = PIPELINED_READS != 0 && (completion_drain_q || !link_active_i);
    wire [5:0] send_index = normal_tx ? completion_index_q : tx_index_q;
    wire [4:0] send_chunk = normal_tx ? slot_chunk_q[read_tx_q] : chunk_q;
    wire [2:0] send_status = normal_tx ? (slot_bad_q[read_tx_q] ? 3'd4 : 3'd0) : status_q;
    wire [12:0] send_bytes = normal_tx ? (slot_bad_q[read_tx_q] ? 13'd0 : slot_bytes_q[read_tx_q]) :
        byte_count_q;
    wire [6:0]
        send_lower = normal_tx ? (slot_bad_q[read_tx_q] ? 7'd0 : slot_lower_q[read_tx_q]) : lower_q;
    wire [15:0] send_requester = normal_tx ? slot_requester_q[read_tx_q] : requester_q;
    wire [7:0] send_tag = normal_tx ? slot_tag_q[read_tx_q] : tag_q;
    wire [5:0] send_words = send_status != 0 ? 6'd3 : 6'd3 + {1'b0, send_chunk};
    reg [4:0] read_index_q;
    wire [4:0] issue_chunk = issue_remaining_q < (11'd16 - {7'b0, issue_address_q[5:2]}) ?
        issue_remaining_q[4:0] : (5'd16 - {1'b0, issue_address_q[5:2]});
    wire [4:0] issue_beats = (issue_chunk + {4'b0, issue_address_q[2]} + 5'd1) >> 1;
    wire [4:0] response_beats = (slot_chunk_q[read_response_q] +
                                 {4'b0, slot_offset_q[read_response_q]} + 5'd1) >> 1;
    wire aw_accept = m_axi_awvalid && m_axi_awready;
    wire b_accept = m_axi_bvalid && m_axi_bready;
    wire ar_accept = m_axi_arvalid && m_axi_arready;
    wire r_accept = m_axi_rvalid && m_axi_rready;
    wire r_end = r_accept && m_axi_rlast;
    wire r_error = r_accept &&
        (m_axi_rresp != 0 || m_axi_rlast != (read_index_q == response_beats - 1'b1));
    wire read_pop = read_run_q && ((tx_valid_o && tx_ready_i && tx_last_o &&
                                    (PIPELINED_READS != 0 ? normal_tx : state_q == TX)) ||
                                   ((PIPELINED_READS != 0 ? pipeline_drain : state_q == DRAIN) &&
                                    read_slots_q != 0 && slot_done_q[read_tx_q]));
    wire read_finish =
        (PIPELINED_READS != 0 ? (state_q != PREP && (issue_remaining_q == 0 || read_abort_q)) :
         state_q == DRAIN) && read_slots_q == 0 && read_pending_q == 0 && !ar_offer_q;

    function automatic [31:0] payload_word(input [3:0] index);
        payload_word = index[0] ? read_high_q[{read_tx_q, index[3:1]}] :
            read_low_q[{read_tx_q, index[3:1]}];
    endfunction
    function automatic [31:0] swap(input [31:0] v);
        swap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction
    function automatic [1:0] last(input [3:0] v);
        last = v[3] ? 3 : v[2] ? 2 : v[1] ? 1 : v[0] ? 0 : 0;
    endfunction
    function automatic [1:0] first(input [3:0] v);
        first = v[0] ? 0 : v[1] ? 1 : v[2] ? 2 : v[3] ? 3 : 0;
    endfunction
    wire [31:0] h0 = swap(packet_q[0]), h1 = swap(packet_q[1]);
    wire four = h0[29], write_req = h0[30], memory_req = h0[28:24] == 0;
    wire [10:0] length_dw = h0[9:0] == 0 ? 11'd1024 : {1'b0, h0[9:0]};
    wire [63:0] addr = four ? {swap(packet_q[2]), swap(packet_q[3])} : {32'b0, swap(packet_q[2])};
    wire [3:0] fbe = h1[3:0], lbe = h1[7:4];
    wire [2:0] single_span = fbe[3] ? 3'd4 - {1'b0, first(
        fbe
    )} : fbe[2] ? 3'd3 - {1'b0, first(
        fbe
    )} : fbe[1] ? 3'd2 - {1'b0, first(
        fbe
    )} : 3'd1;
    wire [12:0] bytes_req = length_dw == 1 ?
        {10'b0, single_span} : ({2'b0, length_dw} << 2) - {11'b0, first(
        fbe
    )} - (13'd3 - {11'b0, last(
        lbe
    )});
    wire be_bad = length_dw == 1 ?
        lbe != 0 : (fbe == 0 || lbe == 0 || (!(length_dw == 2 && addr[2] == 0) &&
                                             !((fbe == 8 || fbe == 12 || fbe == 14 || fbe == 15) &&
                                               (lbe == 1 || lbe == 3 || lbe == 7 || lbe == 15))));
    wire unused_header = ^{h0[23], h0[19], h0[17:16], send_bytes[12]};
    wire semantic_bad = h0[31] || h0[22:20] != 0 || h0[18] || h0[15:12] != 0 || h0[11:10] != 0 ||
        addr[1:0] != 0 || be_bad;
    wire [12:0] end_page = {1'b0, addr[11:0]} + ({2'b0, length_dw} << 2);
    wire ddr_range = addr[63:31] == 0 &&
        ({1'b0, addr[30:0]} + ({21'b0, length_dw} << 2)) <= 32'h80000000;
    wire [5:0] header_dw = four ? 6'd4 : 6'd3;
    wire shape_bad = overflow_q ||
        (write_req ? ({5'b0, count_q} != ({5'b0, header_dw} + length_dw)) : count_q != header_dw);
    wire msi_address = addr == 64'hfee00000;
    wire [31:0] msi_data = first_payload_q;
    wire pipeline_read = memory_req && !write_req && !semantic_bad && !shape_bad && end_page <=
        4096 && ddr_range && dma_enable_i && !fault_o && !r_error && !(length_dw == 1 && fbe == 0);
    wire check_ready = !link_active_i ||
        ((PIPELINED_READS == 0 || !read_run_q || pipeline_read) && !write_busy &&
         (write_out_q == 0 || (memory_req && write_req && !msi_address && write_out_q < 2)));
    wire write_launch = state_q == CHECK && check_ready && link_active_i && !semantic_bad &&
        !shape_bad && end_page <= 4096 && memory_req && write_req && !msi_address && ddr_range &&
        dma_enable_i && !fault_o && !(b_accept && m_axi_bresp != 0) && length_dw <= 32;
    wire [12:0] chunk_bytes = ({8'b0, chunk_q} << 2) - {11'b0, first(
        first_be_q
    )} - (remaining_q == {6'b0, chunk_q} && remaining_q != 1 ? (13'd3 - {11'b0, last(
        last_be_q
    )}) : 13'd0);
    // Four bounded whole-packet slots. Oversize packets are drained and replayed
    // to the validator as 37/38 DWORDs, which cannot pass its length check.
    // Storage is deliberately unreset; pointers/lengths establish validity.
    reg [32*RX_DWORDS-1:0] pending_data_q[0:4*PENDING_BEATS-1];
    reg [5:0] pending_length_q[0:3];
    reg [1:0] pending_wr_q, pending_rd_q;
    reg [2:0] pending_count_q;
    reg [5:0] pending_fill_q, pending_send_q;
    wire pending_push = rx_valid_i && rx_ready_o && rx_last_i;
    wire engine_valid = pending_count_q != 0 && link_active_i;
    wire engine_ready = state_q == RX && link_active_i;
    wire [5:0] input_words = RX_DWORDS == 2 ? (rx_last_i && rx_last_single_i ? 6'd1 : 6'd2) : 6'd1;
    wire [5:0] engine_words = (pending_length_q[pending_rd_q] - pending_send_q) < 6'(RX_DWORDS) ?
        pending_length_q[pending_rd_q] - pending_send_q : 6'(RX_DWORDS);
    wire engine_last = pending_send_q + engine_words == pending_length_q[pending_rd_q];
    wire pending_pop = engine_valid && engine_ready && engine_last;
    wire [32*RX_DWORDS-1:0] engine_data = pending_send_q < 36 ?
        pending_data_q[int'(pending_rd_q)*PENDING_BEATS+int'(pending_send_q)/RX_DWORDS] : '0;
    // Passive host-clock profiling. Events overlap; see the DBR1 contract.
    // No event or counter feeds transaction admission, ordering or reset.
    assign perf_events_o[0] = 1'b1;
    assign perf_events_o[1] = read_run_q;
    assign perf_events_o[2] = (PIPELINED_READS != 0 ? read_run_q && !completion_active_q :
                               state_q == RA) && !slot_done_q[read_tx_q];
    assign perf_events_o[3] = (PIPELINED_READS != 0 ? read_run_q && !completion_active_q :
                               state_q == RA) && slot_done_q[read_tx_q];
    assign perf_events_o[4] = tx_valid_o && !tx_ready_i;
    assign perf_events_o[5] = tx_valid_o && tx_ready_i;
    assign perf_events_o[6] = tx_valid_o && tx_ready_i && send_index + 6'(TX_DWORDS) > 3 &&
        send_status == 0;
    assign perf_events_o[7] = tx_valid_o && tx_ready_i && tx_last_o;
    assign perf_events_o[8] = ar_accept;
    assign perf_events_o[9] = m_axi_arvalid && !m_axi_arready;
    assign perf_events_o[10] = r_accept;
    assign perf_events_o[11] = r_end;
    assign perf_events_o[12] = m_axi_rready && !m_axi_rvalid;
    assign perf_events_o[13] = m_axi_rready && !m_axi_rvalid && read_index_q == 0;
    assign perf_events_o[14] = read_pending_q == 1;
    assign perf_events_o[15] = read_pending_q == 2;
    assign perf_events_o[16] = read_slots_q == (SLOT_BITS + 1)'(READ_SLOTS);
    assign perf_events_o[17] = read_run_q && issue_remaining_q != 0 &&
        read_slots_q == (SLOT_BITS + 1)'(READ_SLOTS);
    assign perf_events_o[18] = state_q == RX && !engine_valid;
    assign perf_events_o[19] = state_q == RX && engine_valid;
    assign perf_events_o[20] = state_q == CHECK && !check_ready;
    assign perf_events_o[21] = state_q == PREP;
    assign perf_events_o[22] = state_q == DRAIN;
    assign perf_events_o[23] = r_accept && read_index_q == 0;
    assign perf_events_o[24] = pending_count_q != 0 && state_q != RX;
    assign perf_events_o[25] = rx_valid_i && !rx_ready_o;
    assign perf_events_o[26] = write_busy;
    assign perf_events_o[27] = write_out_q != 0;
    assign perf_events_o[28] = fault_o;
    assign perf_events_o[29] = link_active_i;
    assign perf_events_o[30] = state_q == CHECK;
    assign perf_events_o[31] = msi_valid_o;
    assign idle_o = state_q == RX && count_q == 0 && pending_count_q == 0 && pending_fill_q == 0 &&
        write_out_q == 0 && !write_busy && !read_run_q && !ar_offer_q;
    assign rx_ready_o = pending_count_q < 4 && link_active_i;
    always @(posedge clk) begin
        if (rx_valid_i && rx_ready_o && pending_fill_q < 36)
            pending_data_q[int'(pending_wr_q)*PENDING_BEATS+int'(pending_fill_q)/RX_DWORDS] <=
                rx_data_i;
        if (!rst_n || !link_active_i) begin
            pending_wr_q    <= 0;
            pending_rd_q    <= 0;
            pending_count_q <= 0;
            pending_fill_q  <= 0;
            pending_send_q  <= 0;
        end else begin
            case ({
                pending_push, pending_pop
            })
                2'b10: pending_count_q <= pending_count_q + 1'b1;
                2'b01: pending_count_q <= pending_count_q - 1'b1;
                default: begin
                end
            endcase
            if (rx_valid_i && rx_ready_o) begin
                if (rx_last_i) begin
                    pending_length_q[pending_wr_q] <= pending_fill_q + input_words;
                    pending_wr_q                   <= pending_wr_q + 1'b1;
                    pending_fill_q                 <= 0;
                end else if (pending_fill_q < 36) pending_fill_q <= pending_fill_q + input_words;
            end
            if (engine_valid && engine_ready) begin
                if (engine_last) begin
                    pending_rd_q   <= pending_rd_q + 1'b1;
                    pending_send_q <= 0;
                end else pending_send_q <= pending_send_q + engine_words;
            end
        end
    end
    assign tx_valid_o       = (state_q == TX || normal_tx) && link_active_i && !lost_q;
    assign tx_last_o        = send_index + 6'(TX_DWORDS) >= send_words;
    assign tx_last_single_o = TX_DWORDS == 2 && send_index + 1'b1 == send_words;
    assign tx_credits_o     = send_status != 0 ? 0 : ({4'b0, send_chunk} + 3) >> 2;
    integer tx_lane, tx_word;
    always @* begin
        tx_data_o = 0;
        tx_word   = 0;
        for (tx_lane = 0; tx_lane < TX_DWORDS; tx_lane = tx_lane + 1) begin
            tx_word = int'(send_index) + tx_lane;
            if (tx_word < int'(send_words))
                case (tx_word)
                    0:
                    tx_data_o[tx_lane*32+:32] = swap(
                        send_status != 0 ? 32'h0a000000 : (32'h4a000000 | {27'b0, send_chunk}));
                    1:
                    tx_data_o[tx_lane*32+:32] = swap({16'b0, send_status, 1'b0, send_bytes[11:0]});
                    2:
                    tx_data_o[tx_lane*32+:32] = swap({send_requester, send_tag, 1'b0, send_lower});
                    default:
                    tx_data_o[tx_lane*32+:32] = !normal_tx && remaining_q == 1 && first_be_q == 0 ?
                        32'b0 : payload_word(4'(tx_word - 3));
                endcase
        end
    end
    // Completion transmission is independent of request parsing/AR issuance in
    // pipelined mode. A slot remains owned until its entire TLP is handed off.
    always @(posedge clk) begin
        if (!rst_n) begin
            completion_active_q <= 0;
            completion_index_q  <= 0;
            completion_drain_q  <= 0;
        end else if (PIPELINED_READS != 0) begin
            if (!link_active_i) begin
                completion_active_q <= 0;
                // Initial link training owns no reads. Only a loss with live read
                // ownership latches fatal drain; otherwise the first boot would silently
                // discard every completion after the link becomes active.
                if (read_run_q || completion_active_q) completion_drain_q <= 1;
            end else if (normal_tx && tx_valid_o && tx_ready_i) begin
                if (tx_last_o) begin
                    completion_active_q <= 0;
                    completion_index_q  <= 0;
                    if (send_status != 0) completion_drain_q <= 1;
                end else completion_index_q <= completion_index_q + 6'(TX_DWORDS);
            end else if (!completion_active_q && !completion_drain_q && read_slots_q != 0 &&
                         slot_done_q[read_tx_q]) begin
                completion_active_q <= 1;
                completion_index_q  <= 0;
            end
        end
    end
    // Align DDR bursts to eight bytes, masking unused write lanes. Validation
    // precedes rounding, so aligned reads stay inside DDR and the same 4KiB page.
    wire [6:0] write_beats = ({1'b0, write_length_q} + {6'b0, write_address_q[2]} + 7'd1) >> 1;
    // One elastic synchronous-read stage sustains one beat per cycle and
    // holds all W-channel signals while stalled. Fetch starts during AW offer.
    wire write_take = m_axi_wvalid && m_axi_wready;
    wire write_fetch = write_busy && (!write_valid_q || write_take) &&
        {1'b0, write_index_q} < write_beats;
    reg [7:0] fetch_strobe;
    integer lane, dword_index;
    always @* begin
        fetch_strobe = 0;
        dword_index  = 0;
        for (lane = 0; lane < 2; lane = lane + 1) begin
            dword_index = 2 * int'(write_index_q) + lane - int'(write_address_q[2]);
            if (dword_index >= 0 && dword_index < int'(write_length_q) && dword_index < 32)
                fetch_strobe[lane*4+:4] = dword_index == 0 ? write_first_be_q :
                    dword_index == int'(write_length_q) - 1 ? write_last_be_q : 4'hf;
        end
        // Unwritten edge lanes may contain stale data; never expose those bytes.
        for (integer byte_lane = 0; byte_lane < 8; byte_lane = byte_lane + 1)
        m_axi_wdata[byte_lane*8+:8] = m_axi_wstrb[byte_lane] ? write_payload_q[byte_lane*8+:8] :
            8'b0;
    end
    always @(posedge clk)
        if (write_fetch) begin
            write_payload_q <= {
                payload_high_q[{write_bank_q, write_index_q[4:0]}],
                payload_low_q[{write_bank_q, write_index_q[4:0]}]
            };
            m_axi_wstrb <= fetch_strobe;
            write_last_q <= {1'b0, write_index_q} == write_beats - 1'b1;
        end
    assign m_axi_awaddr  = {write_address_q[31:3], 3'b0};
    assign m_axi_awlen   = {1'b0, write_beats} - 1'b1;
    assign m_axi_awsize  = 3;
    assign m_axi_awburst = 1;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 0;
    assign m_axi_awvalid = write_state_q == W_ADDR;
    assign m_axi_wlast   = write_last_q;
    assign m_axi_wvalid  = write_state_q == W_DATA && write_valid_q;
    assign m_axi_bready  = write_out_q != 0;
    assign m_axi_araddr  = {issue_address_q[31:3], 3'b0};
    assign m_axi_arlen   = {3'b0, issue_beats} - 1'b1;
    assign m_axi_arsize  = 3;
    assign m_axi_arburst = 1;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 0;
    assign m_axi_arvalid = ar_offer_q;
    assign m_axi_rready  = read_pending_q != 0;
    wire [5:0] read_base = {read_index_q, 1'b0} - {5'b0, slot_offset_q[read_response_q]};
    reg read_low_store, read_high_store;
    reg [SLOT_BITS+2:0] read_low_address, read_high_address;
    reg [31:0] read_low_data, read_high_data;
    reg [5:0] read_position;
    always @* begin
        read_low_store    = 0;
        read_high_store   = 0;
        read_low_address  = 0;
        read_high_address = 0;
        read_low_data     = 0;
        read_high_data    = 0;
        read_position     = 0;
        for (integer read_lane = 0; read_lane < 2; read_lane = read_lane + 1) begin
            read_position = read_base + 6'(read_lane);
            if (r_accept && (read_index_q != 0 || !slot_offset_q[read_response_q] || read_lane !=
                             0) && read_position < {1'b0, slot_chunk_q[read_response_q]}) begin
                if (read_position[0]) begin
                    read_high_store   = 1;
                    read_high_address = {read_response_q, read_position[3:1]};
                    read_high_data    = m_axi_rdata[read_lane*32+:32];
                end else begin
                    read_low_store   = 1;
                    read_low_address = {read_response_q, read_position[3:1]};
                    read_low_data    = m_axi_rdata[read_lane*32+:32];
                end
            end
        end
    end
    always @(posedge clk) begin
        if (read_low_store) read_low_q[read_low_address] <= read_low_data;
        if (read_high_store) read_high_q[read_high_address] <= read_high_data;
    end
    always @(posedge clk) begin
        for (integer word_lane = 0; word_lane < RX_DWORDS; word_lane = word_lane + 1) begin
            if (engine_valid && engine_ready && 6'(word_lane) < engine_words) begin
                if (int'(count_q) + word_lane < 4)
                    packet_q[int'(count_q)+word_lane] <= engine_data[word_lane*32+:32];
                if (int'(count_q) + word_lane == int'(header_dw))
                    first_payload_q <= engine_data[word_lane*32+:32];
            end
        end
        if (!rst_n) begin
            state_q      <= RX;
            count_q      <= 0;
            overflow_q   <= 0;
            tx_index_q   <= 0;
            address_q    <= 0;
            remaining_q  <= 0;
            chunk_q      <= 0;
            byte_count_q <= 0;
            requester_q  <= 0;
            tag_q        <= 0;
            first_be_q   <= 0;
            last_be_q    <= 0;
            status_q     <= 0;
            lower_q      <= 0;
            lost_q       <= 0;
            msi_valid_o  <= 0;
            msi_vector_o <= 0;
            fault_o      <= 0;
        end else begin
            msi_valid_o <= 0;
            // A link loss never withdraws an accepted AXI request. Finish that request,
            // then discard its completion and latch a fatal recovery requirement.
            if (!link_active_i && (state_q != RX || pending_count_q != 0 || pending_fill_q != 0 ||
                                   write_out_q != 0 || write_busy || read_run_q)) begin
                lost_q  <= 1;
                fault_o <= 1;
            end
            if ((b_accept && m_axi_bresp != 0) || r_error) fault_o <= 1;
            case (state_q)
                RX:
                if (!link_active_i) begin
                    if (count_q != 0) fault_o <= 1;
                    count_q    <= 0;
                    overflow_q <= 0;
                end else if (engine_valid && engine_ready) begin
                    if (count_q < 36) count_q <= count_q + engine_words;
                    else overflow_q <= 1;
                    if (engine_last) state_q <= CHECK;
                end
                CHECK:
                if (check_ready) begin
                    requester_q  <= h1[31:16];
                    tag_q        <= h1[15:8];
                    address_q    <= addr[31:0];
                    remaining_q  <= length_dw;
                    first_be_q   <= fbe;
                    last_be_q    <= lbe;
                    lower_q      <= addr[6:0] + {5'b0, first(fbe)};
                    byte_count_q <= bytes_req == 0 ? 13'd4 : bytes_req;
                    status_q     <= 0;
                    lost_q       <= !link_active_i;
                    // Unsupported requests get UR; malformed/poisoned requests are dropped.
                    if (!link_active_i || semantic_bad || shape_bad || end_page > 4096) begin
                        fault_o    <= 1;
                        state_q    <= RX;
                        count_q    <= 0;
                        overflow_q <= 0;
                    end else if (memory_req && write_req && msi_address && length_dw == 1 &&
                                 fbe == 15 && msi_data < 32) begin
                        if (!fault_o) begin
                            msi_valid_o  <= 1;
                            msi_vector_o <= msi_data[4:0];
                        end
                        state_q <= RX;
                        count_q <= 0;
                    end else if (memory_req && ddr_range && dma_enable_i && !fault_o &&
                                 !(b_accept && m_axi_bresp != 0) &&
                                 (!write_req || length_dw <= 32)) begin
                        if (!write_req && length_dw == 1 && fbe == 0) begin
                            chunk_q    <= 1;
                            tx_index_q <= 0;
                            lower_q    <= addr[6:0];
                            state_q    <= TX;
                        end else if (write_req) begin
                            // Ownership transfers to the independent writer on write_launch.
                            state_q <= RX;
                            count_q <= 0;
                        end else state_q <= PREP;
                    end else begin
                        fault_o <= 1;
                        if (!write_req) begin
                            status_q     <= 1;
                            byte_count_q <= 0;
                            lower_q      <= 0;
                            tx_index_q   <= 0;
                            state_q      <= TX;
                        end else begin
                            state_q <= RX;
                            count_q <= 0;
                        end
                    end
                end
                PREP:    state_q <= RA;
                RA: begin
                    if (PIPELINED_READS != 0) begin
                        if (issue_remaining_q == 0 || read_abort_q) begin
                            state_q <= RX;
                            count_q <= 0;
                        end
                    end else if (lost_q || !link_active_i) state_q <= DRAIN;
                    else if (slot_done_q[read_tx_q]) begin
                        chunk_q    <= slot_chunk_q[read_tx_q];
                        tx_index_q <= 0;
                        state_q    <= TX;
                        if (slot_bad_q[read_tx_q]) begin
                            status_q     <= 4;
                            byte_count_q <= 0;
                            lower_q      <= 0;
                        end
                    end
                end
                DRAIN:
                if (read_finish) begin
                    state_q <= RX;
                    count_q <= 0;
                end
                TX: begin
                    if (lost_q || !link_active_i) begin
                        state_q <= read_run_q ? DRAIN : RX;
                        count_q <= 0;
                    end else if (tx_ready_i) begin
                        if (tx_last_o) begin
                            if (status_q == 0 && remaining_q > {6'b0, chunk_q}) begin
                                remaining_q  <= remaining_q - {6'b0, chunk_q};
                                address_q    <= address_q + ({27'b0, chunk_q} << 2);
                                byte_count_q <= byte_count_q - chunk_bytes;
                                lower_q      <= (address_q[6:0] + ({2'b0, chunk_q} << 2));
                                first_be_q   <= 15;
                                state_q      <= RA;
                            end else begin
                                state_q <= read_run_q ? DRAIN : RX;
                                count_q <= 0;
                            end
                        end else tx_index_q <= tx_index_q + 6'(TX_DWORDS);
                    end
                end
                default: state_q <= RX;
            endcase
        end
    end
    // Whole-packet validation precedes this transfer. RAM has no reset.
    // Once offered, AW and W must drain even if link, admission or fault changes.
    // A 3-DWORD header can put the first payload in the upper input lane.
    // Select at most one write per RAM lane, including address offset four.
    // For a 3-DW header, the address and first payload arrive in the same beat.
    wire       payload_offset = count_q == 2 && !four ? engine_data[26] : addr[2];
    reg  [5:0] payload_position;
    reg payload_low_store, payload_high_store;
    reg [5:0] payload_low_address, payload_high_address;
    reg [31:0] payload_low_data, payload_high_data;
    always @* begin
        payload_position     = 0;
        payload_low_store    = 0;
        payload_high_store   = 0;
        payload_low_address  = 0;
        payload_high_address = 0;
        payload_low_data     = 0;
        payload_high_data    = 0;
        for (integer word_lane = 0; word_lane < RX_DWORDS; word_lane = word_lane + 1) begin
            payload_position = count_q + 6'(word_lane) - header_dw + {5'b0, payload_offset};
            if (rst_n && engine_valid && engine_ready && 6'(word_lane) < engine_words &&
                int'(count_q) + word_lane >= int'(header_dw) && int'(count_q) + word_lane < 36 &&
                int'(count_q) + word_lane - int'(header_dw) < 32) begin
                if (payload_position[0]) begin
                    payload_high_store   = 1;
                    payload_high_address = {prepare_bank_q, payload_position[5:1]};
                    payload_high_data    = engine_data[word_lane*32+:32];
                end else begin
                    payload_low_store   = 1;
                    payload_low_address = {prepare_bank_q, payload_position[5:1]};
                    payload_low_data    = engine_data[word_lane*32+:32];
                end
            end
        end
    end
    always @(posedge clk) begin
        if (payload_low_store) payload_low_q[payload_low_address] <= payload_low_data;
        if (payload_high_store) payload_high_q[payload_high_address] <= payload_high_data;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            write_state_q    <= W_IDLE;
            write_index_q    <= 0;
            write_address_q  <= 0;
            write_length_q   <= 0;
            write_first_be_q <= 0;
            write_last_be_q  <= 0;
            prepare_bank_q   <= 0;
            write_bank_q     <= 0;
            write_valid_q    <= 0;
        end else begin
            if (write_take) write_valid_q <= 0;
            if (write_fetch) begin
                write_valid_q <= 1;
                write_index_q <= write_index_q + 1'b1;
            end
            case (write_state_q)
                W_IDLE:
                if (write_launch) begin
                    write_state_q    <= W_ADDR;
                    write_index_q    <= 0;
                    write_address_q  <= addr[31:2];
                    write_length_q   <= length_dw[5:0];
                    write_first_be_q <= fbe;
                    write_last_be_q  <= lbe;
                    write_bank_q     <= prepare_bank_q;
                    prepare_bank_q   <= !prepare_bank_q;
                    write_valid_q    <= 0;
                end
                W_ADDR:  if (m_axi_awready) write_state_q <= W_DATA;
                W_DATA:  if (write_take && m_axi_wlast) write_state_q <= W_IDLE;
                default: write_state_q <= W_IDLE;
            endcase
        end
    end
    // AXI ownership is reset only by the system/global reset, never link/PERST.
    always @(posedge clk) begin
        if (!rst_n) begin
            write_out_q       <= 0;
            read_slots_q      <= 0;
            read_pending_q    <= 0;
            read_run_q        <= 0;
            read_abort_q      <= 0;
            ar_offer_q        <= 0;
            read_issue_q      <= 0;
            read_response_q   <= 0;
            read_tx_q         <= 0;
            issue_address_q   <= 0;
            issue_remaining_q <= 0;
            read_index_q      <= 0;
            issue_bytes_q     <= 0;
            issue_first_be_q  <= 0;
            slot_done_q       <= 0;
            slot_bad_q        <= 0;
        end else begin
            case ({
                aw_accept, b_accept
            })
                2'b10: write_out_q <= write_out_q + 1'b1;
                2'b01: write_out_q <= write_out_q - 1'b1;
                default: begin
                end
            endcase
            case ({
                ar_accept, read_pop
            })
                2'b10: read_slots_q <= read_slots_q + 1'b1;
                2'b01: read_slots_q <= read_slots_q - 1'b1;
                default: begin
                end
            endcase
            case ({
                ar_accept, r_end
            })
                2'b10: read_pending_q <= read_pending_q + 1'b1;
                2'b01: read_pending_q <= read_pending_q - 1'b1;
                default: begin
                end
            endcase
            if (state_q == PREP) begin
                issue_bytes_q     <= byte_count_q;
                issue_first_be_q  <= first_be_q;
                read_run_q        <= 1;
                read_abort_q      <= 0;
                issue_address_q   <= address_q;
                issue_remaining_q <= remaining_q;
            end
            if (read_finish && state_q != PREP) read_run_q <= 0;
            if (read_run_q && (!link_active_i || r_error)) read_abort_q <= 1;
            if (!ar_offer_q && read_run_q && !read_abort_q && !r_error && link_active_i && state_q
                != DRAIN && issue_remaining_q != 0 && read_slots_q < (SLOT_BITS + 1)'(READ_SLOTS))
                ar_offer_q <= 1;
            if (ar_accept) begin
                ar_offer_q <= 0;
                slot_chunk_q[read_issue_q] <= issue_chunk;
                slot_offset_q[read_issue_q] <= issue_address_q[2];
                slot_done_q[read_issue_q] <= 0;
                slot_bad_q[read_issue_q] <= 0;
                read_issue_q <= read_issue_q + 1'b1;
                slot_requester_q[read_issue_q] <= requester_q;
                slot_tag_q[read_issue_q] <= tag_q;
                slot_bytes_q[read_issue_q] <= issue_bytes_q;
                slot_lower_q[read_issue_q] <= issue_address_q[6:0] + {5'b0, first(
                    issue_first_be_q
                )};
                issue_bytes_q <= issue_bytes_q - ({8'b0, issue_chunk} << 2) + {11'b0, first(
                    issue_first_be_q
                )};
                issue_first_be_q <= 15;
                issue_address_q <= issue_address_q + ({27'b0, issue_chunk} << 2);
                issue_remaining_q <= issue_remaining_q - {6'b0, issue_chunk};
            end
            if (r_accept) begin
                if (r_error) slot_bad_q[read_response_q] <= 1;
                if (m_axi_rlast) begin
                    slot_done_q[read_response_q] <= 1;
                    read_response_q              <= read_response_q + 1'b1;
                    read_index_q                 <= 0;
                end else if (read_index_q < 16) read_index_q <= read_index_q + 1'b1;
            end
            if (read_pop) begin
                slot_done_q[read_tx_q] <= 0;
                read_tx_q              <= read_tx_q + 1'b1;
            end
        end
    end
endmodule

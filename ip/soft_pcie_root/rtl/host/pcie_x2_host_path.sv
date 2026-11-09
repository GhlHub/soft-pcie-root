// SPDX-License-Identifier: Apache-2.0
// Gen3 x2 only. clk is 125 MHz host/DDR; link_clk is 250 MHz aggregate link.
// link_active_i and dma_enable_i must already be synchronized to host clk.
// rst_n is GLOBAL cold reset. Never reset CDC or accepted AXI ownership for Recovery.
module pcie_x2_host_path (
    input wire clk, link_clk, rst_n, link_active_i, dma_enable_i,
    output wire rx_cross_fault_o, tx_cross_fault_o,
    input wire [63:0] link_rx_data_i,
    input wire link_rx_valid_i, link_rx_last_i,
    output wire link_rx_ready_o,
    // Link beat occupancy is 1/2 DWORDs; non-final beats contain two.
    input wire [1:0] link_rx_words_i,
    output wire [63:0] link_tx_data_o,
    output wire link_tx_valid_o, link_tx_last_o,
    input wire link_tx_ready_i,
    output wire [8:0] link_tx_credits_o,
    output wire [1:0] link_tx_words_o,
    output wire msi_valid_o,
    output wire [4:0] msi_vector_o,
    output wire fault_o,
    // Bridge idle only; CDC/adapters can still own packets. Not permission to reset.
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
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
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
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready
);

    (* ASYNC_REG="TRUE" *) reg [2:0] link_release, host_release;
    always @(posedge link_clk or negedge rst_n)
        if (!rst_n) link_release <= 0;
        else link_release <= {link_release[1:0], 1'b1};
    always @(posedge clk or negedge rst_n)
        if (!rst_n) host_release <= 0;
        else host_release <= {host_release[1:0], 1'b1};
    wire [127:0] rx_data_i, tx_data_o;
    wire [2:0] rx_words_i, tx_words_o;
    wire rx_valid_i, rx_last_i, rx_ready_o, tx_valid_o, tx_last_o, tx_ready_i;
    wire [  8:0] tx_credits_o;
    wire [127:0] packed_rx;
    wire [  2:0] packed_words;
    wire packed_valid, packed_last, packed_ready, pack_fault, rx_fifo_fault;
    wire [10:0] unused_rx_meta;
    pcie_packet_width #(
        .INPUT_DWORDS (2),
        .OUTPUT_DWORDS(4)
    ) rx_pack (
        link_clk,
        link_release[2],
        link_rx_data_i,
        {1'b0, link_rx_words_i},
        11'b0,
        link_rx_valid_i,
        link_rx_last_i,
        link_rx_ready_o,
        packed_rx,
        packed_words,
        unused_rx_meta,
        packed_valid,
        packed_last,
        packed_ready,
        pack_fault
    );
    // Fixed 128-bit host beats. All four slots publish whole packets only.
    pcie_cdc_packet #(
        .WIDTH(131),
        .WORDS(16)
    ) rx_cdc (
        link_clk,
        clk,
        rst_n,
        {packed_words, packed_rx},
        packed_valid,
        packed_last,
        packed_ready,
        rx_fifo_fault,
        {rx_words_i, rx_data_i},
        rx_valid_i,
        rx_last_i,
        rx_ready_o
    );
    wire [141:0] tx_cdc_data;
    wire tx_cdc_valid, tx_cdc_last, tx_cdc_ready, tx_fifo_fault, unpack_fault;
    wire [ 2:0] unpack_words;
    wire [10:0] unpack_meta;
    pcie_cdc_packet #(
        .WIDTH(142),
        .WORDS(16)
    ) tx_cdc (
        clk,
        link_clk,
        rst_n,
        {2'd2, tx_credits_o, tx_words_o, tx_data_o},
        tx_valid_o,
        tx_last_o,
        tx_ready_i,
        tx_fifo_fault,
        tx_cdc_data,
        tx_cdc_valid,
        tx_cdc_last,
        tx_cdc_ready
    );
    pcie_packet_width #(
        .INPUT_DWORDS (4),
        .OUTPUT_DWORDS(2)
    ) tx_unpack (
        link_clk,
        link_release[2],
        tx_cdc_data[127:0],
        tx_cdc_data[130:128],
        tx_cdc_data[141:131],
        tx_cdc_valid,
        tx_cdc_last,
        tx_cdc_ready,
        link_tx_data_o,
        unpack_words,
        unpack_meta,
        link_tx_valid_o,
        link_tx_last_o,
        link_tx_ready_i,
        unpack_fault
    );
    assign link_tx_words_o   = unpack_words[1:0];
    assign link_tx_credits_o = unpack_meta[8:0];
    assign rx_cross_fault_o  = pack_fault || rx_fifo_fault;
    // Both exported crossing faults are observed in the link clock domain.
    (* ASYNC_REG="TRUE" *) reg [2:0] tx_fault_sync;
    always @(posedge link_clk)
        if (!link_release[2]) tx_fault_sync <= 0;
        else tx_fault_sync <= {tx_fault_sync[1:0], tx_fifo_fault};
    assign tx_cross_fault_o = unpack_fault || tx_fault_sync[2];
    wire unused = ^{unused_rx_meta, unpack_words[2], unpack_meta[10:9]};
    pcie_ddr_bridge_x2 bridge (
        .rst_n(host_release[2]),
        .*
    );
endmodule

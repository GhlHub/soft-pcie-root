// Whole-packet asynchronous FIFO. Only completed packets advance the Gray
// publication pointer; packet RAM is held until the reader returns its slot.
// Both domains share GLOBAL reset. Link/PERST/rate changes must not reset one
// side independently. Arbitrary clock pauses preserve ownership/backpressure.
module pcie_cdc_packet #(
    parameter integer WIDTH = 32,
                      WORDS = 64,
                      SLOTS = 4,
    parameter integer AW    = $clog2(WORDS),
                      PW    = $clog2(SLOTS)
) (
    input wire s_clk, m_clk, arst_n,
    input wire [WIDTH-1:0] s_data_i,
    input wire s_valid_i, s_last_i,
    output wire s_ready_o,
    output wire s_fault_o,
    output reg [WIDTH-1:0] m_data_o,
    output wire m_valid_o,
    output reg m_last_o,
    input wire m_ready_i
);
    initial begin
        if (WORDS < 2 || (1 << AW) != WORDS || SLOTS < 2 || (1 << PW) != SLOTS || WIDTH < 1)
            $error("Packet CDC requires positive width and power-of-two WORDS/SLOTS >=2");
    end
    // Intentional reset synchronizers: async assertion reaches pointers with
    // stopped clocks, while the final stage releases only on a local edge.
    /* verilator lint_off SYNCASYNCNET */
    (* ASYNC_REG="TRUE", DONT_TOUCH="TRUE" *) reg [2:0] s_release_q, m_release_q;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge s_clk or negedge arst_n)
        if (!arst_n) s_release_q <= 0;
        else s_release_q <= {s_release_q[1:0], 1'b1};
    always @(posedge m_clk or negedge arst_n)
        if (!arst_n) m_release_q <= 0;
        else m_release_q <= {m_release_q[1:0], 1'b1};
    // Pointer resets assert through these release chains even with a stopped
    // clock, but deassert only on a local clock edge. No raw reset deassertion
    // reaches packet ownership state.
    reg [WIDTH-1:0] data_q  [0:SLOTS*WORDS-1];
    reg [     AW:0] length_q[      0:SLOTS-1];
    reg [PW:0] s_binary_q, s_gray_q, m_binary_q, m_gray_q;
    (* ASYNC_REG="TRUE" *) reg [PW:0] s_read_meta_q, s_read_mid_q, s_read_sync_q;
    (* ASYNC_REG="TRUE" *) reg [PW:0] m_write_meta_q, m_write_mid_q, m_write_sync_q;
    reg [  AW:0] fill_q;
    reg [AW-1:0] read_q;
    reg reading_q, output_valid_q, prefetch_valid_q, prefetch_last_q, fault_q;
    reg [WIDTH-1:0] prefetch_data_q;
    assign s_fault_o = s_release_q[2] && fault_q;
    always @(posedge s_clk) begin
        if (!s_release_q[2]) fault_q <= 0;
        else if (s_valid_i && s_ready_o && s_last_i && fill_q >= (AW + 1)'(WORDS)) fault_q <= 1;
    end
    reg  [AW:0] read_length_q;
    wire [PW:0] s_next = s_binary_q + 1'b1, m_next = m_binary_q + 1'b1;
    // Flip the two most significant Gray bits to test one full ring apart.
    wire        full = s_gray_q == (s_read_sync_q ^ ((PW + 1)'(3) << (PW - 1)));
    assign s_ready_o = s_release_q[2] && !full;
    wire available = m_gray_q != m_write_sync_q;
    wire output_space = !output_valid_q || m_ready_i;
    wire move_output = prefetch_valid_q && output_space;
    wire fetch = m_release_q[2] && reading_q && (!prefetch_valid_q || output_space);
    wire last_word = {1'b0, read_q} == read_length_q - 1'b1;
    assign m_valid_o = m_release_q[2] && output_valid_q;
    always @(posedge s_clk or negedge s_release_q[2]) begin
        if (!s_release_q[2]) begin
            s_binary_q    <= 0;
            s_gray_q      <= 0;
            fill_q        <= 0;
            s_read_meta_q <= 0;
            s_read_mid_q  <= 0;
            s_read_sync_q <= 0;
        end else begin
            s_read_meta_q <= m_gray_q;
            s_read_mid_q  <= s_read_meta_q;
            s_read_sync_q <= s_read_mid_q;
            if (s_valid_i && s_ready_o) begin
                if (s_last_i) begin
                    if (fill_q < (AW + 1)'(WORDS)) begin
                        s_binary_q <= s_next;
                        s_gray_q   <= (s_next >> 1) ^ s_next;
                    end
                    fill_q <= 0;
                end else if (fill_q < (AW + 1)'(WORDS)) fill_q <= fill_q + 1'b1;
            end
        end
    end
    // No data/length reset: synchronized ownership alone makes RAM valid.
    always @(posedge s_clk)
        if (s_valid_i && s_ready_o && fill_q < (AW + 1)'(WORDS)) begin
            data_q[{s_binary_q[PW-1:0], fill_q[AW-1:0]}] <= s_data_i;
            if (s_last_i) length_q[s_binary_q[PW-1:0]] <= fill_q + 1'b1;
        end
    // Register all asynchronous RAM outputs in the receiving domain. Packet
    // length is sampled only after three-stage publication; it then controls
    // reader state locally. An elastic prefetch/output pair isolates BRAM clock
    // to output delay from downstream credit/admission logic at250MHz.
    always @(posedge m_clk) begin
        if (!m_release_q[2]) begin
            reading_q        <= 0;
            output_valid_q   <= 0;
            prefetch_valid_q <= 0;
            read_q           <= 0;
        end else begin
            if (!reading_q && available) begin
                read_length_q <= length_q[m_binary_q[PW-1:0]];
                reading_q     <= 1;
                read_q        <= 0;
            end
            if (output_valid_q && m_ready_i) output_valid_q <= 0;
            if (move_output) begin
                m_data_o         <= prefetch_data_q;
                m_last_o         <= prefetch_last_q;
                output_valid_q   <= 1;
                prefetch_valid_q <= 0;
            end
            if (fetch) begin
                prefetch_data_q  <= data_q[{m_binary_q[PW-1:0], read_q}];
                prefetch_last_q  <= last_word;
                prefetch_valid_q <= 1;
                if (last_word) reading_q <= 0;
                else read_q <= read_q + 1'b1;
            end
        end
    end
    always @(posedge m_clk or negedge m_release_q[2]) begin
        if (!m_release_q[2]) begin
            m_binary_q     <= 0;
            m_gray_q       <= 0;
            m_write_meta_q <= 0;
            m_write_mid_q  <= 0;
            m_write_sync_q <= 0;
        end else begin
            m_write_meta_q <= s_gray_q;
            m_write_mid_q  <= m_write_meta_q;
            m_write_sync_q <= m_write_mid_q;
            // Returning a slot after its last word is copied is safe even if the
            // output stalls: that final word now belongs to the local prefetch register.
            if (fetch && last_word) begin
                m_binary_q <= m_next;
                m_gray_q   <= (m_next >> 1) ^ m_next;
            end
        end
    end
endmodule

// Single-word command transport using AMD's asynchronous FIFO and scoped CDC
// constraints. Only GLOBAL reset may clear ownership. Clock pauses/rate changes
// must not reset this FIFO. Both clocks must resume to finish reset recovery.
module pcie_cmd_fifo #(parameter integer WIDTH=119)(
 input wire s_clk,m_clk,arst_n,
 input wire [WIDTH-1:0] s_data_i,input wire s_valid_i,
 output wire s_ready_o,
 output wire [WIDTH-1:0] m_data_o,output wire m_valid_o,input wire m_ready_i
);
 (* ASYNC_REG="TRUE", DONT_TOUCH="TRUE" *) reg [2:0] s_release_q,m_release_q;
 always @(posedge s_clk or negedge arst_n)
  if(!arst_n)s_release_q<=0;else s_release_q<={s_release_q[1:0],1'b1};
 always @(posedge m_clk or negedge arst_n)
  if(!arst_n)m_release_q<=0;else m_release_q<={m_release_q[1:0],1'b1};
 // XPM rst is synchronous to its write clock, including assertion. Immediate
 // global-reset isolation is supplied by the local wrapper release gates.
 reg fifo_reset_q=1'b1;
 always @(posedge s_clk)fifo_reset_q<=!s_release_q[2];
 wire full,empty,wr_busy,rd_busy;
 // A stopped write clock can delay XPM reset reaching the read domain.
 // Require each side to observe its own reset-busy assertion before exposing
 // data/space again, so stale pre-reset output cannot escape on clock restart.
 reg s_reset_seen_q,m_reset_seen_q;
 always @(posedge s_clk or negedge s_release_q[2])
  if(!s_release_q[2])s_reset_seen_q<=0;else if(wr_busy)s_reset_seen_q<=1;
 always @(posedge m_clk or negedge m_release_q[2])
  if(!m_release_q[2])m_reset_seen_q<=0;else if(rd_busy)m_reset_seen_q<=1;
 assign s_ready_o=s_release_q[2]&&s_reset_seen_q&&!wr_busy&&!full;
 assign m_valid_o=m_release_q[2]&&m_reset_seen_q&&!rd_busy&&!empty;
 // Depth16 is the minimum supported XPM depth. The enclosing owner still
 // admits only one command; this does not increase PCIe tags/outstanding work.
 // FWFT supplies a stable valid/data interface through consumer backpressure.
 xpm_fifo_async #(
  .FIFO_MEMORY_TYPE("distributed"),.FIFO_WRITE_DEPTH(16),
  .WRITE_DATA_WIDTH(WIDTH),.READ_DATA_WIDTH(WIDTH),
  .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(3),
  .RELATED_CLOCKS(0),.USE_ADV_FEATURES("0000"),
  .WR_DATA_COUNT_WIDTH(5),.RD_DATA_COUNT_WIDTH(5),
  .PROG_FULL_THRESH(8),.PROG_EMPTY_THRESH(5),
  .SIM_ASSERT_CHK(1)
 ) fifo (
  .rst(fifo_reset_q),.sleep(1'b0),
  .wr_clk(s_clk),.din(s_data_i),.wr_en(s_valid_i&&s_ready_o),
  .full(full),.wr_rst_busy(wr_busy),
  .rd_clk(m_clk),.dout(m_data_o),.rd_en(m_valid_o&&m_ready_i),
  .empty(empty),.rd_rst_busy(rd_busy),
  .injectsbiterr(1'b0),.injectdbiterr(1'b0),
  .prog_full(),.wr_data_count(),.overflow(),.almost_full(),.wr_ack(),
  .prog_empty(),.rd_data_count(),.underflow(),.almost_empty(),.data_valid(),
  .sbiterr(),.dbiterr()
 );
endmodule

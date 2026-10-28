// SPDX-License-Identifier: Apache-2.0
// Saturated 19-DWORD packets represent 3 header + 16 payload DWORDs.
// Synthetic cumulative ACK timing; no RX/FC/DDR model. Timeout extended to
// isolate scheduling from retries. Counters sample after 1000 warm-up clocks.
`timescale 1ns / 1ps
module test_tx_throughput;
    parameter integer ACK_DELAY = 16, PCS = 1, ACK_EVERY = 1;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1;
    wire ready, ov, ol, fault, pcsready;
    wire [31:0] od;
    wire [3:0] pending, sent;
    wire [11:0] acked, nextseq;
    reg            response = 0;
    reg     [11:0] seq = 0;
    integer        outword = 0;
    integer wi = 0, cycle = 0, frames = 0, delayq[0:16383], seqs[0:16383], wr = 0, rd = 0;
    integer
        activecycles = 0,
        blocked = 0,
        fullcycles = 0,
        ackblocked = 0,
        ackstop = 0,
        copy = 0,
        fmtblocked = 0,
        outblocked = 0,
        emptyout = 0;
    wire sinkready = PCS ? pcsready : 1'b1;
    gen3_tx_window #(
        .REPLAY_CYCLES(4096)
    ) dut (
        clk,
        reset,
        1'b1,
        32'ha5000000 + wi,
        1'b1,
        wi == 18,
        ready,
        od,
        ov,
        ol,
        sinkready,
        response,
        1'b0,
        seq,
        pending,
        sent,
        acked,
        nextseq,
        fault,
    );
    wire [31:0] phys;
    wire pv, ps, td, st, td2, ed, idle, submit, pfault;
    wire        [ 1:0] header;
    wire signed [10:0] bal;
    gen3_recovery_tx pcs (
        clk,
        reset,
        1'b1,
        1'b0,
        1'b1,
        1'b1,
        2'b0,
        4'd4,
        6'd0,
        6'd0,
        6'd0,
        phys,
        pv,
        ps,
        td,
        st,
        header,
        bal,
        td2,
        ed,
        idle,
        1'b0,
        od,
        ov,
        ol,
        pcsready,
        submit,
        pfault,
    );
    always @(posedge clk)
        if (!reset) begin
            cycle = cycle + 1;
            if (ready) wi <= wi == 18 ? 0 : wi + 1;
            if (ov && sinkready) begin
                if (ol != (outword == 20)) $fatal(1, "Incorrect output frame length");
                if (outword >= 1 && outword <= 19 && od != 32'ha5000000 + 32'(outword - 1))
                    $fatal(1, "Payload ordering");
                outword = ol ? 0 : outword + 1;
            end
            if (ov && sinkready && ol) begin
                delayq[wr] = cycle + ACK_DELAY;
                seqs[wr]   = frames % 4096;
                wr         = wr + 1;
                frames     = frames + 1;
            end
            if (cycle > 1000) begin
                activecycles = activecycles + 1;
                blocked      = blocked + (!ready);
                fullcycles   = fullcycles + (pending == 8);
                ackblocked   = ackblocked + (dut.captured && !dut.captured_ready);
                ackstop      = ackstop + (dut.captured && dut.store.tx_state_q == 0);
                copy         = copy + (dut.payload_valid && dut.payload_ready);
                fmtblocked   = fmtblocked + (dut.payload_valid && !dut.payload_ready);
                outblocked   = outblocked + (ov && !sinkready);
                emptyout     = emptyout + (!ov);
            end
            if (fault || (PCS && pfault)) $fatal(1, "fault");
            if (cycle == 101000) begin
                $display(
                    "RESULT pcs=%0d delay=%0d ack_every=%0d cycles=%0d frames=%0d blocked=%0d full=%0d ack_wait=%0d ack_stop=%0d copy=%0d fmt_stall=%0d out_stall=%0d out_empty=%0d",
                    PCS, ACK_DELAY, ACK_EVERY, activecycles, frames, blocked, fullcycles,
                    ackblocked, ackstop, copy, fmtblocked, outblocked, emptyout);
                $finish;
            end
        end
    always @(negedge clk) begin
        response = 0;
        if (!reset && rd + ACK_EVERY <= wr && delayq[rd+ACK_EVERY-1] <= cycle) begin
            response = 1;
            seq      = 12'(seqs[rd+ACK_EVERY-1]);
            rd       = rd + ACK_EVERY;
        end
    end
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
    end
endmodule

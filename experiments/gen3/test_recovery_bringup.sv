// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_recovery_bringup;
    parameter integer FAULT = 0, DATALINK = 0, MISSING_NP = 0;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1;
    wire [127:0] status, last_ts;
    wire [ 4:0] state = status[4:0], legacy_state = status[9:5];
    wire [31:0] txdata;
    wire [1:0] txk, txheader, rate, eqctrl;
    wire txvalid, txstart, detect, idle, polarity;
    wire [1:0] powerdown;
    wire [3:0] preset;
    wire [15:0] partner_plain, partner_data;
    wire [1:0] partner_k, partner_raw_k;
    wire partner_valid, partner_done, partner_boundary;
    wire [1:0] partner_kind_out;
    wire lp = state == 0 && legacy_state < 4;
    wire np = state == 0 && legacy_state < 6;
    wire [1:0] partner_kind = state == 0 ? (legacy_state == 9 || legacy_state == 10 ? 2'd0 :
                                            legacy_state == 3 || legacy_state == 8 ? 2'd2 : 2'd1) :
        state == 1 ? 2'd1 : state == 2 ? 2'd2 : 2'd0;
    gen3_legacy_training partner (
        .clk          (clk),
        .rst_n        (!reset),
        .tx_ready_i   (1'b1),
        .tx_kind_i    (partner_kind),
        .tx_link_i    (8'b0),
        .tx_lane_i    (8'b0),
        .tx_control_i (8'b0),
        .tx_link_pad_i(lp),
        .tx_lane_pad_i(np),
        .tx_data_o    (partner_plain),
        .tx_ctrl_o    (partner_raw_k),
        .tx_valid_o   (partner_valid),
        .tx_done_o    (partner_done),
        .tx_boundary_o(partner_boundary),
        .tx_kind_o    (partner_kind_out),
        .rx_data_i    (16'b0),
        .rx_ctrl_i    (2'b0),
        .rx_valid_i   (1'b0),
        .rx_error_i   (1'b0),
        .rx_ts_valid_o(),
        .rx_ts2_o     (),
        .rx_inverted_o(),
        .rx_bad_o     (),
        .rx_link_o    (),
        .rx_lane_o    (),
        .rx_rate_o    (),
        .rx_control_o (),
        .rx_link_pad_o(),
        .rx_lane_pad_o(),
        .tx_eq_i      (state != 0),
        .tx_preset_i  (4'd4),
        .tx_rate_i    (state == 0 ? 8'h0e : FAULT == 8 ? 8'h86 : 8'h8e)
    );
    wire unusedready, unusedvalid;
    wire [ 1:0] unusedkeep;
    wire [15:0] unusedlfsr;
    pcie_soft_scrambler scramble (
        clk,
        !reset,
        partner_valid ? partner_plain : 16'b0,
        partner_valid ? partner_raw_k : 2'b0,
        2'b11,
        {2{!partner_valid}},
        1'b1,
        unusedready,
        partner_data,
        partner_k,
        unusedkeep,
        unusedvalid,
        1'b1,
        unusedlfsr
    );
    wire [31:0] gen3_data;
    wire gen3_valid, gen3_start, gen3_done, gen3_stop;
    wire        [ 1:0] gen3_header;
    wire signed [10:0] balance;
    wire unused_packet_ready, unused_packet_submit, unused_packet_fault;
    wire [31:0] partner_packet_data;
    wire partner_packet_valid, partner_packet_last, partner_body_ready;
    reg  [ 1:0] partner_class = 0;
    reg  [ 3:0] partner_round = 0;
    wire [ 7:0] partner_type = (partner_round < 2 ? 8'h40 : 8'hc0) | {2'b0, partner_class, 4'b0};
    wire [31:0] partner_body = {24'h084000, partner_type};
    gen3_dllp_source peer_dllp (
        clk,
        reset,
        partner_body,
        DATALINK != 0 && state == 18,
        partner_body_ready,
        partner_packet_data,
        partner_packet_valid,
        partner_packet_last,
        unused_packet_ready
    );
    always @(posedge clk) begin
        if (reset) begin
            partner_class <= 0;
            partner_round <= 0;
        end else if (DATALINK != 0 && state == 18 && partner_body_ready) begin
            partner_class <= partner_class == 2 ? 0 :
                partner_class == 0 && MISSING_NP != 0 ? 2 : partner_class + 1'b1;
            if (partner_class == 2 && partner_round < 15) partner_round <= partner_round + 1'b1;
        end
    end
    wire partner_ts2_done, partner_eieos_done, partner_idle_word;
    gen3_recovery_tx partner3 (
        clk,
        reset,
        rate == 2,
        1'b0,
        (state == 16 || state == 17 || state == 18) && FAULT != 12,
        (state == 17 || state == 18) && FAULT != 13,
        state == 12 || state >= 16 ? 2'b00 : 2'b01,
        4'd4,
        6'd40,
        6'd12,
        6'd0,
        gen3_data,
        gen3_valid,
        gen3_start,
        gen3_done,
        gen3_stop,
        gen3_header,
        balance,
        partner_ts2_done,
        partner_eieos_done,
        partner_idle_word,
        1'b0,
        partner_packet_data,
        partner_packet_valid,
        partner_packet_last,
        unused_packet_ready,
        unused_packet_submit,
        unused_packet_fault,
    );
    reg [5:0] eqdelay = 0, ratedelay = 0;
    reg eqdone = 0, phystatus = 0;
    reg [7:0] count = 0;
    reg [1:0] old_power = 2;
    reg [4:0] power_delay = 0;
    always @(posedge clk) begin
        count     <= count + 1'b1;
        eqdone    <= 0;
        phystatus <= 0;
        old_power <= powerdown;
        if (old_power == 2 && powerdown == 0) power_delay <= 1;
        else if (power_delay != 0 && power_delay < 16) power_delay <= power_delay + 1'b1;
        if (power_delay == 8 && FAULT != 6) phystatus <= 1;
        if (eqctrl == 0) eqdelay <= 0;
        else if (eqdelay < 8) eqdelay <= eqdelay + 1'b1;
        else if (eqdelay == 8) begin
            eqdone  <= !((FAULT == 1 && eqctrl == 1) || (FAULT == 2 && eqctrl == 3));
            eqdelay <= 9;
        end
        if (rate == 0) ratedelay <= 0;
        else if (ratedelay < 32) ratedelay <= ratedelay + 1'b1;
        if (rate == 2 && ratedelay == 16 && FAULT != 3) phystatus <= 1;
        if (detect && count == 0) phystatus <= 1;
    end
    reg [1:0] rxword = 0;
    reg       rx_ts2_block = 0;
    always @(posedge clk) if (gen3_valid && gen3_start) rx_ts2_block <= gen3_data[7:0] == 8'h2d;
    always @(posedge clk) if (gen3_valid) rxword <= gen3_start ? 1 : rxword + 1'b1;
    wire [31:0] impaired = gen3_data ^
        ((FAULT == 5 && rxword == 1) ?
         32'h00010000 : (FAULT == 14 && rx_ts2_block && rxword == 1) ? 32'h01000000 : 32'b0);
    reg [15:0] ei_cycles = 0;
    always @(posedge clk)
        if (state == 4) ei_cycles <= ei_cycles + 1'b1;
        else ei_cycles <= 0;
    wire native_idle = (FAULT == 9 || FAULT == 11) && state >= 3 &&
        (FAULT != 11 || ei_cycles >= 300);
    wire [31:0] rxdata = rate == 2 ? impaired : state >= 3 ?
        ((FAULT >= 9 && FAULT <= 11) ? 32'b0 : {16'b0, count[0] ? 16'h7c7c : 16'h7cbc}) :
        {16'b0, partner_data};
    gen3_eq_bringup #(
        .DATALINK_ENABLE  (DATALINK),
        .INITFC1_PROBE    (DATALINK == 0),
        .RECOVERY_ENABLE  (1),
        .STARTUP_TIMEOUT  (100000),
        .HANDSHAKE_TIMEOUT(4096),
        .EQ_TIMEOUT       (1024),
        .OBSERVE_CYCLES   (5000)
    ) dut (
        clk,
        reset,
        1'b1,
        4'd4,
        rxdata,
        state >= 3 ? 2'b11 : partner_k,
        1'b1,
        gen3_valid && FAULT != 4,
        gen3_start,
        gen3_header,
        native_idle,
        phystatus,
        FAULT == 7 ? 3'b000 : 3'b011,
        eqdone,
        6'd40,
        6'd12,
        {6'd0, 6'd40, 6'd0},
        txdata,
        txk,
        txheader,
        txvalid,
        txstart,
        detect,
        idle,
        polarity,
        rate,
        eqctrl,
        preset,
        last_ts,
        status,
        powerdown,
        1'b0
        ,,
        3'b0,
        64'b0,
        16'b0,
        32'b0,
        4'b0
        ,,
        1'b1
        ,,,
        32'b0,
        1'b0,
        1'b0
        ,,
        2'b0,
        9'b0
        ,,,,
        1'b0
        ,,
    );
    reg seen_apply = 0, seen_query = 0, seen_gen3 = 0, seen_wire = 0;
    always @(negedge clk)
        if (!reset) begin
            if (rate == 2 && !idle && !seen_wire) begin
                if (!txvalid || !txstart || txdata != 32'hff00ff00)
                    $fatal(1, "Gen3 idle exit lost EIEOS");
                seen_wire = 1;
            end
            if (detect && powerdown != 2) $fatal(1, "receiver detect outside P1");
            if (state == 0 && legacy_state == 2 && power_delay < 8)
                $fatal(1, "training before P0 ack");
            if (eqctrl != 0 && !idle) $fatal(1, "preset/query outside electrical idle");
            if (FAULT == 11 && state == 5 && !seen_apply && ei_cycles < 425)
                $fatal(1, "preset applied before fresh post-peer-idle guard");
            if (eqctrl == 1) seen_apply = 1;
            if (eqctrl == 3) begin
                if (!seen_apply) $fatal(1, "query before apply");
                seen_query = 1;
            end
            if (rate == 2) begin
                if (!seen_query) $fatal(1, "rate before preset query");
                seen_gen3 = 1;
            end
            if (state == 15 && (FAULT == 0 || FAULT == 9 || FAULT == 11))
                $fatal(1, "bringup failed %032x", status);
        end
    initial begin
        repeat (4) @(posedge clk);
        #1;
        reset = 0;
        wait (state == 14 || state == 15);
        repeat (2) @(posedge clk);
        #1;
        if (FAULT >= 12) begin
            if (state != 14 || status[22:19] != (FAULT == 13 ? 10 : 9) || dut.reached_l0)
                $fatal(1, "recovery timeout failed %032x", status);
            $display("PASS: Recovery missing TS2/SDS fault %0d", FAULT);
            $finish;
        end
        if (FAULT != 0 && FAULT != 9 && FAULT != 11) begin
            if (FAULT == 10) begin
                if (state != 15 || status[22:19] != 3) $fatal(1, "missing peer idle was accepted");
            end else if (FAULT >= 6) begin
                if (state != 15 || status[22:19] != (FAULT == 8 ? 2 : 1))
                    $fatal(1, "wrong startup/negotiation fault %032x", status);
            end else if (FAULT <= 3) begin
                if (state != 15 || status[22:19] != (FAULT == 3 ? 5 : 4))
                    $fatal(1, "wrong handshake fault %032x", status);
            end else if (state != 14 || !status[15] || status[14] || status[22:19] != 6)
                $fatal(1, "unqualified equalization succeeded %032x", status);
            $display("PASS: equalization bringup injected fault %0d", FAULT);
            $finish;
        end
        if (!dut.reached_l0 || dut.receive_errors != 0 || !seen_gen3 || !status[14] || status[15] ||
            !idle || !dut.eq_skip)
            $fatal(1, "missing successful EQ result %032x", status);
        if (DATALINK != 0 && dut.dl_active !== (MISSING_NP == 0))
            $fatal(
                1,
                "FC initialization state mismatch phase=%d seen=%b seen2=%b dllps=%d last=%h offer=%b ready=%b tx=%b/%b sending=%b kind=%d close=%b"
                    ,
                dut.data_link.link.flow.phase_q,
                dut.data_link.link.flow.seen_q,
                dut.data_link.link.flow.seen2_q,
                dut.dllp_count,
                dut.dllp_body,
                dut.data_link.link.fc_valid,
                dut.data_link.link.fc_ready,
                dut.packet_tx_valid,
                dut.packet_tx_ready,
                dut.recovery_tx.tx3.packet_sending,
                dut.recovery_tx.tx3.kind,
                dut.recovery_tx.tx3.close_stream
            );
        $display(
            "PASS: legacy startup -> Phase 1 -> TS2 -> SDS -> logical idle L0 -> diagnostic stop");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "watchdog state %0d legacy %0d", state, legacy_state);
    end
endmodule

`ifdef GEN3_RX_DIAGNOSTICS
// Simulation sink for the generated AMD ILA. Verify event layout and independent
// activity totals without relying on the RTL diagnostic counter expressions.
module gen3_rx_ila (
    input wire clk,
    input wire [31:0] probe0, probe1, probe2, probe3, probe4, probe5, probe6, probe7, probe8,
        probe9, probe10, probe11, probe12, probe13
);
    integer words = 0, decoded = 0, cycles = 0;
    reg finished = 0;
    always @(posedge clk) begin
        if (probe11[10:6] !== probe2[4:0] || probe11[12:11] !== probe2[6:5])
            $fatal(1, "TX diagnostic state/rate mapping mismatch");
        if (probe2[4:0] == 16 || probe2[4:0] == 17 || probe2[4:0] == 18) begin
            cycles = cycles + 1;
            if (probe2[14]) words = words + 1;
            if (probe2[17]) decoded = decoded + 1;
        end
        if (probe2[4:0] == 14 && !finished) begin
            if (probe3 !== 32'(cycles) || probe5 !== 32'(words) || probe6 !== 32'(decoded))
                $fatal(1, "diagnostic counters/event mapping mismatch");
            if (probe9 != 0) $fatal(1, "DLLP CRC error");
            finished = 1;
            $display("PASS: passive RX diagnostic counters cycles=%0d words=%0d decoded=%0d",
                     cycles, words, decoded);
        end
    end
    wire unused = ^{probe0, probe1, probe4, probe7, probe10, probe12, probe13};
endmodule
`endif

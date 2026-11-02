// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_recovery_bringup;
    parameter integer ADAPT_TEST = 0,
        FAULT = 0, DATALINK = 0, MISSING_NP = 0, LIVE_RECOVERY = -1, PRESET = 4;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1;
    reg inject_header = 0, peer_recover = 0, silence = 0, phy_ready = 1;
    reg send_ack = 0, command = 0, app_valid = 0, app_last = 0;
    reg [31:0] app_data = 0;
    wire command_ready, response_valid, app_ready, dl_active, link_error;
    wire [31:0] response_data;
    wire [ 2:0] response_status;
    reg watch_recovery = 0, ddr_start = 0, ddr_release = 0;
    wire ddr_armed, ddr_done;
    reg     [7:0] saved_used_h;
    integer       recovery_cycles;
    reg completion_valid = 0, completion_last = 0, completion_mode = 0;
    reg [31:0] completion_data = 0;
    wire completion_ready, completion_wire_valid, completion_wire_last;
    wire [31:0] completion_wire_data;
    wire        completion_fault;
    wire        peer_wire_ready;
    gen3_tlp_source peer_completion (
        .clk        (clk),
        .reset_i    (reset),
        .data_i     (completion_data),
        .valid_i    (completion_valid),
        .last_i     (completion_last),
        .ready_o    (completion_ready),
        .sequence_i (12'b0),
        .data_o     (completion_wire_data),
        .valid_o    (completion_wire_valid),
        .last_o     (completion_wire_last),
        .ready_i    (peer_wire_ready && completion_mode),
        .submitted_o(),
        .fault_o    (completion_fault)
    );
    wire [127:0] status, last_ts;
    wire [4:0] state = status[4:0], legacy_state = status[9:5];
    generate
        if (LIVE_RECOVERY >= 0 && DATALINK != 0) begin : live_ddr
            recovery_ddr_owner bridge_check (
                clk,
                reset,
                dl_active,
                state == 19,
                ddr_start,
                ddr_release,
                ddr_armed,
                ddr_done
            );
        end
    endgenerate
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
    wire [31:0] partner_body = send_ack ? 32'h01000000 : {24'h084000, partner_type};
    gen3_dllp_source peer_dllp (
        clk,
        reset,
        partner_body,
        DATALINK != 0 && state == 18 && !completion_mode,
        partner_body_ready,
        partner_packet_data,
        partner_packet_valid,
        partner_packet_last,
        peer_wire_ready && !completion_mode
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
    reg eqdone = 0, phystatus = 0;
    wire [1:0] rx_eq_ctrl;
    reg rx_eq_done = 0, rx_eq_adapted = 0;
    integer query_count = 0, rx_eq_delay = 0, rx_eq_calls = 0;
    reg previous_query_done = 0;
    always @(posedge clk) begin
        previous_query_done <= eqctrl == 3 && eqdone;
        if (eqctrl == 3 && eqdone && !previous_query_done) query_count <= query_count + 1;
        rx_eq_done <= 0;
        if (rx_eq_ctrl == 0) rx_eq_delay <= 0;
        else if (rx_eq_delay < 8) rx_eq_delay <= rx_eq_delay + 1;
        else if (rx_eq_delay == 8) begin
            rx_eq_done    <= 1;
            rx_eq_adapted <= rx_eq_calls != 0;
            rx_eq_calls   <= rx_eq_calls + 1;
            rx_eq_delay   <= 9;
        end
    end
    wire [1:0]
        peer_ec = state == 20 ? (query_count >= 2 ? 2'b11 : 2'b10) : state < 12 ? 2'b01 : 2'b00;
    wire [3:0] peer_preset = state == 20 ? (peer_ec == 2 ? 4'd6 : dut.training_fields[6:3]) : 4'd4;
    wire [30:0] peer_low = {
        1'b0,
        6'b0,
        2'b0,
        (state < 12 ? 6'd12 : 6'd40),
        2'b0,
        (state < 12 ? 6'd40 : 6'd0),
        (state == 20 && peer_ec == 2),
        peer_preset,
        1'b0,
        peer_ec
    };
    gen3_recovery_tx #(
        .EXTERNAL_EQ(ADAPT_TEST)
    ) partner3 (
        clk,
        reset,
        rate == 2,
        1'b0,
        (state == 16 || state == 17 || state == 18) && !peer_recover && FAULT != 12,
        (state == 17 || state == 18) && !peer_recover && FAULT != 13,
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
        completion_mode ? completion_wire_data : partner_packet_data,
        completion_mode ? completion_wire_valid : partner_packet_valid,
        completion_mode ? completion_wire_last : partner_packet_last,
        peer_wire_ready,
        unused_packet_submit,
        unused_packet_fault
        ,,
        {^peer_low, peer_low},
        1'b0
    );
    reg [5:0] eqdelay = 0, ratedelay = 0;
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
        .ADAPTIVE_EQ      (ADAPT_TEST),
        .DATALINK_ENABLE  (DATALINK),
        .INITFC1_PROBE    (DATALINK == 0),
        .RECOVERY_ENABLE  (1),
        .STARTUP_TIMEOUT  (100000),
        .HANDSHAKE_TIMEOUT(4096),
        .EQ_TIMEOUT       (1024),
        .OBSERVE_CYCLES   (LIVE_RECOVERY < 0 ? 5000 : 0)
    ) dut (
        clk,
        reset,
        phy_ready,
        4'(PRESET),
        rxdata,
        state >= 3 ? 2'b11 : partner_k,
        1'b1,
        gen3_valid && FAULT != 4 && !silence,
        gen3_start,
        inject_header ? 2'b00 : gen3_header,
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
        command,
        command_ready,
        3'd2,
        64'b0,
        16'h0100,
        32'b0,
        4'hf,
        response_valid,
        1'b0,
        response_data,
        response_status,
        app_data,
        app_valid,
        app_last,
        app_ready,
        2'b0,
        9'd1
        ,,,,
        1'b0,
        dl_active,
        link_error,
        rx_eq_done,
        rx_eq_adapted,
        1'b1,
        18'd7,
        rx_eq_ctrl
        ,,,
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
            if (eqctrl != 0 && !idle && state != 20)
                $fatal(1, "preset/query outside electrical idle");
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
        if (LIVE_RECOVERY >= 0) begin
            wait (dl_active);
            @(negedge clk);
            ddr_start = 1;
            wait (ddr_armed);
            // Retain one posted packet and one configuration requester across
            // Recovery. The peer withholds ACKs until after L0 is restored.
            for (integer w = 0; w < 4; w = w + 1) begin
                @(negedge clk);
                app_valid = 1;
                app_last = w == 3;
                app_data = w == 0 ? 32'h01000040 :
                    w == 1 ? 32'h0f000001 : w == 2 ? 32'h00100000 : 32'hfeed1234;
                do @(posedge clk); while (!app_ready);
            end
            @(negedge clk);
            app_valid = 0;
            command   = 1;
            do @(posedge clk); while (!command_ready);
            @(negedge clk);
            command = 0;
            wait (dut.data_link.link.replay_sent == 2);
            @(negedge clk);
            saved_used_h   = dut.data_link.link.flow.used_h[0];
            watch_recovery = 1;
            if (LIVE_RECOVERY == 1) peer_recover = 1;
            else if (LIVE_RECOVERY == 4) phy_ready = 0;
            else begin
                do @(negedge clk); while (!gen3_start || !gen3_valid);
                inject_header = 1;
                @(negedge clk);
                inject_header = 0;
            end
            wait (state == 19);
            @(negedge clk);
            peer_recover = 0;
            phy_ready    = 1;
            if (LIVE_RECOVERY == 2) silence = 1;
            if (LIVE_RECOVERY == 3) inject_header = 1;
            recovery_cycles = 0;
            while (state != 18 && state != 13 && state != 14) begin
                @(negedge clk);
                recovery_cycles = recovery_cycles + 1;
                if (state != 13 && state != 14 &&
                    (!dl_active || link_error || response_valid || completion_fault))
                    $fatal(1, "Recovery lost ownership/command state=%d", state);
                if (dut.data_link.link.replay_pending != 2 ||
                    dut.data_link.link.flow.used_h[0] != saved_used_h)
                    $fatal(1, "Recovery reset replay or credits");
                if (recovery_cycles > 4200) $fatal(1, "Unbounded Recovery");
            end
            watch_recovery = 0;
            if (LIVE_RECOVERY == 2 || LIVE_RECOVERY == 3) begin
                if (state != 13 || dl_active || !link_error)
                    $fatal(1, "Failed Recovery did not quarantine");
                $display("PASS: bounded Recovery failure retains owners");
                $finish;
            end
            if (state != 18 || !dl_active || link_error) $fatal(1, "Recovery failed to resume");
            if (LIVE_RECOVERY == 5) begin
                // A new loss on the first resumed L0 cycle must start a new
                // bounded attempt, not clear the retained-owner indication.
                phy_ready = 0;
                do @(negedge clk); while (state != 19);
                phy_ready       = 1;
                recovery_cycles = 0;
                while (state != 18) begin
                    if (!dl_active || link_error || recovery_cycles > 4200)
                        $fatal(1, "Back-to-back Recovery lost its epoch");
                    @(negedge clk);
                    recovery_cycles = recovery_cycles + 1;
                end
            end
            ddr_release = 1;
            send_ack    = 1;
            wait (dut.data_link.link.replay_pending == 0);
            // Retire only through the native CRC-validated peer ACK, then
            // return an independently chosen configuration completion payload.
            @(negedge clk);
            completion_mode = 1;
            for (integer w = 0; w < 4; w = w + 1) begin
                completion_valid = 1;
                completion_last = w == 3;
                completion_data = w == 0 ? 32'h0100004a :
                    w == 1 ? 32'h04000001 : w == 2 ? 32'b0 : 32'h1234144d;
                do @(posedge clk); while (!completion_ready);
                @(negedge clk);
            end
            completion_valid = 0;
            wait (response_valid);
            if (response_status != 0 || response_data != 32'h1234144d || link_error)
                $fatal(1, "Requester did not survive Recovery");
            wait (ddr_done);
            if (preset != 4'(ADAPT_TEST ? 6 : PRESET)) $fatal(1, "Preset selection lost");
            $display("PASS: live same-rate Recovery retained replay, credits and requester");
            $finish;
        end
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
        #(LIVE_RECOVERY >= 0 ? 200000 : 2000000);
        $fatal(1, "watchdog state %0d legacy %0d active=%b cmd=%b rsp=%b", state, legacy_state,
               dl_active, command, response_valid);
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

// Host-side ownership boundary check. Requests enter at the validated packet
// interface; this is not a serial endpoint-to-DDR scoreboard. The actual outer
// controller's DL-active signal must keep a live AXI read and its completion
// storage intact throughout Recovery.
module recovery_ddr_owner (
    input wire clk, reset, active, recovery, start_test, release_completion,
    output reg armed = 0,
    done = 0
);
    reg [63:0] rxdata = 0, rdata = 0;
    reg rxvalid = 0, rxlast = 0, rxsingle = 0, rvalid = 0, rlast = 0;
    wire rxready, txvalid, txlast, txsingle, fault, idle, arvalid, rready;
    wire    [63:0] txdata;
    wire    [31:0] araddr;
    wire    [ 7:0] arlen;
    integer        accepted_reads = 0;
    pcie_ddr_bridge #(
        .RX_DWORDS      (2),
        .TX_DWORDS      (2),
        .READ_SLOTS     (8),
        .PIPELINED_READS(1)
    ) dut (
        .clk             (clk),
        .rst_n           (!reset),
        .link_active_i   (active),
        .dma_enable_i    (1'b1),
        .rx_data_i       (rxdata),
        .rx_valid_i      (rxvalid),
        .rx_last_i       (rxlast),
        .rx_last_single_i(rxsingle),
        .rx_ready_o      (rxready),
        .tx_data_o       (txdata),
        .tx_valid_o      (txvalid),
        .tx_last_o       (txlast),
        .tx_last_single_o(txsingle),
        .tx_ready_i      (release_completion),
        .tx_credits_o    (),
        .msi_valid_o     (),
        .msi_vector_o    (),
        .fault_o         (fault),
        .idle_o          (idle),
        .perf_events_o   (),
        .m_axi_awaddr    (),
        .m_axi_awlen     (),
        .m_axi_awsize    (),
        .m_axi_awburst   (),
        .m_axi_awcache   (),
        .m_axi_awprot    (),
        .m_axi_awvalid   (),
        .m_axi_awready   (1'b0),
        .m_axi_wdata     (),
        .m_axi_wstrb     (),
        .m_axi_wlast     (),
        .m_axi_wvalid    (),
        .m_axi_wready    (1'b0),
        .m_axi_bresp     (2'b0),
        .m_axi_bvalid    (1'b0),
        .m_axi_bready    (),
        .m_axi_araddr    (araddr),
        .m_axi_arlen     (arlen),
        .m_axi_arsize    (),
        .m_axi_arburst   (),
        .m_axi_arcache   (),
        .m_axi_arprot    (),
        .m_axi_arvalid   (arvalid),
        .m_axi_arready   (!armed),
        .m_axi_rdata     (rdata),
        .m_axi_rresp     (2'b0),
        .m_axi_rlast     (rlast),
        .m_axi_rvalid    (rvalid),
        .m_axi_rready    (rready)
    );
    always @(posedge clk)
        if (!reset && arvalid && !armed) begin
            if (araddr != 32'h1000 || arlen != 7) $fatal(1, "Recovery DDR AR changed");
            armed          <= 1;
            accepted_reads <= accepted_reads + 1;
        end
    function automatic [31:0] expected(input integer index);
        case (index)
            0: expected = 32'h1000004a;
            1: expected = 32'h40000000;
            2: expected = 32'h005a0001;
            default: expected = 32'h55000000 + 32'(index - 3);
        endcase
    endfunction
    integer words = 0;
    always @(posedge clk)
        if (!reset && txvalid && release_completion) begin
            if (txdata[31:0] !== expected(
                    words
                ) || (!txsingle && txdata[63:32] !== expected(
                    words + 1
                )) || txlast != (words == 18) || txsingle != (words == 18))
                $fatal(1, "Recovery corrupted DDR completion word %d", words);
            words <= words + (txsingle ? 1 : 2);
        end
    initial begin
        wait (start_test);
        @(negedge clk);
        rxdata  = 64'hff5a0001_10000000;
        rxvalid = 1;
        do @(posedge clk); while (!rxready);
        @(negedge clk);
        rxdata   = 64'h00000000_00100000;
        rxlast   = 1;
        rxsingle = 1;
        do @(posedge clk); while (!rxready);
        @(negedge clk);
        rxvalid = 0;
        wait (recovery);
        // DDR must drain accepted traffic even while the PCIe wire is paused.
        for (integer beat = 0; beat < 8; beat = beat + 1) begin
            @(negedge clk);
            rvalid = 1;
            rlast  = beat == 7;
            rdata  = {32'h55000000 + 32'(2 * beat + 1), 32'h55000000 + 32'(2 * beat)};
            do @(posedge clk); while (!rready);
            if (fault || !active) $fatal(1, "Recovery lost live DDR owner");
        end
        @(negedge clk);
        rvalid = 0;
        wait (release_completion);
        wait (words == 19 && idle);
        if (accepted_reads != 1 || fault) $fatal(1, "Recovery repeated DDR AR or faulted");
        done = 1;
    end
endmodule

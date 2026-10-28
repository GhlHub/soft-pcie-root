// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_link_layer;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, up = 0, enable = 1, dllp = 0, cv = 0, rv = 0, rl = 0, response = 0;
    reg [31:0] body = 0, rd = 0;
    wire rr;
    wire [31:0] td, result, appdata;
    wire tv, tl, cr, rsp, appready, appvalid, applast, active, error, pending;
    wire [  2:0] status;
    wire [127:0] debug;
    reg  [  2:0] cop = 2;
    reg  [ 63:0] ca = 0;
    reg  [ 31:0] cd = 0;
    reg          rspready = 0;
    reg txready = 1, av = 0, al = 0, ar = 0;
    reg [31:0] ad = 0;
    gen3_link_layer dut (
        .pcs_profile_i      (5'b0),
        .clk                (clk),
        .reset_i            (reset),
        .link_up_i          (up),
        .enable_i           (enable),
        .rx_data_i          (rd),
        .rx_valid_i         (rv),
        .rx_last_i          (rl),
        .rx_ready_o         (rr),
        .rx_class_i         (2'd2),
        .rx_credits_i       (9'd1),
        .response_i         (response),
        .nak_i              (1'b0),
        .response_sequence_i(12'b0),
        .dllp_i             (dllp),
        .dllp_body_i        (body),
        .tx_data_o          (td),
        .tx_valid_o         (tv),
        .tx_last_o          (tl),
        .tx_ready_i         (txready),
        .cmd_valid_i        (cv),
        .cmd_ready_o        (cr),
        .cmd_op_i           (cop),
        .cmd_address_i      (ca),
        .cmd_bdf_i          (16'h0100),
        .cmd_data_i         (cd),
        .cmd_be_i           (4'hf),
        .rsp_valid_o        (rsp),
        .rsp_ready_i        (rspready),
        .rsp_data_o         (result),
        .rsp_status_o       (status),
        .app_tx_data_i      (ad),
        .app_tx_valid_i     (av),
        .app_tx_last_i      (al),
        .app_tx_ready_o     (appready),
        .app_tx_class_i     (2'd2),
        .app_tx_credits_i   (9'd8),
        .app_rx_data_o      (appdata),
        .app_rx_valid_o     (appvalid),
        .app_rx_last_o      (applast),
        .app_rx_ready_i     (ar),
        .active_o           (active),
        .error_o            (error),
        .pending_o          (pending),
        .completion_debug_o (debug)
    );
    integer tlps = 0, frame = 0, index = 0, fd;
    reg          is_tlp = 0;
    reg [1023:0] path;
    reg          stalled = 0;
    reg [  32:0] held;
    always @(posedge clk)
        if (!reset) begin
            if (stalled && (!tv || {tl, td} !== held)) $fatal(1, "TX offer changed during stall");
            stalled = tv && !txready;
            held    = {tl, td};
            if (tv && txready) begin
                if (index == 0) is_tlp = td[3:0] == 4'hf;
                $fdisplay(fd, "%0d %0d %08x %0d", frame, index, td, tl);
                if (tl) begin
                    if (is_tlp) tlps = tlps + 1;
                    frame = frame + 1;
                    index = 0;
                end else index = index + 1;
            end
        end
    task tick(input integer n);
        repeat (n) @(negedge clk);
    endtask
    task receive_dllp(input [31:0] value);
        @(negedge clk);
        dllp = 1;
        body = value;
        @(negedge clk);
        dllp = 0;
    endtask
    task receive_word(input [31:0] value, input bit last);
        @(negedge clk);
        rv = 1;
        rd = value;
        rl = last;
        do @(posedge clk); while (!rr);
        @(negedge clk);
        rv = 0;
    endtask
    task profile_command(input [63:0] address, input [31:0] value, input [2:0] expected_status);
        @(negedge clk);
        cop = 7;
        ca  = address;
        cd  = value;
        cv  = 1;
        do @(posedge clk); while (!cr);
        @(negedge clk);
        cv = 0;
        wait (rsp);
        tick(2);
        if (status != expected_status) $fatal(1, "Profile response status");
        rspready = 1;
        tick(1);
        rspready = 0;
    endtask
    initial begin
        if (!$value$plusargs("OUT=%s", path)) $fatal(1, "missing OUT");
        fd = $fopen(path, "w");
        tick(3);
        reset = 0;
        up    = 1;
        receive_dllp(32'h08400040);
        receive_dllp(32'h08400050);
        receive_dllp(32'h00000060);
        wait (dut.flow.phase_q == 1);
        receive_dllp(32'h084000c0);
        wait (active);
        wait (cr);
        @(negedge clk);
        cv = 1;
        @(negedge clk);
        cv = 0;
        wait (tlps == 1);
        // An already validated completion must be ACKed but held for the requester
        // until the peer confirms the outbound request. Delay ACK deliberately.
        @(negedge clk);
        rv       = 1;
        rd       = 32'h0100004a;
        rl       = 0;
        response = 1;
        @(negedge clk);
        response = 0;
        tick(12);
        if (rr || rsp || !pending) $fatal(1, "Early completion bypassed ownership");
        receive_dllp(32'h00000000);
        wait (rr);
        @(posedge clk);
        @(negedge clk);
        rv = 0;
        receive_word(32'h04000001, 0);
        receive_word(32'h00000000, 0);
        receive_word(32'h1234144d, 1);
        wait (rsp);
        tick(1);
        if (status != 0 || result != 32'h1234144d || error)
            $fatal(1, "Config completion failed %d %h", status, result);
        // Exercise maximum supported application completion through the same replay
        // bank. Backpressure cannot switch a held TLP offer to a new DLLP.
        for (integer j = 0; j < 35; j = j + 1) begin
            wait (appready);
            @(negedge clk);
            av = 1;
            al = j == 34;
            ad = j == 0 ? 32'h2000004a : 32'h12340000 + j;
            @(negedge clk);
            av = 0;
        end
        txready = 0;
        tick(8);
        txready = 1;
        wait (tlps == 2);
        receive_dllp(32'h01000000);
        tick(8);
        if (pending || error) $fatal(1, "Application packet did not retire");
        // Retire the held normal response, then use local diagnostics without TLPs.
        rspready = 1;
        tick(1);
        rspready = 0;
        profile_command(0, 0, 0);
        if (result != 32'h4c505232) $fatal(1, "Local profiling magic");
        profile_command(64'h10, 1, 0);
        tick(12);
        profile_command(64'h100, 0, 2);  // live reads are explicitly rejected
        profile_command(64'h10, 0, 0);
        profile_command(64'h100, 0, 0);
        if (result == 0 || tlps != 2 || pending || error)
            $fatal(1, "Profile changed transaction path");
        $fclose(fd);
        $display(
            "PASS: FC -> config request -> early completion held until ACK -> application TLP, stable arbitration"
                );
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "Link test timeout tlps=%d active=%b error=%b", tlps, active, error);
    end
endmodule

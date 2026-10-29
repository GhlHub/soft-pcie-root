// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_gen3_packet_peer;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, valid = 0, start = 0;
    wire        ready;
    reg  [31:0] data = 0;
    reg  [ 1:0] header = 0;
    wire aligned, event_ts, ts1, ts2, error_rx, eios, stream_start, data_valid, stream;
    wire [1:0] ec, pos;
    wire [5:0] fs, lf;
    wire [31:0] symbols, decoded;
    wire [127:0] last_ts;
    wire [  3:0] diagnostic;
    wire active, eds, tlp_valid, tlp_last, response, nak, dllp, packet_error;
    wire [31:0] tlp_data, dllp_body;
    wire [ 1:0] packet_class;
    wire [ 8:0] credits;
    wire [11:0] seq;
    gen3_native_rx rx (
        clk,
        reset,
        1'b1,
        data,
        valid,
        start,
        header,
        eds,
        diagnostic[1],
        aligned,
        event_ts,
        ts1,
        ts2,
        ec,
        fs,
        lf,
        symbols,
        error_rx,
        eios,
        last_ts,
        stream_start,
        data_valid,
        decoded,
        pos,
        stream
    );
    gen3_data_rx #(
        .BUFFERED(1)
    ) packets (
        clk,
        reset,
        stream_start,
        error_rx,
        data_valid,
        decoded,
        pos,
        active,
        eds,
        tlp_data,
        tlp_valid,
        tlp_last,
        ready,
        packet_class,
        credits,
        response,
        nak,
        seq,
        dllp,
        dllp_body,
        packet_error,
        diagnostic
    );
    reg link_enable = 1;
    reg app_ready = 0, app_tx_valid = 0, app_tx_last = 0;
    reg [31:0] app_tx_data = 0;
    wire app_tx_ready, app_valid, app_last, link_active, link_error, pending;
    wire [31:0] app_data, tx_data;
    wire tx_valid, tx_last;
    gen3_link_layer link (
        .clk                (clk),
        .reset_i            (reset),
        .link_up_i          (1'b1),
        .enable_i           (link_enable),
        .rx_data_i          (tlp_data),
        .rx_valid_i         (tlp_valid),
        .rx_last_i          (tlp_last),
        .rx_ready_o         (ready),
        .rx_class_i         (packet_class),
        .rx_credits_i       (credits),
        .response_i         (response),
        .nak_i              (nak),
        .response_sequence_i(seq),
        .dllp_i             (dllp),
        .dllp_body_i        (dllp_body),
        .tx_data_o          (tx_data),
        .tx_valid_o         (tx_valid),
        .tx_last_o          (tx_last),
        .tx_ready_i         (1'b1),
        .cmd_valid_i        (1'b0),
        .cmd_ready_o        (),
        .cmd_op_i           (3'b0),
        .cmd_address_i      (64'b0),
        .cmd_bdf_i          (16'h0100),
        .cmd_data_i         (32'b0),
        .cmd_be_i           (4'hf),
        .rsp_valid_o        (),
        .rsp_ready_i        (1'b1),
        .rsp_data_o         (),
        .rsp_status_o       (),
        .app_tx_data_i      (app_tx_data),
        .app_tx_valid_i     (app_tx_valid),
        .app_tx_last_i      (app_tx_last),
        .app_tx_ready_o     (app_tx_ready),
        .app_tx_class_i     (2'b0),
        .app_tx_credits_i   (9'd1),
        .app_rx_data_o      (app_data),
        .app_rx_valid_o     (app_valid),
        .app_rx_last_o      (app_last),
        .app_rx_ready_i     (app_ready),
        .active_o           (link_active),
        .error_o            (link_error),
        .pending_o          (pending),
        .completion_debug_o (),
        .pcs_profile_i      (5'b0)
    );
    reg [4095:0] path, trace_path;
    integer fd, trace_fd, rc, op, a, b, c, row = 0;
    integer acks = 0, naks = 0, dllps = 0, phy_errors = 0, packet_errors = 0;
    always @(posedge clk) begin
        if (!reset) begin
            if (link_error) $fatal(1, "Unexpected link-layer fault");
            if (tx_valid) $fdisplay(trace_fd, "%08x %0d", tx_data, tx_last);
            if (response && nak) naks = naks + 1;
            if (response && !nak) acks = acks + 1;
            if (dllp) dllps = dllps + 1;
            if (error_rx) phy_errors = phy_errors + 1;
            if (packet_error) packet_errors = packet_errors + 1;
        end
    end
    task tick;
        @(posedge clk);
        #1;
    endtask
    initial begin
        if (!$value$plusargs("VECTORS=%s", path) || !$value$plusargs("TRACE=%s", trace_path))
            $fatal(1, "Missing peer paths");
        fd       = $fopen(path, "r");
        trace_fd = $fopen(trace_path, "w");
        if (!fd || !trace_fd) $fatal(1, "Peer file open failed");
        repeat (3) @(negedge clk);
        reset = 0;
        while (!$feof(
            fd
        )) begin
            rc = $fscanf(fd, "%d %h %h %h\n", op, a, b, c);
            if (rc != 4) $fatal(1, "Bad row %0d", row);
            row = row + 1;
            @(negedge clk);
            valid        = 0;
            app_ready    = 0;
            app_tx_valid = 0;
            case (op)
                0: begin
                    data                   = a;
                    {valid, start, header} = 4'(b);
                    tick;
                end
                1: repeat (a) tick;
                2: begin
                    app_tx_valid = 1;
                    app_tx_data  = a;
                    app_tx_last  = b != 0;
                    do @(posedge clk); while (!app_tx_ready);
                    #1;
                end
                3: begin
                    if ({link_active, pending, app_tx_ready} !== 3'(a))
                        $fatal(
                            1,
                            "Link flags row=%0d got=%b wanted=%b",
                            row,
                            {
                                link_active, pending, app_tx_ready
                            },
                            3'(a)
                        );
                    tick;
                end
                4: begin
                    repeat (3) begin
                        if (!app_valid || app_data !== 32'(a) || app_last !== (b != 0))
                            $fatal(1, "RX retained data mismatch row=%0d", row);
                        tick;
                    end
                    @(negedge clk);
                    app_ready = 1;
                    tick;
                end
                5: begin
                    if (app_valid) $fatal(1, "Unexpected delivered packet row=%0d", row);
                    tick;
                end
                6: begin
                    if (acks != a || naks != b || phy_errors != c)
                        $fatal(
                            1,
                            "RX counts row=%0d ACK=%0d NAK=%0d PHY=%0d",
                            row,
                            acks,
                            naks,
                            phy_errors
                        );
                    tick;
                end
                7: begin
                    link_enable = a != 0;
                    tick;
                end
                8: begin
                    if (phy_errors < a) $fatal(1, "Expected native PHY error not observed");
                    tick;
                end
                default: $fatal(1, "Unknown opcode");
            endcase
        end
        $fclose(fd);
        $fclose(trace_fd);
        $display("PASS: independent native packet peer rows=%0d DLLPs=%0d packet-errors=%0d", row,
                 dllps, packet_errors);
        $finish;
    end
    initial begin
        #10000000;  // Allows natural 12-bit sequence rollover without seeding DUT state.
        $fatal(1, "Native peer watchdog row=%0d", row);
    end
endmodule

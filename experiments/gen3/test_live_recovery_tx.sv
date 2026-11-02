// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_live_recovery_tx;
    parameter integer PHASE = 1;
    reg clk = 0;
    always #2 clk = ~clk;
    reg reset = 1, stream = 1, stop = 0;
    reg [31:0] packet[0:20];
    integer index = 0, fd, cycle = 0, ts_count = 0;
    reg offer = 0;
    wire ready, submit, fault, valid, start, ts_done, stopped;
    wire [31:0] data;
    wire [ 1:0] header;
    reg [4095:0] vector_path, trace_path;
    gen3_recovery_tx dut (
        .clk             (clk),
        .reset_i         (reset),
        .enable_i        (1'b1),
        .stop_i          (stop),
        .ts2_i           (1'b0),
        .stream_i        (stream),
        .ec_i            (2'b0),
        .preset_i        (4'd4),
        .first_i         (6'd0),
        .second_i        (6'd40),
        .post_i          (6'd0),
        .data_o          (data),
        .valid_o         (valid),
        .start_o         (start),
        .ts_done_o       (ts_done),
        .stopped_o       (stopped),
        .header_o        (header),
        .balance_o       (),
        .ts2_done_o      (),
        .eieos_done_o    (),
        .idle_word_o     (),
        .initfc1_i       (1'b0),
        .packet_data_i   (packet[index]),
        .packet_valid_i  (offer),
        .packet_last_i   (index == 20),
        .packet_ready_o  (ready),
        .packet_submit_o (submit),
        .packet_fault_o  (fault),
        .profile_events_o(),
        .eq_fields_i     (32'b0),
        .reset_interval_i(1'b0)
    );
    always @(posedge clk)
        if (!reset && offer && ready) begin
            if (index == 20) offer <= 0;
            else index <= index + 1;
        end
    always @(negedge clk)
        if (!reset) begin
            $fdisplay(fd, "%0d %0d %0d %0d %08x", cycle, valid, start, header, data);
            cycle = cycle + 1;
            if (ts_done) ts_count = ts_count + 1;
            if (fault) $fatal(1, "Recovery interrupted an active packet");
        end
    initial begin
        if (!$value$plusargs("VECTORS=%s", vector_path) || !$value$plusargs("TRACE=%s", trace_path))
            $fatal(1, "Missing paths");
        $readmemh(vector_path, packet);
        fd = $fopen(trace_path, "w");
        repeat (4) @(negedge clk);
        reset = 0;
        offer = 1;
        wait (index == PHASE);
        @(negedge clk);
        stream = 0;
        wait (ts_count >= 16);
        @(negedge clk);
        stream = 1;
        repeat (80) @(negedge clk);
        stop = 1;
        wait (stopped);
        repeat (3) @(negedge clk);
        if (offer) $fatal(1, "Packet not drained");
        $fclose(fd);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "TX Recovery watchdog");
    end
endmodule

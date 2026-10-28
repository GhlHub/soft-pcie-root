// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps
module test_tx_gearbox;
    reg clk = 0;
    always #2 clk = !clk;
    reg reset_i = 1, valid = 0, ready = 0;
    reg [127:0] payload = 0;
    reg [  1:0] header = 0;
    wire in_ready, out_valid;
    wire [31:0] data;
    reg         serial_bits[0:133119];  // 1024 independently serialized blocks
    integer head = 0, tail = 0, sent = 0, received = 0, cycle = 0, bit_no;
    reg [31:0] random_q = 32'h31415926;
    reg        accepted;
    reg        was_stalled = 0;
    reg [31:0] stalled_data;
    gen3_tx_gearbox dut (
        clk,
        reset_i,
        payload,
        header,
        valid,
        in_ready,
        data,
        out_valid,
        ready
    );
    task random_step;
        begin
            random_q = random_q ^ (random_q << 13);
            random_q = random_q ^ (random_q >> 17);
            random_q = random_q ^ (random_q << 5);
        end
    endtask
    always @(posedge clk) begin
        if (!reset_i) begin
            if (sent > 0 && sent < 512 && !out_valid)
                $fatal(1, "bubble during continuously supplied stream");
            if (was_stalled && (!out_valid || data !== stalled_data))
                $fatal(1, "stalled output changed");
            was_stalled  = out_valid && !ready;
            stalled_data = data;
            if (out_valid && ready) begin
                if (tail - head < 32) $fatal(1, "output without enough accepted input");
                for (bit_no = 0; bit_no < 32; bit_no = bit_no + 1)
                if (data[bit_no] !== serial_bits[head+bit_no])
                    $fatal(1, "wire bit mismatch at %0d", head + bit_no);
                head     = head + 32;
                received = received + 1;
            end
            if (valid && in_ready) begin
                serial_bits[tail]   = header[0];
                serial_bits[tail+1] = header[1];
                for (bit_no = 0; bit_no < 128; bit_no = bit_no + 1)
                serial_bits[tail+2+bit_no] = payload[bit_no];
                tail = tail + 130;
                sent = sent + 1;
            end
        end
    end
    initial begin
        @(negedge clk);
        reset_i = 0;
        while (received < 4160) begin
            // Keep offers stable until accepted. Source and sink stalls vary
            // independently. First 512 blocks exercise continuous streaming.
            if (!valid) begin
                random_step();
                valid = (sent < 1024) && ((sent < 512) || random_q[0]);
                if (valid) begin
                    header = sent[0] ? 2'b01 : 2'b10;
                    random_step();
                    payload[31:0] = random_q;
                    random_step();
                    payload[63:32] = random_q;
                    random_step();
                    payload[95:64] = random_q;
                    random_step();
                    payload[127:96] = random_q;
                end
            end
            random_step();
            ready = (sent < 512) || random_q[1];
            @(posedge clk);
            accepted = valid && in_ready;
            #1;
            // A new offer is chosen at the next falling edge only if this one
            // was accepted on the preceding edge.
            if (accepted) valid = 0;
            @(negedge clk);
            cycle = cycle + 1;
            if (cycle > 20000) $fatal(1, "timeout");
        end
        valid = 0;
        ready = 1;
        if (sent != 1024 || head != tail) $fatal(1, "missing or duplicated bits");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (out_valid) $fatal(1, "unexpected trailing word");
            @(negedge clk);
        end
        reset_i = 1;
        @(posedge clk);
        #1;
        if (out_valid) $fatal(1, "reset failed");
        $display("PASS: 1024 blocks, 133120 independent wire bits, stalls and drain");
        $finish;
    end
endmodule

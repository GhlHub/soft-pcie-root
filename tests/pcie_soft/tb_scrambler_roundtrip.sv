`timescale 1ns / 1ps
module tb_scrambler_roundtrip;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, s_valid = 0;
    reg [15:0] s_data = 0;
    reg [1:0] s_ctrl = 0, s_keep = 0;
    wire s_ready, encoded_valid, encoded_ready, decoded_valid;
    wire [15:0] encoded, decoded;
    wire [1:0] encoded_ctrl, encoded_keep, decoded_ctrl, decoded_keep;
    wire [15:0] tx_state, rx_state;
    reg  [31:0] noise = 32'h48ba6a97;
    wire        sink_ready = noise[0] && noise[3];
    pcie_soft_scrambler tx (
        clk,
        rst_n,
        s_data,
        s_ctrl,
        s_keep,
        2'b11,
        s_valid,
        s_ready,
        encoded,
        encoded_ctrl,
        encoded_keep,
        encoded_valid,
        encoded_ready,
        tx_state
    );
    pcie_soft_scrambler rx (
        clk,
        rst_n,
        encoded,
        encoded_ctrl,
        encoded_keep,
        2'b11,
        encoded_valid,
        encoded_ready,
        decoded,
        decoded_ctrl,
        decoded_keep,
        decoded_valid,
        sink_ready,
        rx_state
    );
    reg [19:0] expected[0:5999];
    integer written = 0, read_count = 0, i;
    always @(negedge clk) noise <= {noise[30:0], noise[31] ^ noise[21] ^ noise[1] ^ noise[0]};
    always @(posedge clk)
        if (rst_n) begin
            if (s_valid && s_ready) begin
                expected[written] = {s_data, s_ctrl, s_keep};
                written           = written + 1;
            end
            if (decoded_valid && sink_ready) begin
                if (read_count >= written ||
                    {decoded, decoded_ctrl, decoded_keep} !== expected[read_count])
                    $fatal(1, "Roundtrip mismatch %0d", read_count);
                read_count = read_count + 1;
            end
        end
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (i = 0; i < 6000; i = i + 1) begin
            @(negedge clk);
            s_valid = 1;
            s_data  = noise[15:0];
            s_ctrl  = noise[17:16];
            s_keep  = noise[19:18];
            if (i % 11 == 0) begin
                s_data = 16'h1cbc;
                s_ctrl = 3;
            end
            do begin
                @(posedge clk);
            end while (!s_ready);
            @(negedge clk);
            s_valid = 0;
        end
        wait (read_count == 6000);
        @(negedge clk);
        if (tx_state !== rx_state) $fatal(1, "Roundtrip state mismatch after drain");
        $display("PASS SCRAMBLER RTL roundtrip 6000 words with independent backpressure");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Roundtrip watchdog");
    end
endmodule

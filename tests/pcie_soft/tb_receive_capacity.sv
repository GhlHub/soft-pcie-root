`timescale 1ns / 1ps
// Receiver capacity/ownership test, independent normal-polynomial wire CRC.
module tb_receive_capacity;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst = 0, reset_link = 0, valid = 0, ready = 0;
    reg [15:0] symbols = 0;
    reg [ 1:0] control = 0;
    wire [31:0] data, dllp;
    wire tv, last, response, nak, dv, error;
    wire [ 1:0] cls;
    wire [ 8:0] credits;
    wire [11:0] seq;
    pcie_soft_packet_rx dut (
        clk,
        rst,
        reset_link,
        symbols,
        control,
        valid,
        1'b0,
        data,
        tv,
        last,
        ready,
        cls,
        credits,
        response,
        nak,
        seq,
        dv,
        dllp,
        error
    );
    reg [8:0] bytes_q[0:255];
    integer count = 0, errors = 0, naks = 0;
    always @(posedge clk)
        if (rst) begin
            if (error) errors = errors + 1;
            if (response && nak) naks = naks + 1;
        end
    function [31:0] swap(input [31:0] x);
        swap = {x[7:0], x[15:8], x[23:16], x[31:24]};
    endfunction
    function [31:0] reverse32(input [31:0] x);
        for (integer n = 0; n < 32; n = n + 1) reverse32[n] = x[31-n];
    endfunction
    function [31:0] crc(input [31:0] c, input [7:0] x);
        reg [31:0] v;
        begin
            v = c;
            for (integer n = 0; n < 8; n = n + 1)
            v = (v << 1) ^ ((v[31] ^ x[n]) ? 32'h04c11db7 : 0);
            crc = v;
        end
    endfunction
    function integer words(input integer id);
        words = id % 3 == 0 ? 35 : id % 3 == 1 ? 3 : 4;
    endfunction
    function [31:0] word_at(input integer id, input integer idx);
        if (idx == 0)
            word_at = swap(id % 3 == 0 ? 32'h40000020 : id % 3 == 1 ? 32'h00000020 : 32'h4a000001);
        else word_at = 32'(id * 256 + idx);
    endfunction
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task send_packet(input integer id, input integer sequence_number);
        reg [31:0] c, w;
        reg [7:0] x;
        begin
            count      = 3;
            bytes_q[0] = 9'h1fb;
            bytes_q[1] = {1'b0, 4'b0, 4'(sequence_number >> 8)};
            bytes_q[2] = {1'b0, 8'(sequence_number)};
            c          = crc(crc(32'hffffffff, bytes_q[1][7:0]), bytes_q[2][7:0]);
            for (integer n = 0; n < words(id); n = n + 1) begin
                w = word_at(id, n);
                for (integer b = 0; b < 4; b = b + 1) begin
                    x              = w[b*8+:8];
                    bytes_q[count] = {1'b0, x};
                    count          = count + 1;
                    c              = crc(c, x);
                end
            end
            c = ~reverse32(c);
            for (integer b = 0; b < 4; b = b + 1) begin
                bytes_q[count] = {1'b0, c[b*8+:8]};
                count          = count + 1;
            end
            bytes_q[count] = 9'h1fd;
            count          = count + 1;
            for (integer n = 0; n < count; n = n + 2) begin
                @(negedge clk);
                valid   = 1;
                symbols = {bytes_q[n+1][7:0], bytes_q[n][7:0]};
                control = {bytes_q[n+1][8], bytes_q[n][8]};
            end
            @(negedge clk);
            valid = 0;
            cycles(3);
        end
    endtask
    task drain(input integer id);
        begin
            for (integer n = 0; n < words(id); n = n + 1) begin
                @(negedge clk);
                ready = 0;
                if (!tv || data !== word_at(
                        id, n
                    ) || last !== (n == words(
                        id
                    ) - 1) || cls !== 2'(id % 3) ||
                        credits !== (id % 3 == 0 ? 9'd8 : id % 3 == 1 ? 9'd0 : 9'd1))
                    $fatal(
                        1,
                        "Stored packet corrupt id=%0d word=%0d data=%h class=%d",
                        id,
                        n,
                        data,
                        cls
                    );
                cycles(2);
                @(negedge clk);
                ready = 1;
                cycles(1);
            end
            @(negedge clk);
            ready = 0;
        end
    endtask
    integer base = 0;
    initial begin
        cycles(3);
        @(negedge clk);
        rst = 1;
        repeat (3) begin
            for (integer n = 0; n < 16; n = n + 1) send_packet(base + n, base + n);
            if (dut.occupied_q != 16 || errors != base / 17) $fatal(1, "Capacity/fill error");
            // Deliberate over-credit traffic must NAK without corrupting owned RAM.
            send_packet(base + 16, base + 16);
            if (dut.occupied_q != 16 || naks != base / 17 + 1 || errors != base / 17 + 1)
                $fatal(1, "Overflow protection");
            for (integer n = 0; n < 16; n = n + 1) drain(base + n);
            if (tv || dut.occupied_q != 0) $fatal(1, "Drain ownership leak");
            send_packet(base + 16, base + 16);
            drain(base + 16);
            base = base + 17;
        end
        send_packet(base, base);
        @(negedge clk);
        reset_link = 1;
        cycles(2);
        if (tv || dut.occupied_q != 0) $fatal(1, "Reset retained validity");
        @(negedge clk);
        reset_link = 0;
        send_packet(0, 0);
        drain(0);
        $display(
            "PASS RECEIVE CAPACITY: 16 mixed slots, stalls, overflow/NAK, retry, pointer wrap, reset ownership"
                );
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Receiver capacity watchdog");
    end
endmodule

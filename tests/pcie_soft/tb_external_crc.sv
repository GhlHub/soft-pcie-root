`timescale 1ns / 1ps
module tb_external_crc;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0, clear = 0, valid = 0;
    reg  [15:0] data = 0;
    wire [31:0] crc32;
    wire [15:0] crc16;
    pcie_soft_crc dut (
        clk,
        rst_n,
        clear,
        valid,
        data,
        2'b11,
        crc32,
        crc16
    );
    integer fd, rc, count = 0;
    reg [31:0] word_data, expected32;
    reg [  15:0] expected16;
    reg [2047:0] path;
    initial begin
        if (!$value$plusargs("VECTORS=%s", path)) $fatal(1, "Missing vectors");
        fd = $fopen(path, "r");
        if (!fd) $fatal(1, "Cannot open vectors");
        repeat (3) @(negedge clk);
        rst_n = 1;
        while (!$feof(
            fd
        )) begin
            rc = $fscanf(fd, "%h %h %h\n", word_data, expected32, expected16);
            if (rc != 3) $fatal(1, "Malformed vector");
            @(negedge clk);
            data  = word_data[15:0];
            valid = 1;
            clear = 1;
            @(negedge clk);
            data  = word_data[31:16];
            clear = 0;
            @(posedge clk);
            #1;
            if (crc32 !== expected32 || crc16 !== expected16)
                $fatal(
                    1,
                    "External CRC mismatch %0d data=%08x got=%08x/%04x expected=%08x/%04x",
                    count,
                    word_data,
                    crc32,
                    crc16,
                    expected32,
                    expected16
                );
            count = count + 1;
        end
        $display("PASS external PCIe CRC32/CRC16: %0d DWORDs", count);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "External CRC watchdog");
    end
endmodule

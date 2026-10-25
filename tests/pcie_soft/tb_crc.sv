`timescale 1ns/1ps
module tb_crc;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n, clear_i, valid_i;
    reg [15:0] data_i;
    reg [1:0] keep_i;
    wire [31:0] lcrc;
    wire [15:0] dllp_crc;
    pcie_soft_crc dut(clk,rst_n,clear_i,valid_i,data_i,keep_i,lcrc,dllp_crc);
    integer fd, rc, cycle=0, reset_value, clear_value, valid_value;
    reg [31:0] expected32;
    reg [15:0] expected16;
    reg [2047:0] path;
    initial begin
        if (!$value$plusargs("VECTORS=%s",path)) $fatal(1,"Missing VECTORS");
        fd=$fopen(path,"r");
        if (!fd) $fatal(1,"Cannot open vectors");
        while (!$feof(fd)) begin
            @(negedge clk);
            rc=$fscanf(fd,"%d %d %d %h %h %h %h\n",reset_value,clear_value,
                       valid_value,data_i,keep_i,expected32,expected16);
            if (rc!=7) $fatal(1,"Malformed vector at cycle %0d",cycle);
            rst_n=reset_value!=0; clear_i=clear_value!=0;valid_i=valid_value!=0;
            @(posedge clk); #1;
            if (lcrc!==expected32 || dllp_crc!==expected16)
                $fatal(1,"CRC cycle %0d: got %08x/%04x expected %08x/%04x",
                       cycle,lcrc,dllp_crc,expected32,expected16);
            cycle=cycle+1;
        end
        $display("PASS CRC %0d cycles",cycle);
        $finish;
    end
    initial begin #1000000; $fatal(1,"Timeout"); end
endmodule

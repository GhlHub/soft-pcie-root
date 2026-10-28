`timescale 1ns / 1ps
module tb_scrambler;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n, valid_i, ready_i;
    reg [15:0] data_i;
    reg [1:0] ctrl_i, keep_i, scramble_i;
    wire ready_o, valid_o;
    wire [15:0] data_o, lfsr;
    wire [1:0] ctrl_o, keep_o;
    pcie_soft_scrambler dut (
        clk,
        rst_n,
        data_i,
        ctrl_i,
        keep_i,
        scramble_i,
        valid_i,
        ready_o,
        data_o,
        ctrl_o,
        keep_o,
        valid_o,
        ready_i,
        lfsr
    );
    integer fd, rc, cycle = 0, reset_value, valid_value, ready_value, exp_valid;
    reg [15:0] exp_data, exp_lfsr;
    reg [1:0] exp_ctrl, exp_keep;
    reg [2047:0] path;
    initial begin
        if (!$value$plusargs("VECTORS=%s", path)) $fatal(1, "Missing VECTORS");
        fd = $fopen(path, "r");
        if (!fd) $fatal(1, "Cannot open vectors");
        while (!$feof(
            fd
        )) begin
            @(negedge clk);
            rc = $fscanf(
                fd,
                "%d %d %d %h %h %h %h %d %h %h %h %h\n",
                reset_value,
                valid_value,
                ready_value,
                data_i,
                ctrl_i,
                keep_i,
                scramble_i,
                exp_valid,
                exp_data,
                exp_ctrl,
                exp_keep,
                exp_lfsr
            );
            if (rc != 12) $fatal(1, "Malformed vector %0d", cycle);
            rst_n   = reset_value != 0;
            valid_i = valid_value != 0;
            ready_i = ready_value != 0;
            @(posedge clk);
            #1;
            if (valid_o !== (exp_valid != 0) || lfsr !== exp_lfsr)
                $fatal(
                    1,
                    "Scrambler state/valid mismatch at %0d: %04x expected %04x",
                    cycle,
                    lfsr,
                    exp_lfsr
                );
            if (exp_valid && {data_o, ctrl_o, keep_o} !== {exp_data, exp_ctrl, exp_keep})
                $fatal(
                    1,
                    "Scrambler payload mismatch at %0d: %04x expected %04x",
                    cycle,
                    data_o,
                    exp_data
                );
            cycle = cycle + 1;
        end
        $display("PASS SCRAMBLER %0d cycles", cycle);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Timeout");
    end
endmodule

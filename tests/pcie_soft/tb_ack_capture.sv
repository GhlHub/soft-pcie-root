`timescale 1ns / 1ps
module tb_ack_capture;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst = 0, lr = 0, event_valid = 0, nak = 0, ready = 0;
    reg [11:0] seq = 0, base = 12'hffe;
    reg [10:0] sent = 4;
    wire valid, out_nak, error;
    wire [11:0] out_seq;
    wire [15:0] age;
    pcie_soft_ack_capture dut (
        clk,
        rst,
        lr,
        event_valid,
        nak,
        seq,
        base,
        sent,
        valid,
        ready,
        out_nak,
        out_seq,
        age,
        error
    );
    integer        errors = 0;
    reg     [15:0] saved_age;
    always @(posedge clk) if (rst && error) errors = errors + 1;
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task put(input [11:0] s, input n);
        @(negedge clk);
        seq         = s;
        nak         = n;
        event_valid = 1;
        @(negedge clk);
        event_valid = 0;
        cycles(1);
    endtask
    initial begin
        cycles(3);
        @(negedge clk);
        rst = 1;
        put(12'hfff, 0);
        put(0, 1);
        put(1, 0);
        put(0, 1);
        if (!valid || out_seq !== 1 || out_nak) $fatal(1, "Cumulative wrap/coalescing");
        cycles(4);
        saved_age = age;
        put(1, 1);
        if (!out_nak || age <= saved_age) $fatal(1, "Duplicate discarded original age/NAK");
        put(12'h100, 0);
        if (out_seq !== 1 || !out_nak) $fatal(1, "Invalid future response replaced pending event");
        put(2, 0);
        if (out_seq !== 2 || out_nak) $fatal(1, "Forward progress did not supersede NAK");
        cycles(65540);
        if (age !== 16'hffff) $fatal(1, "Event age wrapped rather than saturated");
        @(negedge clk);
        ready       = 1;
        seq         = 2;
        event_valid = 1;
        nak         = 0;
        @(negedge clk);
        ready       = 0;
        event_valid = 0;
        base        = 2;
        sent        = 0;
        cycles(2);
        if (!valid || out_seq !== 2) $fatal(1, "Concurrent consumption/arrival lost event");
        @(negedge clk);
        ready = 1;
        @(negedge clk);
        ready = 0;
        cycles(2);
        put(2, 0);
        if (!valid || out_seq !== 2) $fatal(1, "Reset/current ACKD_SEQ duplicate rejected");
        lr = 1;
        cycles(2);
        if (valid) $fatal(1, "Link reset retained event");
        if (errors != 1) $fatal(1, "Protocol error reporting");
        $display(
            "PASS ACK capture: arrival without READY, cumulative wrap, NAK supersession, invalid event, age saturation, concurrent pop/push, link reset"
                );
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Capture watchdog");
    end
endmodule

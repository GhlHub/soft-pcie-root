`timescale 1ns / 1ps
// Vendor secure-IP simulation; requires generated pcie_gen1_gt, not Icarus.
module tb_phy_runtime;
    reg passed = 0;
    reg mgmt = 0, refclk = 0, reset = 1, eidle = 0, sidle = 0, target = 0;
    always #10 mgmt = ~mgmt;
    always #5 refclk = ~refclk;
    wire txp, txn, core, ready, applied, rate_ready, rate_fault;
    pcie_soft_gth dut (
        .freerun_clk_i     (mgmt),
        .reset_i           (reset),
        .refclk_p_i        (refclk),
        .refclk_n_i        (!refclk),
        .rx_p_i            (txp),
        .rx_n_i            (txn),
        .tx_p_o            (txp),
        .tx_n_o            (txn),
        .core_clk_o        (core),
        .tx_data_i         (16'h4a4a),
        .tx_ctrl_i         (2'b0),
        .detect_i          (1'b0),
        .electrical_idle_i (eidle),
        .polarity_i        (1'b0),
        .rx_data_o         (),
        .rx_ctrl_o         (),
        .rx_valid_o        (),
        .rx_error_o        (),
        .ready_o           (ready),
        .detect_done_o     (),
        .receiver_present_o(),
        .rx_idle_o         (),
        .diagnostic_o      (),
        .target_gen2_i     (target),
        .speed_idle_i      (sidle),
        .gen2_o            (applied),
        .rate_ready_o      (rate_ready),
        .rate_fault_o      (rate_fault),
        .deemphasis_i      (1'b0)
    );
    task check_period(input realtime expected);
        realtime a, b;
        repeat (12) begin
            @(posedge core);
            a = $realtime;
            @(posedge core);
            b = $realtime;
            if (b - a < expected - 0.01 || b - a > expected + 0.01)
                $fatal(1, "PHY period %0.3f expected %0.3f", b - a, expected);
        end
    endtask
    task change(input bit gen2);
        @(negedge mgmt);
        eidle = 1;
        sidle = 1;
        #1000;
        target = gen2;
        wait (!rate_ready);
        wait (rate_ready);
        #1;
        if (applied != gen2 || rate_fault || !ready) $fatal(1, "PHY rate completion failed");
        check_period(gen2 ? 4.0 : 8.0);
        @(negedge mgmt);
        eidle = 0;
        sidle = 0;
        #10000;
    endtask
    initial begin
        #1000;
        reset = 0;
        wait (ready);
        #10000;
        check_period(8.0);
        change(1);
        change(0);
        change(1);
        passed = 1;
        $display(
            "PASS vendor PHY runtime: production wrapper, 125->250->125->250MHz, electrical idle P0 and acknowledged rate control"
                );
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "PHY rate watchdog ready=%b rate_ready=%b fault=%b applied=%b", ready,
               rate_ready, rate_fault, applied);
    end
endmodule

# SPDX-License-Identifier: Apache-2.0
"""Native two-lane PIPE mapping and fresh receiver/power acknowledgements."""
import pytest

from test_multilane import GEN3, simulate


@pytest.mark.parametrize('scenario', ['success', 'missing-receiver', 'stale-status', 'lost-phy'])
@pytest.mark.parametrize('first_lane', [0, 1])
def test_legacy_x2_pipe_detect(tmp_path, scenario, first_lane):
    success = scenario == 'success'
    peer_status = 0 if scenario == 'missing-receiver' else 3
    simulate(tmp_path, f'''
module tb;
reg clk = 0; always #4 clk = ~clk;
reg rst_n = 0, seek = 0;
reg [1:0] ready = 3, status = 3, valid = 3;
reg [5:0] rxstatus = 0;
wire detect, failed;
wire [1:0] rxvalid, rxerror, powerdown, done, present;
wire [31:0] rx;
wire [127:0] tx;
gen3_legacy_x2_pipe #(.TIMEOUT_CYCLES(40)) dut(
    clk, rst_n, seek, ready, status, valid, rxstatus,
    128'hf00dbabe55aa3456_beefabcd3210fedc, 32'h56781234, rx, tx,
    rxvalid, rxerror, detect, powerdown, done, present, failed);
task tick;
    @(posedge clk); #1; @(negedge clk);
endtask
initial begin
    repeat (2) tick();
    rst_n = 1;
    seek = 1;
    repeat (3) begin
        tick();
        if (detect || done || rxvalid || powerdown != 2)
            $fatal(1, "Initial PHYSTATUS leaked into Detect");
    end
    if ({int(scenario == 'stale-status')}) begin
        repeat (41) tick();
        if (!failed || detect || done || rxvalid || powerdown != 2)
            $fatal(1, "Stale PHY did not fail closed");
    end else begin
        status = 0; tick();
        if (!detect || powerdown != 2) $fatal(1, "Detect did not use P1");
        status[{first_lane}] = 1;
        rxstatus[{3*first_lane}+:3] = 3;
        tick();
        if (!detect || done || rxvalid || powerdown != 2)
            $fatal(1, "One detect reply qualified both lanes");
        repeat (3) tick();
        status[{1-first_lane}] = 1;
        rxstatus[{3*(1-first_lane)}+:3] = {peer_status};
        tick();
        if ({int(scenario == 'missing-receiver')}) begin
            if (detect || !failed || powerdown != 2 || done !== 3 ||
                present !== 2'd{1 << first_lane} || rxvalid)
                $fatal(1, "Missing lane was accepted");
        end else begin
            if (detect || failed || done || powerdown != 2 || rxvalid)
                $fatal(1, "Detect replies were mistaken for P0");
            status[{first_lane}] = 0;
            repeat (4) tick();
            if (powerdown != 2 || done) $fatal(1, "Entered P0 with stale status");
            status = 0; tick();
            if (powerdown != 0 || done || rxvalid) $fatal(1, "Missing P0 request");
            status[{1-first_lane}] = 1; tick();
            if (done || rxvalid) $fatal(1, "One P0 acknowledgement enabled RX");
            status = 0; tick();
            ready[{first_lane}] = {int(success)};
            status[{first_lane}] = 1; tick();
            if ({int(success)}) begin
                if (powerdown != 0 || done != 3 || present != 3 || rxvalid != 3 || failed)
                    $fatal(1, "Two confirmed lanes did not enter P0");
                seek = 0; status = 0; rxstatus = 6'b101010; tick();
                if (rx !== 32'h3456fedc ||
                    tx !== 128'h0000000000005678_0000000000001234 ||
                    rxerror !== 2'b10 || done || powerdown != 0)
                    $fatal(1, "Incorrect legacy word/error mapping");
            end else if (!failed || done || rxvalid || powerdown != 2)
                $fatal(1, "PHY loss during P0 accepted stale RX");
        end
    end
    $display("PASS"); $finish;
end
initial begin #10000; $fatal(1, "timeout"); end
endmodule
''', [GEN3 / 'gen3_legacy_x2_pipe.sv'])


@pytest.mark.parametrize('scenario', ['success', 'missing-ack', 'stale-status', 'lost-tx-idle'])
@pytest.mark.parametrize('first_lane', [0, 1])
def test_native_x2_rate_change(tmp_path, scenario, first_lane):
    simulate(tmp_path, f'''
module tb;
reg clk = 0; always #4 clk = ~clk;
reg rst_n = 0, request = 0, tx_idle = 0;
reg [1:0] target = 1, idle = 0, ready = 3, phystatus = 3;
wire request_ready, rate_ready, busy, failed;
wire [1:0] phy_rate, applied_rate;
gen3_native_x2_rate #(.IDLE_CYCLES(3), .TIMEOUT_CYCLES(28)) dut(
    clk, rst_n, request, target, request_ready, tx_idle, idle, ready, phystatus,
    phy_rate, applied_rate, rate_ready, busy, failed);
task tick;
    @(posedge clk); #1; @(negedge clk);
endtask
initial begin
    repeat (2) tick();
    rst_n = 1; request = 1; tick();
    if (request_ready || !rate_ready || busy || phy_rate != 0)
        $fatal(1, "Rate command accepted while packets could still be transmitted");
    tx_idle = 1; idle = 2'b01; tick(); request = 0;
    repeat (5) tick();
    if (phy_rate != 0 || !busy || rate_ready)
        $fatal(1, "Rate command issued while a peer lane was active");
    idle = 3;
    repeat (6) tick();
    if (phy_rate != 0 || rate_ready || failed) $fatal(1, "A stale PHYSTATUS was used");
    if ({int(scenario == 'stale-status')}) begin
        repeat (21) tick();
        if (!failed || rate_ready || phy_rate != 0)
            $fatal(1, "Stale PHYSTATUS did not block the Rate command through timeout");
    end else begin
        phystatus = 0; tick();
        if (phy_rate != 1 || !busy || applied_rate != 0 || rate_ready)
            $fatal(1, "No Gen2 request or stale timing acceptance");
        phystatus[{first_lane}] = 1;
        ready[{1-first_lane}] = 0;
        tick(); phystatus = 0;
        repeat (2) tick();
        if (rate_ready || applied_rate != 0) $fatal(1, "Single-lane acknowledgement");
        if ({int(scenario == 'missing-ack')}) begin
            ready = 3;
            repeat (21) tick();
            if (!failed || rate_ready || phy_rate != 1 || applied_rate != 0)
                $fatal(1, "Rate timeout did not preserve the issued and applied rates");
        end else if ({int(scenario == 'lost-tx-idle')}) begin
            tx_idle = 0; ready = 3; phystatus = 3; tick();
            if (!failed || rate_ready || phy_rate != 1 || applied_rate != 0)
                $fatal(1, "Lost transmit idle was ignored");
        end else begin
            idle = 0;
            phystatus[{1-first_lane}] = 1; tick(); phystatus = 0;
            if (rate_ready || applied_rate != 0) $fatal(1, "Unready PHY accepted");
            ready = 3; tick();
            if (!rate_ready || applied_rate != 1 || failed || busy)
                $fatal(1, "Separate fresh acknowledgements did not complete Gen2 change");
            request = 1; tick(); request = 0;
            if (busy || !rate_ready || applied_rate != 1)
                $fatal(1, "Same-rate request disturbed the operating PHY");
            target = 2; idle = 3; request = 1; tick(); request = 0;
            repeat (5) tick();
            if (phy_rate != 2 || rate_ready || applied_rate != 1)
                $fatal(1, "Second rate change reused earlier acknowledgements");
            phystatus = 3; tick();
            if (!rate_ready || applied_rate != 2 || failed || busy)
                $fatal(1, "Gen3 request did not complete with fresh acknowledgements");
        end
    end
    $display("PASS"); $finish;
end
initial begin #10000; $fatal(1, "timeout"); end
endmodule
''', [GEN3 / 'gen3_native_x2_rate.sv'])


@pytest.mark.parametrize('scenario', ['success', 'stale-done', 'missing-apply', 'missing-query', 'lost-idle'])
def test_gen3_x2_phase_zero_replies(tmp_path, scenario):
    simulate(tmp_path, f'''
module tb;
reg clk=0; always #4 clk=~clk;
reg reset=1, request=0, tx_idle=1;
reg [1:0] rx_idle=1, done=3;
reg [35:0] coeff=0;
wire [35:0] stored_coeff;
wire [11:0] fs,lf;
wire [3:0] control;
wire ready,failed;
gen3_x2_initial_eq #(.GUARD_CYCLES(2),.TIMEOUT_CYCLES(34)) dut(
 .clk(clk),.reset_i(reset),.request_i(request),.tx_idle_i(tx_idle),
 .rx_idle_i(rx_idle),.phy_ready_i(2'b11),.txeq_done_i(done),
 .phy_fs_i({{6'd39,6'd40}}),.phy_lf_i({{6'd15,6'd12}}),.phy_coeff_i(coeff),
 .txeq_ctrl_o(control),.ready_o(ready),.failed_o(failed),
 .local_fs_o(fs),.local_lf_o(lf),.initial_coeff_o(stored_coeff));
task tick; @(negedge clk); endtask
task expect_failure;
    repeat(40) tick();
    if (!failed || ready || control!=0)
        $fatal(1,"Invalid Phase 0 reply did not quarantine the attempt");
endtask
initial begin
    repeat(2) tick(); reset=0; request=1;
    repeat(5) tick();
    if (control!=0 || ready) $fatal(1,"Phase 0 command while a lane could still be active");
    rx_idle=3;
    repeat(5) tick();
    if (control!=0 || ready) $fatal(1,"Phase 0 accepted stale TXEQDONE");
    if ({int(scenario == 'stale-done')}) expect_failure();
    else begin
        done=0; tick();
        if (control!=4'b0101 || ready) $fatal(1,"Expected a preset command on both lanes");
        done=1; tick();
        if (control!=4'b0100 || ready) $fatal(1,"Missing lane-1 apply was ignored");
        if ({int(scenario == 'missing-apply')}) expect_failure();
        else if ({int(scenario == 'lost-idle')}) begin
            tx_idle=0; done=3; tick();
            if (!failed || ready || control!=0) $fatal(1,"Phase 0 continued past loss of TX idle");
        end else begin
            done=2; tick();
            repeat(4) tick();
            if (control!=0 || ready) $fatal(1,"Stale apply completion satisfied the query guard");
            done=0; wait(control==4'b1111); tick();
            coeff[35:18]=18'h3edcb;
            done=2; tick(); done=0;
            if (control!=4'b0011 || ready) $fatal(1,"Missing lane-0 query was ignored");
            if ({int(scenario == 'missing-query')}) expect_failure();
            else begin
                coeff={{18'h03e0f,18'h1a2b3}};
                done=1; tick();
                if (!ready || failed || control!=0 || stored_coeff!={{18'h3edcb,18'h1a2b3}} ||
                    fs!={{6'd39,6'd40}} || lf!={{6'd15,6'd12}})
                    $fatal(1,"Fresh independent Phase 0 coefficient replies were not retained");
            end
        end
    end
    $display("PASS Phase 0 reply barrier"); $finish;
end
initial begin #10000; $fatal(1,"Phase 0 watchdog"); end
endmodule
''', [GEN3 / 'gen3_x2_initial_eq.sv'])

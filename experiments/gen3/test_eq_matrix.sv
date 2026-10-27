// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Behavioral control-plane experiments, not an analog channel model.
module test_eq_matrix;
    parameter integer SETTLE = 2;
    localparam integer DEADLINE = SETTLE + 64;
    reg clk=0; always #2 clk=~clk;
    reg rst=1, enter=0, cancel=0, skip_phase23=0;
    reg phy_gen3_ready=1, preset_applied=0, rx_aligned=1;
    reg rx_ts_event=0, rx_ts1_valid=1;
    reg [1:0] rx_ec=1;
    reg [3:0] applied_preset=0;
    reg [31:0] rx_symbols6_9=32'h00103001;
    wire active, tx_ts1_valid, go_rcvrlock, go_phase2, go_speed;
    wire phase1_success, phase2_success, phase3_success, complete, phases23_skipped, failed;
    wire [1:0] tx_ec;
    wire [3:0] tx_preset;
    wire [5:0] tx_fs, tx_lf, tx_post, peer_fs, peer_lf;
    wire [2:0] failure_reason;
    wire [15:0] ts_events;
    gen3_eq_phase1 #(.TIMEOUT_CYCLES(DEADLINE),.SETTLE_CYCLES(SETTLE)) dut (
        .clk(clk),.rst(rst),.enter(enter),.cancel(cancel),.skip_phase23(skip_phase23),
        .phy_gen3_ready(phy_gen3_ready),.preset_applied(preset_applied),
        .applied_preset(applied_preset),.applied_fs(6'd40),.applied_lf(6'd12),.applied_post(6'd0),
        .rx_aligned(rx_aligned),.rx_ts_event(rx_ts_event),.rx_ts1_valid(rx_ts1_valid),
        .rx_ec(rx_ec),.rx_symbols6_9(rx_symbols6_9),.rx_fs(6'd48),.rx_lf(6'd16),
        .active(active),.tx_ts1_valid(tx_ts1_valid),.tx_ec(tx_ec),.tx_preset(tx_preset),
        .tx_fs(tx_fs),.tx_lf(tx_lf),.tx_post(tx_post),.peer_fs(peer_fs),.peer_lf(peer_lf),
        .go_rcvrlock(go_rcvrlock),.go_phase2(go_phase2),.go_speed(go_speed),
        .phase1_success(phase1_success),.phase2_success(phase2_success),
        .phase3_success(phase3_success),.complete(complete),
        .phases23_skipped(phases23_skipped),.failed(failed),
        .failure_reason(failure_reason),.ts_events(ts_events));
    integer p, policy, delay_index, delay_cycles, scenario, cycles, cases=0;
    integer expected_events, expected_reason;
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task ts; begin rx_ts_event=1; tick; rx_ts_event=0; end endtask
    task still_active; begin if(!active || failed) $fatal(1,"premature result case %0d",cases); end endtask
    initial begin
        tick; rst=0;
        for(p=0;p<=10;p=p+1)
        for(policy=0;policy<2;policy=policy+1)
        for(delay_index=0;delay_index<4;delay_index=delay_index+1)
        for(scenario=0;scenario<9;scenario=scenario+1)begin
            case(delay_index) 0:delay_cycles=0; 1:delay_cycles=1;
                2:delay_cycles=7; default:delay_cycles=17; endcase
            applied_preset=4'(p); skip_phase23=1'(policy);
            phy_gen3_ready=(scenario!=8); preset_applied=0;
            rx_aligned=(scenario!=6); rx_ts1_valid=1; rx_ec=1;
            rx_symbols6_9=32'h00103001; expected_events=0; expected_reason=0;
            enter=1; tick; enter=0;
            if(ts_events!=0 || failure_reason!=0 || complete || failed)
                $fatal(1,"attempt diagnostics not cleared");
            repeat(delay_cycles)begin
                tick; if(tx_ts1_valid) $fatal(1,"transmit before preset ack");
            end
            preset_applied=(scenario!=5);
            tick; preset_applied=0; // Acknowledge is a pulse, not a ready level.
            repeat(SETTLE+1)tick;
            if(scenario!=5 && scenario!=8)begin
                if(!tx_ts1_valid || tx_preset!=4'(p) || tx_ec!=1 ||
                    tx_fs!=40 || tx_lf!=12 || tx_post!=0)
                    $fatal(1,"preset advertisement");
                applied_preset=4'((p+1)%11); skip_phase23=!1'(policy);
                tick;
                if(tx_preset!=4'(p))$fatal(1,"settings not latched");
            end
            if(scenario<5)begin
                ts; expected_events=1; still_active;
                case(scenario)
                    1:begin // Changed symbols require a fresh matching pair.
                        rx_symbols6_9=32'h00103011; ts;
                        expected_events=2; still_active;
                    end
                    2:begin
                        rx_ts1_valid=0; ts; rx_ts1_valid=1;
                        ts; expected_events=3; still_active;
                    end
                    3:begin
                        rx_aligned=0; tick; rx_aligned=1;
                        ts; expected_events=2; still_active;
                    end
                    4:begin
                        phy_gen3_ready=0; tick; expected_reason=5;
                    end
                    default:begin
                        // No TS events during permitted intervening OS/gaps.
                        repeat(3)tick; still_active;
                    end
                endcase
                if(scenario!=4)begin ts; expected_events=expected_events+1; end
            end else begin
                case(scenario) 5:expected_reason=2; 6:expected_reason=3;
                    7:expected_reason=4; 8:expected_reason=1; endcase
                cycles=0;
                while(active && cycles<=DEADLINE)begin tick; cycles=cycles+1; end
            end
            if(active || ts_events!=16'(expected_events) || failure_reason!=3'(expected_reason))
                $fatal(1,"diagnostics case %0d scenario %0d",cases,scenario);
            if(expected_reason!=0)begin
                if(!go_speed || !failed || !complete || phase1_success || go_rcvrlock || go_phase2)
                    $fatal(1,"failure did not request fallback");
            end else begin
                if(failed || !phase1_success || go_speed || peer_fs!=48 || peer_lf!=16 ||
                    go_rcvrlock!=1'(policy) || go_phase2==1'(policy) ||
                    complete!=1'(policy) || phases23_skipped!=1'(policy) ||
                    phase2_success!=1'(policy) || phase3_success!=1'(policy))
                    $fatal(1,"wrong policy handoff");
            end
            tick;
            if(go_speed || go_phase2 || go_rcvrlock)$fatal(1,"result pulse repeated");
            if(failure_reason!=3'(expected_reason))$fatal(1,"diagnostic not sticky");
            cases=cases+1;
        end
        $display("PASS: equalization matrix settle=%0d cases=%0d",SETTLE,cases);
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule

// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module test_tx_path;
    reg mgmt_clk=0;always #10 mgmt_clk=~mgmt_clk;
    reg user_clk=0,fast=0;
    always begin if(fast)#2;else #4;user_clk=~user_clk;end
    reg mgmt_reset_i=1,user_reset_i=1,req_valid_i=0;reg [1:0] req_rate_i=0;
    wire req_ready_o;
    reg rate_idle_i=1,user_gen3_ready_i=0;
    reg pll_lock_i=1,tx_reset_done_i=1,rx_reset_done_i=1;
    reg data_enable_i=0;
    reg [31:0] packet_data_i=0;reg packet_valid_i=0,packet_last_i=0;
    reg [15:0] packet_id_i=16'h1234;
    wire packet_ready_o,packet_done_o;wire [15:0] packet_done_id_o;
    wire [31:0] tx_data_o;wire tx_valid_o,tx_start_o;wire [1:0] tx_header_o;
    wire submit_o;wire [31:0] submit_token_o;
    reg complete_i=0;reg [31:0] complete_token_i=0;
    reg [7:0] physical_pipeline=0;
    wire wire_empty_i=physical_pipeline==0 && !tx_valid_o;
    reg legacy_drained_i=1;
    wire electrical_idle_o,quiesce_o;wire [2:0] txrate_o,rxrate_o;
    wire electrical_idle_ack_i=electrical_idle_o;
    wire [1:0] applied_rate_o;wire applied_valid_o,rate_done_o,rate_fault_o,busy_o;
    wire [3:0] rate_fault_reason_o;wire transport_fault_o,stopped_o,clock_sample_o;
    wire [15:0] clock_edges_o;
    gen3_tx_path #(.TIMEOUT_CYCLES(160),.IDLE_HOLD_CYCLES(3),.STABLE_CYCLES(3),
        .WINDOW_CYCLES(16),.GEN1_EDGES(40),.FAST_EDGES(80),.TOLERANCE(3),
        .SKP_INTERVAL(4)) dut(.*);
    reg [2:0] observed_rate=0;
    integer changing=0,submissions=0,done_packets=0;
    reg [31:0] captured_token;
    reg [15:0] last_done_id;
    // Independent behavioral PHY model; not an AMD GT timing model.
    always @(posedge mgmt_clk) begin
        if(mgmt_reset_i)begin
            observed_rate<=0;rate_idle_i<=1;user_gen3_ready_i<=0;changing<=0;fast<=0;
        end else if(txrate_o!=observed_rate)begin
            if(!electrical_idle_o || !wire_empty_i || dut.pending)
                $fatal(1,"rate changed before physical drain");
            observed_rate<=txrate_o;rate_idle_i<=0;changing<=5;
        end else if(changing!=0)begin
            changing<=changing-1;
            if(changing==1)begin
                rate_idle_i<=1;user_gen3_ready_i<=(observed_rate==2);fast<=(observed_rate!=0);
            end
        end
    end
    always @(posedge user_clk)begin
        if(user_reset_i)physical_pipeline<=0;
        else begin
            physical_pipeline<={physical_pipeline[6:0],tx_valid_o};
            if(submit_o)begin submissions=submissions+1;captured_token=submit_token_o;end
            if(packet_done_o)begin done_packets=done_packets+1;last_done_id=packet_done_id_o;end
            if(electrical_idle_o && tx_valid_o)$fatal(1,"electrical idle over active PCS");
        end
    end
    task utick;begin @(posedge user_clk);#0.1;@(negedge user_clk);end endtask
    task mtick;begin @(posedge mgmt_clk);#0.1;@(negedge mgmt_clk);end endtask
    task request(input [1:0] r);begin
        while(!req_ready_o)mtick;
        req_rate_i=r;req_valid_i=1;mtick;req_valid_i=0;
    end endtask
    task wait_rate(input [1:0] r);begin
        while(!rate_done_o && !rate_fault_o)mtick;
        if(rate_fault_o || applied_rate_o!=r || !applied_valid_o)$fatal(1,"rate change failed");
        mtick;
    end endtask
    task word(input integer i,input bit last);begin
        while(!packet_ready_o)utick;
        packet_data_i=32'h01000000+32'(i);packet_valid_i=1;packet_last_i=last;utick;
        packet_valid_i=0;packet_last_i=0;
    end endtask
    task complete_packet;begin
        complete_token_i=captured_token;complete_i=1;utick;complete_i=0;repeat(2)utick;
    end endtask
    task cold_reset;begin
        mgmt_reset_i=1;user_reset_i=1;data_enable_i=0;
        repeat(4)mtick;mgmt_reset_i=0;user_reset_i=0;repeat(4)mtick;
    end endtask
    initial begin
        cold_reset;request(2);wait_rate(2);data_enable_i=1;
        word(0,0);word(1,0);
        request(1); // Recovery requested with a partially collected packet.
        word(2,0);word(3,1);
        while(submissions<1)utick;
        repeat(20)utick;
        if(done_packets!=0 || txrate_o!=2 || electrical_idle_o)$fatal(1,"early release/rate change");
        complete_packet;wait_rate(1);
        if(done_packets!=1 || last_done_id!=16'h1234 || transport_fault_o)$fatal(1,"packet identity");
        data_enable_i=0;
        // Immediately ask for another change: old drain ack must clear first.
        request(0);wait_rate(0);request(2);wait_rate(2);data_enable_i=1;
        packet_id_i=16'h5678;word(0,0);word(1,1);
        while(submissions<2)utick;
        if(captured_token!=1)$fatal(1,"token reused across Recovery");
        request(1);
        // The old completion token must never release this new packet.
        complete_token_i=0;complete_i=1;utick;complete_i=0;
        repeat(4)utick;
        if(!transport_fault_o || done_packets!=1 || !dut.pending)$fatal(1,"stale token released RAM");
        while(!rate_fault_o)mtick;
        if(electrical_idle_o || txrate_o!=2 || !dut.scheduler.full)$fatal(1,"fault lost ownership");
        $display("PASS: integrated TX/CDC/rate changes, physical drain, retained tokens and stale-completion quarantine");
        $finish;
    end
    initial begin #100000;$fatal(1,"watchdog");end
endmodule

// SPDX-License-Identifier: Apache-2.0
// Management-clock controller for an already initialized native PCIe PHY.
// Rates: 0=Gen1, 1=Gen2, 2=Gen3. No PLL/GT/global datapath reset on rate change.
// req_* and drain/idle/clock acknowledgements must be synchronous here. Their
// CDC bridges must hold requests until acknowledged; pulses are not CDC-safe.
module gen3_phy_rate #(
    parameter integer TIMEOUT_CYCLES=50000,
    parameter integer IDLE_HOLD_CYCLES=50,
    parameter integer STABLE_CYCLES=8
)(
    input wire clk, reset_i,
    input wire req_valid_i, input wire [1:0] req_rate_i,
    output wire req_ready_o,
    input wire drained_i, electrical_idle_ack_i,
    // Native asynchronous status levels, synchronized below.
    input wire rate_idle_i, user_gen3_ready_i, pll_lock_i,
    input wire tx_reset_done_i, rx_reset_done_i,
    // Ack from clock observer: requested rate's clocks are active/stable.
    // Must go low after clock_check_o drops, high only for new clock_check_o.
    input wire clocks_ready_i,
    output wire quiesce_o, electrical_idle_o, clock_check_o,
    output reg [1:0] gt_rate_o, applied_rate_o,
    output reg applied_valid_o, done_o, fault_o,
    output reg [3:0] fault_reason_o,
    output wire busy_o
);
    localparam [2:0] IDLE=0,DRAIN=1,EI=2,ARM=3,CHANGE=4,CLOCK=5,FAILED=6;
    localparam integer TW=(TIMEOUT_CYCLES>1)?$clog2(TIMEOUT_CYCLES):1;
    localparam integer HW=(IDLE_HOLD_CYCLES>1)?$clog2(IDLE_HOLD_CYCLES+1):1;
    localparam integer SW=(STABLE_CYCLES>1)?$clog2(STABLE_CYCLES+1):1;
    reg [2:0] state;
    reg [1:0] target;
    reg [TW-1:0] timer;
    reg [HW-1:0] hold_count;
    reg [SW-1:0] stable_count;
    reg saw_busy;
    (* ASYNC_REG="TRUE" *) reg [1:0] rate_sync,gen3_sync,pll_sync,tx_sync,rx_sync;
    wire healthy=pll_sync[1] && tx_sync[1] && rx_sync[1] &&
                 (gen3_sync[1] == (target==2));
    assign req_ready_o=state==IDLE && !reset_i;
    assign busy_o=state!=IDLE && state!=FAILED;
    assign quiesce_o=state!=IDLE;
    // A drain timeout MUST NOT truncate an accepted packet by asserting idle.
    reg idle_held;
    assign electrical_idle_o=idle_held;
    assign clock_check_o=state==CLOCK;
    initial begin
        if (TIMEOUT_CYCLES<2 || IDLE_HOLD_CYCLES<1 || STABLE_CYCLES<1)
            $fatal(1,"Invalid PHY sequencing timing");
    end
    always @(posedge clk) begin
        if(reset_i) begin
            state<=IDLE; target<=0; gt_rate_o<=0; applied_rate_o<=0;
            applied_valid_o<=0; done_o<=0; fault_o<=0; fault_reason_o<=0;
            timer<=0; hold_count<=0; stable_count<=0; saw_busy<=0; idle_held<=0;
            rate_sync<=0;gen3_sync<=0;pll_sync<=0;tx_sync<=0;rx_sync<=0;
        end else begin
            rate_sync<={rate_sync[0],rate_idle_i};
            gen3_sync<={gen3_sync[0],user_gen3_ready_i};
            pll_sync<={pll_sync[0],pll_lock_i};
            tx_sync<={tx_sync[0],tx_reset_done_i};
            rx_sync<={rx_sync[0],rx_reset_done_i};
            done_o<=0;
            if(state==IDLE) begin
                timer<=0;
                if(req_valid_i) begin
                    if(req_rate_i==3) begin
                        fault_o<=1; fault_reason_o<=1; state<=FAILED; applied_valid_o<=0;
                    end else begin target<=req_rate_i; state<=DRAIN; end
                end
            end else if(state!=FAILED) begin
                if(state!=DRAIN && state!=EI && !electrical_idle_ack_i) begin
                    state<=FAILED; fault_o<=1; applied_valid_o<=0; fault_reason_o<=9;
                end else if(timer==TW'(TIMEOUT_CYCLES-1)) begin
                    state<=FAILED; fault_o<=1; applied_valid_o<=0;
                    fault_reason_o<={1'b0,state}+4'd2;
                end else begin
                    timer<=timer+1'b1;
                    case(state)
                        DRAIN: if(drained_i) begin
                            idle_held<=1; state<=EI; timer<=0; hold_count<=0;
                        end
                        EI: begin
                            if(!electrical_idle_ack_i) hold_count<=0;
                            else if(hold_count==HW'(IDLE_HOLD_CYCLES-1)) begin
                                state<=ARM; timer<=0;
                            end else hold_count<=hold_count+1'b1;
                        end
                        // Require idle baseline and a cleared clock ack BEFORE
                        // issuing the new rate; stale busy/high cannot complete it.
                        ARM: if(rate_sync[1] && !clocks_ready_i) begin
                            gt_rate_o<=target; applied_valid_o<=0;
                            saw_busy<=0; stable_count<=0; timer<=0;
                            if(target==gt_rate_o) state<=CLOCK;
                            else state<=CHANGE;
                        end
                        CHANGE: begin
                            if(!rate_sync[1]) saw_busy<=1;
                            if(saw_busy && rate_sync[1] && healthy) begin
                                state<=CLOCK; timer<=0; stable_count<=0;
                            end
                        end
                        CLOCK: begin
                            if(!healthy || !rate_sync[1] || !clocks_ready_i)
                                stable_count<=0;
                            else if(stable_count==SW'(STABLE_CYCLES-1)) begin
                                applied_rate_o<=target; applied_valid_o<=1;
                                done_o<=1; state<=IDLE; idle_held<=0;
                            end else stable_count<=stable_count+1'b1;
                        end
                        default: state<=FAILED;
                    endcase
                end
            end
        end
    end
endmodule

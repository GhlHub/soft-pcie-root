// SPDX-License-Identifier: Apache-2.0
// Independent management-clock measurement of a possibly stopped user clock.
// Constrain Gray bus max delay/skew to one observed-clock period at integration.
// Resets are synchronous in their respective domains; only cold reset is valid.
module gen3_clock_watch #(
    parameter integer WINDOW_CYCLES=256,
    parameter integer GEN1_EDGES=640,
    parameter integer FAST_EDGES=1280,
    parameter integer TOLERANCE=8
)(
    input wire user_clk, user_reset_i, mgmt_clk, reset_i,
    input wire check_i, input wire [1:0] rate_i,
    output reg ready_o, output reg sample_o,
    output reg [15:0] measured_o
);
    reg [15:0] count, gray;
    (* ASYNC_REG="TRUE" *) reg [15:0] gray_meta,gray_sync;
    reg [15:0] binary, previous;
    localparam integer W=(WINDOW_CYCLES>1)?$clog2(WINDOW_CYCLES):1;
    reg [W-1:0] timer;
    reg [1:0] saved_rate;
    reg armed, good_previous;
    wire [15:0] delta=binary-previous;
    wire [15:0] expected_edges=(saved_rate==0)?16'(GEN1_EDGES):16'(FAST_EDGES);
    wire good=delta>=expected_edges-16'(TOLERANCE) &&
              delta<=expected_edges+16'(TOLERANCE) && saved_rate!=3;
    always @* begin
        binary[15]=gray_sync[15];
        for(integer i=14;i>=0;i=i-1) binary[i]=binary[i+1]^gray_sync[i];
    end
    always @(posedge user_clk) begin
        if(user_reset_i) begin count<=0; gray<=0; end
        else begin count<=count+1'b1; gray<=((count+16'd1)>>1)^(count+16'd1); end
    end
    always @(posedge mgmt_clk) begin
        if(reset_i) begin
            gray_meta<=0;gray_sync<=0;previous<=0;timer<=0;
            saved_rate<=0;armed<=0;good_previous<=0;ready_o<=0;sample_o<=0;
        end else begin
            gray_meta<=gray;gray_sync<=gray_meta;sample_o<=0;
            if(!check_i || !armed || saved_rate!=rate_i) begin
                previous<=binary;timer<=0;saved_rate<=rate_i;
                armed<=check_i;good_previous<=0;ready_o<=0;
            end else if(timer==W'(WINDOW_CYCLES-1)) begin
                measured_o<=delta;sample_o<=1;previous<=binary;timer<=0;
                good_previous<=good;ready_o<=good && good_previous;
            end else timer<=timer+1'b1;
        end
    end
endmodule

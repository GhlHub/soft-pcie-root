// SPDX-License-Identifier: Apache-2.0
// Registered, lossless DLLP formatter. The output is two framed DWORDs.
// Acceptance captures the whole body; only output handshake advances ownership.
module gen3_dllp_source(
    input wire clk,reset_i,
    input wire [31:0] body_i,input wire valid_i,output wire ready_o,
    output wire [31:0] data_o,output wire valid_o,last_o,input wire ready_i
);
    reg occupied,second;
    reg [63:0] frame;
    function automatic [15:0] crc16(input [31:0] value);
        reg [15:0] c;
        begin
            c=16'hffff;
            for(integer b=0;b<32;b=b+1)c=(c>>1)^((c[0]^value[b])?16'hd008:0);
            crc16=~c;
        end
    endfunction
    assign ready_o=!occupied && !reset_i;
    assign valid_o=occupied;
    assign last_o=second;
    assign data_o=second?frame[63:32]:frame[31:0];
    always @(posedge clk)begin
        if(reset_i)begin occupied<=0;second<=0;end
        else begin
            if(valid_i && ready_o)begin frame<={crc16(body_i),body_i,16'hacf0};occupied<=1;end
            if(valid_o && ready_i)begin
                second<=!second;
                if(second)occupied<=0;
            end
        end
    end
endmodule

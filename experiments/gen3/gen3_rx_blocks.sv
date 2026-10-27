// SPDX-License-Identifier: Apache-2.0
// Experimental RAW x1 receive block acquisition/extraction, bit 0 first.
// valid_i pauses delivery without omitting serial bits. No backpressure:
// downstream must accept every block_valid_o pulse. reset_i/restart_i discard
// only physical coding state, never packet, replay, credit, or AXI ownership.
// Blocks remain scrambled; SKP parity, training/DC balance and data-stream
// framing validation belong downstream. Polarity must already be corrected.
module gen3_rx_blocks (
    input wire clk, reset_i, restart_i, valid_i,
    input wire [31:0] data_i,
    output reg aligned_o, locked_o,
    output reg block_valid_o, error_o,
    output reg [1:0] header_o,
    output reg [191:0] payload_o,
    output reg [4:0] symbols_o
);
    localparam [127:0] SDS = {{15{8'h55}},8'he1};
    wire anchor;
    wire [4:0] anchor_end;
    reg [31:0] word_q;
    reg word_valid_q;
    // Parallel search runs independently; locked extraction ignores matches.
    gen3_eieos_detect detector(clk, reset_i || restart_i, 1'b1, valid_i,
                               data_i, anchor, anchor_end);
    reg [224:0] buffer_q, buffer_n;
    reg [7:0] count_q, count_n;
    reg expect_q, expect_n;
    reg aligned_n, locked_n, emit_n, error_n;
    reg [1:0] header_n;
    reg [191:0] payload_n;
    reg [4:0] symbols_n;
    reg [7:0] needed;
    reg skp, terminated, bad_skp;
    integer k;
    always @* begin
        buffer_n=buffer_q; count_n=count_q; expect_n=expect_q;
        aligned_n=aligned_o; locked_n=locked_o;
        emit_n=0; error_n=0;
        header_n=0; payload_n=0; symbols_n=0;
        needed=130; skp=0; terminated=0; bad_skp=0;
        if(word_valid_q) begin
            if(anchor && !locked_o) begin
                buffer_n={193'b0,word_q} >> (int'(anchor_end)+1);
                count_n=8'd31-{3'b0,anchor_end};
                aligned_n=1; locked_n=0; expect_n=0;
                emit_n=1; header_n=1; symbols_n=16;
                payload_n={64'b0,{8{16'hff00}}};
            end else if(aligned_o) begin
                buffer_n[count_q +: 32]=word_q;
                count_n=count_q+8'd32;
                if(buffer_n[1:0]==0 || buffer_n[1:0]==3 ||
                   (expect_q && buffer_n[1:0]!=2)) begin
                    error_n=1;
                end else begin
                    expect_n=0;
                    skp=buffer_n[1:0]==1 && buffer_n[9:2]==8'haa;
                    if(skp) begin
                        needed=194;
                        for(k=1;k<=20;k=k+1) begin
                            if(!terminated && int'(count_n)>=2+8*(k+1)) begin
                                if(buffer_n[2+8*k +: 8]==8'he1 && k%4==0) begin
                                    terminated=1; needed=8'(2+8*(k+4));
                                end else if(buffer_n[2+8*k +: 8]!=8'haa || k==20)
                                    bad_skp=1;
                            end
                        end
                    end
                    if(bad_skp) error_n=1;
                    else if(count_n>=needed && (!skp || terminated)) begin
                        emit_n=1; header_n=buffer_n[1:0];
                        symbols_n=5'((int'(needed)-2)/8);
                        for(k=0;k<24;k=k+1)
                            if(k<int'(symbols_n)) payload_n[8*k +: 8]=buffer_n[2+8*k +: 8];
                        buffer_n=buffer_n >> needed;
                        count_n=count_n-needed;
                        if(header_n==1 && !skp && payload_n[127:0]==SDS) begin
                            locked_n=1; expect_n=1;
                        end
                    end
                end
            end
                // A completed block may leave the next header in this word.
                if(emit_n && count_n>=2) begin
                    if(buffer_n[1:0]==0 || buffer_n[1:0]==3 ||
                       (expect_n && buffer_n[1:0]!=2)) error_n=1;
                    else expect_n=0;
                    if(buffer_n[1:0]==1 && count_n>=18 && buffer_n[9:2]==8'haa &&
                       buffer_n[17:10]!=8'haa) error_n=1;
                    if(buffer_n[1:0]==1 && count_n>=26 && buffer_n[9:2]==8'haa &&
                       buffer_n[25:18]!=8'haa) error_n=1;
                end
                if(error_n) begin
                    aligned_n=0; locked_n=0; count_n=0; expect_n=0;
                end

        end
    end
    always @(posedge clk) begin
        if(reset_i || restart_i) begin
            aligned_o<=0; locked_o<=0; block_valid_o<=0; error_o<=0;
            count_q<=0; expect_q<=0; word_valid_q<=0;
        end else begin
            word_valid_q<=valid_i;
            if(valid_i) word_q<=data_i;
            count_q<=count_n; expect_q<=expect_n;
            aligned_o<=aligned_n; locked_o<=locked_n;
            block_valid_o<=emit_n; error_o<=error_n;
            if(word_valid_q) buffer_q<=buffer_n;
            if(emit_n) begin header_o<=header_n; payload_o<=payload_n; symbols_o<=symbols_n; end
        end
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
// DWORD-rate token parser with a sixteen-byte circular ingress buffer.
// Tokens are aligned once and decoded in parallel; payload drains one DWORD
// per clock. Finish and the following STP may coincide. Payload storage is
// unreset. All outputs remain provisional until the downstream packet gate.
module gen3_stream_buffered_rx (
    input wire clk, reset_i, stream_start_i, abort_i, valid_i,
    input wire [31:0] data_i,
    input wire [1:0] position_i,
    output reg active_o, error_o, eds_o, start_o,
    output reg [10:0] length_o,
    output reg [11:0] sequence_o,
    output reg [31:0] body_o,
    output reg [2:0] body_bytes_o,
    output reg body_last_o, finish_o, nullified_o, dllp_o,
    output reg [47:0] dllp_bytes_o
);
    localparam [1:0] TOKEN=0,BODY=1,AFTER=2;
    reg [1:0] mode, next_mode, write_pointer;
    reg [3:0] read_pointer;
    reg [4:0] count;
    reg [12:0] remaining,next_remaining;
    reg [31:0] memory[0:3];
    reg [1:0] positions[0:3];
    reg [2:0] prefix;
    wire [1:0] row0=read_pointer[3:2],row1=row0+2'd1,row2=row0+2'd2,row3=row0+2'd3;
    // Per-byte {nullification, token, DLLP, zero} classification, written
    // atomically with data. Like payload RAM, metadata is never reset.
    reg [15:0] metadata[0:3];
    wire [63:0] metadata_window={metadata[row3],metadata[row2],metadata[row1],metadata[row0]} >> (4*read_pointer[1:0]);
    wire [3:0] pointer_four=read_pointer+4'd4;
    wire [3:0] pointer_token=read_pointer+4'(prefix)+4'd4;
    wire [3:0] pointer_dllp=read_pointer+4'(prefix)+4'd8;
    reg [3:0] next_read_pointer;
    reg [1:0] token_metadata;
    wire [127:0] window={memory[row3],memory[row2],memory[row1],memory[row0]} >> (8*read_pointer[1:0]);
    reg [63:0] token_window;
    reg [31:0] token;
    reg [10:0] token_length;
    reg [3:0] crc,token_pointer;
    reg [4:0] consumed;
    reg [4:0] next_count;
    reg err,eds,start,body,last,finish,nullified,dllp;
    function automatic [3:0] fcrc(input [10:0] len);
        begin
            fcrc[0]=^(len & 11'h4d7);fcrc[1]=^(len & 11'h6bc);
            fcrc[2]=^(len & 11'h35e);fcrc[3]=^(len & 11'h1af);
        end
    endfunction
    always @* begin
        prefix=0;
        if(metadata_window[0])begin
            prefix=1;
            if(metadata_window[4])begin
                prefix=2;
                if(metadata_window[8])begin prefix=3;if(metadata_window[12])prefix=4;end
            end
        end
    end
    always @* begin
        next_mode=mode;next_remaining=remaining;consumed=0;next_read_pointer=read_pointer;
        err=0;eds=0;start=0;body=0;last=0;finish=0;nullified=0;dllp=0;
        token_window=64'(window >> (8*prefix));
        token_metadata=2'(metadata_window >> (4*prefix+1));
        token=token_window[31:0];token_length={token[14:8],token[7:4]};crc=fcrc(token_length);
        token_pointer=read_pointer+4'(prefix);
        if(active_o && count>=4)begin
            if(mode==BODY)begin
                consumed=4;next_read_pointer=pointer_four;body=1;next_remaining=remaining-4;
                if(remaining==4)begin last=1;next_mode=AFTER;end
            end else if(mode==AFTER && metadata_window[3])begin
                consumed=4;next_read_pointer=pointer_four;finish=1;nullified=1;next_mode=TOKEN;
                if(window[31:0]!=32'hc0c0c0c0)err=1;
            end else begin
                // Classify the next token while completing the preceding TLP.
                // This removes an extra cycle between back-to-back packets.
                if(mode==AFTER)begin finish=1;next_mode=TOKEN;end
                if(prefix==4)begin consumed=4;next_read_pointer=pointer_four;end
                else if(token_metadata[0])begin
                    if(count>=5'(prefix)+8)begin
                        consumed=5'(prefix)+8;next_read_pointer=pointer_dllp;dllp=1;
                        if(token[15:8]!=8'hac)err=1;
                    end
                end else if(token_metadata[1])begin
                    if(count>=5'(prefix)+4)begin
                        consumed=5'(prefix)+4;next_read_pointer=pointer_token;
                        if(token==32'h0090801f)begin
                            eds=1;
                            if(token_pointer[1:0]!=0 || positions[token_pointer[3:2]]!=3)err=1;
                        end else begin
                            start=1;next_mode=BODY;next_remaining=({2'b0,token_length}-1'b1)<<2;
                            if(token_length<2 || token_length>=1152 || token[23:20]!=crc ||
                               token[15]!=^{token_length,crc})err=1;
                        end
                    end
                end else err=1;
            end
        end
        next_count=count+5'(valid_i && active_o ? 4:0)-consumed;
        // Every nonzero drain consumes at least four bytes. Therefore an
        // arriving DWORD can overflow only when fewer than four slots remain
        // and nothing drains. Avoid putting the count adder/subtractor ahead
        // of every event-valid signal.
        if(count>16 || (valid_i && active_o && count>12 && consumed==0))err=1;
        if(err)begin start=0;body=0;last=0;finish=0;nullified=0;dllp=0;eds=0;end
    end
    always @(posedge clk)begin
        if(!reset_i && !abort_i && !stream_start_i && active_o && valid_i)begin
            memory[write_pointer]<=data_i;positions[write_pointer]<=position_i;
            for(integer lane=0;lane<4;lane=lane+1)begin
                metadata[write_pointer][4*lane+:4]<={
                    data_i[8*lane+:8]==8'hc0, data_i[8*lane+:4]==4'hf,
                    data_i[8*lane+:8]==8'hf0, data_i[8*lane+:8]==0};
            end
        end
        if(reset_i || abort_i || stream_start_i)begin
            active_o<=!reset_i && !abort_i && stream_start_i;
            error_o<=0;eds_o<=0;start_o<=0;body_bytes_o<=0;body_last_o<=0;
            finish_o<=0;nullified_o<=0;dllp_o<=0;
            mode<=TOKEN;write_pointer<=0;read_pointer<=0;count<=0;remaining<=0;
        end else begin
            error_o<=active_o && err;eds_o<=eds;start_o<=start;
            body_bytes_o<=body?3'd4:3'd0;body_last_o<=last;
            finish_o<=finish;nullified_o<=nullified;dllp_o<=dllp;
            if(active_o)begin
                if(err || eds)begin active_o<=0;count<=0;end
                else count<=next_count[4:0];
                // These ingress-only cursors may advance on the quarantine
                // edge. No event escapes on err, active_o falls, and the next
                // validated SDS reinitializes them. Keep token validation out
                // of the ingress RAM write-enable and cursor enable paths.
                read_pointer<=next_read_pointer;
                if(valid_i)write_pointer<=write_pointer+1'b1;
                mode<=next_mode;remaining<=next_remaining;
            end
            // Payload registers have independent valid strobes. Updating
            // inactive data removes validation fanout from wide clock enables.
            length_o<=token_length;sequence_o<={token[19:16],token[31:24]};
            body_o<=window[31:0];
            dllp_bytes_o<=token_window[63:16];
        end
    end
endmodule

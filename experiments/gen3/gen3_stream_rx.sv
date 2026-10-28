// SPDX-License-Identifier: Apache-2.0
// Gen3 x1 DATA-stream token parser. Input is four consecutive descrambled
// symbols; position_i is the DWORD index within the 16-symbol Data Block.
// Ordered sets do not enter here. stream_start_i marks a validated SDS; the
// block-transition controller must enforce EDS/OS/Data sequencing externally.
// Outputs are provisional: the packet layer must retain all bytes until both
// CRC/length validation and finish_o. No memory or credit side effect here.
module gen3_stream_rx (
    input wire clk, reset_i, stream_start_i, abort_i, valid_i,
    input wire [31:0] data_i,
    input wire [1:0] position_i,
    output reg active_o, error_o, eds_o,
    output reg start_o,
    output reg [10:0] length_o,
    output reg [11:0] sequence_o,
    output reg [31:0] body_o,
    output reg [2:0] body_bytes_o,
    output reg body_last_o, finish_o, nullified_o,
    output reg dllp_o,
    output reg [47:0] dllp_bytes_o
);
    localparam [2:0] TOKEN = 0, STP = 1, SDP = 2, BODY = 3, DLLP = 4, AFTER = 5, EDB = 6;
    reg [2:0] mode_q, mode_n, used_q, used_n;
    reg [31:0] token_q, token_n;
    reg [47:0] dllp_q, dllp_n;
    reg [12:0] remaining_q, remaining_n;
    reg active_n, error_n, eds_n, start_n, last_n, finish_n, null_n, dllp_valid_n;
    reg [10:0] length_n, token_length;
    reg     [11:0] sequence_n;
    reg     [31:0] body_n;
    reg     [ 2:0] body_bytes_n;
    reg     [ 7:0] octet;
    reg     [ 3:0] crc;
    integer        i;
    function automatic [3:0] fcrc(input [10:0] len);
        begin
            fcrc[0] = ^(len & 11'h4d7);
            fcrc[1] = ^(len & 11'h6bc);
            fcrc[2] = ^(len & 11'h35e);
            fcrc[3] = ^(len & 11'h1af);
        end
    endfunction
    always @* begin
        mode_n       = mode_q;
        used_n       = used_q;
        token_n      = token_q;
        dllp_n       = dllp_q;
        remaining_n  = remaining_q;
        active_n     = active_o;
        error_n      = 0;
        eds_n        = 0;
        start_n      = 0;
        last_n       = 0;
        finish_n     = 0;
        null_n       = 0;
        dllp_valid_n = 0;
        length_n     = length_o;
        sequence_n   = sequence_o;
        body_n       = 0;
        body_bytes_n = 0;
        octet        = 0;
        crc          = 0;
        token_length = 0;
        if (valid_i && active_o) begin
            for (i = 0; i < 4; i = i + 1) begin
                octet = data_i[8*i+:8];
                if (active_n) begin
                    if (mode_n == AFTER) begin
                        if (octet == 8'hc0) begin
                            mode_n = EDB;
                            used_n = 0;
                        end else begin
                            finish_n = 1;
                            mode_n   = TOKEN;
                        end
                    end
                    case (mode_n)
                        TOKEN: begin
                            used_n  = 1;
                            token_n = {24'b0, octet};
                            if (octet == 0) used_n = 0;
                            else if (octet[3:0] == 4'hf) mode_n = STP;
                            else if (octet == 8'hf0) mode_n = SDP;
                            else error_n = 1;
                        end
                        STP: begin
                            token_n[8*used_n+:8] = octet;
                            used_n               = used_n + 1'b1;
                            if (used_n == 4) begin
                                token_length = {token_n[14:8], token_n[7:4]};
                                crc          = fcrc(token_length);
                                if (token_n == 32'h0090801f) begin
                                    if (position_i != 3 || i != 3) error_n = 1;
                                    else begin
                                        eds_n    = 1;
                                        active_n = 0;
                                        mode_n   = TOKEN;
                                    end
                                end else begin
                                    if (token_length < 2 || token_length >= 1152 || token_n[
                                        23:20] != crc || token_n[15] != ^{token_length, crc})
                                        error_n = 1;
                                    start_n     = 1;
                                    length_n    = token_length;
                                    sequence_n  = {token_n[19:16], token_n[31:24]};
                                    remaining_n = ({2'b0, token_length} - 13'd1) << 2;
                                    mode_n      = BODY;
                                end
                                used_n = 0;
                            end
                        end
                        SDP: begin
                            if (octet != 8'hac) error_n = 1;
                            mode_n = DLLP;
                            used_n = 0;
                        end
                        BODY: begin
                            body_n[8*body_bytes_n+:8] = octet;
                            body_bytes_n              = body_bytes_n + 1'b1;
                            remaining_n               = remaining_n - 1'b1;
                            if (remaining_n == 0) begin
                                last_n = 1;
                                mode_n = AFTER;
                            end
                        end
                        DLLP: begin
                            dllp_n[8*used_n+:8] = octet;
                            used_n              = used_n + 1'b1;
                            if (used_n == 6) begin
                                dllp_valid_n = 1;
                                used_n       = 0;
                                mode_n       = TOKEN;
                            end
                        end
                        EDB: begin
                            if (octet != 8'hc0) error_n = 1;
                            used_n = used_n + 1'b1;
                            if (used_n == 4) begin
                                finish_n = 1;
                                null_n   = 1;
                                mode_n   = TOKEN;
                                used_n   = 0;
                            end
                        end
                        default: error_n = 1;
                    endcase
                end
            end
        end
        // Defer error quarantine until all four byte lanes are evaluated.
        // Feeding CRC/token validation back into each following lane creates
        // a long combinational chain; no provisional event is exposed below.
        // Never authorize a candidate or leak body/DLLP events on a framing error.
        if (error_n) begin
            active_n     = 0;
            start_n      = 0;
            finish_n     = 0;
            body_bytes_n = 0;
            last_n       = 0;
            dllp_valid_n = 0;
            eds_n        = 0;
        end
    end
    always @(posedge clk) begin
        if (reset_i || abort_i || stream_start_i) begin
            active_o     <= !reset_i && !abort_i && stream_start_i;
            mode_q       <= TOKEN;
            used_q       <= 0;
            remaining_q  <= 0;
            error_o      <= 0;
            eds_o        <= 0;
            start_o      <= 0;
            body_bytes_o <= 0;
            body_last_o  <= 0;
            finish_o     <= 0;
            nullified_o  <= 0;
            dllp_o       <= 0;
        end else begin
            mode_q       <= mode_n;
            used_q       <= used_n;
            remaining_q  <= remaining_n;
            active_o     <= active_n;
            error_o      <= error_n;
            eds_o        <= eds_n;
            start_o      <= start_n;
            body_last_o  <= last_n;
            finish_o     <= finish_n;
            nullified_o  <= null_n;
            dllp_o       <= dllp_valid_n;
            body_bytes_o <= body_bytes_n;
            if (valid_i && active_o) begin
                token_q <= token_n;
                dllp_q  <= dllp_n;
            end
            if (start_n) begin
                length_o   <= length_n;
                sequence_o <= sequence_n;
            end
            if (body_bytes_n != 0) body_o <= body_n;
            if (dllp_valid_n) dllp_bytes_o <= dllp_n;
        end
    end
endmodule

`timescale 1ns / 1ps
// Independent procedural endpoint partner at the decoded GTH/PIPE boundary.
// Normal-polynomial CRC division, byte-parallel scrambling, real packet bytes.
module tb_root_link #(
    parameter         GEN2_TEST   = 0,
    parameter integer LINK_WIDTH  = 1,
    parameter integer LANE1_DELAY = 0
);
    reg phygen2 = 0, rateready = 1;
    wire targetgen2, speedidle, fallback;
    wire [1:0] native_rate, applied_rate;
    wire       native_rate_ready;
    wire       current_gen2 = LINK_WIDTH == 2 ? applied_rate == 1 : phygen2;
    reg  [7:0] peer_rate = GEN2_TEST ? 6 : 2;
    reg        clk = 0;
    always begin
        #(current_gen2 === 1'b1 ? 2 : 4);
        clk = ~clk;
    end
    reg rst = 0, enable = 1, phyready = 1, rxidle = 1, detectdone = 0, present = 1, retrain = 0;
    wire detect, txidle, up, active, error;
    wire [LINK_WIDTH-1:0] polarity;
    wire [           4:0] state;
    wire [16*LINK_WIDTH-1:0] phy_tx, link_tx, link_rx, shifted_rx;
    wire [2*LINK_WIDTH-1:0] phy_tc, shifted_rc, link_rx_ctrl;
    wire [LINK_WIDTH-1:0] shifted_valid, link_rx_valid, link_rx_error, detect_done,
        receiver_present;
    reg  [16*LINK_WIDTH-1:0] phy_rx = 0;
    reg  [ 2*LINK_WIDTH-1:0] phy_rc = 0;
    reg                      peer_enabled = 0;
    reg                      cv = 0;
    wire                     cr;
    reg  [              2:0] op = 0;
    reg  [             63:0] addr = 0;
    reg  [             15:0] bdf = 16'h0100;
    reg  [             31:0] cmddata = 0;
    reg  [              3:0] be = 15;
    wire                     rspv;
    reg                      rspr = 0;
    wire [             31:0] rspdata;
    wire [              2:0] rspstatus;
    reg  [             31:0] atd = 0;
    reg atv = 0, atl = 0;
    wire        atr;
    reg  [ 1:0] atclass = 2;
    reg  [ 8:0] atcost = 1;
    wire [31:0] ard;
    wire arv, arl;
    reg arr = 0;
    for (genvar pl = 0; pl < LINK_WIDTH; pl = pl + 1) begin : peer_skew
        if (pl == 1 && LANE1_DELAY > 0) begin : delay_lane
            reg [18:0] pipe[0:LANE1_DELAY-1];
            always @(posedge clk) begin
                pipe[0] <= {peer_enabled, phy_rc[2*pl+:2], phy_rx[16*pl+:16]};
                for (integer i = 1; i < LANE1_DELAY; i = i + 1) pipe[i] <= pipe[i-1];
            end
            assign {shifted_valid[pl], shifted_rc[2*pl+:2], shifted_rx[16*pl+:16]} =
                pipe[LANE1_DELAY-1];
        end else begin : direct
            assign shifted_valid[pl]     = peer_enabled;
            assign shifted_rx[16*pl+:16] = phy_rx[16*pl+:16];
            assign shifted_rc[2*pl+:2]   = phy_rc[2*pl+:2];
        end
    end
    if (LINK_WIDTH == 2) begin : native_pipe
        wire phy_detect, failed;
        wire [  1:0] powerdown;
        wire [127:0] pipe_tx;
        wire [ 31:0] adapter_rx;
        wire [1:0] adapter_valid, adapter_error;
        reg [1:0] phystatus = 0;
        gen3_legacy_x2_pipe #(
            .TIMEOUT_CYCLES(64)
        ) adapter (
            .clk               (clk),
            .rst_n             (rst),
            .detect_i          (detect),
            .ready_i           ({2{phyready}}),
            .phystatus_i       (phystatus),
            .rxvalid_i         (shifted_valid),
            .rxstatus_i        (phy_detect ? 6'b011011 : 6'b0),
            .rxdata_i          ({48'b0, shifted_rx[31:16], 48'b0, shifted_rx[15:0]}),
            .txdata_i          (link_tx),
            .rxdata_o          (adapter_rx),
            .txdata_o          (pipe_tx),
            .rxvalid_o         (adapter_valid),
            .rxerror_o         (adapter_error),
            .detect_o          (phy_detect),
            .powerdown_o       (powerdown),
            .detect_done_o     (detect_done),
            .receiver_present_o(receiver_present),
            .failed_o          (failed)
        );
        assign phy_tx = {pipe_tx[79:64], pipe_tx[15:0]};

        task acknowledge(input [1:0] lane);
            @(negedge clk);
            phystatus = lane;
            @(negedge clk);
            phystatus = 0;
        endtask
        initial begin
            wait (phy_detect);
            acknowledge(2'b10);
            acknowledge(2'b01);
            wait (powerdown == 0);
            acknowledge(2'b01);
            if (detect_done != 0) $fatal(1, "P0 completed before both lanes acknowledged");
            acknowledge(2'b10);
            if (GEN2_TEST)
                forever begin
                    wait (native_rate != applied_rate);
                    @(negedge clk);
                    if (!txidle || !rxidle || !up) $fatal(1, "Unsafe shared RATE command");
                    phyready = 0;
                    acknowledge(2'b10);
                    repeat (4) @(negedge clk);
                    if (!speedidle || !up || native_rate_ready || native_rate == applied_rate)
                        $fatal(1, "One lane advanced the link's active rate");
                    acknowledge(2'b01);
                    if (native_rate_ready) $fatal(1, "Rate completed before PHY was ready");
                    phyready = 1;
                    wait (native_rate == applied_rate);
                end
        end
        if (GEN2_TEST) begin : shared_rate
            reg [31:0] rx_data_q;
            reg [ 3:0] rx_ctrl_q;
            reg [1:0] rx_valid_q, rx_error_q;
            always @(posedge clk) begin
                rx_data_q  <= adapter_rx;
                rx_ctrl_q  <= shifted_rc;
                rx_valid_q <= adapter_valid & {2{rst && !speedidle}};
                rx_error_q <= adapter_error & {2{rst && !speedidle}};
            end
            assign {link_rx, link_rx_ctrl, link_rx_valid, link_rx_error} = {
                rx_data_q, rx_ctrl_q, rx_valid_q, rx_error_q
            };
            gen3_native_x2_rate #(
                .IDLE_CYCLES   (5),
                .TIMEOUT_CYCLES(500)
            ) controller (
                .clk            (clk),
                .rst_n          (rst),
                .request_i      (speedidle),
                .target_i       ({1'b0, targetgen2}),
                .request_ready_o(),
                .tx_idle_i      (speedidle),
                .rx_idle_i      ({2{rxidle}}),
                .phy_ready_i    ({2{phyready}}),
                .phystatus_i    (phystatus),
                .phy_rate_o     (native_rate),
                .applied_rate_o (applied_rate),
                .rate_ready_o   (native_rate_ready),
                .busy_o         (),
                .failed_o       ()
            );
        end else begin : fixed_rate
            assign {native_rate, applied_rate, native_rate_ready} = 5'b00001;
            assign {link_rx, link_rx_ctrl, link_rx_valid, link_rx_error} = {
                adapter_rx, shifted_rc, adapter_valid, adapter_error
            };
        end
        always @(posedge clk) if (rst && failed) $fatal(1, "Native PIPE startup failed");
    end else begin : decoded_pipe
        assign {native_rate, applied_rate, native_rate_ready} = 5'b00001;
        assign {detect_done, receiver_present}                = {detectdone, present};
        assign {link_rx, link_rx_valid, link_rx_error}        = {shifted_rx, shifted_valid, 1'b0};
        assign link_rx_ctrl                                   = shifted_rc;
        assign phy_tx                                         = link_tx;
    end
    pcie_soft_link #(
        .GEN2_ENABLE       (GEN2_TEST),
        .LINK_WIDTH        (LINK_WIDTH),
        .QUIET_CYCLES      (16),
        .POLL_CYCLES       (100000),
        .CONFIG_CYCLES     (10000),
        .COMPLETION_TIMEOUT(4096)
    ) dut (
        .force_gen1_i      (GEN2_TEST == 0),
        .phy_gen2_i        (current_gen2),
        .phy_rate_ready_i  (LINK_WIDTH == 2 ? native_rate_ready : rateready),
        .target_gen2_o     (targetgen2),
        .speed_idle_o      (speedidle),
        .fallback_o        (),
        .clk               (clk),
        .rst_n             (rst),
        .enable_i          (enable),
        .phy_ready_i       ({LINK_WIDTH{phyready}}),
        .rx_idle_i         ({LINK_WIDTH{rxidle}}),
        .detect_done_i     (detect_done),
        .receiver_present_i(receiver_present),
        .detect_o          (detect),
        .electrical_idle_o (txidle),
        .polarity_o        (polarity),
        .phy_rx_data_i     (link_rx),
        .phy_rx_ctrl_i     (link_rx_ctrl),
        .phy_rx_valid_i    (link_rx_valid),
        .phy_rx_error_i    (link_rx_error),
        .phy_tx_data_o     (link_tx),
        .phy_tx_ctrl_o     (phy_tc),
        .link_up_o         (up),
        .dl_active_o       (active),
        .state_o           (state),
        .retrain_i         (retrain),
        .cmd_valid_i       (cv),
        .cmd_ready_o       (cr),
        .cmd_op_i          (op),
        .cmd_address_i     (addr),
        .cmd_bdf_i         (bdf),
        .cmd_data_i        (cmddata),
        .cmd_be_i          (be),
        .rsp_valid_o       (rspv),
        .rsp_ready_i       (rspr),
        .rsp_data_o        (rspdata),
        .rsp_status_o      (rspstatus),
        .app_tx_data_i     (atd),
        .app_tx_valid_i    (atv),
        .app_tx_last_i     (atl),
        .app_tx_ready_o    (atr),
        .app_tx_class_i    (atclass),
        .app_tx_credits_i  (atcost),
        .app_rx_data_o     (ard),
        .app_rx_valid_o    (arv),
        .app_rx_last_o     (arl),
        .app_rx_ready_i    (arr),
        .error_o           (error)
    );
    reg [9:0] queue[0:LINK_WIDTH-1][0:131071];
    integer tails[0:LINK_WIDTH-1], heads[0:LINK_WIDTH-1];
    wire    [31:0] producer = tails[0], consumer = heads[0];
    integer        packet_lane = 0;
    reg [15:0] peer_lfsr[0:LINK_WIDTH-1], monitor_lfsr[0:LINK_WIDTH-1];
    reg [              9:0] symbol;
    reg [16*LINK_WIDTH-1:0] rxword;
    reg [ 2*LINK_WIDTH-1:0] rxk;
    integer skip_count = 0, monitor_training[0:LINK_WIDTH-1];
    reg [7:0] byte_value;
    reg       bypass;
    function [7:0] reverse8(input [7:0] x);
        for (integer n = 0; n < 8; n = n + 1) reverse8[n] = x[7-n];
    endfunction
    function [31:0] reverse32(input [31:0] x);
        for (integer n = 0; n < 32; n = n + 1) reverse32[n] = x[31-n];
    endfunction
    function [15:0] reverse16(input [15:0] x);
        for (integer n = 0; n < 16; n = n + 1) reverse16[n] = x[15-n];
    endfunction
    function [15:0] step(input [15:0] x);
        reg [15:0] expanded;
        begin
            expanded = {x[7:0], x[15:8]};
            step     = expanded ^ (16'(x[15:8]) << 3) ^ (16'(x[15:8]) << 4) ^ (16'(x[15:8]) << 5);
        end
    endfunction
    function [31:0] crc32(input [31:0] c, input [7:0] x);
        reg [31:0] v;
        begin
            v = c;
            for (integer n = 0; n < 8; n = n + 1)
            v = (v << 1) ^ ((v[31] ^ x[n]) ? 32'h04c11db7 : 0);
            crc32 = v;
        end
    endfunction
    function [15:0] crc16(input [15:0] c, input [7:0] x);
        reg [15:0] v;
        begin
            v = c;
            for (integer n = 0; n < 8; n = n + 1) v = (v << 1) ^ ((v[15] ^ x[n]) ? 16'h100b : 0);
            crc16 = v;
        end
    endfunction
    function [31:0] swap(input [31:0] x);
        swap = {x[7:0], x[15:8], x[23:16], x[31:24]};
    endfunction
    task push_lane(input integer physical_lane, input [7:0] x, input k, input scramble);
        queue[physical_lane][tails[physical_lane]] = {scramble, k, x};
        tails[physical_lane]                       = tails[physical_lane] + 1;
    endtask
    task push(input [7:0] x, input k, input scramble);
        push_lane(packet_lane, x, k, scramble);
        packet_lane = (packet_lane + 1) % LINK_WIDTH;
    endtask
    always @(negedge clk) begin
        if (!rst) begin
            for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                peer_lfsr[lane] = 16'hffff;
                heads[lane]     = 0;
                tails[lane]     = 0;
            end
            phy_rx = 0;
            phy_rc = 0;
        end else if (peer_enabled) begin
            rxword = 0;
            rxk    = 0;
            for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                for (integer slot = 0; slot < 2; slot = slot + 1) begin
                    symbol = heads[lane] < tails[lane] ? queue[lane][heads[lane]] : 10'h200;
                    if (heads[lane] < tails[lane]) heads[lane] = heads[lane] + 1;
                    byte_value = symbol[7:0];
                    if (!symbol[8] && symbol[9])
                        byte_value = byte_value ^ reverse8(peer_lfsr[lane][15:8]);
                    rxword[16*lane+8*slot+:8] = byte_value;
                    rxk[2*lane+slot]          = symbol[8];
                    if (symbol[8] && symbol[7:0] == 8'hbc) peer_lfsr[lane] = 16'hffff;
                    else if (!(symbol[8] && symbol[7:0] == 8'h1c))
                        peer_lfsr[lane] = step(peer_lfsr[lane]);
                end
            end
            phy_rx = rxword;
            phy_rc = rxk;
        end
    end
    task ts(input ts2, input lp, input np);
        for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
            push_lane(lane, 8'hbc, 1, 0);
            push_lane(lane, lp ? 8'hf7 : 8'h00, lp, 0);
            push_lane(lane, np ? 8'hf7 : 8'(lane), np, 0);
            push_lane(lane, 32, 0, 0);
            push_lane(lane, peer_rate, 0, 0);
            push_lane(lane, 0, 0, 0);
            repeat (10) push_lane(lane, ts2 ? 8'h45 : 8'h4a, 0, 0);
        end
    endtask
    task peer_eieos;
        for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
            push_lane(lane, 8'hbc, 1, 0);
            repeat (14) push_lane(lane, 8'hfc, 1, 0);
            push_lane(lane, 8'h4a, 0, 0);
        end
    endtask
    task partner_speed(input bit gen2);
        peer_rate = gen2 ? 8'h86 : 8'h82;
        repeat (20) ts(0, 0, 0);
        wait (state == 11);
        wait (state == 12);
        repeat (40) ts(1, 0, 0);
        wait (speedidle);
        wait (consumer == producer);
        @(negedge clk);
        rxidle       = 1;
        peer_enabled = 0;
        rateready    = 0;
        wait (targetgen2 == gen2);
        repeat (50) @(negedge clk);
        phygen2 = gen2;
        repeat (50) @(negedge clk);
        rateready = 1;
        wait (state == 11);
        @(negedge clk);
        rxidle       = 0;
        peer_enabled = 1;
        peer_rate    = 6;
        if (gen2) peer_eieos();
        repeat (16) ts(0, 0, 0);
        wait (state == 12);
        repeat (40) ts(1, 0, 0);
        wait (state == 10);
        cycles(30);
    endtask
    task dllp(input [31:0] body);
        reg [15:0] c;
        begin
            push(8'h5c, 1, 0);
            c = 16'hffff;
            for (integer n = 0; n < 4; n = n + 1) begin
                push(body[n*8+:8], 0, 1);
                c = crc16(c, body[n*8+:8]);
            end
            c = ~reverse16(c);
            push(c[7:0], 0, 1);
            push(c[15:8], 0, 1);
            push(8'hfd, 1, 0);
        end
    endtask
    task fc(input [7:0] typ, input [7:0] h, input [11:0] d);
        dllp({d[7:0], h[1:0], 2'b0, d[11:8], 2'b0, h[7:2], typ});
    endtask
    task compensated_skp(input integer lane0_skps, input integer lane1_skps);
        push_lane(0, 8'hbc, 1, 0);
        push_lane(1, 8'hbc, 1, 0);
        repeat (lane0_skps) push_lane(0, 8'h1c, 1, 0);
        repeat (lane1_skps) push_lane(1, 8'h1c, 1, 0);
    endtask
    task ack(input nak, input [11:0] seq);
        dllp({seq[7:0], 4'b0, seq[11:8], 8'b0, nak ? 8'h10 : 8'h00});
    endtask
    reg [31:0] outbound[0:63];
    task tlp(input [11:0] seq, input integer words, input corrupt);
        reg [31:0] c;
        reg [ 7:0] v;
        begin
            push(8'hfb, 1, 0);
            push({4'b0, seq[11:8]}, 0, 1);
            push(seq[7:0], 0, 1);
            c = crc32(crc32(32'hffffffff, {4'b0, seq[11:8]}), seq[7:0]);
            for (integer n = 0; n < words; n = n + 1)
            for (integer b = 0; b < 4; b = b + 1) begin
                v = outbound[n][b*8+:8];
                push(v, 0, 1);
                c = crc32(c, v);
            end
            c = ~reverse32(c);
            if (corrupt) c = c ^ 1;
            for (integer n = 0; n < 4; n = n + 1) push(c[n*8+:8], 0, 1);
            push(8'hfd, 1, 0);
        end
    endtask
    task cpl(input [11:0] seq, input [7:0] tag, input withdata, input [31:0] value, input corrupt);
        outbound[0] = swap(withdata ? 32'h4a000001 : 32'h0a000000);
        outbound[1] = swap(32'h01000004);
        outbound[2] = swap({16'b0, tag, 8'b0});
        outbound[3] = value;
        tlp(seq, withdata ? 4 : 3, corrupt);
    endtask
    // TX monitor checks framing, polynomial residue and captured request layout.
    reg [7:0] received[0:511];
    integer
        frame_kind = 0,
        frame_bytes = 0,
        packets = 0,
        naks = 0,
        acks = 0,
        init1 = 0,
        init2_count = 0;
    reg [31:0] captured     [0:63];
    reg [11:0] captured_seq;
    reg [31:0] check32, actual32;
    reg     [15:0] check16;
    integer        errors = 0;
    time last_packet_end = 0, last_packet_start = 0, replay_end = 0;
    always @(posedge clk)
        if (rst) begin
            if (error) errors = errors + 1;
            for (integer b = 0; b < 2 * LINK_WIDTH; b = b + 1) begin
                integer lane, index;
                lane       = b % LINK_WIDTH;
                index      = 2 * lane + b / LINK_WIDTH;
                byte_value = phy_tx[index*8+:8];
                bypass     = 0;
                if (phy_tc[index] && byte_value == 8'hbc) begin
                    monitor_lfsr[lane]     = 16'hffff;
                    monitor_training[lane] = 15;
                    bypass                 = 1;
                end else begin
                    if (phy_tc[index] && byte_value == 8'h1c) begin
                        monitor_training[lane] = 0;
                        skip_count             = skip_count + 1;
                        bypass                 = 1;
                    end else begin
                        if (monitor_training[lane] != 0) begin
                            bypass                 = 1;
                            monitor_training[lane] = monitor_training[lane] - 1;
                        end
                        if (!phy_tc[index] && !bypass)
                            byte_value = byte_value ^ reverse8(monitor_lfsr[lane][15:8]);
                        monitor_lfsr[lane] = step(monitor_lfsr[lane]);
                    end
                end
                if (phy_tc[index] && (byte_value == 8'hfb || byte_value == 8'h5c)) begin
                    frame_kind  = byte_value == 8'hfb ? 1 : 2;
                    frame_bytes = 0;
                    if (frame_kind == 1) last_packet_start = $time;
                end else if (phy_tc[index] && byte_value == 8'hfd && frame_kind != 0) begin
                    if (frame_kind == 1) begin
                        check32 = 32'hffffffff;
                        for (integer n = 0; n < frame_bytes - 4; n = n + 1)
                        check32 = crc32(check32, received[n]);
                        actual32 = {
                            received[frame_bytes-1],
                            received[frame_bytes-2],
                            received[frame_bytes-3],
                            received[frame_bytes-4]
                        };
                        if (actual32 !== ~reverse32(check32)) $fatal(1, "Root emitted bad LCRC");
                        captured_seq = {received[0][3:0], received[1]};
                        for (integer n = 0; n < (frame_bytes - 6) / 4; n = n + 1)
                        captured[n] = {
                            received[5+4*n], received[4+4*n], received[3+4*n], received[2+4*n]
                        };
                        packets         = packets + 1;
                        last_packet_end = $time;
                    end else begin
                        check16 = 16'hffff;
                        for (integer n = 0; n < 4; n = n + 1) check16 = crc16(check16, received[n]);
                        if ({received[5], received[4]} !== ~reverse16(check16))
                            $fatal(1, "Root emitted bad DLLP CRC");
                        if (received[0] == 8'h10) naks = naks + 1;
                        if (received[0] == 0) acks = acks + 1;
                        if (received[0] == 8'h40) init1 = init1 + 1;
                        if (received[0] == 8'hc0) init2_count = init2_count + 1;
                    end
                    frame_kind = 0;
                end else if (!phy_tc[index] && frame_kind != 0) begin
                    received[frame_bytes] = byte_value;
                    frame_bytes           = frame_bytes + 1;
                end
            end
        end else begin
            for (integer lane = 0; lane < LINK_WIDTH; lane = lane + 1) begin
                monitor_lfsr[lane]     = 16'hffff;
                monitor_training[lane] = 0;
            end
            frame_kind  = 0;
            frame_bytes = 0;
        end
    task cycles(input integer n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask
    task command(input [2:0] kind, input [63:0] a, input [31:0] value);
        wait (cr);
        @(negedge clk);
        op      = kind;
        addr    = a;
        cmddata = value;
        cv      = 1;
        @(negedge clk);
        cv = 0;
    endtask
    task response(input [31:0] value);
        wait (rspv);
        if (rspstatus !== 0 || rspdata !== value)
            $fatal(1, "Root response %0d %08x wanted %08x", rspstatus, rspdata, value);
        cycles(5);
        @(negedge clk);
        rspr = 1;
        @(negedge clk);
        rspr = 0;
        cycles(1);
    endtask
    integer eios_seen = 0, eieos_seen = 0, eieos_word = 0;
    always @(posedge clk)
        if (rst && !txidle) begin
            if (eieos_word != 0) begin
                if (phy_tx !== {LINK_WIDTH{eieos_word == 7 ? 16'h4afc : 16'hfcfc}} ||
                    phy_tc !== {LINK_WIDTH{eieos_word == 7 ? 2'b01 : 2'b11}})
                    $fatal(1, "EIEOS encoding/interruption at word %0d", eieos_word);
                if (eieos_word == 7) eieos_word = 0;
                else eieos_word++;
            end else if (phy_tx == {LINK_WIDTH{16'hfcbc}} && (&phy_tc)) begin
                eieos_seen++;
                eieos_word = 1;
            end
            if (phy_tx == {LINK_WIDTH{16'h7cbc}} && (&phy_tc)) eios_seen++;
        end
    integer trace_state = -1;
    always @(posedge clk)
        if ($test$plusargs("TRACE")) begin
            if (state !== trace_state) begin
                $display("TRACE state=%0d t=%0t", state, $time);
                trace_state = state;
            end
            if (dut.rx_dllp_valid)
                $display(
                    "TRACE RX DLLP=%08x phase=%0d seen=%b",
                    dut.rx_dllp,
                    dut.flow.phase_q,
                    dut.flow.seen_q
                );
            if (dut.rx_packet_error) $display("TRACE RX packet error");
            if (dut.fc_dllp_valid && dut.fc_dllp_ready)
                $display(
                    "TRACE TX FC=%02x phase=%0d seen=%b seen2=%b",
                    dut.fc_type,
                    dut.flow.phase_q,
                    dut.flow.seen_q,
                    dut.flow.seen2_q
                );
            if ($time > 120000) $finish;
        end
    integer before_packets, before_naks, before_init, before_errors;
    reg [31:0] held_rx;
    initial begin
        cycles(4);
        @(negedge clk);
        rst = 1;
        wait (detect);
        @(negedge clk);
        detectdone = 1;
        @(negedge clk);
        detectdone   = 0;
        rxidle       = 0;
        peer_enabled = 1;
        wait (state == 2);
        repeat (1030) ts(0, 1, 1);
        wait (state == 3);
        repeat (32) ts(1, 1, 1);
        wait (state == 4);
        repeat (8) ts(0, 0, 1);
        wait (state == 6);
        repeat (12) ts(0, 0, 0);
        wait (state == 8);
        repeat (32) ts(1, 0, 0);
        wait (state == 10);
        if (GEN2_TEST) begin
            wait (state == 11);
            peer_rate = 8'h86;
            repeat (16) ts(0, 0, 0);
            wait (state == 12);
            repeat (40) ts(1, 0, 0);
            wait (speedidle);
            wait (consumer == producer);
            @(negedge clk);
            rxidle       = 1;
            peer_enabled = 0;
            rateready    = 0;
            wait (targetgen2);
            repeat (50) @(negedge clk);
            phygen2 = 1;
            repeat (50) @(negedge clk);
            rateready = 1;
            wait (state == 11);
            cycles(400);
            @(negedge clk);
            rxidle       = 0;
            peer_enabled = 1;
            peer_rate    = 6;
            // Gen2 EIEOS precedes TS1; independently encoded, not the DUT codec.
            peer_eieos();
            repeat (16) ts(0, 0, 0);
            wait (state == 12);
            repeat (40) ts(1, 0, 0);
            wait (state == 10);
        end
        fc(8'h40, 2, 16);
        fc(8'h50, 2, 16);
        fc(8'h60, 0, 0);
        fc(8'hc0, 2, 16);
        fc(8'hd0, 2, 16);
        fc(8'he0, 0, 0);
        wait (init2_count != 0);
        fc(8'hc0, 2, 16);
        fc(8'hd0, 2, 16);
        fc(8'he0, 0, 0);
        wait (active);
        if (LINK_WIDTH == 2) begin
            // The two logical SKP sets arrived together on the wire. The
            // local elastic buffers changed their decoded lengths independently.
            compensated_skp(2, 3);
            fc(8'h80, 2, 16);
            compensated_skp(3, 2);
        end
        cycles(30);
        if (errors != 0) $fatal(1, "Unexpected error during link/FC initialization");
        command(2, 0, 0);
        wait (packets == 1);
        if (captured_seq !== 0 || captured[0] !== 32'h01000004 || captured[2] !== 32'h00000001)
            $fatal(1, "CfgRd0 packet layout");
        if (GEN2_TEST) begin
            before_init = init1;
            partner_speed(0);
            partner_speed(1);
            if (!active || !up || init1 != before_init || packets != 1 || rspv)
                $fatal(1, "Rate changes lost pending requester/replay/credit ownership");
        end
        ack(0, 0);
        cpl(0, 0, 1, 32'h12348086, 0);
        response(32'h12348086);
        command(3, 64'h10, 32'hfffff000);
        wait (packets == 2);
        ack(0, 1);
        cpl(1, 1, 0, 0, 0);
        response(0);
        command(0, 64'h00000001_00001000, 0);
        cycles(100);
        if (packets != 2) $fatal(1, "NPH exhaustion did not block");
        fc(8'h90, 3, 17);
        wait (packets == 3);
        if (captured[2] !== 32'h01000000 || captured[3] !== 32'h00100000) $fatal(1, "MRd64 layout");
        ack(0, 2);
        cpl(2, 2, 1, 32'hcafef00d, 0);
        response(32'hcafef00d);
        command(1, 64'h1000, 32'hdeadbeef);
        wait (packets == 4);
        response(0);
        ack(0, 3);
        fc(8'h90, 4, 18);
        command(0, 64'h1000, 0);
        wait (packets == 5);
        ack(1, 3);
        wait (packets == 6);
        if (captured_seq !== 4) $fatal(1, "NAK did not replay the original sequence");
        replay_end = last_packet_end;
        wait (packets == 7);
        if ((last_packet_start - replay_end) * (GEN2_TEST ? 2 : 1) < 2844 ||
            (last_packet_start - replay_end) * (GEN2_TEST ? 2 : 1) > 5688)
            $fatal(1, "Replay outside port timer window: %0t", last_packet_start - replay_end);
        $display("METRIC short replay: %0d ns", last_packet_start - replay_end);
        ack(0, 4);
        cpl(3, 4, 1, 32'h11112222, 0);
        response(32'h11112222);
        before_errors = errors;
        before_naks   = naks;
        fc(8'h90, 5, 19);
        command(0, 64'h1000, 0);
        wait (packets == 8);
        ack(0, 5);
        cpl(4, 5, 1, 32'h33334444, 1);
        cycles(60);
        if (rspv || naks <= before_naks) $fatal(1, "Bad completion was not NAKed/dropped");
        cpl(4, 5, 1, 32'h33334444, 0);
        response(32'h33334444);
        cpl(4, 5, 1, 32'h33334444, 0);
        cycles(40);
        if (rspv || arv) $fatal(1, "Duplicate delivered twice");
        // Incoming endpoint DMA/MMIO write is exposed only as a validated TLP.
        outbound[0] = swap(32'h40000001);
        outbound[1] = swap(32'h0100550f);
        outbound[2] = swap(32'h2000);
        outbound[3] = 32'hfeedbeef;
        tlp(5, 4, 0);
        wait (arv);
        held_rx = ard;
        cycles(20);
        if (!arv || ard !== held_rx) $fatal(1, "Application RX did not hold ownership");
        @(negedge clk);
        arr = 1;
        do begin
            @(posedge clk);
        end while (!(arv && arl));
        @(negedge clk);
        arr = 0;
        cycles(3);
        // Host-memory/completer boundary can transmit an application completion.
        for (integer n = 0; n < 4; n = n + 1) begin
            @(negedge clk);
            atv = 1;
            atl = n == 3;
            case (n)
                0: atd = swap(32'h4a000001);
                1: atd = swap(32'h00000004);
                2: atd = swap(32'h01005500);
                3: atd = 32'habcdef01;
            endcase
            do begin
                @(posedge clk);
            end while (!atr);
            @(negedge clk);
            atv = 0;
        end
        wait (packets == 9);
        ack(0, 6);
        cycles(20);
        before_init = init1;
        @(negedge clk);
        retrain = 1;
        @(negedge clk);
        retrain = 0;
        wait (state == 11);
        if (!active || !up) $fatal(1, "Retrain destroyed data link");
        repeat (16) ts(0, 0, 0);
        wait (state == 12);
        repeat (32) ts(1, 0, 0);
        wait (state == 10);
        cycles(30);
        if (!active || init1 != before_init) $fatal(1, "Recovery reinitialized credits");
        // Exhaustion requests PHY Recovery; a successful retrain must resume
        // the retained TLP without reinitializing credit or requesting retrain twice.
        fc(8'h90, 6, 20);
        command(0, 64'h1000, 0);
        wait (packets == 10);
        wait (state == 11);
        if (!active || dut.replay_pending !== 1) $fatal(1, "Retry exhaustion lost ownership");
        repeat (16) ts(0, 0, 0);
        wait (state == 12);
        repeat (32) ts(1, 0, 0);
        wait (state == 10);
        wait (packets == 14);
        if (captured_seq !== 7) $fatal(1, "Post-retrain replay changed sequence");
        ack(0, 7);
        cpl(6, 6, 1, 32'ha0a01234, 0);
        response(32'ha0a01234);
        cycles(30);
        if (state != 10 || init1 != before_init) $fatal(1, "Repeated retrain or lost FC state");
        // Full MPS128 application traffic, with a concurrent incoming MWr.
        // Check both maximum-payload data and the replay deadline at the symbol port.
        outbound[0] = swap(32'h40000020);
        outbound[1] = swap(32'h010055ff);
        outbound[2] = swap(32'h2000);
        for (integer n = 0; n < 32; n = n + 1) outbound[n+3] = 32'hface0000 + 32'(n);
        tlp(7, 35, 0);
        for (integer n = 0; n < 35; n = n + 1) begin
            @(negedge clk);
            atv    = 1;
            atl    = n == 34;
            atcost = 8;
            case (n)
                0: atd = swap(32'h4a000020);
                1: atd = swap(32'h00000080);
                2: atd = swap(32'h01005500);
                default: atd = 32'hbeef0000 + 32'(n - 3);
            endcase
            do begin
                @(posedge clk);
            end while (!atr);
            @(negedge clk);
            atv = 0;
        end
        wait (packets == 15);
        replay_end = last_packet_end;
        wait (packets == 16);
        if (captured_seq !== 8 || (last_packet_start - replay_end) * (GEN2_TEST ? 2 : 1) < 2844 ||
            (last_packet_start - replay_end) * (GEN2_TEST ? 2 : 1) > 5688)
            $fatal(1, "MPS128 replay timing/sequence");
        $display("METRIC MPS128 replay: %0d ns", last_packet_start - replay_end);
        for (integer n = 0; n < 32; n = n + 1)
        if (captured[n+3] !== 32'hbeef0000 + 32'(n)) $fatal(1, "MPS128 TX corruption");
        ack(0, 8);
        wait (arv);
        held_rx = ard;
        cycles(10);
        if (ard !== held_rx) $fatal(1, "MPS128 RX stall changed data");
        @(negedge clk);
        arr = 1;
        for (integer n = 0; n < 35; n = n + 1) begin
            do begin
                @(posedge clk);
            end while (!arv);
            if (ard !== outbound[n] || arl !== (n == 34)) $fatal(1, "MPS128 RX corruption %0d", n);
        end
        @(negedge clk);
        arr = 0;
        cycles(10);
        if (skip_count < 3) $fatal(1, "No SKP traffic observed");
        if (errors != before_errors + 1)
            $fatal(1, "Unexpected error events %0d baseline %0d", errors, before_errors);
        if (GEN2_TEST && (eios_seen != 4 || eieos_seen < 2))
            $fatal(1, "Missing EIOS/EIEOS sequences %0d/%0d", eios_seen, eieos_seen);
        $display(
            "PASS integrated Gen1/Gen2 link: independent symbol partner, training/scrambling/SKP, FC starvation, config/memory TLPs, CRC/ACK/NAK/replay, duplicate suppression, application TLPs and retrain"
                );
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Integrated watchdog state=%0d packets=%0d active=%b rsp=%b/%d queued=%0d",
               state, packets, active, rspv, rspstatus, producer - consumer);
    end
endmodule

// SPDX-License-Identifier: Apache-2.0
// ZCU104 bounded Gen3 configuration-read diagnostic image. Arm via JTAG VIO after cold setup.
// No PS/AXI/DMA. Disarm is a cold reset of this isolated experiment and the SSD.
module gen3_eq_board (
    input wire refclk_p_i, refclk_n_i, rx_p_i, rx_n_i,
    output wire tx_p_o, tx_n_o, perst_a_o, disable_ssd2_power_o
);
    wire gtref, rawref, refclk, pclk;
    IBUFDS_GTE4 #(
        .REFCLK_HROW_CK_SEL(2'b00)
    ) reference_clock (
        .I    (refclk_p_i),
        .IB   (refclk_n_i),
        .CEB  (1'b0),
        .O    (gtref),
        .ODIV2(rawref)
    );
    BUFG_GT management_clock (
        .I      (rawref),
        .CE     (1'b1),
        .CEMASK (1'b0),
        .CLR    (1'b0),
        .CLRMASK(1'b0),
        .DIV    (3'b0),
        .O      (refclk)
    );
    wire        arm;
    wire [ 3:0] selected_preset;
    reg  [23:0] hold_count = 0;
    reg  [ 3:0] preset = 4;
    reg         watchdog_fault = 0;
    reg  [24:0] watchdog = 0;
    reg release_phy = 0, release_ssd = 0;
    always @(posedge refclk) begin
        release_phy <= arm && hold_count >= 100000 && !watchdog_fault && preset <= 10;
        release_ssd <= arm && hold_count >= 10000000 && !watchdog_fault && preset <= 10;
    end
    assign perst_a_o            = !release_ssd;
    assign disable_ssd2_power_o = 1;
    wire phystatus_rst, phystatus, powergood;
    wire [63:0] rx_data;
    wire [1:0] rx_k, rx_start, rx_header;
    wire rx_valid, rx_data_valid, rx_idle;
    wire [ 2:0] rx_status;
    wire [31:0] tx_data;
    wire [1:0] tx_k, tx_header, rate, txeq_ctrl, powerdown;
    wire tx_valid, tx_start, detect, idle, polarity;
    wire [3:0] txeq_preset;
    wire [5:0] txeq_fs, txeq_lf;
    wire [17:0] txeq_coeff;
    wire        txeq_done;
    (* ASYNC_REG="TRUE" *)reg  [ 2:0] release_sync = 0;
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync = 0, idle_sync = 3;
    always @(posedge pclk) begin
        release_sync <= {release_sync[1:0], release_ssd};
        ready_sync   <= {ready_sync[0], !phystatus_rst};
        idle_sync    <= {idle_sync[0], rx_idle};
    end
    wire reset = !release_sync[2];
    wire [127:0] status, last_ts;
    reg detect_source = 0;
    always @(posedge pclk) begin
        if (reset) detect_source <= 0;
        else detect_source <= status[4:0] == 0 && status[9:5] <= 1;
    end
    // Five milliseconds at 250 MHz exceeds the peer Recovery.Idle timeout.
    gen3_eq_bringup #(
        .CONFIG_PROBE   (1),
        .DATALINK_ENABLE(1),
        .RECOVERY_ENABLE(1),
        .OBSERVE_CYCLES (1250000)
    ) experiment (
        pclk,
        reset,
        ready_sync[1],
        preset,
        rx_data[31:0],
        rx_k,
        rx_valid,
        rx_data_valid,
        rx_start[0],
        rx_header,
        idle_sync[1],
        phystatus,
        rx_status,
        txeq_done,
        txeq_fs,
        txeq_lf,
        txeq_coeff,
        tx_data,
        tx_k,
        tx_header,
        tx_valid,
        tx_start,
        detect,
        idle,
        polarity,
        rate,
        txeq_ctrl,
        txeq_preset,
        last_ts,
        status,
        powerdown,
        1'b0
        ,,
        3'b0,
        64'b0,
        16'b0,
        32'b0,
        4'b0
        ,,
        1'b1
        ,,,
        32'b0,
        1'b0,
        1'b0
        ,,
        2'b0,
        9'b0
        ,,,,
        1'b0
        ,,
    );
    wire [ 63:0] phy_diag;
    reg  [127:0] legacy_history = 0;
    reg  [  4:0] previous_legacy = 0;
    always @(posedge pclk) begin
        if (reset) begin
            legacy_history  <= 0;
            previous_legacy <= 0;
        end else if (status[4:0] != 14 && status[4:0] != 15 && status[9:5] != previous_legacy) begin
            legacy_history <= {legacy_history[119:0], powerdown[1], detect, phystatus, status[9:5]};
            previous_legacy <= status[9:5];
        end
    end
    reg [7:0] status_events = 0;
    reg [2:0] last_rxstatus = 0;
    reg detect_seen = 0, detect_status_seen = 0, rxvalid_seen = 0;
    reg detect_level = 0, rxidle_level = 0, txidle_level = 0, ready_level = 0, status_level = 0;
    reg [1:0] powerdown_level = 0;
    always @(posedge pclk) begin
        if (reset) begin
            status_events      <= 0;
            last_rxstatus      <= 0;
            detect_seen        <= 0;
            detect_status_seen <= 0;
            rxvalid_seen       <= 0;
            detect_level       <= 0;
            rxidle_level       <= 0;
            txidle_level       <= 0;
            ready_level        <= 0;
            status_level       <= 0;
            powerdown_level    <= 0;
        end else if (status[4:0] != 14 && status[4:0] != 15) begin
            detect_level    <= detect;
            powerdown_level <= powerdown;
            rxidle_level    <= idle_sync[1];
            txidle_level    <= idle;
            ready_level     <= ready_sync[1];
            status_level    <= phystatus;
            if (detect) detect_seen <= 1;
            if (phystatus && detect) detect_status_seen <= 1;
            if (rx_valid) rxvalid_seen <= 1;
            if (phystatus) begin
                if (detect) last_rxstatus <= rx_status;
                if (status_events != 255) status_events <= status_events + 1'b1;
            end
        end
    end
    wire [63:0] diagnostic_bus = {
        status_events,
        last_rxstatus,
        detect_seen,
        detect_status_seen,
        detect_level,
        powerdown_level,
        rxvalid_seen,
        rxidle_level,
        txidle_level,
        ready_level,
        status_level,
        phy_diag[42:0]
    };
    // Independent diagnostic levels, not a coherent protocol/control crossing.
    // All asynchronous bits originate at primitive outputs or source registers.
    (* ASYNC_REG="TRUE" *) reg [63:0] phy_diag_meta = 0, phy_diag_sync = 0;
    reg [63:0] phy_diag_last = 0, phy_diag_seen = 0;
    always @(posedge refclk) begin
        phy_diag_meta <= diagnostic_bus;
        phy_diag_sync <= phy_diag_meta;
        if (!arm) begin
            phy_diag_last <= 0;
            phy_diag_seen <= 0;
        end else if (!watchdog_fault) begin
            phy_diag_last <= phy_diag_sync;
            phy_diag_seen <= phy_diag_seen | phy_diag_sync;
        end
    end
    gen3_reference_phy phy (
        .eq_diag             (phy_diag),
        .phy_refclk          (refclk),
        .phy_gtrefclk        (gtref),
        .phy_rst_n           (release_phy),
        .phy_txdata          ({32'b0, tx_data}),
        .phy_txdatak         (tx_k),
        .phy_txdata_valid    (tx_valid),
        .phy_txstart_block   (tx_start),
        .phy_txsync_header   (tx_header),
        .phy_rxp             (rx_p_i),
        .phy_rxn             (rx_n_i),
        .phy_txp             (tx_p_o),
        .phy_txn             (tx_n_o),
        .phy_txdetectrx      (detect),
        .phy_txelecidle      (idle || reset),
        .phy_txcompliance    (1'b0),
        .phy_rxpolarity      (polarity),
        .phy_powerdown       (powerdown),
        .phy_rate            (rate),
        .phy_txmargin        (3'b0),
        .phy_txswing         (1'b0),
        .phy_txdeemph        (1'b1),
        .phy_txeq_ctrl       (txeq_ctrl),
        .phy_txeq_preset     (txeq_preset),
        .phy_txeq_coeff      (6'b0),
        .phy_rxeq_ctrl       (2'b0),
        .phy_rxeq_txpreset   (4'b0),
        .as_mac_in_detect    (detect_source),
        .as_cdr_hold_req     (1'b0),
        .phy_coreclk         (),
        .phy_userclk         (),
        .phy_mcapclk         (),
        .phy_pclk            (pclk),
        .phy_rxdata          (rx_data),
        .phy_rxdatak         (rx_k),
        .phy_rxdata_valid    (rx_data_valid),
        .phy_rxstart_block   (rx_start),
        .phy_rxsync_header   (rx_header),
        .phy_rxvalid         (rx_valid),
        .phy_phystatus       (phystatus),
        .phy_phystatus_rst   (phystatus_rst),
        .phy_rxelecidle      (rx_idle),
        .phy_rxstatus        (rx_status),
        .phy_txeq_fs         (txeq_fs),
        .phy_txeq_lf         (txeq_lf),
        .phy_txeq_new_coeff  (txeq_coeff),
        .phy_txeq_done       (txeq_done),
        .phy_rxeq_preset_sel (),
        .phy_rxeq_new_txcoeff(),
        .phy_rxeq_adapt_done (),
        .phy_rxeq_done       (),
        .gt_gtpowergood      (powergood)
    );
    // Toggle mailbox: snapshot is held until the following request. All 256
    // data bits receive a max-delay bound; only toggle synchronizer entry pins
    // are false-pathed. Live multi-bit signals are not sampled by the VIO.
    reg request = 0, ack = 0;
    (* ASYNC_REG="TRUE" *) reg [1:0] request_sync = 0, ack_sync = 0;
    reg [255:0] snapshot;
    reg [255:0] display_snapshot = 0;
    reg [  7:0] interval = 0;
    always @(posedge pclk) begin
        request_sync <= {request_sync[0], request};
        if (request_sync[1] != ack) begin
            snapshot <= {status[11:10] == 0 ? legacy_history : last_ts, status};
            ack      <= request_sync[1];
        end
    end
    always @(posedge refclk) begin
        ack_sync <= {ack_sync[0], ack};
        if (!arm) begin
            hold_count     <= 0;
            preset         <= selected_preset;
            watchdog_fault <= 0;
            watchdog       <= 0;
        end else begin
            if (hold_count < 10000000) hold_count <= hold_count + 1'b1;
            if (release_ssd && !watchdog_fault) begin
                if (ack_sync[1] != request) begin
                    if (watchdog == 2500000) watchdog_fault <= 1;
                    else watchdog <= watchdog + 1'b1;
                end else watchdog <= 0;
            end
        end
        if (request == ack_sync[1]) begin
            if (interval == 255) begin
                display_snapshot <= snapshot;
                request          <= !request;
                interval         <= 0;
            end else interval <= interval + 1'b1;
        end else interval <= 0;
    end
    wire sample, clock_ready;
    wire [15:0] edges;
    gen3_clock_watch #(
        .GEN1_EDGES(320),
        .FAST_EDGES(640)
    ) clock_monitor (
        .user_clk    (pclk),
        .user_reset_i(reset),
        .mgmt_clk    (refclk),
        .reset_i     (!arm),
        .check_i     (release_ssd),
        .rate_i      (display_snapshot[11:10]),
        .ready_o     (clock_ready),
        .sample_o    (sample),
        .measured_o  (edges)
    );
    wire [31:0] diagnostics = {
        edges,
        8'b0,
        watchdog_fault,
        clock_ready,
        sample,
        release_phy,
        release_ssd,
        arm,
        1'b0,
        (preset > 10)
    };
    gen3_eq_vio control (
        .clk       (refclk),
        .probe_in0 (display_snapshot[127:0]),
        .probe_in1 (display_snapshot[255:128]),
        .probe_in2 (diagnostics),
        .probe_in3 (phy_diag_last),
        .probe_in4 (phy_diag_seen),
        .probe_out0(arm),
        .probe_out1(selected_preset)
    );
    wire unused = ^{rx_data[63:32], rx_start[1], powergood};
endmodule

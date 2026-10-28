// Experimental packet-level transmit/replay store. This is not a PCIe port.
// Input/output contain TLP DWORDs only; seq/LCRC/framing live outside this store.
// ACK/NAK events MUST already have passed DLLP CRC/type validation. Sequence is
// the last good received TLP for both ACK and NAK. Normal ACKs retire only
// the already-sent prefix, concurrently with copying later originals. NAKs
// and replay responses retain the drain barrier. Two originals may be copied
// ahead; replay packets remain serialized.
module pcie_soft_replay #(
    parameter integer DEPTH                 = 8,
    parameter integer MAX_DWORDS            = 64,
    parameter integer REPLAY_TIMEOUT_CYCLES = 512,
    parameter integer MAX_REPLAYS           = 3
) (
    input wire clk,
    input wire rst_n,
    input wire link_reset_i,
    input wire enable_i,
    input wire [31:0] s_data_i,
    input wire s_valid_i,
    input wire s_last_i,
    output wire s_ready_o,
    output wire [31:0] m_data_o,
    output wire m_valid_o,
    output wire m_last_o,
    output wire [11:0] m_sequence_o,
    output wire m_replay_o,
    // Identity of the oldest packet at its final-wire event (not prefetch).
    output wire [11:0] wire_sequence_o,
    output wire wire_replay_o,
    input wire m_ready_i,
    // Packet admission by the future serializer/credit scheduler. Examined
    // before a packet starts, not a PCIe flow-control credit implementation.
    input wire tx_allow_i,
    // Serializer event is the final wire symbol, not the final payload beat.
    input wire tx_wire_done_i,
    input wire phy_hold_i,
    input wire retrain_done_i,
    input wire response_valid_i,
    output wire response_ready_o,
    input wire response_nak_i,
    input wire [11:0] response_sequence_i,
    input wire [15:0] response_age_i,
    output wire [$clog2(DEPTH):0] pending_o,
    output wire [$clog2(DEPTH):0] sent_o,
    output wire replaying_o,
    output wire [11:0] acknowledged_o, next_sequence_o,
    output reg recovery_req_o,
    output reg response_error_o,
    output reg overflow_o,
    output reg replay_event_o,
    output reg timeout_event_o,
    output wire [7:0] profile_events_o
);
    localparam integer SLOT_W = $clog2(DEPTH);
    localparam integer WORD_W = $clog2(MAX_DWORDS);
    localparam integer TIMER_W = $clog2(REPLAY_TIMEOUT_CYCLES + 1);
    localparam integer RETRY_W = $clog2(MAX_REPLAYS + 2);
    localparam [1:0] TX_IDLE = 0, TX_READ = 1, TX_SEND = 2, TX_WIRE = 3;

    // Payload and slot metadata have no reset/INIT validity contract.
    (* ram_style = "block" *)reg [    31:0] payload  [0:DEPTH*MAX_DWORDS-1];
    reg [WORD_W:0] words    [           0:DEPTH-1];
    reg [    11:0] sequences[           0:DEPTH-1];
    reg [31:0] read_data, output_data_q;
    reg prefetch_valid_q, output_valid_q, prefetch_last_q, output_last_q;
    reg [WORD_W:0] fetch_word_q;
    reg [SLOT_W-1:0] head_q, write_slot_q, replay_slot_q, tx_slot_q;
    reg [SLOT_W:0] count_q, sent_q, replay_left_q;
    reg [1:0] inflight_q;  // original packets submitted but not wire-complete
    reg [11:0] head_sequence_q, next_sequence_q, tx_sequence_q;
    reg writing_q, dropping_q, replaying_q, tx_replay_q;
    reg [ WORD_W-1:0] write_word_q;
    reg [   WORD_W:0] tx_words_q;
    reg [        1:0] tx_state_q;
    reg [TIMER_W-1:0] timer_q;
    reg               timeout_pending_q;
    reg timer_running_q, first_replay_q, nak_pending_q;
    reg [RETRY_W-1:0] attempts_q;

    wire resetting = !rst_n || link_reset_i;
    // Two elastic stages: synchronous BRAM read and held output. A stall
    // retains both words; simultaneous output movement/refill sustains 1 DW/clk.
    wire output_space = !output_valid_q || m_ready_i;
    wire move_output = prefetch_valid_q && output_space;
    wire fetch = !resetting && (tx_state_q == TX_READ || tx_state_q == TX_SEND) &&
        fetch_word_q < tx_words_q && (!prefetch_valid_q || output_space);
    wire input_fire = s_valid_i && s_ready_o;
    wire commit_packet = input_fire && s_last_i && !dropping_q;
    wire output_fire = m_valid_o && m_ready_i;
    wire response_fire = response_valid_i && response_ready_o;
    wire [11:0] ack_distance = response_sequence_i - head_sequence_q;
    wire [11:0] previous_head = head_sequence_q - 12'd1;
    wire response_good = (ack_distance < 12'(sent_q)) || (response_sequence_i == previous_head);
    wire [SLOT_W:0] retire_count = (response_fire && response_good && ack_distance < 12'(sent_q)) ?
        (SLOT_W + 1)'(ack_distance + 12'd1) : (SLOT_W + 1)'(0);
    wire [SLOT_W:0] remaining_sent = sent_q - retire_count;
    wire received_nak = response_fire && response_good && response_nak_i && remaining_sent != 0;
    wire request_nak_replay = !replaying_q && !phy_hold_i && (received_nak || nak_pending_q) &&
        remaining_sent != 0 && inflight_q == 0 && tx_state_q == TX_IDLE;
    wire request_timeout_replay = tx_state_q == TX_IDLE && inflight_q == 0 && !response_valid_i &&
        timeout_pending_q && sent_q != 0 && !replaying_q && !phy_hold_i;
    wire request_replay = !recovery_req_o && (request_nak_replay || request_timeout_replay);
    wire [RETRY_W-1:0] attempts_base = retire_count != 0 ? RETRY_W'(0) : attempts_q;
    wire [SLOT_W-1:0] head_after_retire = head_q + SLOT_W'(retire_count);
    wire [SLOT_W-1:0] next_unsent_slot = head_q + SLOT_W'(sent_q) + SLOT_W'(inflight_q);
    wire [11:0] replay_distance = sequences[replay_slot_q] - head_sequence_q;
    wire [WORD_W-1:0] input_word = writing_q ? write_word_q : WORD_W'(0);

    assign s_ready_o = !resetting && enable_i && !recovery_req_o &&
        (writing_q || (!replaying_q && !request_replay && !timeout_pending_q && !nak_pending_q &&
                       count_q < (SLOT_W + 1)'(DEPTH)));
    assign m_valid_o = !resetting && tx_state_q == TX_SEND && output_valid_q;
    assign m_data_o = output_data_q;
    assign m_last_o = output_last_q;
    assign m_sequence_o = tx_sequence_q;
    assign m_replay_o = tx_replay_q;
    assign wire_replay_o = tx_replay_q;
    assign wire_sequence_o = tx_replay_q ? tx_sequence_q : head_sequence_q + 12'(sent_q);
    // Normal ownership is ordered: sent prefix, staged originals, active copy,
    // then unsent entries. A valid normal ACK touches only the sent prefix.
    // tx_slot_q/tx_sequence_q are immutable during a copy; advancing head by R
    // and reducing sent by R preserves head+sent (oldest staged identity) and
    // head+sent+inflight (next unsent slot), including simultaneous wire-done.
    // Replay may reread the sent prefix, so its responses still require drain.
    wire normal_ack_path = !response_nak_i && !replaying_q && !tx_replay_q && !nak_pending_q;
    wire response_allows_start = !response_valid_i || (normal_ack_path && response_good);
    assign response_ready_o = !resetting && !recovery_req_o &&
        (normal_ack_path || (tx_state_q == TX_IDLE && inflight_q == 0));
    // Passive observations only; never feed ownership or admission.
    assign profile_events_o = {
        replaying_q,
        timeout_event_o,
        response_fire && response_nak_i,
        response_fire && !response_nak_i,
        response_valid_i && tx_state_q == TX_IDLE && !response_allows_start,
        response_valid_i && !response_ready_o && inflight_q != 0,
        response_valid_i && !response_ready_o && tx_state_q != TX_IDLE,
        response_valid_i
    };
    assign pending_o = count_q;
    assign sent_o = sent_q;
    assign replaying_o = replaying_q;
    assign acknowledged_o = previous_head;
    assign next_sequence_o = next_sequence_q;

    // A true synchronous-read payload RAM; reset affects ownership, never RAM.
    always @(posedge clk) begin
        if (!resetting && input_fire && !dropping_q)
            payload[{write_slot_q, input_word}] <= s_data_i;
        if (fetch) read_data <= payload[{tx_slot_q, fetch_word_q[WORD_W-1:0]}];
        if (!resetting && move_output) output_data_q <= read_data;
        if (!resetting && commit_packet) begin
            words[write_slot_q]     <= {1'b0, input_word} + 1'b1;
            sequences[write_slot_q] <= next_sequence_q;
        end
    end

    // Packet RAM/data registers remain unreset. Only validity and fetch
    // ownership reset. Normal ACKs never address the active-copy/staged suffix.
    // Replay/normal identity transitions still require all copied packets drained.
    always @(posedge clk) begin
        if (resetting) begin
            prefetch_valid_q <= 0;
            output_valid_q   <= 0;
            prefetch_last_q  <= 0;
            output_last_q    <= 0;
            fetch_word_q     <= 0;
        end else if (tx_state_q == TX_IDLE) begin
            prefetch_valid_q <= 0;
            output_valid_q   <= 0;
            fetch_word_q     <= 0;
        end else begin
            if (output_fire) output_valid_q <= 0;
            if (move_output) begin
                output_valid_q   <= 1;
                output_last_q    <= prefetch_last_q;
                prefetch_valid_q <= 0;
            end
            if (fetch) begin
                prefetch_valid_q <= 1;
                prefetch_last_q  <= fetch_word_q == tx_words_q - 1'b1;
                fetch_word_q     <= fetch_word_q + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (resetting) begin
            head_q            <= 0;
            write_slot_q      <= 0;
            count_q           <= 0;
            sent_q            <= 0;
            inflight_q        <= 0;
            head_sequence_q   <= 0;
            next_sequence_q   <= 0;
            writing_q         <= 0;
            dropping_q        <= 0;
            write_word_q      <= 0;
            tx_state_q        <= TX_IDLE;
            tx_slot_q         <= 0;
            tx_words_q        <= 0;
            tx_sequence_q     <= 0;
            tx_replay_q       <= 0;
            replay_slot_q     <= 0;
            replay_left_q     <= 0;
            replaying_q       <= 0;
            timer_q           <= 0;
            timeout_pending_q <= 0;
            timer_running_q   <= 0;
            first_replay_q    <= 0;
            nak_pending_q     <= 0;
            attempts_q        <= 0;
            recovery_req_o    <= 0;
            response_error_o  <= 0;
            overflow_o        <= 0;
            replay_event_o    <= 0;
            timeout_event_o   <= 0;
        end else begin
            response_error_o <= 0;
            overflow_o <= 0;
            replay_event_o <= 0;
            timeout_event_o <= 0;
            count_q <= count_q + (SLOT_W + 1)'(commit_packet) - retire_count;
            inflight_q <= inflight_q + 2'(output_fire && m_last_o && !tx_replay_q) -
                2'(tx_wire_done_i && !tx_replay_q);
            sent_q <= sent_q + (SLOT_W + 1)'(tx_wire_done_i && !tx_replay_q) - retire_count;
            if (received_nak && replaying_q) nak_pending_q <= 1;
            if (retire_count != 0 && !response_nak_i) nak_pending_q <= 0;
            if (remaining_sent == 0) nak_pending_q <= 0;

            if (input_fire) begin
                if (s_last_i) begin
                    writing_q    <= 0;
                    dropping_q   <= 0;
                    write_word_q <= 0;
                    if (!dropping_q) begin
                        write_slot_q    <= write_slot_q + 1'b1;
                        next_sequence_q <= next_sequence_q + 12'd1;
                    end
                end else begin
                    writing_q <= 1;
                    if (!dropping_q) begin
                        if (input_word == WORD_W'(MAX_DWORDS - 1)) begin
                            dropping_q <= 1;
                            overflow_o <= 1;
                        end else write_word_q <= input_word + 1'b1;
                    end
                end
            end

            if (response_fire) begin
                if (!response_good) response_error_o <= 1;
                if (retire_count != 0) begin
                    head_q          <= head_after_retire;
                    head_sequence_q <= head_sequence_q + 12'(retire_count);
                    attempts_q      <= 0;
                    if (replaying_q && 12'(retire_count) > replay_distance) begin
                        // Skip acknowledged entries that have not yet replayed.
                        if (12'(retire_count) - replay_distance >= 12'(replay_left_q)) begin
                            replay_left_q <= 0;
                            replaying_q   <= 0;
                        end else begin
                            replay_slot_q <= head_after_retire;
                            replay_left_q <= replay_left_q -
                                (SLOT_W + 1)'(12'(retire_count) - replay_distance);
                        end
                    end
                end
            end

            // Timeout is latched while a packet is stalled. It is serviced only
            // at a packet boundary; never truncate an offered output packet.
            if ((sent_q == retire_count && !tx_wire_done_i) || request_replay) begin
                timer_q           <= 0;
                timeout_pending_q <= 0;
                timer_running_q   <= 0;
            end else if (phy_hold_i || recovery_req_o) begin
                // Hold the timer and pending expiry throughout PHY retraining.
            end else if (retire_count != 0 && remaining_sent == 0 && tx_wire_done_i &&
                         !tx_replay_q) begin
                // All older sent packets retired as a new original completed.
                // Its timeout starts now, not at the age of the older ACK.
                timer_q           <= 0;
                timer_running_q   <= 1;
                timeout_pending_q <= 0;
            end else if (retire_count != 0) begin
                timer_q <= 32'(response_age_i) >= REPLAY_TIMEOUT_CYCLES ?
                    TIMER_W'(REPLAY_TIMEOUT_CYCLES - 1) : TIMER_W'(response_age_i);
                timer_running_q <= 1;
                timeout_pending_q <= 32'(response_age_i) >= REPLAY_TIMEOUT_CYCLES;
            end else
                if (tx_wire_done_i && (!timer_running_q || (tx_replay_q && first_replay_q))) begin
                timer_q           <= 0;
                timer_running_q   <= 1;
                timeout_pending_q <= 0;
                first_replay_q    <= 0;
            end else if (timer_running_q && !timeout_pending_q) begin
                if (timer_q == TIMER_W'(REPLAY_TIMEOUT_CYCLES - 1)) timeout_pending_q <= 1;
                else timer_q <= timer_q + 1'b1;
            end

            if (request_replay) begin
                nak_pending_q <= 0;
                if (attempts_base >= RETRY_W'(MAX_REPLAYS)) begin
                    recovery_req_o <= 1;
                    replaying_q    <= 0;
                    attempts_q     <= 0;
                end else begin
                    attempts_q      <= attempts_base + 1'b1;
                    replay_slot_q   <= head_after_retire;
                    replay_left_q   <= remaining_sent;
                    replaying_q     <= 1;
                    first_replay_q  <= 1;
                    replay_event_o  <= 1;
                    timeout_event_o <= request_timeout_replay;
                end
            end
            if (recovery_req_o && retrain_done_i) begin
                recovery_req_o    <= 0;
                replaying_q       <= remaining_sent != 0;
                replay_slot_q     <= head_after_retire;
                replay_left_q     <= remaining_sent;
                first_replay_q    <= 1;
                timer_q           <= 0;
                timer_running_q   <= 0;
                timeout_pending_q <= 0;
            end

            if (tx_wire_done_i && tx_replay_q) begin
                replay_slot_q <= replay_slot_q + 1'b1;
                replay_left_q <= replay_left_q - 1'b1;
                if (replay_left_q == 1) replaying_q <= 0;
            end
            case (tx_state_q)
                TX_IDLE: begin
                    if (enable_i && tx_allow_i && !phy_hold_i && !recovery_req_o &&
                        response_allows_start && !request_replay) begin
                        if (replaying_q && replay_left_q != 0 && inflight_q == 0) begin
                            tx_slot_q     <= replay_slot_q;
                            tx_sequence_q <= sequences[replay_slot_q];
                            tx_words_q    <= words[replay_slot_q];
                            tx_replay_q   <= 1;
                            tx_state_q    <= TX_READ;
                        end else
                            if (!replaying_q && !timeout_pending_q && !nak_pending_q && inflight_q <
                                2 && count_q > sent_q + (SLOT_W + 1)'(inflight_q)) begin
                            tx_slot_q     <= next_unsent_slot;
                            tx_sequence_q <= sequences[next_unsent_slot];
                            tx_words_q    <= words[next_unsent_slot];
                            tx_replay_q   <= 0;
                            tx_state_q    <= TX_READ;
                        end
                    end
                end
                TX_READ: tx_state_q <= TX_SEND;
                TX_SEND:
                if (output_fire) begin
                    if (m_last_o) begin
                        tx_state_q <= !tx_replay_q || tx_wire_done_i ? TX_IDLE : TX_WIRE;
                    end
                end
                TX_WIRE: if (tx_wire_done_i) tx_state_q <= TX_IDLE;
                default: tx_state_q <= TX_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 2 || DEPTH >= 2048 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "DEPTH must be a power of two between 2 and 1024");
        if (MAX_DWORDS < 2 || (MAX_DWORDS & (MAX_DWORDS - 1)) != 0)
            $fatal(1, "MAX_DWORDS must be a power of two >= 2");
        if (REPLAY_TIMEOUT_CYCLES < 1 || MAX_REPLAYS < 1)
            $fatal(1, "Timeout and retry limit must be positive");
    end
`endif
endmodule

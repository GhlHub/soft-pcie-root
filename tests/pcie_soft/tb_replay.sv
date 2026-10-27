`timescale 1ns/1ps
module tb_replay;
    parameter integer WORDS=8;
    parameter integer SEED=32'h631ba421;
    localparam integer D=4, W=WORDS, TIMEOUT=256;
    reg clk=0;
    always #4 clk=~clk;
    reg rst_n=0,link_reset=0,enable=1,tx_allow=0,retrain_done=0,phy_hold=0;
    reg [31:0] s_data=0;
    reg s_valid=0,s_last=0;
    wire s_ready;
    wire [31:0] m_data;
    wire m_valid,m_last,m_replay;
    wire [11:0] m_seq;
    reg allow_ready=1,random_ready=0;
    reg [31:0] noise=SEED;
    wire m_ready=allow_ready && (!random_ready || noise[0] || noise[3]);
    reg rsp_valid=0,rsp_nak=0;
    reg [11:0] rsp_seq=0;
    wire rsp_ready;
    wire [2:0] pending,sent;
    wire replaying,recovery,rsp_error,overflow,replay_event,timeout_event;
    pcie_soft_replay #(.DEPTH(D),.MAX_DWORDS(W),
        .REPLAY_TIMEOUT_CYCLES(TIMEOUT),.MAX_REPLAYS(3)) dut (
        .clk(clk),.rst_n(rst_n),.link_reset_i(link_reset),.enable_i(enable),
        .s_data_i(s_data),.s_valid_i(s_valid),.s_last_i(s_last),.s_ready_o(s_ready),
        .m_data_o(m_data),.m_valid_o(m_valid),.m_last_o(m_last),
        .m_sequence_o(m_seq),.m_replay_o(m_replay),.m_ready_i(m_ready),
        .tx_allow_i(tx_allow),.tx_wire_done_i(m_valid&&m_ready&&m_last),
        .phy_hold_i(phy_hold),.retrain_done_i(retrain_done),.response_age_i(16'b0),.response_valid_i(rsp_valid),.response_ready_o(rsp_ready),
        .response_nak_i(rsp_nak),.response_sequence_i(rsp_seq),
        .pending_o(pending),.sent_o(sent),.replaying_o(replaying),
        .recovery_req_o(recovery),.response_error_o(rsp_error),.overflow_o(overflow),
        .replay_event_o(replay_event),.timeout_event_o(timeout_event)
    );
    integer expected_words[0:4095];
    reg [31:0] expected_base[0:4095];
    reg was_sent[0:4095];
    reg [11:0] input_sequence=0,first_sequence=0,active_sequence;
    reg active_replay;
    integer out_word=0,tx_packets=0,new_packets=0,replay_packets=0;
    integer error_count=0,overflow_count=0,replay_count=0,timeout_count=0;
    integer i,j,goal,errors_before,retained_packets;
    reg stalled=0;
    reg [45:0] held_output;

    always @(negedge clk)
        noise <= {noise[30:0],noise[31]^noise[21]^noise[1]^noise[0]};

    // Packet-level scoreboard: data and ordering, independent of RAM/FSM latency.
    always @(posedge clk) begin
        if (!rst_n || link_reset) begin
            out_word=0;tx_packets=0;new_packets=0;replay_packets=0;
            error_count=0;overflow_count=0;replay_count=0;timeout_count=0;
            first_sequence=0;stalled=0;
            for (integer k=0;k<4096;k=k+1) was_sent[k]=0;
        end else begin
            if (pending>D || sent>pending) $fatal(1,"Ownership/credit bound");
            if (stalled && (!m_valid || {m_data,m_last,m_seq,m_replay}!==held_output))
                $fatal(1,"Output changed under backpressure");
            stalled=m_valid&&!m_ready;
            held_output={m_data,m_last,m_seq,m_replay};
            if (m_valid&&m_ready) begin
                if (out_word==0) begin
                    active_sequence=m_seq;active_replay=m_replay;
                    if (m_replay && !was_sent[m_seq]) $fatal(1,"Replayed unsent sequence");
                    if (!m_replay && m_seq!==first_sequence) $fatal(1,"New packet order %0d expected %0d",m_seq,first_sequence);
                end
                if (m_seq!==active_sequence || m_replay!==active_replay)
                    $fatal(1,"Packet metadata changed");
                if (m_data!==expected_base[m_seq]+32'(out_word))
                    $fatal(1,"Payload mismatch seq %0d word %0d got %08x",m_seq,out_word,m_data);
                if (m_last !== (out_word==expected_words[m_seq]-1))
                    $fatal(1,"Packet length mismatch");
                if (m_last) begin
                    tx_packets=tx_packets+1;was_sent[m_seq]=1;
                    if (m_replay) replay_packets=replay_packets+1;
                    else begin new_packets=new_packets+1;first_sequence=first_sequence+12'd1;end
                    out_word=0;
                end else out_word=out_word+1;
            end
            #1;
            if (rsp_error) error_count=error_count+1;
            if (overflow) overflow_count=overflow_count+1;
            if (replay_event) replay_count=replay_count+1;
            if (timeout_event) timeout_count=timeout_count+1;
        end
    end

    task automatic cycles(input integer n);
        repeat(n) begin @(posedge clk);#2;end
    endtask
    task automatic word(input reg [31:0] value,input reg last);
        @(negedge clk);s_data=value;s_last=last;s_valid=1;
        do begin @(posedge clk);end while(!s_ready);
        @(negedge clk);s_valid=0;
    endtask
    task automatic packet(input integer length,input reg [31:0] base);
        integer n;
        begin
            expected_words[input_sequence]=length;
            expected_base[input_sequence]=base;
            for(n=0;n<length;n=n+1) word(base+32'(n),n==length-1);
            if(length<=W) input_sequence=input_sequence+12'd1;
        end
    endtask
    task automatic response(input reg nak,input reg [11:0] seq);
        @(negedge clk);rsp_nak=nak;rsp_seq=seq;rsp_valid=1;
        do begin @(posedge clk);end while(!rsp_ready);
        @(negedge clk);rsp_valid=0;
        cycles(1);
    endtask
    task automatic wait_packets(input integer target);
        integer n;
        begin
            n=0;
            while(tx_packets<target && n<10000) begin cycles(1);n=n+1;end
            if(tx_packets!=target) $fatal(1,"Expected %0d packets, got %0d",target,tx_packets);
        end
    endtask
    task automatic reset_link;
        @(negedge clk);link_reset=1;s_valid=0;rsp_valid=0;
        cycles(2);
        @(negedge clk);link_reset=0;input_sequence=0;
        cycles(1);
        if(pending!==0||sent!==0||recovery) $fatal(1,"Reset left valid ownership");
    endtask

    initial begin
        cycles(3);@(negedge clk);rst_n=1;
        // Fill before any packet can be transmitted. Unsent packets cannot ACK.
        for(i=0;i<D;i=i+1) packet(i+1,32'h10000000+32'(i*256));
        cycles(1);
        if(pending!==D||s_ready) $fatal(1,"Queue did not apply full backpressure");
        response(0,12'd0);
        if(error_count!=1||pending!==D) $fatal(1,"ACK released unsent packet");
        random_ready=1;tx_allow=1;
        wait_packets(D);
        if(pending!==D||sent!==D) $fatal(1,"Sent data not retained");
        errors_before=error_count;
        response(0,12'd8);
        if(error_count!=errors_before+1||pending!==D) $fatal(1,"Future ACK accepted");
        response(0,12'd1);
        if(pending!==2||sent!==2) $fatal(1,"Cumulative ACK failed");
        response(0,12'd1);
        if(pending!==2) $fatal(1,"Duplicate ACK changed ownership");

        // Hold a replay packet on its first beat. An ACK must not release the
        // currently offered payload or allow new writes to overwrite its RAM.
        random_ready=0;allow_ready=0;
        response(1,12'd1);
        wait(m_valid);cycles(2);
        @(negedge clk);rsp_valid=1;rsp_nak=0;rsp_seq=3;
        cycles(15);
        if(rsp_ready||pending!==2) $fatal(1,"ACK freed an active replay");
        @(negedge clk);allow_ready=1;
        do begin @(posedge clk);end while(!rsp_ready);
        @(negedge clk);rsp_valid=0;
        cycles(4);
        if(pending!==0||replay_packets!=1||tx_packets!=D+1)
            $fatal(1,"ACK failed to skip the remaining replay");

        // Oversized packets are drained and rolled back without sequence use.
        packet(W+2,32'hbad00000);cycles(3);
        if(overflow_count!=1||pending!==0||tx_packets!=D+1) $fatal(1,"Overflow rollback failed");
        packet(W,32'h20000000);wait_packets(D+2);
        response(0,12'd4);
        if(pending!==0) $fatal(1,"Maximum packet boundary failed");

        // Concurrent commit and ACK must conserve slots; neither owner is lost.
        packet(1,32'h31000000);wait_packets(D+3);
        fork
            response(0,12'd5);
            packet(1,32'h32000000);
        join
        wait_packets(D+4);response(0,12'd6);
        if(pending!==0) $fatal(1,"Concurrent ACK/commit accounting failed");

        tx_allow=0;packet(2,32'h40000000);word(32'hdeadbeef,0);
        reset_link();tx_allow=1;random_ready=1;
        // Reuse every RAM slot and cross the actual 12-bit sequence wrap.
        for(i=0;i<4094;i=i+1) begin
            packet(1,32'h50000000+32'(i));
            wait_packets(i+1);
            response(0,12'(i));
            if(pending!==0) $fatal(1,"Sequence wrap retire failed at %0d",i);
        end
        // One outstanding window spans 4094,4095,0,1; cumulative NAK and
        // ACK arithmetic must work across wrap, not only for a single packet.
        random_ready=0;tx_allow=0;
        for(i=0;i<D;i=i+1) packet(i+1,32'h58000000+32'(i*256));
        tx_allow=1;wait_packets(4094+D);tx_allow=0;
        response(1,12'hfff);
        if(pending!==2||sent!==2||!replaying) $fatal(1,"Wrapped NAK retirement failed");
        tx_allow=1;wait_packets(4094+D+2);
        response(0,12'd1);
        if(pending!==0||first_sequence!==12'd2) $fatal(1,"Wrapped replay/ACK failed");
        reset_link();random_ready=0;
        // A partial accepted input may drain, but no new TLP may start once
        // replay is active. Committing it cannot overwrite retained payload.
        packet(1,32'h59000000);wait_packets(1);
        expected_words[input_sequence]=2;expected_base[input_sequence]=32'h59100000;
        word(32'h59100000,0);allow_ready=0;response(1,12'hfff);wait(m_valid);
        if(!s_ready) $fatal(1,"Partial input deadlocked by replay");
        word(32'h59100001,1);input_sequence=input_sequence+12'd1;cycles(1);
        if(s_ready||pending!==2) $fatal(1,"New TLP admitted during replay");
        allow_ready=1;wait_packets(3);response(0,12'd1);
        if(pending!==0) $fatal(1,"Partial-input replay ownership failed");
        reset_link();

        // Timeout during a stalled new packet must wait for its boundary.
        packet(1,32'h60000000);wait_packets(1);
        allow_ready=0;packet(3,32'h61000000);wait(m_valid);
        cycles(TIMEOUT+20);
        if(replay_count!=0||pending!==2||sent!==1) $fatal(1,"Timeout truncated active packet");
        allow_ready=1;
        wait(recovery);cycles(3);
        if(replay_count!=3||timeout_count!=3||pending!==2||sent!==2||s_ready||rsp_ready||m_valid)
            $fatal(1,"Retry exhaustion did not quarantine ownership");
        retained_packets=tx_packets;phy_hold=1;cycles(40);
        if(tx_packets!=retained_packets) $fatal(1,"Recovery leaked transmission");
        // Successful retrain resumes the retained window without link reset.
        @(negedge clk);retrain_done=1;phy_hold=0;
        @(negedge clk);retrain_done=0;
        wait_packets(retained_packets+2);response(0,12'd1);
        if(pending!==0||recovery) $fatal(1,"Retrain failed to resume retained packets");
        reset_link();packet(1,32'h70000000);wait_packets(1);response(0,0);
        if(pending!==0) $fatal(1,"Reset recovery/reuse failed");
        // Fill both elastic stages while the first beat is blocked. Fetch
        // must stop at exactly two words, then sustain a DWORD each cycle.
        reset_link();random_ready=0;allow_ready=0;packet(W,32'h71000000);
        wait(m_valid);cycles(5);
        if(!dut.prefetch_valid_q||!dut.output_valid_q||dut.fetch_word_q!=2)
            $fatal(1,"Elastic capacity/first-beat backpressure");
        @(negedge clk);allow_ready=1;
        repeat(W)begin @(posedge clk);if(!m_valid||!m_ready)$fatal(1,"Pipeline bubble");end
        @(negedge clk);wait_packets(1);response(0,0);
        // Stop in the middle and on the final beat; metadata/data must hold,
        // and the final beat must not free the ACK owner before acceptance.
        reset_link();allow_ready=0;packet(W,32'h72000000);wait(m_valid);
        @(negedge clk);allow_ready=1;
        wait(out_word==3);@(negedge clk);allow_ready=0;cycles(8);
        if(out_word!=3||dut.fetch_word_q!=5||!dut.prefetch_valid_q)$fatal(1,"Mid-packet elastic stall");
        @(negedge clk);allow_ready=1;
        wait(m_valid&&m_last);@(negedge clk);allow_ready=0;cycles(8);
        if(out_word!=W-1||sent!=0||pending!=1)$fatal(1,"Final-beat ownership");
        // The response channel may now accept normal ACKs during a copy, but
        // this packet is unsent and must remain owned even under a bad ACK.
        errors_before=error_count;response(0,0);
        if(pending!=1||sent!=0||error_count!=errors_before+1)$fatal(1,"ACK freed stalled unsent packet");
        @(negedge clk);allow_ready=1;wait_packets(1);response(0,0);
        // Link reset invalidates both occupied stages; old RAM remains but
        // cannot emerge as a stale packet after restart.
        reset_link();allow_ready=0;packet(W,32'h73000000);wait(m_valid);cycles(3);
        reset_link();allow_ready=1;cycles(8);
        if(m_valid)$fatal(1,"Stale elastic data after reset");
        packet(1,32'h74000000);wait_packets(1);response(0,0);
        $display("PASS PIPELINED REPLAY: sustained beats, first/middle/final stalls, two occupied stages reset");
        $display("PASS REPLAY: full, unsent/future/duplicate ACK, cumulative ACK, NAK, stalled replay ACK, overflow, concurrent commit, reset, 12-bit wrap, timeout, recovery");
        $finish;
    end
    initial begin #10000000; $fatal(1,"Replay bench watchdog");end
endmodule

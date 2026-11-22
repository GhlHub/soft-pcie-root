# SPDX-License-Identifier: Apache-2.0
"""Exercise the bonded port from the post-EQ, Phase 0, and native PIPE boundaries."""
from pathlib import Path

import pytest

from test_gen3_packet_peer import ack, dllp, fc, tlp
from test_gen3_x2_receive import EDS, sources
from test_multilane import GEN3, RTL, simulate
from test_x2_datapath import body, link_files

FIXTURES = Path(__file__).resolve().parent / 'pcie_soft'


@pytest.mark.parametrize('recover', [False, True])
@pytest.mark.parametrize('entry', ['post-eq', 'phase-zero', 'native', 'native-partial-block'])
def test_gen3_x2_port(tmp_path, recover, entry):
    completion = bytes.fromhex('4a0000010100000400000000') + (0x1234144d).to_bytes(4, 'little')
    app = body(1, 0x4567)

    def block(payload):
        assert len(payload) <= 32
        return f"send_data(256'h{int.from_bytes(payload.ljust(32, bytes(1)), 'little'):064x});"

    init1 = block(b''.join(dllp(fc(kind, 2, 16)) for kind in (0x40, 0x50, 0x60)))
    init2 = block(b''.join(dllp(fc(kind, 2, 16)) for kind in (0xc0, 0xd0, 0xe0)))
    recovery = ''
    if recover:
        recovery = f'{block(bytes(28) + EDS)} send_eieos(); train();'
    source = r'''
module tb;
reg clk=0; always #2 clk=~clk;
reg reset=1, enable=0, command=0, consume=0;
reg [63:0] rx_data=0;
reg [1:0] rx_valid=0,rx_start=0;
reg [3:0] rx_header=0;
reg app_tx_valid=0, app_tx_last=0;
reg [63:0] app_tx_data=0;
wire app_tx_ready;
wire up,active,epoch,failed,error,cmd_ready,rsp,app_valid,app_last;
wire [4:0] state;
wire [63:0] tx_data,app_data,peer_payload;
wire [1:0] tx_valid,tx_start,app_words,peer_words;
wire [3:0] tx_header;
wire [2:0] status;
wire [31:0] result;
PORT_MODE
wire peer_fault,peer_valid,peer_last;
integer cfg_words=0,app_index=0,lock_entries=0;
reg [4:0] last_state=0;
reg expect_owner=0;
reg [22:0] lfsr[0:1];
localparam [127:0] EIEOS=128'hff00ff00ff00ff00ff00ff00ff00ff00;
localparam [127:0] SDS=128'h555555555555555555555555555555e1;
PORT_MODULE root(
 PORT_PINS
 .link_up_o(up),.dl_active_o(active),.error_o(error),.state_o(state),
 .cmd_valid_i(command),.cmd_ready_o(cmd_ready),.cmd_op_i(3'd2),.cmd_address_i(64'b0),
 .cmd_bdf_i(16'h0100),.cmd_data_i(32'b0),.cmd_be_i(4'hf),
 .rsp_valid_o(rsp),.rsp_ready_i(1'b0),.rsp_data_o(result),.rsp_status_o(status),
 .app_tx_data_i(app_tx_data),.app_tx_words_i(2'd2),.app_tx_valid_i(app_tx_valid),
 .app_tx_last_i(app_tx_last),.app_tx_ready_o(app_tx_ready),.app_tx_credits_i(9'd1),
 .app_rx_data_o(app_data),.app_rx_words_o(app_words),
 .app_rx_valid_o(app_valid),.app_rx_last_o(app_last),.app_rx_ready_i(consume));
gen3_x2_receive endpoint_rx(.clk(clk),.reset_i(reset),.enable_i(1'b1),.abort_i(1'b0),
 .lane_data_i(tx_data),.lane_valid_i(tx_valid),.lane_start_i(tx_start),.lane_header_i(tx_header),
 .framing_fault_o(peer_fault),.tlp_data_o(peer_payload),.tlp_words_o(peer_words),.tlp_valid_o(peer_valid),
 .tlp_last_o(peer_last),.tlp_ready_i(1'b1));
always @(posedge clk) if (!reset) begin
    if (failed || error || peer_fault) $fatal(1,"post-EQ fault st=%d root=%b phy=%b",state,error,peer_fault);
    if (expect_owner && !active) $fatal(1,"Recovery dropped data-link ownership");
    if (selected && state==19 && last_state!=19) lock_entries <= lock_entries+1;
    last_state <= state;
    if (peer_valid) begin
        if (cfg_words==0 && (peer_words!=2 || peer_last || peer_payload !== 64'h0f00000001000004))
            $fatal(1,"unexpected configuration header %h",peer_payload);
        if (cfg_words==1 && (peer_words!=1 || !peer_last || peer_payload[31:0] !== 32'h00000001))
            $fatal(1,"unexpected configuration target %h",peer_payload);
        if (cfg_words==2 && (peer_words!=2 || peer_last || peer_payload!==APP0))
            $fatal(1,"unexpected first outbound application beat %h",peer_payload);
        if (cfg_words==3 && (peer_words!=2 || !peer_last || peer_payload!==APP1))
            $fatal(1,"unexpected last outbound application beat %h",peer_payload);
        cfg_words <= cfg_words+1;
    end
    if (app_valid && consume) begin
        if (app_words!=2 || app_last!==app_index[0] || app_data !== (app_index==0 ? APP0 : APP1))
            $fatal(1,"unexpected application TLP beat %d %h",app_index,app_data);
        app_index <= app_index+1;
    end
end
// Encode each lane independently, including 23-bit per-lane seed and TS
// bypass of the first byte. The PHY test observes the outgoing CFG TLP.
task send_block(input [127:0] lane0, lane1, input [1:0] hdr, input bit ts);
    reg [127:0] encoded[0:1], plain[0:1];
    reg [7:0] mask;
    plain[0]=lane0; plain[1]=lane1;
    for (integer lane=0;lane<2;lane=lane+1) begin
        for (integer byte_index=0;byte_index<16;byte_index=byte_index+1) begin
            for (integer bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                mask[bit_index]=lfsr[lane][22];
                lfsr[lane]={lfsr[lane][21:0],1'b0} ^ (lfsr[lane][22] ? 23'h210125 : 23'b0);
            end
            encoded[lane][8*byte_index+:8]=plain[lane][8*byte_index+:8] ^
                ((hdr==2 || (ts && byte_index!=0)) ? mask : 8'b0);
        end
    end
    for (integer word_index=0;word_index<4;word_index=word_index+1) begin
        @(negedge clk);
        rx_valid=3; rx_start=word_index==0 ? 2'b11 : 2'b0; rx_header={hdr,hdr};
        rx_data={encoded[1][32*word_index+:32],encoded[0][32*word_index+:32]};
    end
endtask
task send_eieos;
    send_block(EIEOS,EIEOS,1,0);
    lfsr[0]=23'h1dbfbc; lfsr[1]=23'h0607bb;
endtask
task send_ts(input bit is_ts2);
    reg [127:0] lane0,lane1;
    lane0=is_ts2 ? 128'h45454545454545454500000e2000002d : 128'h4a4a4a4a4a4a00000000000e2000001e;
    lane1=lane0; lane1[23:16]=1;
    send_block(lane0,lane1,1,1);
endtask
task send_eq(input [1:0] ec);
    reg [127:0] lane0,lane1;
    lane0=128'h4a4a4a4a4a4a00000000000e2000001e;
    lane0[55:48]={1'b0,4'd4,1'b0,ec};
    lane0[63:56]=ec==1 ? 40 : 0;
    lane0[71:64]=ec==1 ? 12 : 40;
    lane0[79]=^lane0[78:48];
    lane1=lane0; lane1[23:16]=1;
    send_block(lane0,lane1,1,1);
endtask
task send_data(input [255:0] data);
    reg [127:0] lane0,lane1;
    for(integer byte_index=0;byte_index<16;byte_index=byte_index+1) begin
        lane0[8*byte_index+:8]=data[16*byte_index+:8];
        lane1[8*byte_index+:8]=data[16*byte_index+8+:8];
    end
    send_block(lane0,lane1,2,0);
endtask
task train;
    for (integer set_number=0;set_number<60 && state!=16;set_number=set_number+1) send_ts(0);
    if (state!=16) $fatal(1,"Receiver lock did not qualify");
    for (integer set_number=0;set_number<100 && state!=17;set_number=set_number+1) send_ts(1);
    if (state!=17) $fatal(1,"Configuration did not qualify");
    send_block(SDS,SDS,1,0);
    repeat (8) send_data(0);
    if (!up || !epoch) $fatal(1,"No Gen3 x2 L0 st=%0d",state);
endtask
initial begin
    lfsr[0]=0; lfsr[1]=0;
    repeat(4) @(negedge clk); reset=0; enable=1;
    @(negedge clk); enable=0;
    STARTUP
    train();
    repeat(8) begin INIT1 end
    repeat(8) begin INIT2 end
    @(negedge clk); rx_valid=0;
    wait(active && cmd_ready);
    @(negedge clk); command=1;
    @(negedge clk); command=0;
    wait (cfg_words==2);
    expect_owner=1;
    RECOVERY
    COMPLETION
    APPLICATION
    repeat (4) send_data(0);
    @(negedge clk); rx_valid=0; consume=1;
    wait(rsp && app_index==2);
    if (status!=0 || result!=32'h1234144d || lock_entries!=EXPECTED_LOCKS)
        $fatal(1,"wrong completion %h/%d or startup count %d",result,status,lock_entries);
    @(negedge clk); app_tx_data=APP0; app_tx_valid=1; app_tx_last=0;
    do @(posedge clk); while(!app_tx_ready);
    @(negedge clk); app_tx_data=APP1; app_tx_last=1;
    do @(posedge clk); while(!app_tx_ready);
    @(negedge clk); app_tx_valid=0;
    wait(cfg_words==4);
    $display("PASS Gen3 x2 port"); $finish;
end
initial begin #120000; $fatal(1,"timeout state=%0d active=%b cfg_words=%d",state,active,cfg_words); end
endmodule
'''
    replacements = {
        'INIT1': init1, 'INIT2': init2, 'RECOVERY': recovery,
        'COMPLETION': block(dllp(ack(0)) + tlp(0, completion)),
        'APPLICATION': block(tlp(1, app)),
        'APP0': f"64'h{int.from_bytes(app[:8], 'little'):016x}",
        'APP1': f"64'h{int.from_bytes(app[8:], 'little'):016x}",
        'EXPECTED_LOCKS': str(1 + recover),
    }
    port_pins = '''
 .clk(clk),.reset_i(reset),.phy_ready_i(2'b11), PORT_CONTROL
 .rx_data_i(rx_data),.rx_valid_i(rx_valid),.rx_start_i(rx_start),.rx_header_i(rx_header),
 .tx_data_o(tx_data),.tx_valid_o(tx_valid),.tx_start_o(tx_start),.tx_header_o(tx_header),'''
    if entry != 'post-eq':
        replacements.update({
            'PORT_MODULE': 'gen3_x2_port #(.GUARD_CYCLES(3),.REQUEST_CYCLES(400),'
                           '.EVALUATE_CYCLES(12),.APPLY_CYCLES(20))',
            'PORT_PINS': port_pins.replace('PORT_CONTROL', '''
 .phase0_i(enable),.handoff_i(applied_rate==2),.legacy_idle_i(1'b1),.rx_idle_i(2'b11),
 .phy_fs_i(6'd40),.phy_lf_i(6'd12),.phy_coeff_i({2{{6'd0,6'd40,6'd0}}}),
 .phy_rx_proposal_i(36'b0),.txeq_done_i(tx_done),.rxeq_done_i(rx_done),
 .rxeq_adapt_done_i(2'b11),.rxeq_preset_sel_i(2'b0),
 .txeq_ctrl_o(tx_eq_ctrl),.rxeq_ctrl_o(rx_eq_ctrl),.rate_allowed_o(rate_allowed),
 .selected_o(selected),'''),
            'PORT_MODE': r'''
wire [3:0] tx_eq_ctrl,rx_eq_ctrl;
wire selected,rate_allowed;
wire [1:0] rate,applied_rate;
reg [1:0] tx_done=0,rx_done=0,rate_done=0;
reg [1:0] saw_apply=0,saw_query=0,saw_rate=0;
integer tx_ticks[0:1], rx_ticks[0:1], rate_ticks=0, cadence_words=0;
assign failed=state==31;
assign epoch=root.data_link.epoch_o;
gen3_native_x2_rate #(.IDLE_CYCLES(4),.TIMEOUT_CYCLES(90)) native_rate(
 .clk(clk),.rst_n(!reset),.request_i(rate_allowed && !selected),.target_i(2'd2),
 .tx_idle_i(1'b1),.rx_idle_i(2'b11),.phy_ready_i(2'b11),.phystatus_i(rate_done),
 .phy_rate_o(rate),.applied_rate_o(applied_rate));
always @(negedge clk) begin
    for (integer lane=0;lane<2;lane=lane+1) begin
        if (reset || tx_eq_ctrl[2*lane+:2]==0) tx_ticks[lane]=0;
        else tx_ticks[lane]=tx_ticks[lane]+1;
        tx_done[lane]=!reset && tx_ticks[lane]==3+4*lane;
        if (tx_done[lane] && tx_eq_ctrl[2*lane+:2]==1) saw_apply[lane]=1;
        if (tx_done[lane] && tx_eq_ctrl[2*lane+:2]==3) saw_query[lane]=1;
        if (reset || rx_eq_ctrl[2*lane+:2]!=2) rx_ticks[lane]=0;
        else rx_ticks[lane]=rx_ticks[lane]+1;
        rx_done[lane]=!reset && rx_ticks[lane]==3+4*lane;
    end
    if (rate==2) rate_ticks=rate_ticks+1;
    rate_done[0]=rate_ticks==3;
    rate_done[1]=rate_ticks==7;
    saw_rate=saw_rate | rate_done;
end
always @(posedge clk) if (!reset) begin
    if (rate!=0 && (saw_apply!=3 || saw_query!=3)) $fatal(1,"RATE preceded Phase 0 PHY replies");
    if (selected && saw_rate!=3) $fatal(1,"Started Gen3 before both fresh RATE replies");
    if (cmd_ready && !active) $fatal(1,"Startup admitted a command");
    if (&tx_valid) cadence_words <= cadence_words + 1;
    else if (cadence_words != 0) begin
        if (cadence_words != 64) $fatal(1,"EQ handoff lost PIPE cadence after %0d words",cadence_words);
        cadence_words <= 0;
    end
end''',
            'STARTUP': '''
    wait(selected);
    send_eieos();
    for (integer n=0;n<40 && state!=21;n=n+1) send_eq(1);
    if (state!=21) $fatal(1,"Phase 1 did not qualify both lanes");
    for (integer n=0;n<80 && state!=19;n=n+1) send_eq(3);
    if (state!=19) $fatal(1,"Both lanes did not complete adaptive EQ");''',
        })
    else:
        replacements.update({
            'PORT_MODULE': 'gen3_x2_post_port #(.HANDSHAKE_CYCLES(1500))',
            'PORT_PINS': port_pins.replace('PORT_CONTROL', '''
 .start_i(enable),.tx_preset_i(8'h44),.tx_coeff_i({2{{6'd0,6'd40,6'd0}}}),
 .epoch_o(epoch),.failed_o(failed),
 .eq_active_i(1'b0),.eq_restart_interval_i(1'b0),.eq_failed_i(1'b0),.eq_fields_i(64'b0),'''),
            'PORT_MODE': "wire selected=1'b1;",
            'STARTUP': 'send_eieos();',
        })
    if entry.startswith('native'):
        replacements.update({
            'PORT_MODE': (FIXTURES / 'gen3_x2_native_peer.svh').read_text(),
            'PORT_MODULE': 'gen3_native_x2 #(.GEN2_ENABLE(1),.GEN3_ENABLE(1))',
            'PORT_PINS': '''
 .reset_i(reset),.enable_i(1'b1),.force_gen1_i(1'b0),
 .refclk_p_i(clk),.refclk_n_i(!clk),.rx_p_i(2'b00),.rx_n_i(2'b11),''',
        })
        if entry == 'native-partial-block':
            replacements['STARTUP'] = replacements['STARTUP'].replace('    send_eieos();', '''
    repeat (3) begin
        @(negedge clk);
        rx_valid=3; rx_start=0; rx_header=4'b0101;
        rx_data=64'h1234560a876543fd;
    end
    send_eieos();''', 1)
    for name, code in replacements.items():
        source = source.replace(name, code)
    files = sources() + link_files() + [GEN3 / f'{name}.sv' for name in (
        'gen3_x2_post_port', 'gen3_x2_post_eq', 'gen3_x2_recovery_tx', 'gen3_recovery_tx',
    )]
    if entry != 'post-eq':
        files += [GEN3 / f'{name}.sv' for name in (
            'gen3_native_x2_rate', 'gen3_x2_port', 'gen3_x2_initial_eq', 'gen3_multilane_eq',
            'gen3_training_rx', 'gen3_training_tx', 'gen3_eq_phase1', 'gen3_eq_adapt',
        )]
    if entry.startswith('native'):
        files += [GEN3 / f'{name}.sv' for name in (
            'gen3_native_x2', 'gen3_legacy_x2_pipe', 'gen3_legacy_x2_phy',
            'gen3_multilane_startup', 'gen3_legacy_training',
        )]
        files += sorted(RTL.glob('*.sv'))
        files.append(FIXTURES / 'tb_gen3_x2_phy_model.sv')
    simulate(tmp_path, source, list(dict.fromkeys(files)))

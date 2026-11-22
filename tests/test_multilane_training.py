# SPDX-License-Identifier: Apache-2.0
"""Shared training simulations. No generated PHY or packet backend is modeled."""
from pathlib import Path
import subprocess
import pytest
from test_multilane import simulate

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'experiments/gen3'


STARTUP_FAULTS = ['none', 'missing', 'wrong-lane', 'control', 'rate-mismatch',
                  'recovery-timeout', 'recovery-config-timeout', 'absent', 'polarity',
                  'finite-ts2', 'insufficient-ts2', 'polling-ts1-only']


@pytest.mark.parametrize('width,fault', [(w, f) for w in (1, 2) for f in STARTUP_FAULTS
                                       if w == 2 or f != 'rate-mismatch'])
@pytest.mark.parametrize('skew', [0, 3, 11])
def test_shared_startup_wire_peer(tmp_path, width, skew, fault, poll_tx=16):
    polling_timeout = fault == 'polling-ts1-only'
    poll_cycles = max(3000, poll_tx * 10)
    # Real two-symbol training codecs in both directions; peer observes decoded
    # transmitted TS, not internal controller state. Lane skew delays its start.
    source = f'''`default_nettype none
module tb;
localparam W={width};
reg clk=0;always #2 clk=~clk;
reg rst=1,retrain=0;reg[W-1:0] phy='1,detect_done=0,present='1;
wire detect,ei,lp,np,l0,up,epoch,failed,retrained;wire[4:0] state;wire[1:0] kind;
wire[W*8-1:0] lanes;wire[W-1:0] polarity;
wire[W-1:0] ts,ts2,inverted,bad,rlp,rnp,txdone,rv,idle,txidle,rx_error;
wire[W*8-1:0] rlink,rlane,rate,control;wire[W*2-1:0] txkind;
wire[127:0] polling_debug;
wire[31:0] last_lane_debug=polling_debug[32*(W-1)+:32];
integer tick=0,seen_l0=0,recoveries=0,recovery_start_tick=0;reg saw_rec_config=0;
gen3_multilane_startup #(.LINK_WIDTH(W),.QUIET_CYCLES(2),.POLL_CYCLES({poll_cycles}),
 .CONFIG_CYCLES(2000),.RECOVERY_CYCLES(3000),.POLL_TX_COUNT({poll_tx}),
 .GEN2_ENABLE({int(polling_timeout)}),.GEN3_ENABLE({int(polling_timeout)})) dut(
 .clk(clk),.reset_i(rst),.enable_i(1'b1),.phy_ready_i(phy),.rx_electrical_idle_i({{W{{1'b1}}}}),
 .detect_done_i(detect_done),.receiver_present_i(present),.ts_valid_i(ts),.ts2_i(ts2),
 .inverted_i(inverted),.ts_bad_i(bad),.rx_link_i(rlink),.rx_lane_i(rlane),.rx_rate_i(rate),
 .rx_control_i(control),.rx_link_pad_i(rlp),.rx_lane_pad_i(rnp),.tx_ts_done_i(txdone),
 .tx_ts_kind_i(txkind),.rx_symbol_valid_i(rv),.rx_idle_pair_i(idle),.tx_idle_pair_i(txidle),
 .rx_error_i(rx_error),.retrain_i(retrain),.detect_o(detect),.electrical_idle_o(ei),
 .force_gen1_i(1'b0),.phy_gen2_i(1'b0),.phy_gen3_i(1'b0),.phy_rate_ready_i(1'b1),.eios_done_i(1'b0),
 .tx_kind_o(kind),.tx_lane_o(lanes),.polarity_o(polarity),.tx_link_pad_o(lp),.tx_lane_pad_o(np),
 .l0_o(l0),.link_up_o(up),.epoch_started_o(epoch),.failed_o(failed),
 .retrain_done_o(retrained),.state_o(state),.polling_debug_o(polling_debug));
always @(negedge clk) if(!rst) begin
 tick=tick+1;detect_done=0;
 for(integer k=0;k<W;k=k+1) if(detect && tick==(5+k*{skew})) detect_done[k]=1;
 if(failed && (&phy)) $fatal(1,"unexpected failure state %0d tick %0d",state,tick);
 if(state==12)saw_rec_config=1;
 if(l0)seen_l0=seen_l0+1;if(retrained)recoveries=recoveries+1;
end
for(genvar k=0;k<W;k=k+1) begin : peers
 localparam integer LANE_INDEX=k;
 wire[15:0] local_data,peer_data;wire[1:0] local_k,peer_k;
 wire local_valid,peer_valid,peer_event,peer_ts2,peer_lp,peer_np;
 wire[7:0] peer_link,peer_lane;
 reg[1:0] peer_kind=1;reg peer_link_pad=1,peer_lane_pad=1;
 reg[7:0] assigned_link=0,assigned_lane=0;
 integer completes=0;
 wire started=tick>20+k*{skew};
 wire local_ready=1;
 localparam integer FINITE_TS2={12 if fault == 'finite-ts2' else 6 if fault == 'insufficient-ts2' else 0};
 wire early_idle=FINITE_TS2!=0 && k==W-1 && !epoch;
 reg peer_was_valid=0;
 always @(posedge clk) peer_was_valid <= peer_valid;
 assign rx_error[k]=early_idle && completes>=FINITE_TS2 && peer_was_valid && !peer_valid;
 assign rv[k]=started;
 assign idle[k]=started && !peer_valid;
 assign txidle[k]=!local_valid;
 gen3_legacy_training local_codec(
 .clk(clk),.rst_n(!rst),.tx_ready_i(local_ready),.tx_kind_i(kind),.tx_link_i(8'd0),
 .tx_lane_i(lanes[8*k+:8]),.tx_control_i(8'd0),.tx_link_pad_i(lp),.tx_lane_pad_i(np),
 .tx_data_o(local_data),.tx_ctrl_o(local_k),.tx_valid_o(local_valid),.tx_done_o(txdone[k]),
 .tx_kind_o(txkind[2*k+:2]),.rx_data_i(peer_valid?peer_data:16'd0),
 .rx_ctrl_i(peer_valid?peer_k:2'd0),.rx_valid_i(started),.rx_error_i(rx_error[k]),
 .rx_ts_valid_o(ts[k]),.rx_ts2_o(ts2[k]),.rx_inverted_o(inverted[k]),.rx_bad_o(bad[k]),
 .rx_link_o(rlink[8*k+:8]),.rx_lane_o(rlane[8*k+:8]),.rx_rate_o(rate[8*k+:8]),
 .rx_control_o(control[8*k+:8]),.rx_link_pad_o(rlp[k]),.rx_lane_pad_o(rnp[k]),
 .tx_eq_i(1'b0),.tx_preset_i(4'd4),.tx_rate_i(8'h0e));
 gen3_legacy_training peer_codec(
 .clk(clk),.rst_n(!rst && started),.tx_ready_i(1'b1),.tx_kind_i(peer_kind),
 .tx_link_i(assigned_link),.tx_lane_i(assigned_lane),.tx_control_i(8'd0),
 .tx_link_pad_i(peer_link_pad),.tx_lane_pad_i(peer_lane_pad),
 .tx_data_o(peer_data),.tx_ctrl_o(peer_k),.tx_valid_o(peer_valid),
 .rx_data_i(local_valid?local_data:16'd0),.rx_ctrl_i(local_valid?local_k:2'd0),
 .rx_valid_i(1'b1),.rx_error_i(1'b0),.rx_ts_valid_o(peer_event),.rx_ts2_o(peer_ts2),
 .rx_link_o(peer_link),.rx_lane_o(peer_lane),.rx_link_pad_o(peer_lp),.rx_lane_pad_o(peer_np),
 .tx_eq_i(1'b0),.tx_preset_i(4'd4),.tx_rate_i(8'h0e));
 always @(negedge clk) if(!rst && started && peer_event) begin
  assigned_link=peer_link;assigned_lane=peer_lane;peer_link_pad=peer_lp;peer_lane_pad=peer_np;
  if(!peer_ts2) begin peer_kind=1;completes=0;end
  else if(peer_lp || peer_np) peer_kind=({int(polling_timeout)} && k==W-1)?1:2;
  else begin completes=completes+1;peer_kind=completes>=(early_idle?FINITE_TS2:16)?0:2;end
 end
end
initial begin
 repeat(3) @(negedge clk);rst=0;
 wait(l0);repeat(3) @(negedge clk);#1;
 if(!epoch || !up || lanes!=={width*8}'h{(0x100 if width==2 else 0):x}) $fatal(1,"lane assignment");
 retrain=1;@(negedge clk);#1;retrain=0;
 repeat(3) @(negedge clk);if(!epoch || !up || l0) $fatal(1,"recovery ownership");
 wait(retrained);repeat(3) @(negedge clk);
 if(!l0 || recoveries!=1) $fatal(1,"shared recovery");
 phy[W-1]=0;@(negedge clk);#1;
 if(!failed || l0 || up || !epoch) $fatal(1,"failed recovery erased history");
 $display("PASS shared wire training");$finish;
end
initial begin #60000;$fatal(1,"timeout state %0d",state);end
endmodule'''
    if fault == 'polarity':
        source = source.replace('.rx_data_i(peer_valid?peer_data:16\'d0)',
            ".rx_data_i(peer_valid?((LANE_INDEX==W-1 && !polarity[LANE_INDEX] && peer_data==16'h4a4a)?16'hb5b5:peer_data):16'd0)")
        source = source.replace(' retrain=1;', ' if(polarity!==(1<<(W-1))) $fatal(1,"per-lane polarity");\n retrain=1;',1)
    elif fault not in ('none', 'finite-ts2'):
        source = source.replace('if(failed && (&phy)) $fatal', "if(1'b0) $fatal")
        if fault == 'absent':
            source = source.replace('rst=0;', 'rst=0;present[W-1]=0;',1)
        elif fault == 'missing':
            source = source.replace('wire started=tick>', 'wire started=(k!=W-1) && tick>')
        elif fault == 'wrong-lane':
            source = source.replace('.tx_lane_i(assigned_lane)', ".tx_lane_i(assigned_lane ^ (LANE_INDEX==W-1?8'd1:8'd0))")
        elif fault == 'control':
            source = source.replace('.tx_lane_i(assigned_lane),.tx_control_i(8\'d0)',
                                    ".tx_lane_i(assigned_lane),.tx_control_i(LANE_INDEX==W-1?8'd1:8'd0)")
        elif fault == 'rate-mismatch':
            # Only peer encoder; local advertised capability remains unchanged.
            anchor = source.index('gen3_legacy_training peer_codec')
            source = source[:anchor] + source[anchor:].replace(".tx_rate_i(8'h0e)", ".tx_rate_i(LANE_INDEX==W-1?8'h06:8'h0e)")
        elif fault == 'recovery-config-timeout':
            source = source.replace('wire started=tick>', 'wire started=!(epoch && kind==2 && k==W-1) && tick>')
        elif fault == 'recovery-timeout':
            source = source.replace('wire started=tick>', 'wire started=!(epoch && k==W-1) && tick>')
        begin = source.index(' wait(l0);repeat(3)')
        end = source.index(' $display("PASS shared wire training")', begin)
        prelude = ' wait(l0);@(negedge clk);#1;recovery_start_tick=tick;retrain=1;@(negedge clk);#1;retrain=0;\n' if fault.startswith('recovery-') else ''
        source = source[:begin] + prelude + f'''
 wait(failed);@(negedge clk);#1;
 if(l0 || up || epoch!==1'b{int(fault.startswith('recovery-'))}) $fatal(1,"bad lane escaped failure/drain history");
 if({int(fault=='recovery-config-timeout')} && (!saw_rec_config || tick-recovery_start_tick>3003))
 $fatal(1,"Recovery deadline restarted between substates");
 repeat(10) @(negedge clk);if(!failed) $fatal(1,"failure not sticky");
 if({int(polling_timeout)}) begin
  if(polling_debug[127:96]!==32'h58504331 || polling_debug[95:64]!==32'd{2*poll_cycles-1})
   $fatal(1,"missing held Polling.Configuration timeout: %h",polling_debug);
  if(last_lane_debug[31:22]!==10'b0 || last_lane_debug[21:20]!==2'b10 ||
    last_lane_debug[15:0]!==16'h0e00) $fatal(1,"wrong stalled-lane history: %h",last_lane_debug);
  if(W==2 && (polling_debug[31:27]<8 || polling_debug[26:22]<16 || !polling_debug[20]))
   $fatal(1,"other lane never met the polling requirements: %h",polling_debug[31:0]);
 end
''' + source[end:]
    simulate(tmp_path, source, [SRC/'gen3_multilane_startup.sv', SRC/'gen3_legacy_training.sv'])


@pytest.mark.parametrize('width', [1, 2])
def test_training_lint(width):
    for module, deps in [
        ('gen3_multilane_startup', []),
        ('gen3_multilane_eq', ['gen3_training_rx', 'gen3_training_tx', 'gen3_eq_phase1', 'gen3_eq_adapt']),
    ]:
        result = subprocess.run(['verilator', '--lint-only', '-Wall', '--top-module', module,
                                 f'-GLINK_WIDTH={width}',
                                 *[str(SRC/(name+'.sv')) for name in [module, *deps]]],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout+result.stderr


class LanePeer:
    """Independent byte-wise Gen3 peer, not the RTL training transmitter."""
    def __init__(self, lane, delay=0):
        self.lane = lane
        self.seed = (0x1dbfbc, 0x0607bb)[lane]
        self.state = self.seed
        self.rows = [(0, 0, 0)] * delay

    def block(self, data, scramble=False):
        wire = []
        for byte_no, byte in enumerate(data):
            mask = 0
            for bit in range(8):
                feedback = (self.state >> 22) & 1
                mask |= feedback << bit
                self.state = ((self.state << 1) & 0x7fffff) ^ (0x210125 if feedback else 0)
            wire.append(byte ^ mask if scramble and byte_no else byte)
        for offset in range(0, 16, 4):
            self.rows.append((int.from_bytes(bytes(wire[offset:offset+4]), 'little'), 1, int(offset == 0)))
        self.rows += [(0, 0, 0)] * 2

    def eieos(self):
        self.block(bytes([0, 255]) * 8)
        self.state = self.seed

    def ts(self, ec, bad_lane=False, bad_parity=False, rate=0x0e):
        fields = [ec | ((4+self.lane) << 3), 40 if ec == 1 else 0,
                  12 if ec == 1 else 40, 0]
        fields[3] |= (sum(x.bit_count() for x in fields) & 1) << 7
        if bad_parity:
            fields[3] ^= 0x80
        self.block(bytes([0x1e, 0, self.lane ^ int(bad_lane), 32, rate, 0, *fields,
                          0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a]), scramble=True)


@pytest.mark.parametrize('width', [1, 2])
@pytest.mark.parametrize('scenario', ['normal', 'skew', 'late-adapt', 'missing-lane',
                                     'wrong-lane', 'bad-parity', 'missing-preset', 'phy-loss',
                                     'bad-rate', 'adapt-timeout', 'config-change', 'stale-success',
                                     'cancel-reenter', 'alignment-loss', 'orphan-before-eieos',
                                     'orphan-after-eieos'])
def test_shared_equalization_wire_peer(tmp_path, width, scenario):
    peers = []
    for lane in range(width):
        victim = lane == width-1
        p = LanePeer(lane, delay=(25 if scenario=='skew' else 50) if scenario in ('skew', 'alignment-loss') and victim else 0)
        if scenario == 'orphan-before-eieos':
            p.rows.extend([(0x785634fd, 1, 0)] * (2 + lane))
        p.eieos()
        if victim and scenario == 'orphan-after-eieos':
            p.rows.append((0x785634fd, 1, 0))
        for index in range(10):
            p.ts(1, bad_lane=victim and scenario == 'wrong-lane',
                 bad_parity=victim and scenario == 'bad-parity',
                 rate=0x8e if victim and scenario == 'bad-rate' else 0x0e)
            if scenario=='alignment-loss' and lane==0 and index==2:
                p.block(bytes([0x66])*16)
        for index in range(70):
            p.ts(3, bad_lane=(scenario == 'stale-success' and lane == 0 and index == 18))
        if victim and scenario == 'missing-lane':
            p.rows = []
        if scenario == 'cancel-reenter':
            p.rows = p.rows[:81] + p.rows
        peers.append(p)
    cycles = 1100
    vectors = tmp_path/'peer.hex'
    values = []
    for cycle in range(cycles):
        data = valid = start = 0
        for lane, peer in enumerate(peers):
            word, v, st = peer.rows[cycle] if cycle < len(peer.rows) else (0, 0, 0)
            data |= word << (32*lane)
            valid |= v << lane
            start |= st << lane
        values.append(data | (valid << (32*width)) | (start << (33*width)))
    vectors.write_text(''.join(f'{value:0{(34*width+3)//4}x}\n' for value in values))
    success = scenario in ('normal', 'skew', 'late-adapt', 'config-change', 'cancel-reenter',
                           'orphan-before-eieos')
    preset = sum((4+lane) << (4*lane) for lane in range(width))
    coeff = sum((40 << 6) << (18*lane) for lane in range(width))
    fs = sum(40 << (6*lane) for lane in range(width))
    lf = sum(12 << (6*lane) for lane in range(width))
    simulate(tmp_path, f'''module tb;
localparam W={width};reg clk=0;always #2 clk=~clk;
reg rst=1,enter=0,cancel=0;reg[W-1:0] phy='1,preset_ack='1,rxack=0;
reg[34*W-1:0] vectors[0:{cycles-1}];reg[34*W-1:0] row=0;
wire active,done,failed;wire[1:0] phase;wire[W-1:0] p1,p23;
wire[127:0] failure_debug;
wire[2*W-1:0] rctrl,tctrl,txheader;wire[32*W-1:0] txdata;wire[W-1:0] txvalid,txstart;
reg[4*W-1:0] requested_preset={4*width}'h{preset:x};
integer tick,k,successes=0;
integer pending[0:W-1];
gen3_multilane_eq #(.LINK_WIDTH(W),.PHASE1_CYCLES(200),.PHASE2_CYCLES(400),
 .PHASE3_CYCLES(600),.TOTAL_CYCLES(1000),.SETTLE_CYCLES(2),.REQUEST_CYCLES(300),
 .EVALUATE_CYCLES(8),.APPLY_CYCLES(16)) dut(
 .clk(clk),.reset_i(rst),.enter_i(enter),.cancel_i(cancel),.phy_ready_i(phy),
 .preset_applied_i(preset_ack),.preset_i(requested_preset),
 .local_fs_i({6*width}'h{fs:x}),.local_lf_i({6*width}'h{lf:x}),
 .initial_coeff_i({18*width}'h{coeff:x}),.rx_data_i(row[32*W-1:0]),
 .rx_valid_i(row[32*W+:W]),.rx_start_i(row[33*W+:W]),.rx_header_i({{W{{2'b01}}}}),
 .txeq_done_i({{W{{1'b0}}}}),.rxeq_done_i(rxack),.rxeq_adapt_done_i({{W{{1'b1}}}}),
 .rxeq_preset_sel_i({{W{{1'b0}}}}),.txeq_coeff_i({18*width}'h{coeff:x}),
 .rxeq_proposal_i({18*width}'d0),.rxeq_ctrl_o(rctrl),.txeq_ctrl_o(tctrl),
 .tx_data_o(txdata),.tx_valid_o(txvalid),.tx_start_o(txstart),.tx_header_o(txheader),
 .active_o(active),.done_o(done),.failed_o(failed),.phase_o(phase),
 .phase1_complete_o(p1),.phase23_complete_o(p23),.failure_debug_o(failure_debug));
for(genvar lane=0;lane<W;lane=lane+1) begin : output_checks
 wire good;wire[1:0] ec;wire[5:0] fs,lf;wire[31:0] fields;
 gen3_training_rx #(.LANE_ID(lane)) monitor(.clk(clk),.reset_i(rst),.enable_i(1'b1),
  .data_i(txdata[32*lane+:32]),.valid_i(txvalid[lane]),.start_i(txstart[lane]),
  .header_i(txheader[2*lane+:2]),.ts1_valid_o(good),.ec_o(ec),.fs_o(fs),.lf_o(lf),.symbols6_9_o(fields));
 always @(posedge clk) if(good && ec==1) begin
  if(fs!=40 || lf!=12 || fields[6:3]!==4'(4+lane)) $fatal(1,"attempt configuration changed");
 end
end
always @(posedge clk) if(!rst) begin
 if(phase==2 && !(&p1)) $fatal(1,"adapt entered before all lanes qualified");
 if(done) begin
  successes=successes+1;
  if(!(&p23) || failed) $fatal(1,"premature/shared success");
 end
 if(failed && (rctrl!=0 || tctrl!=0)) $fatal(1,"PHY controls survived quarantine");
end
initial begin
 $readmemh("{vectors}",vectors);
 for(k=0;k<W;k=k+1)pending[k]=0;
 repeat(3) @(negedge clk);rst=0;enter=1;
 @(negedge clk);enter=0;
 if({int(scenario=='missing-preset')}) preset_ack[W-1]=0;
 for(tick=0;tick<{cycles};tick=tick+1) begin
  row=vectors[tick];
  if({int(scenario=='cancel-reenter')}) begin cancel=(tick==75);enter=(tick==80);end
  if({int(scenario=='config-change')} && tick==20) requested_preset='0;
  if({int(scenario=='phy-loss')} && tick==75) phy[W-1]=0;
  for(k=0;k<W;k=k+1) begin
   if(rctrl[2*k+:2]==2) begin
    pending[k]=pending[k]+1;
    rxack[k]=pending[k]>(({int(scenario in ('late-adapt', 'stale-success'))} && k==W-1)?80:2);
    if({int(scenario=='adapt-timeout')} && k==W-1)rxack[k]=0;
   end else begin pending[k]=0;rxack[k]=0;end
  end
  @(negedge clk);
 end
 if({int(success)}) begin
  if(successes!=1 || failed || active) $fatal(1,"EQ success missing: %0d fail%b phase%0d p1%b p23%b",successes,failed,phase,p1,p23);
  if(failure_debug!==0) $fatal(1,"successful EQ recorded a failure");
 end else if(successes || !failed || active) $fatal(1,"bad lane escaped shared deadline");
 else if(failure_debug[127:96]!==32'h58455131 || (^failure_debug)===1'bx)
  $fatal(1,"missing or incomplete EQ failure record: %h",failure_debug);
 if({int(scenario == 'orphan-after-eieos')} && failure_debug[32*(W-1)+29+:3]!==3'd4)
  $fatal(1,"orphan continuation after alignment escaped the decoder diagnostic");
 $display("PASS shared Gen3 equalization");$finish;
end
endmodule''', [SRC/(name+'.sv') for name in ['gen3_multilane_eq', 'gen3_training_rx',
                                           'gen3_training_tx', 'gen3_eq_phase1', 'gen3_eq_adapt']])


def test_full_poll_transmit_requirement(tmp_path):
    test_shared_startup_wire_peer(tmp_path, 2, 3, 'none', poll_tx=1024)

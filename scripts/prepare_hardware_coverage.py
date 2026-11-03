#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create an isolated, instrumented source snapshot; never alter normal RTL.

The fallback image reports PHY-not-ready to the adaptive controller only,
forcing its normal failure/stop/fallback path before any ownership exists.
The recovery image arms once on an accepted LPR start command (op7,0x10,1),
then requests the existing same-rate Recovery path during an RX packet.
No PHY reset, clock interruption, ownership reset or protocol bypass is added.
Both replace the informational completion diagnostics with HWT1 counters.
"""
import argparse, hashlib, io, json, subprocess, tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROL = r"""
    // Diagnostic-only overlay. Absent from the normal catalog source.
    reg hw_armed;
    reg hw_pulse;
    reg [31:0] hw_triggers;
    reg [15:0] hw_entries, hw_returns;
    reg [4:0] hw_previous;
    reg [31:0] hw_flags;
    wire hw_arm = cmd_valid_i && cmd_ready_o && cmd_op_i == 7 &&
                  cmd_address_i == 64'h10 && cmd_data_i == 1;
    always @(posedge clk) begin
        if (reset_i) begin
            hw_armed <= 0;
            hw_pulse <= 0;
            hw_triggers <= 0;
            hw_entries <= 0;
            hw_returns <= 0;
            hw_previous <= 0;
            hw_flags <= 0;
        end else begin
            hw_previous <= state;
            hw_pulse <= 0;
            if (hw_arm && HW_MODE == 2 && state == RL0) hw_armed <= 1;
            if (HW_MODE == 1 && state == ADAPT && hw_triggers == 0) begin
                hw_triggers <= 1;
                hw_flags <= 32'h1;
            end
            if (hw_armed && state == RL0 && packet_active && dl_active_o) begin
                hw_pulse <= 1;
                hw_armed <= 0;
                hw_triggers <= hw_triggers + 1'b1;
                hw_flags <= {28'b0, link_pending, dl_active_o, packet_active, 1'b0};
            end
            if (state == RLOCK && hw_previous != RLOCK) hw_entries <= hw_entries + 1'b1;
            if (state == RL0 && hw_previous != RL0 && hw_entries != hw_returns)
                hw_returns <= hw_returns + 1'b1;
        end
    end
"""

def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)

def instrument(root, mode):
    p = root / 'experiments/gen3/gen3_eq_bringup.sv'
    text = p.read_text()
    text = replace_once(text, '    reg [15:0] dllp_count, receive_errors, ts2_count;',
        '    localparam integer HW_MODE = ' + str(mode) + ';\n' + CONTROL +
        '\n    reg [15:0] dllp_count, receive_errors, ts2_count;')
    start = text.index('    assign last_ts_o=')
    end = text.index(';', start) + 1
    text = text[:start] + "    assign last_ts_o = {32'h48575431, hw_triggers, hw_entries, hw_returns, hw_flags};" + text[end:]
    if mode == 1:
        text = replace_once(text, '.phy_ready_i      (phy_ready_i),',
            '.phy_ready_i      (phy_ready_i && !(state == ADAPT && !reached_l0)),')
    else:
        text = replace_once(text, 'if (error_rx || (DATALINK_ENABLE != 0 ? packet_diagnostic[1] : parser_error) ||',
            'if (hw_pulse || error_rx || (DATALINK_ENABLE != 0 ? packet_diagnostic[1] : parser_error) ||')
    p.write_text(text)
    p = root / 'experiments/gen3/gen3_native_root.sv'
    text = p.read_text()
    text = replace_once(text, "completion_debug_o <= fallback_selected ? g2_debug :\n                rate == 0 ? {32'h4c475331, startup_history, status[31:0]} : last_ts;",
        "completion_debug_o <= fallback_selected ? {32'h48574631, status[31:0], last_ts[95:64], last_ts[31:0]} : last_ts;")
    # Keep diagnostic launch flops distinct. Identical magic/flag bits otherwise
    # merge and fan out to independent existing synchronizer chains (CDC-11).
    text = replace_once(text, '    output reg [127:0] completion_debug_o,',
                        '    output wire [127:0] completion_debug_o,')
    text = replace_once(text, '    wire gtref, rawref, refclk, pclk;',
        '    (* DONT_TOUCH = "TRUE" *) reg [127:0] hw_debug_q;\n'
        '    assign completion_debug_o = hw_debug_q;\n'
        '    wire gtref, rawref, refclk, pclk;')
    text = text.replace('completion_debug_o     <=', 'hw_debug_q             <=')
    text = text.replace('completion_debug_o <=', 'hw_debug_q <=')
    p.write_text(text)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=('fallback', 'recovery'))
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(['git', 'archive', revision], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tf:
        tf.extractall(args.output, filter='data')
    instrument(args.output, 1 if args.mode == 'fallback' else 2)
    (args.output / 'diagnostic-provenance.json').write_text(json.dumps({
        'base_revision': revision, 'mode': args.mode,
        'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'warning': 'Diagnostic injection image only; not a release or SD default',
    }, indent=2) + '\n')
    print(args.output)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Add local PHY observations and an explicit optional startup-clock correction.

Never vendor generated output. Fail on changed insertion anchors. Without the
startup flag, existing assignments remain unchanged.
"""
import hashlib
import json
from pathlib import Path
import sys

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f'Expected exactly one insertion anchor: {old!r}')
    return text.replace(old, new)

def instrument(base, out, startup_reference=False):
    out.mkdir()
    evidence = {}
    for relative in ['source/gen3_reference_phy_gt_phy_rst.v',
                     'source/gen3_reference_phy_gt_phy_wrapper.v',
                     'source/gen3_reference_phy_core_top.v',
                     'synth/gen3_reference_phy.v']:
        original = (base / relative).read_text()
        text = original
        if relative.endswith('_rst.v'):
            text = replace_once(text, '    input                               RST_REFCLK,',
                                '    output wire [31:0] EQ_DIAG,\n    input                               RST_REFCLK,')
            signals = ['fsm[0]', 'fsm[1]', 'fsm[2]', 'rrst_n', 'rst_n_internal',
                       'cplllock_r[0]', 'qpll0lock_r[0]', 'qpll1lock_r[0]',
                       'txprogdivresetdone_r[0]', 'txresetdone_r[0]',
                       'rxresetdone_r[0]', 'txsync_done_r[0]', 'phystatus_r[0]',
                       'cpllpd', 'cpllreset', 'qpllpd', 'qpllreset',
                       'txprogdivreset', 'gtreset', 'userrdy', 'txsync_start',
                       'idle', 'rst_n_internal_i[2]', 'intclk_rrst_n',
                       'RST_GTPOWERGOOD[0]', 'prst_n', 'txpisopd_r']
            added = '\n'.join(f'assign EQ_DIAG[{i}] = {s};' for i, s in enumerate(signals))
            text = replace_once(text, 'endmodule', added + "\nassign EQ_DIAG[31:27] = 0;\nendmodule")
        elif relative.endswith('_wrapper.v'):
            if startup_reference:
                text = replace_once(text,
                    "assign PHY_TXOUTCLKSEL = 3'h5; //rst_cpllreset ? 3'h3 : 3'h5;",
                    "assign PHY_TXOUTCLKSEL = rst_cpllreset ? 3'h3 : 3'h5;")
            text = replace_once(text, '    input                               PHY_REFCLK,',
                                '    output wire [63:0] EQ_DIAG,\n    input                               PHY_REFCLK,')
            text = replace_once(text, 'phy_rst_i\n(', 'phy_rst_i\n(\n    .EQ_DIAG(EQ_DIAG[31:0]),')
            signals = ['gt_gtpowergood[0]', 'gt_bufgtce[0]', 'gt_bufgtreset[0]',
                       'gt_bufgtcemask[0]', 'gt_bufgtrstmask[0]',
                       'gt_bufgtdiv[0]', 'gt_bufgtdiv[1]', 'gt_bufgtdiv[2]',
                       'eq_raw_count[7]', 'eq_int_count[7]', 'eq_pclk_count[7]']
            added = '''// Observation-only free-running counters; do not control the PHY.
wire eq_raw_clock;
BUFG_GT eq_observation_clock (.I(gt_txoutclk[0]), .CE(1'b1), .CEMASK(1'b0),
    .CLR(1'b0), .CLRMASK(1'b0), .DIV(3'b0), .O(eq_raw_clock));
reg [7:0] eq_raw_count = 0, eq_int_count = 0, eq_pclk_count = 0;
always @(posedge eq_raw_clock) eq_raw_count <= eq_raw_count + 1'b1;
always @(posedge int_clock) eq_int_count <= eq_int_count + 1'b1;
always @(posedge pclk) eq_pclk_count <= eq_pclk_count + 1'b1;
'''
            added += '\n'.join(f'assign EQ_DIAG[{32+i}] = {s};' for i, s in enumerate(signals))
            text = replace_once(text, 'endmodule', added + "\nassign EQ_DIAG[63:43] = 0;\nendmodule")
        elif relative.endswith('_core_top.v'):
            text = replace_once(text, '   input  wire                         phy_refclk,',
                                '   output wire [63:0] eq_diag,\n   input  wire                         phy_refclk,')
            text = replace_once(text, ') diablo_gt_phy_wrapper (', ') diablo_gt_phy_wrapper (\n            .EQ_DIAG(eq_diag),')
        else:
            text = replace_once(text, '  phy_refclk,', '  eq_diag,\n  phy_refclk,')
            text = replace_once(text, 'input wire phy_refclk;', 'output wire [63:0] eq_diag;\ninput wire phy_refclk;')
            text = replace_once(text, '  ) inst (', '  ) inst (\n    .eq_diag(eq_diag),')
        (out / Path(relative).name).write_text(text)
        evidence[relative] = {'original_sha256': hashlib.sha256(original.encode()).hexdigest(),
                              'instrumented_sha256': hashlib.sha256(text.encode()).hexdigest()}
    (out / 'instrumentation.json').write_text(json.dumps(evidence, indent=2)+'\n')

if __name__ == '__main__':
    if len(sys.argv) not in (3,4) or (len(sys.argv)==4 and sys.argv[3]!='--startup-reference'):
        raise SystemExit('Usage: instrument_eq_phy.py generated-ip output [--startup-reference]')
    instrument(Path(sys.argv[1]), Path(sys.argv[2]), len(sys.argv)==4)

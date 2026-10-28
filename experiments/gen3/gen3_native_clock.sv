// SPDX-License-Identifier: Apache-2.0
// Native PCIe clock control wiring. Inputs are the corresponding GT BUFGT
// outputs, NOT management-clock rate decodes. Reserved GT attributes are left
// at Wizard values. PCLK uses BUFGTDIV[2:0], CEMASK/RSTMASK[0]. Verify the
// generated GTHE4 configuration and routed clocks before board integration.
module gen3_native_clock (
    input wire txoutclk_i, bufgtce_i, bufgtreset_i,
    input wire [2:0] bufgtdiv_i,
    input wire bufgtcemask_i, bufgtrstmask_i,
    output wire user_clk_o
);
    BUFG_GT user_clock (
        .I      (txoutclk_i),
        .CE     (bufgtce_i),
        .CEMASK (bufgtcemask_i),
        .CLR    (bufgtreset_i),
        .CLRMASK(bufgtrstmask_i),
        .DIV    (bufgtdiv_i),
        .O      (user_clk_o)
    );
endmodule

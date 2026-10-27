# SPDX-License-Identifier: Apache-2.0
# Diagnostic-only review of the generated ILA's programmed capture predicate.
# Its serially loaded comparator configuration is held fixed while armed.
# This is NOT a waiver for live PCIe signals or arbitrary ILA crossings.
proc gen3_review_ila_config_cdc {output} {
    report_cdc -details -name gen3_before_review -file $output/cdc_before_review.rpt
    set prefix {experiment/receive_trace/inst/ila_core_inst/u_trig/STRG_QUAL.U_STRG_QUAL}
    set dut $prefix/allx_typeA_match_detection.ltlib_v1_0_4_allx_typeA_inst/DUT
    set source $dut/u_srl_drive/CLK
    set first {I_WHOLE_SLICE.G_SLICE_IDX[0].U_ALL_SRL_SLICE/I_IS_TERMINATION_SLICE_W_OUTPUT_REG.DOUT_O_reg}
    set target $dut/$first/D
    set stages [list $dut/$first $prefix/yes_output_reg.dout_reg_reg \
        experiment/receive_trace/inst/ila_core_inst/u_trig/shift_cap_strg_qual_reg \
        experiment/receive_trace/inst/ila_core_inst/u_trig/CAP_QUAL_STRG_reg]
    set reviewed 0
    foreach v [get_cdc_violations -name gen3_before_review -filter {SEVERITY == Critical && IS_WAIVED == 0}] {
        if {[get_property CHECK $v] ne "CDC-10" ||
            [lindex [get_property STARTPOINT_PIN $v] 0] ne $source ||
            [lindex [get_property ENDPOINT_PIN $v] 0] ne $target ||
            [get_property STARTPOINT_CLOCK $v] ne "pcie_refclk" ||
            [get_property ENDPOINT_CLOCK $v] ne "txoutclk" ||
            [get_property DEPTH $v]!=4 ||
            [join [get_property SYNCHRONIZER $v] "\n"] ne [join $stages "\n"]} {
            report_property $v
            error "Unreviewed critical CDC; no diagnostic bitstream"
        }
        set from [get_pins -quiet $source]
        set to [get_pins -quiet $target]
        if {[llength $from]!=1 || [llength $to]!=1} {error "ILA configuration endpoint lookup changed"}
        create_waiver -type CDC -id CDC-10 -user soft_pcie_diagnostic \
            -description {Isolated ILA capture-predicate configuration is loaded before arming and held fixed throughout capture; exact four-stage generated storage-qualifier path only.} \
            -from $from -to $to
        incr reviewed
    }
    if {$reviewed>1} {error "Unexpected duplicate ILA configuration CDC"}
    report_cdc -details -name gen3_after_review -file $output/cdc.rpt
    if {[llength [get_cdc_violations -name gen3_after_review -filter {SEVERITY == Critical && IS_WAIVED == 0}]]} {
        error "Critical CDC remains after scoped review"
    }
    write_waivers -force $output/reviewed_waivers.xdc
    puts "Reviewed ILA configuration crossings: $reviewed"
}

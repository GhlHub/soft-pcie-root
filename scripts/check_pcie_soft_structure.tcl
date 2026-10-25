# Shared post-synthesis/reopened-DCP checks for isolated experimental blocks.
proc check_pcie_soft_structure {top} {
    set brams [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]
    set expected [expr {$top in {pcie_soft_replay pcie_soft_link pcie_soft_root_port} ? 1 : 0}]
    if {[llength $brams] != $expected} {
        error "Unexpected BRAM count for $top: expected $expected"
    }
    foreach cell $brams {
        foreach pin {RSTRAMARSTRAM RSTRAMB RSTREGARSTREG RSTREGB} {
            set net [get_nets -segments -of_objects [get_pins $cell/$pin]]
            set drivers [get_pins -leaf -of_objects $net -filter {DIRECTION == OUT}]
            set source [get_cells -of_objects $drivers]
            if {[llength $source] != 1 || [get_property REF_NAME $source] ne "GND"} {
                error "Unexpected reset on replay RAM/output: $cell/$pin"
            }
        }
    }
    if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {
        error "Soft foundation unexpectedly instantiates a PCIe hard macro"
    }
    foreach cell [get_cells -hier -quiet -filter {REF_NAME == FDCE || REF_NAME == FDPE}] {
        if {$top eq "pcie_soft_root_port" && ([string match phy/gt/* $cell] || [string match *release_q_reg* $cell])} {continue}
        error "Unexpected asynchronous-reset register in $top: $cell"
    }
    puts "PCIE_SOFT_STRUCTURE_PASS $top: $expected BRAM, RAM reset pins inactive, reset ownership checked, no PCIe hard macro"
}

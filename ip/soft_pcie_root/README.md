# Reusable soft PCIe IP

`soft_pcie_root` is the public top module. It combines the transceiver-facing
root port, management mailbox, CPU BAR access, noncoherent DDR bridge and MSI
integration. The top was extracted from the verified ZCU104 shell by changing
its module identifier only. The protocol and DMA RTL bodies are preserved.

Run `make ip IP_OUTPUT=build/ip_v1` from the repository root. Add
`build/ip_v1/core` to Vivado's IP repositories, or use the supplied ZCU104 example.
The packager generates the GTH sub-IP locally and imports its XCI into the
package. A packaged core can be copied to another project on the same supported
tool/device setup; it does not depend on the laboratory workspace.

The packaged configuration fixes management50MHz, host125MHz, reference100MHz,
and one UltraScale+ GTH channel. Its supplied GT configuration selects X0Y15
on XCZU7EV, matching ZCU104. Other lane/device mappings need regenerated GT
configuration and reviewed constraints. This release does not expose unverified
GUI parameters for lane count, Gen3 or arbitrary AXI clocks.

| Interface | Direction | Contract |
| --- | --- | --- |
| `S_AXI` | Slave | 32-bit AXI4-Lite, 12-bit address, SRP1 management/config |
| `S_MEM` | Slave | 32-bit AXI4-Lite, 25-bit address, DBR1 + BAR PIO window |
| `M_DDR` | Master | 64-bit AXI4, 32-bit address, ordered same-ID bursts, max8beats |
| `aclk`, `aresetn` | Inputs | Independent50MHz management, global active-low reset |
| `host_clk_i` | Input | Stable125MHz host/DDR clock |
| `core_clk_o`, `core_resetn_o` | Outputs | Host clock alias and synchronized host reset release |
| `refclk_p_i/n_i` | Inputs | Differential100MHz GTH reference |
| `rx_p_i/n_i`, `tx_p_o/n_o` | Serial | One PCIe lane, Gen1/Gen2 |
| `perst_a_o` | Output | FPGA-facing active-high reset; card inverts to PERST# |
| `disable_ssd2_power_o` | Output | Fixed-high legacy example helper; not a second PCIe port |
| `irq_o` | Output | Level-high aggregate MSI/MSI-X interrupt |

AXI bus associations and memory maps are present in generated `component.xml`.
`core_clk_o` is the host125MHz clock, **not** the variable-rate GTH link clock.
The alias input `host_clk_i` has no separate AXI association in the packager;
the buses associate with `core_clk_o`, as in the verified shell.

Physical pin, clock and scoped CDC constraints deliberately live with the example.
They are required, not optional timing hints. The current constraints/audit assume
one core instance and the documented hierarchy; multi-instance integration is not
qualified. Do not replace them with broad asynchronous clock-group false paths.
See [the integration guide](../../docs/ip-guide.md) before integrating elsewhere.

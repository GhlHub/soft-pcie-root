# Reusable soft PCIe IP

`soft_pcie_root` is the public top module. It combines the transceiver-facing
root port, management mailbox, CPU BAR access, noncoherent DDR bridge and MSI
integration. The top was extracted from the verified ZCU104 shell by changing
its module identifier only. Subsequent payload banking, packet-width, prefetch and normal-ACK changes depart
from that baseline; see [verification status](../../docs/verification.md) for the
source provenance and physical qualification of each revision.

Run `make ip IP_OUTPUT=build/ip_v1` from the repository root. Add `build/ip_v1/core` to
Vivado's IP repositories, or use the supplied ZCU104 example. The packager generates
both PHY backends locally and imports their generated RTL, retaining vendor notices. A
constraint template emits only the selected PHY constraints when Vivado generates output
products. A packaged core can be copied to another project on the same supported
tool/device setup; it does not depend on the laboratory workspace.

The packaged configuration fixes management 50 MHz, host 125 MHz, reference 100 MHz, and
one UltraScale+ GTH channel. Its supplied GT configuration selects X0Y15 on XCZU7EV,
matching ZCU104. Other lane/device mappings need regenerated GT configuration and
reviewed constraints. This release does not expose unverified GUI parameters for lane
count or arbitrary AXI clocks. Version 1.1 provides one catalog entry with an **Enable
experimental Gen3** checkbox, default off; see [optional Gen3
packaging](../../docs/ip-guide.md#optional-gen3-packaging). Physical measurements by
revision are in the [performance history](../../docs/performance-history.md).

| Interface | Direction | Contract |
| --- | --- | --- |
| `S_AXI` | Slave | 32-bit AXI4-Lite, 12-bit address, SRP1 management/config |
| `S_MEM` | Slave | 32-bit AXI4-Lite, 25-bit address, DBR1 + BAR PIO window |
| `M_DDR` | Master | 64-bit AXI4, 32-bit address, ordered same-ID bursts, max 8 beats |
| `aclk`, `aresetn` | Inputs | Independent 50 MHz management, global active-low reset |
| `host_clk_i` | Input | Stable 125 MHz host/DDR clock |
| `core_clk_o`, `core_resetn_o` | Outputs | Host clock alias and synchronized host reset release |
| `refclk_p_i/n_i` | Inputs | Differential 100 MHz GTH reference |
| `rx_p_i/n_i`, `tx_p_o/n_o` | Serial | One PCIe lane; Gen1/Gen2 default or experimental Gen3 |
| `perst_a_o` | Output | FPGA-facing active-high reset; card inverts to PERST# |
| `disable_ssd2_power_o` | Output | Fixed-high legacy example helper; not a second PCIe port |
| `irq_o` | Output | Level-high aggregate MSI/MSI-X interrupt |

AXI bus associations and memory maps are present in generated `component.xml`.
`core_clk_o` is the host 125 MHz clock, **not** the variable-rate GTH link clock.
The alias input `host_clk_i` has no separate AXI association in the packager;
the buses associate with `core_clk_o`, as in the verified shell.

Generated PHY constraints travel with the package. Board pin assignments, external clock
setup and host/link CDC constraints live with the example. They are required, not
optional timing hints. The current constraints/audit assume one core instance and the
documented hierarchy; multi-instance integration is not qualified. Do not replace them
with broad asynchronous clock-group false paths. See [the integration
guide](../../docs/ip-guide.md) before integrating elsewhere.

## Catalog selection regression

After creating a fresh package, check actual customization, repeated checkbox changes,
AXI metadata, generated HDL and synthesis of both backends:

```sh
vivado -mode batch -source scripts/check_ip_catalog.tcl \
  -tclargs build/catalog_check_next build/ip_v1/core
```

The check expects the normal default-off package. It verifies one GTH, no hard PCIe, the
selected backend, packet RAM width, read-owner capacity and the matching board clock/CDC
constraints. It rejects synthesis critical warnings and unwaived critical CDC findings.
It does not route or program hardware.

Use the packaged block-design cell for AXI automation. Vivado 2026.1 standalone wrappers
retain the default two-read annotation in Gen3 mode; the generated HDL parameter and
eight-slot hardware are correct. See the integration guide for this limitation and the
distinction between package validation and board tests.

Verification coverage is tracked separately for
[Gen1/Gen2](../../docs/gen1-gen2-compliance-matrix.md) and
[Gen3](../../docs/gen3-verification-matrix.md). The latest 1,663-test simulation
regression includes independent Gen3 training/packet peers, eight-slot replay
ownership and natural sequence/credit rollover. These tests do not qualify the
physical PHY or full Recovery; the latest source has not been deployed.

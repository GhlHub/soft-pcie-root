# Soft PCIe Root Port

**Gen3 x1 PCIe in FPGA logic: 733.45 MB/s read and 564.16 MB/s write with an NVMe SSD under Linux.**

A GTH transceiver and custom SystemVerilog implement the PCIe root port, with
no hard PCIe controller or vendor PCIe controller IP. A custom Linux PCI host
driver connects it to the standard Linux NVMe driver.

![Gen3 x1 soft PCIe: 733.45 MB/s sequential read and 564.16 MB/s sequential write](docs/media/linkedin-soft-pcie.png)

## Current Gen3 x1 results

The requester-fix image passed fresh synthesis, place-and-route, independent
checkpoint audit and physical validation on **2026-10-29**. These measurements
cover the complete ZCU104 PL example, including its AXI interconnects.

| Item | Current measured result |
| --- | --- |
| FPGA / adapter | ZCU104, XCZU7EV-2; Opsero OP047 Rev D, SSD1 |
| SSD | Samsung 990 EVO 1 TB |
| Link | **Gen3 x1, 8 GT/s** |
| Software | Linux 6.6.70, custom PCI host driver, standard NVMe driver |
| Sequential read / write, QD8 | **733.45 / 564.16 MB/s** |
| Sequential read / write, QD1 | **589.63 / 339.49 MB/s** |
| Workload | 1 MiB, direct/libaio, one job, 30 seconds per workload; decimal MB/s |
| Resources | **11,245 LUTs, 10,491 FFs**, 2.5 BRAM tiles, one GTH; no DSP or URAM |
| Routed Gen3 setup / hold slack | **+0.116 / +0.010 ns** |
| Hardware checks | 28,000 configuration reads; eight NVMe performance/integrity jobs; final read-only CRC |

Existing and fresh data CRC, sector-offset CRC, post-flush verification and exact
write accounting passed. SMART error and unsafe-shutdown counters were unchanged.
The timeout fix prevents a completion accepted on the timeout cycle from leaving
the requester faulted. That exact collision is verified in simulation; it was
not deliberately injected on the SSD.

[Exact hardware evidence](docs/evidence/requester_fix_v1/completion.json) ·
[Verification scope](docs/verification.md) ·
[Performance history](docs/performance-history.md)

The Gen3 path uses 64-bit host packet transfers, eight 64-byte DDR read-prefetch
slots, an eight-entry replay store and concurrent normal ACK retirement.
The latest full regression passed **1,663 tests**, including 994 independent
Gen3 training, packet, corruption, ownership and rollover cases.
See the [Gen3 coverage matrix](docs/gen3-verification-matrix.md).

**Gen3 remains experimental.** Full Recovery, cold-cycle qualification, broader
SSD interoperability and PCIe compliance are not established. The new image was
validated through temporary JTAG programming; the SD default remains the
previous [RX metadata image](docs/evidence/rx_metadata_v1/default-boot.json).
No SD or flash update is included in these results.

## Configuration and earlier results

The unified Vivado **Enable experimental Gen3** checkbox selects Gen3 at build
time. It defaults off, selecting Gen1/Gen2 x1 with 32-bit host packet paths and
two DDR read-prefetch slots. Both selections retain a 64-bit/125 MHz DDR AXI
interface. See [packaging and integration](docs/ip-guide.md#optional-gen3-packaging).
The PHY targets UltraScale+ GTHE4; other families and wider links need development.

The frozen release remains Gen1/Gen2 x1. The latest measured Gen2 ACK-retirement
build achieved **428.30/260.21 MB/s** at QD8; a fresh Gen2 backend build containing
the requester fix is still outstanding. Historical Gen2/Gen3 results and timing
improvements remain in the [performance history](docs/performance-history.md).
They are separate runs, not interleaved statistical comparisons.

OP047 Rev D is the tested adapter. Its successor OP063 has not been qualified;
the power initializer currently recognizes OP047 only. See
[adapter compatibility](examples/zcu104/README.md#adapter-compatibility).

## Repository layout

| Path | Purpose |
| --- | --- |
| `ip/soft_pcie_root/` | Reusable RTL and Vivado IP packager |
| `examples/zcu104/` | IP-based block design, physical constraints and audit |
| `software/driver/` | GPL-2.0-only Linux PCI host driver |
| `software/linux/` | Reproducible Buildroot/Linux/U-Boot example configuration |
| `tests/` | Protocol, ownership, DMA, CDC and software regressions |
| `docs/` | IP guide, register contract, validation and release notes |
| `docs/media/` | Editable graphic, PNG and LinkedIn draft |

## Build and test

Use Linux, Python 3.12+, GCC, Icarus Verilog, Verilator and **Vivado 2026.1** with
Zynq UltraScale+ device/board support. Source Vivado's `settings64.sh` first.
AMD XPM and GT Wizard/primitive simulation support come from that installation;
no generated AMD IP is committed here.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
make test lint
make ip IP_OUTPUT=build/ip_v1
make hardware OUTPUT=build/zcu104_v1 IP_REPO=build/ip_v1/core
make hardware-audit HARDWARE_OUTPUT=build/zcu104_v1 AUDIT_OUTPUT=build/audit_v1
```

Outputs must be fresh. `make ip` creates a local IP repository with VLNV
`soft-pcie.org:user:soft_pcie_root:1.1` (a local identifier, not a service URL). The
example instantiates that packaged IP. Its **Enable experimental Gen3** checkbox selects
the backend at customization time (default off). The frozen source provenance is checked
separately from generated build hashes. `make release-check` is a strict check of the
frozen Gen1/Gen2 baseline and is expected to reject this development tree's shared RTL
changes. Its historical manifests are preserved; do not regenerate them to label
experimental Gen3 as a qualified release. See [IP
integration](ip/soft_pcie_root/README.md) and [ZCU104 setup](examples/zcu104/README.md).
Those hardware commands select the default Gen1/Gen2 backend. For the Gen3
configuration featured above, use the same fresh IP package with:

```sh
vivado -mode batch -source experiments/gen3/build_host.tcl \
  -tclargs build/zcu104_gen3_next build/ip_v1/core
```

See [Gen3 reproduction](experiments/gen3/README.md#current-design-and-reproduction)
for source-manifest checks and build constraints. These commands do not program
a board.

## Scope and limitations

One direct endpoint, function 0 only; up to 16 MiB of endpoint BAR space; noncoherent
DMA to lower 2 GiB DDR in the example; 32 MSI/MSI-X vectors. The DDR master is 64-bit
AXI at 125 MHz; the ZCU104 interconnect converts to 128-bit PS HP0. Default
Gen1/Gen2 packaging has two read and two write owners, with 128 bytes of read
prefetch. Experimental Gen3 has eight read and two write owners, with 512 bytes.

No PCIe compliance certification, switch topology, Type 1 routing, multifunction,
INTx, hotplug, ASPM/AER or safe live PL replacement. Accepted AXI requests must
finish; local reset cannot cancel them. Use a disposable, unmounted SSD for
bring-up. See [integration and reset contract](docs/ip-guide.md),
[registers](docs/registers.md) and [future work](docs/roadmap.md).

## Licensing

Original RTL, tools and documentation: **Apache-2.0**. The Linux host driver in
`software/driver/` remains **GPL-2.0-only**. AMD-generated IP/libraries and fetched
upstream software retain their own licenses. The GPL pcievhost oracle is optional,
test-only and fetched into ignored build output; it is not synthesized or vendored.
See [LICENSE](LICENSE), [NOTICE](NOTICE) and [third-party notices](THIRD_PARTY.md).

For the HDL whitespace style and repeatable checks, see [HDL formatting](docs/hdl-formatting.md).

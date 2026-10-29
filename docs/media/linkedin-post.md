# LinkedIn draft for the historical Gen2 release

For the later Gen2/Gen3 comparison, use the [current asset notes](README.md).

Suggested image: [marketing graphic](linkedin-marketing-v2.png).

PCIe, built in logic.

This experimental FPGA root port uses a GTH transceiver and custom SystemVerilog protocol logic—no hard PCIe block or vendor PCIe controller IP. It supports Gen1/Gen2 x1 and has been verified with a Samsung 990 EVO NVMe SSD on a ZCU104 under Linux, using a custom PCI host driver and the standard Linux NVMe driver.

Measured sequential throughput for the packaged example: 428.3 MB/s read and 259.7 MB/s write (Gen2 x1, 1 MiB direct I/O, QD8, 30 seconds).

The design is available as an Apache-2.0 IP core with a ZCU104 example; the Linux host driver remains GPL-2.0-only. The tested adapter is Opsero OP047 Rev D, now superseded by OP063. OP063 has not been qualified with this design. Optional experimental Gen3 and subsequent improvements are documented separately
in the [performance history](../performance-history.md); this draft and its
graphic retain the historical Gen2 measurements.

The implementation still uses AMD transceiver-generation tools and XPM primitives. This is an experimental implementation, not PCIe compliance certification.

Repository: https://github.com/GhlHub/soft-pcie-root

#FPGA #PCIe #SystemVerilog #Linux #NVMe #OpenSource

## Graphic alt text

The suggested marketing graphic is a conceptual FPGA/NVMe illustration showing
Gen2 x1, 428 MB/s read and 260 MB/s write. Its rounded values describe the
packaged example. See [asset notes](linkedin-marketing-v2.md).

The original editable [SVG](linkedin-soft-pcie-gen2-baseline.svg) and
[PNG](linkedin-soft-pcie-gen2-baseline.png) instead show the txdouble_v1 baseline's rounded
428.6/260.1 MB/s. Regenerate those original assets with
`python3 scripts/render_graphic.py`; requires Pillow and DejaVu Sans fonts.

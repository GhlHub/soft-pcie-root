# LinkedIn draft

PCIe, built in logic.

This experimental FPGA root port uses a GTH transceiver and custom SystemVerilog protocol logic—no hard PCIe block or vendor PCIe controller IP. It supports Gen1/Gen2 x1 and has been verified with a Samsung 990 EVO NVMe SSD on a ZCU104 under Linux, using a custom PCI host driver and the standard Linux NVMe driver.

Measured sequential throughput: 428.6 MB/s read and 260.1 MB/s write (Gen2 x1, 1 MiB direct I/O, QD8, 30 seconds).

The design is being prepared as an Apache-2.0 IP core with a ZCU104 example; the Linux host driver remains GPL-2.0-only. The tested adapter is Opsero OP047 Rev D, now superseded by OP063. OP063 has not been qualified with this design. Gen3+, wider links and further optimization remain future investigations.

The implementation still uses AMD transceiver-generation tools and XPM primitives. This is an experimental implementation, not PCIe compliance certification.

Repository: https://github.com/GhlHub/soft-pcie-root

#FPGA #PCIe #SystemVerilog #Linux #NVMe #OpenSource

## Graphic alt text

Soft PCIe root port: Linux and DDR connect through custom PCIe RTL and one GTH transceiver to an NVMe SSD. No hard PCIe block or vendor PCIe controller IP. Gen2 x1 measured sequential read 428.6 MB/s and write 260.1 MB/s, with 1 MiB direct I/O at QD8 for 30 seconds on ZCU104 and OP047 Rev D.

The SVG is editable; the PNG is 1600 × 900 pixels. Measurements belong to the physically verified txdouble_v1 baseline; see ../verification.md for scope.

Regenerate with `python3 scripts/render_graphic.py` from the repository root; requires Pillow and DejaVu Sans fonts.

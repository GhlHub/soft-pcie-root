# Current Gen3 x1 performance post

[Graphic](linkedin-soft-pcie.png) · [Editable SVG](linkedin-soft-pcie.svg)

Gen3 x1 PCIe, built in FPGA logic.

Our soft PCIe root port measured **737.37 MB/s sequential read and 563.84 MB/s
sequential write** with a Samsung 990 EVO NVMe SSD on ZCU104 under Linux.
The link uses a GTH transceiver and custom SystemVerilog, with no hard PCIe
controller or vendor PCIe controller IP. Linux uses a custom PCI host driver
and its standard NVMe driver.

The latest adaptive review-fix image passed fresh synthesis/route, an independent
audit, 28,000 configuration reads and all eight NVMe performance/integrity jobs.
It uses 16,116 LUTs and 12,367 FFs; routed Gen3 setup margin is +0.041 ns.
Three controlled Gen3 startups passed. The image subsequently became the SD
default; unattended warm boot and read-only CRC passed on 2026-11-03.
Physical Gen2 fallback and injected Recovery remain open.

Measurements: sequential 1 MiB, QD8, direct/libaio, one job, 30 seconds per
workload, decimal MB/s. Read and write are separate measurements. Gen3 remains
experimental; full Recovery and broader qualification remain open. This is
functional hardware validation, not PCIe compliance certification.

[Source and exact evidence](../evidence/adaptive_review_v1/completion.json).

Repository: https://github.com/GhlHub/soft-pcie-root

#FPGA #PCIe #SystemVerilog #Linux #NVMe #OpenSource

# Soft PCIe release workspace

Read README.md, docs/ip-guide.md, docs/registers.md, examples/zcu104/README.md and
docs/verification.md first. This repository is the authoritative development source.
Local board/deployment handoff, when available, is in ignored build/lab/HANDOFF.md. The release stops at Gen1/Gen2 x1.

Reusable sources: ip/soft_pcie_root/rtl; packaging: ip/soft_pcie_root/package.tcl;
board build/audit/constraints: examples/zcu104; Linux integration: software/.
Do not weaken whole-packet validation, credit/replay ownership, all-B-before-MSI,
noncoherent DMA or accepted-AXI drain. Packet RAM stays unreset. Never reset away
accepted ownership. No safe live reset/remove or stopped-reference recovery.

Original source license Apache-2.0; Linux host driver GPL-2.0-only; retain notices.
AMD IP is generated locally and not committed. No vendor/specification PDFs,
private deployment addresses, raw laboratory logs or credentials in releases.
Use fresh build outputs. Freeze RTL/scripts/constraints during hardware builds;
source manifests must match. Passing simulation or route is not physical proof.

Local builds/tests are authorized by normal development requests. Board/media
writes and publishing require user instructions. Do not infer access to a board
or a repository account from the existence of this example. No automatic SSD
formatting or service provisioning. See Makefile for reproducible commands.

Packaged example_zcu104_v1 subsequently passed physical Gen2x1 I/O/CRC tests.
See docs/verification.md and docs/evidence/repackaged_v1/completion.json.
The image subsequently became the SD default; automatic warm boot and256MiB
read-only CRC passed. See the default-boot.json evidence beside completion.json.

# Linux PCI host driver

`zcu104-soft-pcie.c` is GPL-2.0-only; retain its SPDX identifier and COPYING.
The Buildroot example builds it against Linux 6.6.70. Device tree compatible:
`ngt,zcu104-soft-pcie-1.0`. The legacy name is retained to preserve the tested ABI.

The driver exposes one direct PCI endpoint at bus 1/device 0/function 0, programs
BARs within 16 MiB, constrains MPS128 and relaxed/no-snoop policy, and implements 32
MSI/MSI-X vectors. Linux's standard NVMe driver enumerates and operates the SSD.
DMA uses Linux cache-maintenance APIs for the noncoherent HP0 path.

No safe live remove/reprobe exists; the module pins itself after successful probe.
Do not bind UIO or pcie-rootctl concurrently. Global recovery requires reboot.
The driver embeds its source SHA256 in modinfo so packaging can reject stale
installed/Kbuild artifacts. Generated .ko/.o/module metadata never belongs in Git.

The review follow-up preserves the 50 ms requester completion allowance and
400 ms atomic polling guard. Updated SRP1 RTL reports observed link/fatal errors
promptly while retaining accepted ownership for late-response drain. The driver
recognizes quarantine with or without done and blocks subsequent configuration
commands. Silent failures can still take the full existing timeout; no sleeping
wait or shorter completion deadline is introduced. See
[the implementation and validation boundary](../../docs/review-followup.md).

The adaptive-EQ FPGA image and its SD-default validation retained the existing
installed driver. The new early-quarantine callback branch has C/MMIO model
coverage but still needs a source-matched rebuild and physical deployment test.

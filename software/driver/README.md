# Linux PCI host driver

`zcu104-soft-pcie.c` is GPL-2.0-only; retain its SPDX identifier and COPYING.
The Buildroot example builds it against Linux6.6.70. Device tree compatible:
`ngt,zcu104-soft-pcie-1.0`. The legacy name is retained to preserve the tested ABI.

The driver exposes one direct PCI endpoint at bus1/device0/function0, programs
BARs within16MiB, constrains MPS128 and relaxed/no-snoop policy, and implements32
MSI/MSI-X vectors. Linux's standard NVMe driver enumerates and operates the SSD.
DMA uses Linux cache-maintenance APIs for the noncoherent HP0 path.

No safe live remove/reprobe exists; the module pins itself after successful probe.
Do not bind UIO or pcie-rootctl concurrently. Global recovery requires reboot.
The driver embeds its source SHA256 in modinfo so packaging can reject stale
installed/Kbuild artifacts. Generated .ko/.o/module metadata never belongs in Git.

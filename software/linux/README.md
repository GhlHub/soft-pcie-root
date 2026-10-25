# Reproducible ZCU104 Linux example

Pinned Buildroot2025.02.18 builds AMD Linux6.6.70 and the AMD2024.2 boot chain
(SPL, PMU firmware, TF-A, full U-Boot). Exact upstream hashes are in
`sources.lock.json`. The custom PCI host driver is built as a kernel module and
uses the standard Linux PCI/NVMe and DMA APIs. The SSD remains a normal Linux
NVMe device; there is no synthesized NVMe command processor.

From the repository root:

```sh
make linux-configure
make linux JOBS=12
make linux-verify
make linux-archive LINUX_OUTPUT=build/linux_v1
make soft-profile HARDWARE_OUTPUT=build/zcu104_v1 PROFILE_OUTPUT=build/profile_v1
```

`WORK` defaults to ignored `build/linux-cache`; it can point to an existing cache.
The baseline SD image omits the PL host node. The optional profile adds a PL-first
boot script, host DTB, matching bitstream and identities. The script expects its
files at the SD boot partition root and the existing baseline ext4 rootfs
PARTUUID1045a7a0-02. The reported lab benchmarks instead used the same kernel with
a RAM rootfs. Review the generated script before manually selecting it in U-Boot;
packaging never writes SD media or programs hardware.

Before binding the host node, load the correct PL bitstream and confirm FMC power.
Do not set dma-coherent: HP0 is noncoherent. Driver source SHA256 is embedded in
modinfo; verify.py and profile packaging check installed and archived modules
against source. After modifying the driver, run the Buildroot
`zcu104-pcie-host-dirclean` target, rebuild Linux, verify and create fresh archives.

## FMC power initializer

Full U-Boot calls the local initializer before boot commands. It operates only
on the ZCU104 Rev C DT, refuses changes if PL is configured/unknown, checks FMC
presence, validates the card FRU checksums and exact OP047 identity, then checks
that the advertised VADJ range allows1.8V. It programs only IRPS5401 page3/SW-D
with readback and bounded telemetry checks; successful boot sets
`fmc_vadj_ready=1`. This flag does not replace a physical voltage measurement.
The supplied boot profile refuses PL loading without the flag. OP063 is not yet
accepted by this policy; see the adapter discussion in the example README.

To rebuild U-Boot after initializer changes (substitute your cache path):

```sh
make -C build/linux-cache/buildroot-2025.02.18   O="$PWD/build/linux-cache/output"   BR2_EXTERNAL="$PWD/software/linux/buildroot" uboot-rebuild -j12
make linux
make linux-verify
```

## Services and software validation

The historical example includes SSH/SFTP, NFS, Samba and storage/admin utilities.
Server services are opt-in under `/usr/lib/zcu104/services/`; no SSH host keys,
users/passwords, exports, shares or data-disk mounts ship in the source release.
Do not start a DHCP server without network-specific provisioning. The VM smoke
test creates ephemeral fixtures without a disk or external NIC; these fixtures
are not production credentials/configuration.

`make linux-test` requires `qemu-system-aarch64` (override QEMU if needed) and
checks generic ARM64 userspace/module ABI, not physical PCIe enumeration or DMA.
`make linux-legal-info` collects upstream software notices. Known historical
Buildroot source/toolchain/tool metadata gaps are not a blanket redistribution
clearance: audit legal-info before distributing OS/toolchain binary images.
This public repository contains source/configuration, not those binary images.

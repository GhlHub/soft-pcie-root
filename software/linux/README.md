# Reproducible ZCU104 Linux example

Pinned Buildroot 2025.02.18 builds AMD Linux 6.6.70 and the AMD 2024.2 boot chain
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
PARTUUID 1045a7a0-02. The throughput benchmarks used the same kernel with a RAM rootfs. The deployed
banked-payload image now boots from the persistent ext4 SD root partition. Review the generated script before manually selecting it in U-Boot;
packaging never writes SD media or programs hardware.

Before binding the host node, load the correct PL bitstream and confirm FMC power.
Do not set dma-coherent: HP0 is noncoherent. Driver source SHA256 is embedded in
modinfo; verify.py and profile packaging check installed and archived modules
against source. After modifying the driver, run the Buildroot
`zcu104-pcie-host-dirclean` target, rebuild Linux, verify and create fresh archives.

## Persistent SD root

The deployed ZCU104 uses a 256 MiB FAT boot partition and an ext4 root partition
expanded to consume the rest of its 14.8 GiB SD card (about 14.6 GiB for root).
The prior 1 GiB root filesystem was preserved, checked offline and expanded;
there were no extra partitions to delete. Its kernel modules were updated to the
same verified versions used by the RAM-root deployment. The kernel already has
built-in SD/MMC and ext4 support, so no kernel rebuild was needed.

After the usual FMC readiness check and PL/kernel/host-DTB loads, the deployed
U-Boot script uses:

```text
setenv bootargs 'console=ttyPS0,115200 root=PARTUUID=1045a7a0-02 rootfstype=ext4 rw rootwait clk_ignore_unused'
booti 0x00200000 - 0x04000000
```

The example network overlay sets `eth0` to `02:00:00:10:04:00` before DHCP.
This is the user-selected address for this ZCU104; assign a distinct address
when deploying the image to additional boards. U-Boot may still report its
random address before Linux applies this setting; EEPROM contents are unchanged.

Root files now persist across reboot. `/tmp` and `/run` remain tmpfs; the FAT
boot partition remains unmounted during normal operation. The unused initramfs
was removed from the SD boot partition. Two automatic warm boots, a file written
from SD root and retained across reboot, and a 256 MiB read-only NVMe CRC passed.
See [deployment evidence](../../docs/evidence/ddr_banked_v1/sd-root.json).

Generated `sdcard.img` files retain a compact 1 GiB root partition for deployment.
Expanding a physical card is a separate, explicitly authorized operation: inspect
its actual partition table, preserve the boot partition and root start sector,
expand the final root partition into trailing free space, and run offline
`e2fsck`/`resize2fs` from a RAM-root environment before selecting SD-root boot.
Do not apply the laboratory partition geometry to an unidentified card.

## FMC power initializer

Full U-Boot calls the local initializer before boot commands. It operates only
on the ZCU104 Rev C DT, refuses changes if PL is configured/unknown, checks FMC
presence, validates the card FRU checksums and exact OP047 identity, then checks
that the advertised VADJ range allows 1.8 V. It programs only IRPS5401 page 3/SW-D
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

## ZCU104 SD performance and signaling limits

The deployed 16 GB SDHC card negotiated a 4-bit, 50 MHz SD High Speed bus at
3.3 V. A 1 GiB temporary-file fio test on ext4 measured **23.81 MB/s read** and
**10.53 MB/s write**, with direct I/O, 1 MiB blocks, queue depth 1 and a final
write flush. Both jobs passed and the temporary file was removed. These are
sequential filesystem measurements, not random-I/O or speed-class certification.
[Measured evidence](../../docs/evidence/ddr_banked_v1/sd-performance.json).

The PS controller supports UHS-I SDR50, DDR50 and SDR104, with SDR104 limited to
200 MHz / 100 MB/s by the device specification. The stock ZCU104 SD socket,
however, uses U145 MAX13035E: its FPGA-side VL supply is VCC1V8, while its
card-side VCC supply is fixed to UTIL_3V3. There is no card-side signaling-voltage
switch. The translator requires VCC of 2.2–3.6 V, so powering that side at 1.8 V
is outside its specification. The Linux `no-1-8-v` property is appropriate.

Both SDR50 (100 MHz SDR) and DDR50 (50 MHz DDR) require 1.8 V signaling. A UHS-I
card can operate in backward-compatible 3.3 V High Speed mode here, but cannot
provide UHS-I transfer rates through the stock circuit. The supported High Speed
bus ceiling is 25 MB/s; measured reads reach about 95% of that limit. Enabling
UHS requires a hardware redesign, not simply removing the device-tree property.

References: [ZCU104 schematic, sheet 37](https://www.infineon.com/assets/row/public/documents/24/57/infineon-board-schematics-xilinx-zcu104-ati-en.pdf#page=37),
[MAX13035E specifications](https://www.analog.com/en/products/max13035e.html),
[AMD PS SD timing limits](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/PS-SD/SDIO-Controller-Interface),
[SD bus speeds](https://www.sdcard.org/developers/sd-standard-overview/bus-speed-default-speed-high-speed-uhs-sd-express/).

The local deployed image also has SSH enabled at boot, with persistent host keys
and user-provisioned root password authentication. Credentials, keys and private
network addresses are not included in this repository. Rebuilt source images
retain opt-in SSH and key-only defaults until explicitly provisioned.

# Verification and release scope

## Physically verified baseline

The `txdouble_v1` design was exercised on a ZCU104 with OP047 Rev D, SSD1 and a
Samsung 990 EVO 1 TB (MZ-V9E1T0). Linux 6.6.70 used the custom PCI host driver
and standard NVMe driver. The link was Gen2 x1, 5 GT/s, MPS128, MRRS512, RCB64,
with MSI-X. VADJ was confirmed at 1.8 V during bring-up.

| Measurement | Before double transmit buffering | Verified baseline |
| --- | ---: | ---: |
| Sequential write, QD1 | 182.160459 MB/s | 199.569042 MB/s |
| Sequential write, QD8 | 232.241045 MB/s | 260.057741 MB/s |
| Sequential read, QD8 | 427.813419 MB/s | 428.575486 MB/s |

fio 3.38, direct I/O, libaio, one job, 1 MiB blocks, 30 seconds per job;
decimal MB/s. Writes used [8 GiB, 12 GiB); reads used [0, 4 GiB). These are
sequential benchmark results, not latency, endurance or arbitrary-workload claims.
CRC read-back checks passed. New-image write accounting recorded 23,850,909,696
bytes, matching 46,583,808 sectors. SMART media/error-log counts remained zero.
Accepted AXI write responses still retire before MSI delivery.

Baseline bitstream SHA-256:
`82a97ec256ff77b34bcabea9d991f24b5fd5fbf92c381fe557c44006de64dd68`.
Baseline timing: WNS +0.284 ns, WHS +0.011 ns, WPWS +0.543 ns.
Complete example resources: 11,881 LUTs, 11,171 FFs, 2,718 CLBs, two BRAM tiles,
one GTH and one MMCM. These are not standalone IP utilization numbers.

Compact source evidence is in [evidence/txdouble_v1](evidence/txdouble_v1).
`completion.json` records physical status; `hardware-validation.json`, if present,
is a static build validator and does not itself certify hardware operation.
The laboratory deployment was volatile; the prior SD default remained unchanged.

## Public IP refactor

All protocol, DMA, CSR and PHY RTL is preserved from the accepted baseline.
Only the board-named top module identifier changed to `soft_pcie_root`.
[baseline-rtl.json](baseline-rtl.json) records original and release hashes;
`make release-check` verifies the rename-normalized contents and RTL inventory.
[source-origin.json](source-origin.json) records imported source provenance.

The public example instantiates the packaged Vivado IP rather than a module
reference. The package and board recipe are validated separately from the
physically measured baseline; packaging can change implementation placement.

- Vivado 2026.1 package integrity check: passed.
- Release-tree regression tests: 39 passed; Verilator lint and XPM elaboration passed.
- Fresh packaged-example route and reopened audit: see [release-build.json](release-build.json).

## Physical verification of the packaged example

The exact packaged bitstream was subsequently deployed after clean Linux reboot
and CRC-checked DDR staging. SHA-256:
`041ca732584c4b522206e731ce2dacceff1ac64718e7ec30e64eb119be9d69da`.
Same ZCU104/OP047 Rev D/Samsung SSD and Linux/driver as above; Gen2 x1,
MPS128/MRRS512/RCB64/MSI-X. U-Boot VADJ telemetry was1.801V.

| Test | Packaged example | Difference from txdouble_v1 |
| --- | ---: | ---: |
| Read QD1 | 379.222345 MB/s | No corresponding baseline run |
| Read QD8 | 428.330965 MB/s | -0.057% |
| Write QD1 | 200.174748 MB/s | +0.304% |
| Write QD8 | 259.734844 MB/s | -0.124% |

Same fio3.38, one job, direct/libaio,1MiB,30s and benchmark ranges as above.
All eight I/O/CRC jobs passed, including previous256MiB CRC, fresh288MiB CRC,
and post-flush256MiB CRC.14,108,590,080written bytes exactly match block-sector
accounting. Final SMART media/error-log and critical warnings0;45C; unsafe
shutdown count unchanged. Link/DDR healthy; MSI-X delivered; SSD unmounted.
Performance is essentially unchanged in these short runs, not a statistical
or endurance qualification. Existing all-B-before-MSI logic is unchanged.

[Physical evidence and exact parameters](evidence/repackaged_v1/completion.json).
The image was initially deployed in volatile configuration. It subsequently
became the SD default and passed uninterrupted warm boot plus256MiB read-only
CRC verification. [Default-boot evidence](evidence/repackaged_v1/default-boot.json).
The prior boot script and cmdxpm image remain available for rollback. No OP063, Gen1 retest, cold power cycle or power-loss test was performed.

## Limits and reproducing measurements

Gen1/Gen2 x1 is the supported scope. There is no PCI-SIG compliance certification,
Gen3+, wider-link, hotplug, power-loss or endurance qualification. This stopping
point did not repeat a Gen1/cold-cycle qualification. The small receive/completion
buffers remain a future performance investigation.

Build/test commands are in the [README](../README.md). Hardware tests require
reviewed power initialization, an explicitly selected disposable unmounted SSD,
and separate deployment instructions. `scripts/profile_completion_path.py`
requires `SOFT_PCIE_TEST_SSD_SERIAL` to identify the intended test device; write
benchmarks overwrite their configured ranges. Do not run them on unknown disks.

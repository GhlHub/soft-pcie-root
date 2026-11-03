# Additional deployed-hardware coverage

This campaign uses the ZCU104/OP047/990 EVO setup and the verified review-fix
SD image. Hardware fault testing and scratch-region writes were explicitly
authorized. No diagnostic image becomes the SD default. Normal RTL is unchanged.

## Verified I/O matrix

The normal Gen3 SD image passed **33 jobs** on 2026-11-03: randomized
write-and-verify at 4 KiB, 8 KiB, 128 KiB and 1 MiB, each at QD1/8/32, followed
by namespace flush and full-region readback. Additional preconditioned 4 KiB
70/30 mixed read/write jobs ran at QD1/8/32 with full post-flush readback.

Each job covers 128 MiB within the authorized region beginning at 8 GiB;
the write/verify matrix starts 512 bytes past that boundary. CRC32C and an
offset-tagged pattern check data and address integrity. An LFSR permutation
avoids same-block concurrent-write races. Exact write accounting was
**2,131,046,400 bytes**. SMART error/unsafe-shutdown counters were unchanged;
the independent 256 MiB reference CRC at 16 GiB also passed afterward.

These finite jobs are not throughput or endurance benchmarks. The fixed
per-case pattern does not prove stale-write detection for every mixed overwrite.
No sub-sector NVMe I/O, arbitrary AXI strobes or electrical compliance is claimed.

Script: [verify_nvme_matrix.py](../scripts/verify_nvme_matrix.py).
[Sanitized results](evidence/hardware_coverage_v1/verified-matrix.json).
The script requires the intended SSD serial in `SOFT_PCIE_TEST_SSD_SERIAL`,
checks identity/mounts/holders, and rejects a reused output directory. It is
an authorized destructive scratch-region test, not an automatic startup test.

## Isolated fault-injection images

[prepare_hardware_coverage.py](../scripts/prepare_hardware_coverage.py) exports
the current Git HEAD into a fresh directory and instruments only that snapshot.
It records the base commit, generator hash and mode. Packaging captures the
modified snapshot's own source hashes. Never substitute normal-image manifests.

- **Fallback:** during ADAPT, report not-ready to the adaptive controller only.
  This deliberately uses its normal failure, stop and startup-fallback path.
  It does not physically interrupt the PHY clock or assert a reset. It does
  not represent a naturally occurring analog equalization failure.
- **Recovery:** an accepted local LPR start command (operation 7, address 0x10,
  data 1) arms one pulse. The pulse is consumed only in Gen3 L0 with an active
  received packet and established DL ownership. It enters the existing
  same-rate Recovery condition. No clocks or ownership registers are reset.
  This proves activity at the packet boundary, not an outstanding DDR AXI burst.

Diagnostic CSR words 0x40/44/48/4C report `HWT1`, trigger count, 16-bit
Recovery entry/return counts, and trigger flags. Flags bit 1/2 record packet
active/DL active; bit 3 records requester pending. After fallback they report
`HWF1`, the stopped Gen3 status, injection count and flags. Counts must be stable
before interpreting this informational multibit CDC as a snapshot.

The diagnostic source flops are preserved to prevent identical constant/flag
bits from merging into a launch flop that fans out to separate synchronizers.
The first build attempts were withheld at synthesized CDC; no waiver was added.

Build each mode from a fresh snapshot, using the existing unified package and
Gen3 board flow. Run the independent
[audit](../scripts/audit_hardware_coverage.tcl) from the snapshot root, supplying
its routed checkpoint, fresh audit directory and package directory. Require
positive setup/hold margins, accepted CDC/DRC, complete routing and matching
source manifests before programming. Freeze the snapshot throughout the build.

[test_hardware_recovery.py](../scripts/test_hardware_recovery.py) requires HWT1
and exclusive administrative SRP1 access. It starts read-only CRC traffic,
arms the event and requires exactly one observed entry and return, no I/O
errors, unchanged SMART and zero writes. The normal image does not implement
this trigger. Do not run concurrent PCI configuration tools during this test.

## Physical results — 2026-11-03

Both fresh diagnostic builds passed full synthesis/route and independent audits,
with no unwaived critical CDC or new waivers. Setup/hold margins were
+0.073/+0.011 ns for fallback and +0.042/+0.015 ns for Recovery. Each used a
clean Linux shutdown and independently verified kernel-entry stop before JTAG
programming; no live PL replacement occurred.

| Campaign | Result | Evidence |
| --- | --- | --- |
| Startup fallback | One injected ADAPT failure (code 13), stopped Gen3 controller, automatic Gen2 x1 enumeration on first boot | [Fallback](evidence/hardware_coverage_v1/fallback.json) |
| Fallback I/O | Eight performance/integrity jobs and 14,000 driver-serialized configuration reads passed; 64-bit/eight-slot host configuration retained | Same evidence |
| Same-rate Recovery | One packet-active trigger, one Recovery entry and return; 10 seconds of CRC reads passed, 7,235,174,400 bytes read, zero writes | [Recovery](evidence/hardware_coverage_v1/recovery.json) |

Fallback QD1/QD8 read throughput was 383.38/428.68 MB/s, and write throughput
was 245.70/346.11 MB/s. These are 30-second, 1 MiB direct/libaio runs on the
Gen3-enabled diagnostic image's fallback backend, not the default Gen2 package.
Fresh 256 MiB CRC, 32 MiB sector-offset CRC and post-flush readback passed.
All 18,064,867,328 written bytes were accounted for exactly. SMART error and
unsafe-shutdown counters were unchanged.

Recovery trigger flags were 0xE: RX packet active, DL active and requester
pending. This records those conditions at trigger generation; it does not prove
an outstanding DDR AXI burst or every ownership boundary. CRC traffic completed
and SMART counters were unchanged. One successful event on one SSD/channel does
not qualify full Recovery, electrical margin or stopped-reference recovery.
Broader SSD/channel, cold-power-cycle and physical AXI-stall coverage remain open.


The board was then restored by unattended reboot to the normal review-fix SD
image at Gen3 x1. A final 256 MiB read-only reference CRC passed, with zero
writes, stable SMART and healthy idle status. SD/flash files and normal RTL
were unchanged; the normal image's hardware source manifest still matches.
[Restoration evidence](evidence/hardware_coverage_v1/restored.json).

Two new overlay-control tests pass. Snapshot integration simulations also
passed forced pre-ownership failure and retained replay/credit/requester
ownership through same-rate Recovery. The earlier full regression count remains
a separate checkpoint; it was not rerun for these diagnostic-only tools.

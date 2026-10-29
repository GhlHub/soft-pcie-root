# Release boundary and further investigation

The frozen release is Gen1/Gen2 x1. Current development adds optional experimental Gen3
x1 and changes shared host/replay RTL. Separate current Gen3 and default Gen2 builds
passed short physical I/O/CRC tests; they do not imply broader qualification or support
for other hardware. See [performance history](performance-history.md) for completed
improvements and [verification](verification.md) for evidence and remaining limits.

## Completed development steps

- Gen3 data-link/NVMe operation, with the eight-entry replay capacity and two
  staging banks used by Gen2.
- 64-bit host receive transfers, removing the main measured Gen3 read bottleneck.
- 64-bit host transmit transfers and eight-slot DDR read prefetch with request overlap.
- Link-domain counters separating peer-credit, replay and formatter stalls.
- Normal ACK retirement concurrent with later original packets, retaining
  exceptional-response drain barriers and immutable packet identities.
- One version 1.1 Vivado catalog entry with a default-off experimental Gen3
  checkbox; customization and synthesis/CDC checks passed for both selections.

- Startup-corrected unified Gen3 routing/audit and ten warm-start CRC trials.
- RX/TX timing improvements culminating in +0.136 ns Gen3 WNS and a verified
  RX metadata SD-default image.
- Independent Gen3 training and packet peers: 994 added cases, including CRC
  corruption, retained ownership, full replay-store reuse and natural sequence
  rollover. Full regression: 1,663 passed. See the
  [Gen3 matrix](gen3-verification-matrix.md) for the remaining functional gaps.

The latest RX metadata image measured 734.84 MB/s read and 564.79 MB/s write
at QD8. The earlier ACK-retirement image measured 745.36/567.71 MB/s.
Its five-second link profile recorded no peer-credit or normal-ACK blocking, but
replay admission blocked 27.62% of cycles and formatter output blocked 16.13%.
These events overlap. More DDR slots are not yet justified by these measurements.

## Remaining work

- Route, audit and physically verify the latest shared source with both unified
  1.1 selections. Historical Gen3 unified builds passed; the later shared requester
  timeout fix has not been rebuilt or deployed.
- Resolve the standalone wrapper's stale read-outstanding annotation; use the
  packaged block-design cell for AXI automation in the meantime.
- Distinguish replay-window/peer ACK latency from PCS boundary, cadence and DLLP
  arbitration limits before changing capacity or scheduling.
- Continue timing work from the RX metadata image's +0.136 ns routed Gen3 WNS;
  verify new changes in fresh source-matched builds.
- Extend the corrected startup's ten warm-start CRC trials to cold cycles and
  broader SSD coverage; complete full Recovery/equalization behavior.
- Extend the new default Gen2 ACK-retirement hardware test to Gen1 and cold cycles.
- Add repeated/interleaved benchmarks, longer runs, cold cycles and broader endpoint coverage.
- Qualify OP063 with a reviewed FRU/VADJ policy and board bring-up.
- Investigate wider links or other FPGA families only with matching PHY,
  ownership, timing and hardware evidence.

No accepted AXI or replay ownership may be reset away. Packet RAM stays unreset;
capacity changes require bounded ownership and wrap/error/recovery regressions.

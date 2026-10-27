# Release boundary and further investigation

The frozen release is Gen1/Gen2 x1. Current development adds optional experimental
Gen3 x1 and changes shared host/replay RTL. Current Gen3 physical results do not
qualify a newly rebuilt default Gen2 image or imply support for other hardware.
See [performance history](performance-history.md) for completed improvements and
[verification](verification.md) for evidence and remaining limits.

## Completed development steps

- Gen3 data-link/NVMe operation, with the eight-entry replay capacity and two
  staging banks used by Gen2.
- 64-bit host receive transfers, removing the main measured Gen3 read bottleneck.
- 64-bit host transmit transfers and eight-slot DDR read prefetch with request overlap.
- Link-domain counters separating peer-credit, replay and formatter stalls.
- Normal ACK retirement concurrent with later original packets, retaining
  exceptional-response drain barriers and immutable packet identities.

The latest 30-second QD8 measurements are 745.36 MB/s read and 567.71 MB/s write.
The five-second link profile recorded no peer-credit or normal-ACK blocking, but
replay admission blocked 27.62% of cycles and formatter output blocked 16.13%.
These events overlap. More DDR slots are not yet justified by these measurements.

## Remaining work

- Distinguish replay-window/peer ACK latency from PCS boundary, cadence and DLLP
  arbitration limits before changing capacity or scheduling.
- Improve timing margin: current Gen3 setup slack is only +0.004 ns.
- Resolve intermittent startup and complete full Recovery/equalization behavior.
- Rebuild and physically verify the default Gen2 configuration after shared RTL changes.
- Add repeated/interleaved benchmarks, longer runs, cold cycles and broader endpoint coverage.
- Qualify OP063 with a reviewed FRU/VADJ policy and board bring-up.
- Investigate wider links or other FPGA families only with matching PHY,
  ownership, timing and hardware evidence.

No accepted AXI or replay ownership may be reset away. Packet RAM stays unreset;
capacity changes require bounded ownership and wrap/error/recovery regressions.

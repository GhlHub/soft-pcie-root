# Performance improvements leading to the current design

The current experimental Gen3 x1 design delivers **745.36 MB/s sequential read**
and **567.71 MB/s sequential write** at queue depth 8 on ZCU104 with a Samsung
990 EVO 1 TB. Widening the receive path produced the largest read improvement;
wider transmit transfers with eight-slot DDR prefetch and concurrent normal ACK
retirement produced the later write improvements. These are measured single-drive
results, not projected speeds for other topologies.

The frozen release remains Gen1/Gen2 x1. The current source tree also contains
optional experimental Gen3 and changes to shared host/replay logic. Current Gen3
hardware tests do not requalify a newly built default Gen2 configuration. The
historical Gen2 bitstream remains the SD boot default; the latest Gen3 image was
tested through temporary programming.

## Comparable physical benchmarks

All rows below use one job, sequential 1 MiB direct I/O through fio/libaio, QD1
or QD8, and 30 seconds per workload. Values are decimal MB/s. Reads access
[0, 4 GiB); writes access [8, 12 GiB), with a final flush. A dash means no
corresponding recorded result. Rows are historical runs, not interleaved trials;
small differences should not be treated as statistically established changes.

| Design stage | Link | Read QD1 | Read QD8 | Write QD1 | Write QD8 |
| --- | --- | ---: | ---: | ---: | ---: |
| Before double transmit buffering [1] | Gen2 x1 | — | 427.81 | 182.16 | 232.24 |
| Double transmit buffering [1] | Gen2 x1 | — | 428.58 | 199.57 | 260.06 |
| Repackaged example [2] | Gen2 x1 | 379.22 | 428.33 | 200.17 | 259.73 |
| Banked DDR payload storage [3] | Gen2 x1 | 380.80 | 428.65 | 200.24 | 259.17 |
| Initial single-packet Gen3 transmitter [4] | Gen3 x1 | 389.64 | 433.82 | 106.51 | 121.38 |
| Gen3 transmit capacity matched to Gen2 [5] | Gen3 x1 | 389.45 | 433.82 | 200.06 | 260.49 |
| 64-bit RX packet path [6] | Gen2 x1 | 384.26 | 428.68 | 200.17 | 260.14 |
| 64-bit RX packet path [6] | Gen3 x1 | 612.22 | 741.81 | 200.43 | 260.30 |
| 64-bit RX/TX and eight-slot read prefetch [7] | Gen3 x1 | 611.16 | 742.25 | 297.12 | 454.74 |
| **Normal ACK retirement, current [8]** | **Gen3 x1** | **599.84** | **745.36** | **339.54** | **567.71** |

Evidence: [1 — transmit buffering](evidence/txdouble_v1/performance-comparison.json),
[2 — repackaged example](evidence/repackaged_v1/completion.json),
[3 — payload banking](evidence/ddr_banked_v1/completion.json),
[4 — initial Gen3](../experiments/gen3/evidence/performance-comparison.json),
[5 — transmit window](../experiments/gen3/evidence/tx-window.json),
[6 — RX64](evidence/rx64_v1/completion.json),
[7 — eight-slot prefetch](evidence/prefetch_v1/completion.json),
[8 — current 30-second measurements](evidence/prefetch_v1/ack-retirement-performance.json).

## What each change accomplished

### Double transmit buffering

Two serializer banks overlap packet collection and CRC calculation with wire
transmission. Gen2 QD8 writes increased from 232.24 to 260.06 MB/s, about 12%.
Sent ownership still advances only at final transmission completion; collecting
a packet ahead does not make it eligible for ACK retirement.

### Banked DDR payload storage

Validation transfers ownership of an alternating payload bank to the writer,
removing the parallel payload copy. This primarily reduced resources: the
complete example fell from 11,881 LUTs and 11,171 FFs at the transmit-buffering
baseline to 10,864 LUTs and 9,294 FFs. Gen2 throughput remained essentially
unchanged. The writer retains the bank through the final W handshake; accepted
B-response ownership persists independently. Payload RAM remains unreset.

### Restoring Gen2 transmit capacity in Gen3

The first operational Gen3 host had a single-packet transmit/replay path. Faster
signaling alone did not compensate for that serialization: QD8 writes measured
121.38 MB/s. Reusing the eight-entry replay store and permitting two original
packets ahead, with two Gen3 framing banks, restored QD8 writes to 260.49 MB/s.
The shared replay store avoids separate Gen2 and Gen3 payload copies.

### Widening the receive path

SSD reads produce endpoint Memory Writes into host DDR. The original internal
32-bit packet interface at 125 MHz had a raw capacity of 500 MB/s even though
DDR AXI was already 64-bit. Packing two DWORDs per host transfer raised the
packet interface's raw capacity to 1 GB/s. Gen3 QD8 reads increased from 433.82
to 741.81 MB/s, about 71%. Gen2 stayed near 429 MB/s. Whole-packet validation,
byte enables, odd-length tails and ownership transfer remain enforced.

### Widening transmit transfers and adding read prefetch

SSD writes require the endpoint to fetch data from host DDR. The experimental
Gen3 package widened the host TX packet path to 64 bits, increased completion
prefetch from two to eight 64-byte slots, and overlapped issuance across validated
endpoint read requests. QD8 writes increased from 260.30 to 454.74 MB/s, about
75%, while reads stayed near their prior rates. This is the combined result of
those changes; the measurements do not isolate their individual contributions.

The 512-byte prefetch capacity supplies more outstanding work to hide DDR
latency. AXI remains 64-bit at 125 MHz, with eight read owners and two write
owners. Responses retain ordered requester/tag metadata. Earlier accepted
writes still fence reads, MSI and flushes; errors drain accepted AXI ownership.

### Retiring normal ACKs without draining later originals

Link profiling found no peer-credit admission stalls but substantial replay
admission blocking. The prior policy waited for active copying and staged
packets to drain before accepting a normal ACK, then refilled the pipeline.

The current engine retires only the acknowledged, already-sent prefix while
later originals remain staged or are being copied. Latched slot/sequence
identities remain stable. NAK and replay transitions retain drain barriers;
invalid ACKs cannot free unsent storage. A simultaneous final-old-ACK/new-wire
completion starts a fresh timeout epoch.

In matched 30-second historical comparisons, QD1 writes improved 14.28% and
QD8 writes improved 24.84% over the eight-slot build. Read differences were
−1.85% and +0.42%; repeated trials would be needed to establish a systematic
read effect. See the [ownership analysis](../experiments/gen3/downstream-investigation.md#normal-ack-retirement-implementation).

## Diagnostic runs and remaining constraints

These shorter runs explain the write path; they are separate from the
30-second benchmark table above.

| Diagnostic image | Duration | Write QD1 MB/s | Write QD8 MB/s |
| --- | ---: | ---: | ---: |
| DDR-path profiling | 10 s | 294.43 | 454.16 |
| LPR1 link profiling, drain-before-ACK | 5 s | 291.69 | 451.27 |
| LPR2 link profiling, concurrent normal ACK retirement | 5 s | 333.17 | 562.13 |

[DDR profile](evidence/prefetch_v1/write-profile.json),
[LPR1](evidence/prefetch_v1/link-profile.json),
[LPR2](evidence/prefetch_v1/ack-retirement.json).
LPR2 recorded zero normal ACK wait/launch blocking, peer-credit stalls, NAK,
replay, timeout, fault and overflow events. At QD8, replay admission still blocked
27.62% of capture cycles and formatter output was blocked 16.13%. Events overlap;
they cannot be added as independent lost time. LPR1 ACK counters measured
coincident pending/state conditions, whereas LPR2 measures actual blocking.

The next investigation is to distinguish replay-window/peer ACK latency from
PCS service, block boundaries and DLLP arbitration. The data does not yet prove
that a deeper window or more DDR prefetch is the best next change.

## Current build and verification scope

Current image: `build/ack_retire_board_v1/system.bit`, SHA256
`7ff1c4483da56fb98ae83a53204fe9c9bf8713a779b2316a6463ba0fb19c0860`.
Its source hashes and independent implementation audit are recorded in
[ACK retirement evidence](evidence/prefetch_v1/ack-retirement.json).

| Complete ZCU104 example | Current value |
| --- | ---: |
| LUTs / FFs | 11,309 / 10,343 |
| Control sets | 534 |
| RAMB36 / RAMB18 | 2 / 1 |
| GTH / hard PCIe / DSP / URAM | 1 / 0 / 0 / 0 |
| Gen3 setup / hold slack | +0.004 / +0.011 ns |

All 49 repository tests, lint, focused Gen3 regressions, fresh synthesis/route
and the independent reopened-checkpoint audit passed. Setup margin remains very
narrow. The current image trained on its first deployment attempt, but earlier
startup intermittence remains unresolved.

All eight jobs in the 30-second remeasurement passed: four benchmarks plus
existing-pattern, fresh 256 MiB, sector-offset 32 MiB and post-flush CRC tests.
Exact 27,528,265,728 written bytes matched block accounting. SMART error counts
remained zero and unsafe shutdowns did not increase. CRC verification uses
separate regions; it does not verify every byte of the timed write range.
No endurance, cold-cycle, full Recovery or PCIe compliance qualification is
implied. See [verification](verification.md) for the complete historical scope.

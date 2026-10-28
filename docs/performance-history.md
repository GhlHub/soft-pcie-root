# Performance improvements leading to the current design

The current experimental Gen3 x1 design delivers **736.91 MB/s sequential read**
and **563.90 MB/s sequential write** at queue depth 8 on ZCU104 with a Samsung
990 EVO 1 TB. Widening the receive path produced the largest read improvement;
wider transmit transfers with eight-slot DDR prefetch and concurrent normal ACK
retirement produced the later write improvements. These are measured single-drive
results, not projected speeds for other topologies.

The frozen release remains Gen1/Gen2 x1. The current source tree also contains optional
experimental Gen3 and changes to shared host/replay logic. The current default Gen2
ACK-retirement configuration has now also passed its own fresh build, audit and physical
I/O/CRC tests. The latest TX transform Gen3 image is now the SD boot default and has passed
an unattended warm reboot and read-only CRC check. The unified 1.1 catalog flow
has passed full synthesis/PNR and physical performance tests with Gen3 enabled;
see [current validation](verification.md). Gen3 remains experimental.

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
| **Normal ACK retirement, current [9]** | **Gen2 x1** | **380.46** | **428.30** | **200.84** | **260.21** |
| Normal ACK retirement [8] | Gen3 x1 | 599.84 | 745.36 | 339.54 | 567.71 |
| RX timing pipeline [10] | Gen3 x1 | 595.54 | 737.09 | 341.83 | 565.70 |
| **TX transform, current [11]** | **Gen3 x1** | **611.93** | **736.91** | **342.41** | **563.90** |

Evidence: [1 — transmit buffering](evidence/txdouble_v1/performance-comparison.json), [2
— repackaged example](evidence/repackaged_v1/completion.json), [3 — payload
banking](evidence/ddr_banked_v1/completion.json), [4 — initial
Gen3](../experiments/gen3/evidence/performance-comparison.json), [5 — transmit
window](../experiments/gen3/evidence/tx-window.json), [6 —
RX64](evidence/rx64_v1/completion.json), [7 — eight-slot
prefetch](evidence/prefetch_v1/completion.json), [8 — current Gen3
measurements](evidence/prefetch_v1/ack-retirement-performance.json), [9 — current Gen2
measurements](evidence/prefetch_v1/ack-retirement-gen2.json), [10 — RX timing
pipeline](evidence/rx_pipeline_v1/completion.json), [11 — TX
transform](evidence/tx_transform_v1/completion.json).

## Mixed random I/O baseline — 2026-10-27

The TX transform Gen3 x1 image completed a 15-minute fio 3.38 workload with
4 KiB random requests, 70% reads / 30% writes, QD32, one direct/libaio job and
a fixed 4 GiB region. These concurrent read/write results establish a separate
baseline from the sequential measurements above.

| Direction | IOPS | MB/s (decimal) | Mean completion latency | p99 completion latency |
| --- | ---: | ---: | ---: | ---: |
| Read | 29,457.75 | 120.66 | 0.749 ms | 0.848 ms |
| Write | 12,623.33 | 51.71 | 0.722 ms | 0.807 ms |
| Combined | 42,081.09 | 172.36 | — | — |

Zero fio errors, exact write accounting, final flush, healthy idle and a
post-test 256 MiB read-only CRC outside the working region passed. SMART
warnings, media errors and error-log entries stayed zero. The randomly written
payload itself was not CRC-verified. fio consumed nearly one CPU core, so the
measurement may include a CPU/software bottleneck. This single run does not
establish steady-state performance or extend Gen3 qualification.

See the [repeatable preset and detailed results](benchmarks/README.md) and
[sanitized measurement evidence](evidence/tx_transform_v1/random-rw-15m.json).

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

### Gen2 measurement with the same ACK retirement logic

A fresh build of the current default Gen2 package measured QD1/QD8 reads of
380.46/428.30 MB/s and writes of 200.84/260.21 MB/s. This is essentially the same
throughput as the originally shared packaged Gen2 baseline (QD8 read/write 428.33/259.73
MB/s). Normal ACK retirement did not materially improve measured throughput in this
configuration. Unlike Gen3, the default Gen2 package retains 32-bit host packet paths
and two 64-byte prefetch slots. The comparison is between the packaged configurations,
not an isolated link-rate experiment.

All eight benchmark/CRC jobs passed with exact 14,142,144,512-byte write accounting,
unchanged SMART error/unsafe-shutdown counts and an idle healthy finish. The new Gen2
image is temporarily running; SD boot files are unchanged. [Gen2
evidence](evidence/prefetch_v1/ack-retirement-gen2.json).

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

## Gen3 build and verification scope

Gen3 image: `build/ack_retire_board_v1/system.bit`, SHA256
`7ff1c4483da56fb98ae83a53204fe9c9bf8713a779b2316a6463ba0fb19c0860`. Its source hashes
and independent implementation audit are recorded in [ACK retirement
evidence](evidence/prefetch_v1/ack-retirement.json).

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

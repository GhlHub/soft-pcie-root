# Verification and release scope

The [Gen1/Gen2 compliance coverage matrix](gen1-gen2-compliance-matrix.md) maps
existing tests to protocol topics, identifies missing coverage and separates
functional evidence from compliance qualification. Its project-scope waivers
exclude features unrelated to direct-attached NVMe operation while retaining
protocol correctness, error containment and data-integrity coverage.

## Gen1/Gen2 NVMe-scope fault and timer coverage

The [coverage matrix](gen1-gen2-compliance-matrix.md#nvme-scope-regression-campaign)
now records 584 new parameterized simulation cases covering packet corruption,
completion validation, requester timeout arbitration, replay boundaries and
UpdateFC scheduling. Unit benches run at both Gen1/Gen2 clock rates; they do not
constitute physical link or full compliance qualification.

The tests found and reproduced a timeout/completion race: a valid completion on
the deadline returned success while leaving the requester faulted, blocking
subsequent commands until reset. The failure reproduced at both test clock rates;
it was found in simulation, not observed on the board. Both header-only and data-completion paths now cancel the coincident timeout fault.
Malformed completions remain quarantined and link loss retains final priority.
All **669 repository tests passed**, including the 584 new cases. Repository
lint and real-XPM elaboration passed with Vivado 2026.1.
[Results and exact changed-source hashes](evidence/gen12_coverage_v1/completion.json).

This shared requester RTL change has not been synthesized, routed or deployed;
the recorded SD image and historical hardware evidence are unchanged.

## RX ingress metadata and parallel pointer image

The parser change passed fresh unified Gen3 packaging, full synthesis/PNR and
an independent reopened audit on 2026-10-28. Routed Gen3 setup WNS improved
from **+0.090 to +0.136 ns** (+46 ps); hold is +0.010 ns. Gen1 startup setup/hold
is +0.642/+0.010 ns. No extra postroute optimization was used. Timing coverage,
CDC, DRC, routing, bus skew and source manifests passed. The limiting path now
runs from the parser read pointer to the count register's synchronous reset.
Resources are 11,252 LUTs, 10,459 FFs, 538 control sets, two RAMB36 and one RAMB18.

Per-byte classifications are written with ingress data, and the pointer selects
parallel advance candidates. No parser latency was added. Payload and metadata
remain unreset; control resets remain synchronous and packet validation is
unchanged. All 82 existing tests plus three added RX tests passed. The independent
framing oracle covers 208 cases; cycle-by-cycle comparison matched the prior
parser across 6,745 stimulus entries plus drains, including control state,
cursors, counts and valid data. This is tested equivalence, not a formal proof.

One clean-halt/kernel-stop/program/resume attempt negotiated Gen3 x1 and passed
256 MiB read-only CRC. All eight matched performance/integrity jobs passed:

| Workload | Previous TX transform MB/s | RX metadata MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 611.93 | 595.24 | -2.73% |
| Read QD8 | 736.91 | 734.84 | -0.28% |
| Write QD1 | 342.41 | 339.91 | -0.73% |
| Write QD8 | 563.90 | 564.79 | +0.16% |

Same fio 3.38, 1 MiB direct/libaio, one job, 30 seconds per benchmark. Existing
and fresh 256 MiB CRC, sector-offset 32 MiB CRC and post-flush CRC passed. Exact
27,453,816,832 written bytes matched block accounting; SMART warnings, media
errors and error-log entries stayed zero, with unsafe shutdowns unchanged.
Historical performance comparisons are not interleaved statistical trials.
The random-I/O baseline was not remeasured.

The board is healthy and idle on the RX metadata image; SD still defaults to the
TX transform image. One controlled startup and short tests do not qualify cold
cycles, endurance, full Recovery or compliance. Gen3 remains experimental.
[Implementation and physical evidence](evidence/rx_metadata_v1/completion.json).
[LinkedIn graphic](media/linkedin-rx-parser-timing-v2.png).

The RX metadata image subsequently became the SD default. SHA-256 readback
passed after remount and after an unattended warm reboot. A new Linux boot ID
and the `soft_pcie.image=rx_metadata_v1` command-line marker confirmed execution
of the updated boot script, whose boot path requires successful FPGA loading.
Gen3 x1 and 256 MiB read-only CRC passed; SMART counters were unchanged, with
zero SSD writes. Bootloader, Linux and DTB files were retained, no QSPI update
was made, and persistent SD ext4 root remains read/write. The boot partition was
unmounted afterward. [Default-boot evidence](evidence/rx_metadata_v1/default-boot.json).
No cold-cycle qualification or UART CRC observation is claimed.


## TX LFSR transform image

The TX transform passed fresh unified Gen3 packaging, full synthesis/PNR and an
independent reopened audit on 2026-10-27. Gen3 setup/hold is **+0.090/+0.012 ns**;
Gen1 startup is +0.699/+0.012 ns. The TX formatter's worst slack improved from
+0.073 to +0.184 ns; the overall limiting path is now buffered RX packet-parser
read-pointer logic. Resources are 11,175 LUTs, 10,444 FFs, 538 control sets, two
RAMB36, one RAMB18 and one GTH. Source manifests, timing coverage, CDC, DRC,
bus-skew, routing and structure checks passed. No extra postroute optimization
was required. All 82 repository tests and the focused TX/native-link tests passed.

After clean halt and an independently checked kernel-entry stop, the programmed
image negotiated Gen3 x1 on its first attempt and passed a 256 MiB read-only CRC
check. All eight matched performance/integrity jobs subsequently passed:

| Workload | Previous RX pipeline MB/s | TX transform MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 595.54 | 611.93 | +2.75% |
| Read QD8 | 737.09 | 736.91 | -0.02% |
| Write QD1 | 341.83 | 342.41 | +0.17% |
| Write QD8 | 565.70 | 563.90 | -0.32% |

Same fio 3.38, direct/libaio, one job, 1 MiB blocks and 30 seconds per benchmark.
Existing and fresh 256 MiB CRC, sector-offset 32 MiB CRC and post-flush verification
passed. All 27,501,002,752 written bytes matched block-sector accounting. SMART
critical warnings, media errors and error-log entries stayed zero; unsafe
shutdowns stayed at 26. These historical comparisons are not an interleaved
statistical study. At the end of this initial test, the board was live and idle; SD boot
files had not yet been updated. One startup and short I/O testing do not qualify cold
cycles, endurance, full Recovery or compliance; setup margin remains narrow.
[Exact implementation and physical evidence](evidence/tx_transform_v1/completion.json).

The TX transform image subsequently became the SD default. Bitstream and script
SHA-256 readback passed after remount and again after an unattended warm reboot.
The restarted Linux instance reported Gen3 x1; existing 256 MiB read-only NVMe
CRC passed with zero SSD writes and unchanged SMART counters. UART boot output
was unavailable, so no UART CRC observation is claimed. Existing bootloader and
Linux files were retained, no QSPI update was required, and persistent SD ext4
root remains read/write. The boot partition was unmounted after verification.
[Default-boot evidence](evidence/tx_transform_v1/default-boot.json). No cold-cycle
qualification was added.

The TX transform image also passed a [repeatable 15-minute mixed random I/O
benchmark](benchmarks/README.md#tx-transform-baseline-2026-10-27): 4 KiB,
70/30 reads/writes, QD32, one direct/libaio job. Combined throughput was
42,081 IOPS (172.36 MB/s), with zero fio errors and passing post-test CRC/SMART
checks. fio used nearly one CPU core; this is not a hardware-only capacity
measurement.

## RX timing pipeline image

The RX timing refactor passed fresh unified 1.1 Gen3 packaging, full synthesis
and place-and-route, and an independent reopened-checkpoint audit on 2026-10-27.
Gen3 setup/hold slack is **+0.073/+0.011 ns**, versus +0.002/+0.011 ns for the
startup-tested image. Gen1 startup is +0.630/+0.011 ns. The worst path moved from
RX decoding to the TX recovery formatter's LFSR-to-correction logic. All source
manifests, structural checks, timing coverage, CDC, DRC, routing and bus-skew
checks passed. Utilization is 11,219 LUTs, 10,491 FFs, 540 control sets, two RAMB36,
one RAMB18 and one GTH. All 76 repository tests and focused native RX/link tests
passed before the frozen build.

The image was programmed after a clean Linux halt and independently checked
kernel-entry stop. It negotiated Gen3 x1 on its first attempt and passed a
256 MiB read-only CRC check followed by eight performance/integrity jobs.

| Workload | Previous ACK-retirement MB/s | RX pipeline MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 599.84 | 595.54 | -0.72% |
| Read QD8 | 745.36 | 737.09 | -1.11% |
| Write QD1 | 339.54 | 341.83 | +0.67% |
| Write QD8 | 567.71 | 565.70 | -0.35% |

Same fio 3.38, direct/libaio, one job, 1 MiB blocks and 30-second runs. Existing
256 MiB CRC, fresh 256 MiB CRC, sector-offset 32 MiB CRC and post-flush verification
passed. All 27,537,702,912 written bytes matched block-sector accounting. SMART
critical warnings, media errors and error-log entries stayed zero; unsafe shutdowns
stayed at 26. A missing benchmark Python helper stopped the first harness launch
before I/O; restoring it allowed the complete suite to run without reprogramming.

The board remains healthy and idle on this image. SD boot files are unchanged.
This comparison is historical, not an interleaved statistical study. One warm
startup does not extend cold-cycle, endurance or compliance qualification; full
Recovery remains incomplete. The setup margin is still narrow.
[Exact source and physical evidence](evidence/rx_pipeline_v1/completion.json).

For a consolidated benchmark table and the reason for each optimization, see
[performance improvements](performance-history.md). Sections below preserve
historical build evidence; a reported final board state applies to that test.
The latest results are first. Frozen Gen1/Gen2 provenance manifests remain
unchanged. `make release-check` intentionally rejects newer shared RTL and RTL
inventory; passing current development tests does not relabel that baseline.

## Startup-corrected unified Gen3 image

The Configuration.Complete receive qualification now survives the peer's transition
to idle while the local transmit requirement finishes. Passive legacy startup history
was added to the existing diagnostic registers. All 74 repository tests, including
25 focused startup cases, lint and XPM elaboration passed.

Fresh synthesis and implementation, followed by an additional physical-optimization
pass, passed an independent reopened audit. Gen3 setup/hold is +0.002/+0.011 ns;
Gen1 startup is +0.427/+0.011 ns. Resources are 11,341 LUTs, 10,411 FFs, 536 control
sets, two RAMB36 and one RAMB18. CDC, bus skew, DRC and routing checks passed.

Ten controlled warm starts all negotiated Gen3 x1 and passed 256 MiB read-only NVMe
CRC verification each: 2.5 GiB total, zero SSD writes, no new SMART errors or unsafe
shutdowns. Two debugger-control retries occurred before Linux startup; neither
required another link-training attempt. The board was left running this corrected
image; SD boot files remain unchanged. No new throughput measurement was made.

See the [correction and test method](../experiments/gen3/startup-stabilization.md) and
[exact evidence](evidence/startup_fix_v1/completion.json). This bounded test does not
qualify cold cycling, temperature variation, endurance or compliance. The very narrow
Gen3 setup margin and incomplete full Recovery remain limitations.

## Initial unified catalog development

The current source now uses one version 1.1 catalog definition with a default-off
**Enable experimental Gen3** checkbox. This packaging/elaboration change follows the
physical measurements below; those exact images have not been replaced. The common host
derives 32-bit/two-slot or 64-bit/eight-slot dimensions from the same HDL parameter.
Native generated helpers are namespaced, and native constraints are generated only for
the enabled native backend. See [catalog
configuration](ip-guide.md#optional-gen3-packaging).

Vivado 2026.1 package integrity, repeated block-design checkbox changes, and
out-of-context synthesis of both configurations passed. Each elaborates one GTH and the
selected backend only, with the expected packet RAM width and read-owner capacity.
Matching PHY clocks and board CDC constraints passed with no critical warnings or
unwaived critical CDC findings. All 49 repository tests and lint/XPM elaboration passed.
See [sanitized catalog evidence](evidence/catalog_v1/selection.json). The integration guide documents the standalone wrapper
annotation limitation; use the packaged block-design cell for AXI automation.

The unified Gen3-enabled package subsequently passed full synthesis, place-and-route,
bitstream generation, and an independent reopened checkpoint audit. Final Gen3 setup/hold
slack is +0.073/+0.010 ns; Gen1 startup is +0.540/+0.010 ns. Utilization is 11,322 LUTs,
10,375 FFs, 535 control sets, two RAMB36 and one RAMB18. Timing coverage, bus skew,
DRC, routing, CDC and source-manifest checks passed. See
[implementation evidence](evidence/catalog_gen3_v1/implementation.json). This image has
not been programmed or physically qualified. Its startup RTL is unchanged; a simulated
Configuration.Complete receive-qualification race remains a candidate explanation for
intermittent startup, pending hardware confirmation.

## Current Gen2 ACK retirement measurement

The pre-unification default Gen2 package was freshly built with the same shared ACK
retirement optimization and programmed after clean shutdown and an independently
verified pre-kernel stop. The first boot negotiated Gen2 x1. Host packet paths are
32-bit with two 64-byte prefetch slots; DDR AXI remains 64-bit/125 MHz.

| Workload | Current Gen2 MB/s |
| --- | ---: |
| Read QD1 | 380.46 |
| Read QD8 | 428.30 |
| Write QD1 | 200.84 |
| Write QD8 | 260.21 |

One job, 1 MiB direct/libaio, 30 seconds per workload. This is essentially unchanged
from the historical Gen2 baseline; it does not demonstrate an ACK-only speedup. All
eight benchmark/CRC jobs passed, including existing/fresh/sector-offset and post-flush
checks. Exact 14,142,144,512 written bytes match block accounting. SMART
warnings/media/errors remain zero, unsafe shutdowns remain 26, and the board is
healthy/idle. The timed write range is separate from CRC verification.

Fresh synthesis/PNR and independent reopened audits passed. Both before-package and
routed source manifests match. Resources: 9,214 LUTs, 8,185 FFs, 447 control sets, three
RAMB18s, one GTH and no hard PCIe. Setup/hold slack is +0.068/+0.013 ns; there are no
unwaived critical CDC findings. Existing reset-waiver count is 15.

The board now runs `build/ack_gen2_board_v1/system.bit`; SD boot files are unchanged.
[Exact build and physical evidence](evidence/prefetch_v1/ack-retirement-gen2.json). This
adds a short Gen2 hardware test to the shared ACK change, not a Gen1, cold-cycle,
endurance, full Recovery or compliance qualification. The Gen3 results below remain
historical measurements on their matching image.

## Normal ACK retirement: implemented and physically tested

Normal ACKs can now release the already-sent prefix while later original packets
remain staged or are being copied. NAK/replay transitions retain their drain
barriers, staged sequence identities remain stable, and packet RAM stays unreset.
The timeout epoch is refreshed when retirement of all old sent packets coincides
with a new wire completion. See the
[ownership argument](../experiments/gen3/downstream-investigation.md#normal-ack-retirement-implementation).

The fresh LPR2 image passed synthesis/PNR, an independent reopened-checkpoint
audit, all 49 repository tests, lint and focused Gen3 regressions. Both source
manifests match. Utilization is 11,309 LUTs, 10,343 FFs, 534 control sets, two
RAMB36 and one RAMB18, one GTH and no DSP/URAM/hard PCIe. Gen3 setup/hold slack is
+0.004/+0.011 ns; Gen1 startup +0.369/+0.011 ns. Setup margin is very narrow.

The ZCU104 trained Gen3 x1 on the first deployment attempt. Five-second direct
libaio, 1 MiB write captures show:

| Workload | Previous LPR1 MB/s | Normal ACK retirement MB/s | Change |
| --- | ---: | ---: | ---: |
| Write QD1 | 291.69 | 333.17 | +14.22% |
| Write QD8 | 451.27 | 562.13 | +24.57% |

LPR2 actual ACK wait/copy-launch blocking counters are zero. Replay admission
stalls fall to 16.33%/27.62%; formatter output blocking is 9.52%/16.13%.
Peer-credit stalls, NAK, replay, timeout, fault and overflow counters are zero.
LPR1 ACK counters included coincident pending/state cycles; their numerical
values are not directly interchangeable with LPR2 blocking predicates.

Existing-pattern CRC, fresh 256 MiB CRC, sector-offset 32 MiB CRC, namespace
flush and post-flush CRC passed. Exact 4,787,798,016 written bytes match block
accounting. SMART critical warnings/media errors/error-log entries remain zero;
unsafe shutdowns remain 26. CRC covers the separate verification ranges, not
the timed profiling write range. Final DMA/root status is healthy, NVMe is live
and no I/O is in flight.

Current image: `build/ack_retire_board_v1/system.bit`; audit reports:
`build/ack_retire_audit_v1`. SD boot files are unchanged.
[Evidence](evidence/prefetch_v1/ack-retirement.json). This is a short historical
comparison, not statistical/endurance/compliance qualification. The successful boot does
not resolve prior startup intermittence. At that stage Gen2 regression simulation
passed; the subsequent Gen2 physical measurement is recorded above.

### Current-image 30-second remeasurement

The same normal-ACK image was remeasured with direct/libaio, one job, 1 MiB
blocks and 30 seconds per workload. Live LPR2 magic, Gen3 x1 and the eight-slot
64-bit configuration were checked before testing. Profiling counters remained
stopped to avoid overflow during these longer runs.

| Workload | Earlier eight-slot build, 30 s MB/s | Current ACK retirement, 30 s MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 611.16 | 599.84 | -1.85% |
| Read QD8 | 742.25 | 745.36 | +0.42% |
| Write QD1 | 297.12 | 339.54 | +14.28% |
| Write QD8 | 454.74 | 567.71 | +24.84% |

All eight benchmark/CRC jobs passed, including existing, fresh 256 MiB,
sector-offset 32 MiB and post-flush CRC checks. Exact 27,528,265,728 written
bytes match block accounting. SMART warning/media/error-log counts remain zero;
unsafe shutdowns remain 26. Temperature rose from 311 to 318 K. Final DMA is
healthy/idle with no I/O in flight. Board image and SD boot files are unchanged.
These are single runs against historical results; the modest read differences
do not establish a systematic change. Timed write ranges are separate from the
CRC verification ranges. [Evidence](evidence/prefetch_v1/ack-retirement-performance.json).

## Gen3 link-clock profiling (historical LPR1)

The LPR1 diagnostic image passed fresh synthesis/PNR and independent reopened
checks, then physical profiling on ZCU104. It retains the eight-slot DDR
configuration and the existing ACK retirement policy. Local command operation 7
controls 32 link-clock counters through the existing mailbox CDC; snapshots
freeze in the link domain before readout. No packet/replay reset was added.

| Five-second write capture | QD1 | QD8 |
| --- | ---: | ---: |
| fio throughput, MB/s | 291.69 | 451.27 |
| Application blocked by peer credits, % cycles | 0.00 | 0.00 |
| Application blocked by replay admission, % cycles | 26.52 | 41.13 |
| Replay window full, % cycles | 26.58 | 41.25 |
| Captured ACK waiting on staged packets, % cycles | 28.97 | 44.94 |
| Pending ACK while copy engine idle, % cycles | 21.53 | 33.41 |
| Formatter output blocked, % cycles | 4.81 | 7.46 |
| Copy engine blocked by formatter, % cycles | 0.00 | 0.00 |

Counter events overlap; percentages use the complete capture window including
fio startup/flush. The copy-idle ACK count includes retirement itself
(0.80%/1.24% of cycles), and does not prove an eligible new copy on every cycle.
No NAK, replay, timeout or fault events occurred. The physical result supports
normal-ACK pipeline drain/refill as the primary internal optimization target;
peer credit admission was not a bottleneck in these runs. It does not establish
that endpoint ACK latency has no influence on throughput.

All captures had zero overflow. Exact 3,724,541,952 written bytes matched block
accounting; namespace flush and existing 256 MiB CRC readbacks before/after
passed. These CRC checks cover the established 16 GiB verification region, not
the profiling write range. SMART error counts remained zero and unsafe shutdowns
stayed at 26. Two initial boots failed training before enumeration; the third
succeeded. Startup intermittence remains unresolved.

Diagnostic utilization: 11,318 LUTs, 10,375 FFs, 535 control sets, two RAMB36 and
one RAMB18, one GTH, no URAM/DSP/hard PCIe. Gen3 setup/hold slack is
+0.059/+0.011 ns; Gen1 startup +0.515/+0.011 ns. All routing, DRC, bus-skew,
coverage and structural audits pass; no unwaived critical CDC was added.
All 47 repository tests passed, along with lint and focused Gen3 regressions.

At completion of that earlier run, the board ran `build/link_profile_board_v1/system.bit`, healthy and
idle, with SD boot files unchanged. Reports: `build/link_profile_audit_v1`.
[Evidence](evidence/prefetch_v1/link-profile.json),
[counter register contract](registers.md#experimental-gen3-link-profiling-lpr1),
and [investigation](../experiments/gen3/downstream-investigation.md).
This diagnostic result does not qualify full Recovery, cold cycles, endurance
or compliance. ACK optimization was implemented and tested subsequently above.

## Optional Gen3 and DDR prefetch development

The startup-corrected Gen3-enabled eight-read configuration passed full
synthesis, placement/routing and an independent reopened-checkpoint audit.
Final utilization is **10,532 LUTs, 9,226 FFs, 498 control sets, two RAMB36s and
one RAMB18 (2.5 tiles)**, with one GTH and no DSP, URAM or hard PCIe controller.
Gen3 setup/hold slack is **+0.039/+0.013 ns**; Gen1 startup is
**+0.543/+0.013 ns**. Pulse-width slack is +0.543 ns. Margins remain narrow.
DRC, routing, bus skew, timing coverage and structural checks pass; CDC has no
unwaived critical findings and retains 12 existing reset-waiver endpoints.
Package/build/source manifests match.

Initial hardware testing exposed a startup bug: the new completion drain flag
latched while the link was initially inactive, despite owning no reads. Two
boots trained Gen3 but timed out at NVMe Identify. Passive counters showed two
completed DDR read bursts and zero TX completions. Drain now latches only when
read ownership exists. The regression starts with an inactive link, reproduces
the original failure and passes after the fix; all 46 tests and lint pass.
The corrected image still encountered one link-training timeout, then booted
successfully on retry. Gen3 startup intermittence remains unresolved.

The corrected image passed all eight physical benchmark/CRC jobs:

| Workload | Previous Gen3 MB/s | Eight-read Gen3 MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 612.22 | 611.16 | -0.17% |
| Read QD8 | 741.81 | 742.25 | +0.06% |
| Write QD1 | 200.43 | 297.12 | +48.24% |
| Write QD8 | 260.30 | 454.74 | +74.70% |

Same fio 3.38, direct/libaio, one job, 1 MiB blocks and 30-second runs.
Existing 256 MiB CRC, fresh 256 MiB CRC, sector-offset 32 MiB CRC and post-flush
verification passed. Exact 22,866,296,832 written bytes match block-sector
accounting. SMART critical warnings, media errors and error-log entries remained
zero; unsafe shutdowns stayed at 26. Final DMA status is healthy/idle with no I/O
in flight. These are short historical comparisons, not interleaved statistical,
endurance, cold-cycle or compliance qualification.

The pre-instrumentation image is `build/prefetch_gen3_board_v2/system.bit`, with
its XSA beside it. Reopened reports are in `build/prefetch_gen3_audit_v2`.
[Corrected implementation evidence](evidence/prefetch_v1/implementation_v2.json)
and [physical evidence](evidence/prefetch_v1/completion.json) record hashes and
scope. SD boot files are unchanged. The first `board_v1` image is superseded
because of the startup drain bug; its earlier implementation record remains
historical. Only the Gen3-enabled configuration received this new full build.

The current package selector defaults to Gen1/Gen2 with 32-bit host RX/TX packet
paths and two read slots. Enabling experimental Gen3 selects 64-bit host RX/TX,
eight 64-byte read slots and overlap between validated SSD memory-read requests.
Both retain AXI64/125 MHz, two write owners, ordered completions, all-B-before-MSI
and accepted-AXI drain. See [packaging](ip-guide.md#optional-gen3-packaging).

Subsequent ten-second write counter captures on the corrected eight-slot image measured
294.43 MB/s at QD1 and 454.16 MB/s at QD8. Bridge-to-TX-CDC stalls occupied
22.14%/34.17% of capture cycles, while waiting for the next completed DDR slot occupied
only 0.35%/0.51%. All eight slots were occupied for 53.53%/82.58%; issuance was blocked
by full slots for 51.16%/78.89%. Slots retain ownership until completion transmission
into the CDC, so these are not measurements of eight outstanding AXI bursts. DDR AR
backpressure was zero. The evidence points to downstream transmit backpressure rather
than insufficient DDR prefetch as the next optimization target. Existing counters cannot
isolate transmit scheduling, replay/ACK limits or peer credits. Counter events overlap,
and capture windows include fio startup/flush overhead. All captures had zero
fault/overflow, exact 7,495,221,248-byte write accounting, unchanged SMART
error/unsafe-shutdown counts and a healthy idle finish. See [write counter
evidence](evidence/prefetch_v1/write-profile.json). A subsequent [downstream
investigation](../experiments/gen3/downstream-investigation.md) identified the shared
replay engine's normal-ACK drain/refill policy as a strong internal candidate through
controlled simulation. Subsequent LPR1 physical captures, reported above, supported that
attribution while preserving the old retirement policy. The later normal-ACK revision
changed that policy and is recorded near the top of this document.

Validation passed: 46 repository tests, lint/XPM elaboration, the experimental
Gen3 regression, fresh packaging and full-shell RTL elaboration for both choices.
The new coverage includes 2/4/8/16 read-slot depths; separate request tags while
completions stall; errors in later prefetched requests; held AR/link-loss drain;
malformed RLAST; TX64 CDC ordering, credit metadata, odd lengths, stopped
clocks, rate fallback and backpressure; and PRF2 register/profiler units.

Isolated Vivado 2026.1 synthesis on XCZU7EV-2 produced:

| DDR bridge configuration | Total LUTs (including LUTRAM) | LUTRAM | FFs |
| --- | ---: | ---: | ---: |
| Gen3 disabled: 32-bit, 2 slots | 1,192 | 254 | 494 |
| Gen3 enabled: 64-bit, 8 slots, pipelined reads | 1,736 | 430 | 539 |

Read payload storage uses even/odd DWORD banks with one write port each and
infers distributed RAM, rather than registers and a large mux network. No BRAM,
URAM or DSP is used by the isolated bridge. Each packet CDC separately infers
one RAMB18 in the narrow configuration, or one RAMB36 in the wide configuration.
These figures are not full-design utilization or timing results.

Fresh local outputs are `build/prefetch_gen{2,3}_package_v2` and
`build/prefetch_synth_v2`. Reproduce isolated synthesis with
`scripts/synth_prefetch.tcl fresh-output-directory` under Vivado batch mode.
[Development evidence](evidence/prefetch_v1/development.json) records source and
artifact hashes. At the initial development checkpoint, full implementation and physical tests
had not been performed. The subsequent Gen3 implementation is recorded above;
the corrected revision subsequently passed the physical tests recorded above.
Earlier RX64 performance below must not be attributed to this new revision.
No board or SD changes were made; frozen qualified-release manifests are intact.

## RX64 development builds and physical I/O tests

The widened receive path passed fresh full synthesis, placement, routing and
reopened structural audits for both the Gen2 example and experimental Gen3 host.
Both retain the 64-bit/125 MHz DDR AXI interface and 128-bit PS HP0 connection.

| Build | LUTs | FFs | BRAM tiles | Setup slack | Hold slack |
| --- | ---: | ---: | ---: | ---: | ---: |
| RX64 Gen2 | 11,059 | 9,347 | 2.5 | +0.107 ns | +0.010 ns |
| RX64 Gen3 | 11,816 | 10,227 | 2.5 | +0.062 ns | +0.010 ns |

Each uses two RAMB36s, one RAMB18 and one GTH, with no URAM, DSP or hard PCIe
controller. Gen3's Gen1 startup-mode setup slack is +0.339 ns. Source manifests
match; route, DRC, bus-skew and timing-coverage checks pass. Reopened CDC reports
have no unwaived critical findings and retain the twelve existing global-reset
waiver endpoints. Positive Gen3 setup margin remains narrow.

Both images subsequently passed eight physical NVMe jobs on temporary JTAG
boots: existing-pattern CRC, matched sequential read/write QD1/QD8 benchmarks,
fresh 256 MiB CRC, 32 MiB sector-offset CRC and post-flush readback. Each boot
succeeded on its first attempt in this test; this does not resolve Gen3's
previously observed intermittent startup failure.

| Workload | RX64 Gen2 MB/s | RX64 Gen3 MB/s | Earlier Gen3 MB/s |
| --- | ---: | ---: | ---: |
| Read QD1 | 384.26 | 612.22 | 389.45 |
| Read QD8 | 428.68 | 741.81 | 433.82 |
| Write QD1 | 200.17 | 200.43 | 200.06 |
| Write QD8 | 260.14 | 260.30 | 260.49 |

These use direct/libaio, 1 MiB blocks, one job and 30 seconds per benchmark.
Gen3 read improvement is 57.2% at QD1 and 71.0% at QD8; writes remain essentially
unchanged. The earlier results are historical comparisons, not interleaved
statistical trials. A separate ten-second read-only Gen3 profile measured
738.75 MB/s with zero DMA fault cycles or counter overflow.

Exact written bytes were 14,120,124,416 for Gen2 and 14,132,707,328 for Gen3,
matching block-sector accounting. Namespace flushes passed; SMART media/error
counts stayed zero and unsafe shutdowns did not increase. The board was returned
to the tested RX64 Gen2 image, where a final 256 MiB read-only CRC passed and no
I/O remained in flight. SD boot files were unchanged and still select the earlier
image on normal reboot. No cold-cycle, endurance, full Recovery or electrical
compliance qualification was added.

The historical qualified source hashes and physical results below still refer
to the earlier receive path. See [RX64 implementation evidence](evidence/rx64_v1/implementation.json)
for resources and hashes, and [physical evidence](evidence/rx64_v1/completion.json)
for test scope and final deployment state.

## Verified banked-payload revision

The DDR bridge now uses alternating payload RAM banks with ownership transfer
instead of a parallel packet-to-writer copy. The pending request queue and read
completion storage retain their existing organization. A fresh packaged ZCU104
build passed full synthesis, placement, routing and reopened structural audit
with Vivado 2026.1. The whole example uses 10,864 LUTs, 9,294 FFs, 445 control sets
and two BRAM tiles. Setup/hold/pulse-width slack is +0.089/+0.010/+0.543 ns.
DRC, scoped CDC, bus-skew, timing coverage and source-manifest checks passed.
The regression suite passed 40 tests and lint/XPM elaboration passed.

[Banked-payload implementation evidence](evidence/ddr_banked_v1/implementation.json)
records the exact sources and generated-artifact hashes. The same image then
passed a volatile boot and eight physical NVMe I/O/CRC tests on ZCU104 with
OP047 Rev D and a Samsung 990 EVO 1 TB at Gen2 x1 using MSI-X. Read QD1/QD8
measured 380.80/428.65 MB/s; write QD1/QD8 measured 200.24/259.17 MB/s. All four
results are within 0.42% of the prior packaged image in these 30-second runs.
Previous-pattern, fresh 256 MiB, 32 MiB sector-offset and post-flush CRC checks
passed. The 14,093,910,016 written bytes exactly match block-sector accounting;
SMART media errors and error-log entries remain zero, with no increase in unsafe
shutdowns. See [physical test evidence](evidence/ddr_banked_v1/completion.json).

The banked image is now the SD default. Uninterrupted warm boot, SD hash
readback and a 256 MiB read-only CRC check passed. Obsolete FPGA images, rollback
scripts and the unused legacy kernel/device tree were removed from the SD boot
partition. See [default-boot evidence](evidence/ddr_banked_v1/default-boot.json).
The boot configuration subsequently switched to a persistent read/write ext4
SD root, expanded to the remaining card capacity. Two automatic boots, file
persistence across reboot and a 256 MiB read-only NVMe CRC passed; see
[SD-root evidence](evidence/ddr_banked_v1/sd-root.json).
Fixed Linux MAC configuration also passed reboot verification; see
[MAC evidence](evidence/ddr_banked_v1/fixed-mac.json). Sequential SD file I/O
measured 23.81 MB/s read and 10.53 MB/s write; see
[SD performance evidence](evidence/ddr_banked_v1/sd-performance.json).
No cold-cycle, Gen1, endurance, power-loss or live recovery qualification was
added. The baseline measurements below remain historical evidence for their
named images.

The frozen `docs/baseline-rtl.json` remains historical evidence.
[rtl-updates.json](rtl-updates.json) records the DDR bridge change separately,
linking its exact source hash to the routed image and physical test evidence.
`make release-check` verifies that historical update on its matching source
revision; later development shared RTL intentionally differs.

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

At the initial public refactor, all protocol, DMA, CSR and PHY RTL was preserved
from the accepted baseline.
Only the board-named top module identifier changed to `soft_pcie_root`.
[baseline-rtl.json](baseline-rtl.json) records original and release hashes;
`make release-check` checks the rename-normalized contents and RTL inventory
against that frozen baseline.
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
MPS128/MRRS512/RCB64/MSI-X. U-Boot VADJ telemetry was 1.801 V.

| Test | Packaged example | Difference from txdouble_v1 |
| --- | ---: | ---: |
| Read QD1 | 379.222345 MB/s | No corresponding baseline run |
| Read QD8 | 428.330965 MB/s | -0.057% |
| Write QD1 | 200.174748 MB/s | +0.304% |
| Write QD8 | 259.734844 MB/s | -0.124% |

Same fio 3.38, one job, direct/libaio, 1 MiB, 30 s and benchmark ranges as above.
All eight I/O/CRC jobs passed, including previous 256 MiB CRC, fresh 288 MiB CRC,
and post-flush 256 MiB CRC. 14,108,590,080 written bytes exactly match block-sector
accounting. Final SMART media/error-log and critical warnings 0; 45 C; unsafe
shutdown count unchanged. Link/DDR healthy; MSI-X delivered; SSD unmounted.
Performance is essentially unchanged in these short runs, not a statistical
or endurance qualification. Existing all-B-before-MSI logic is unchanged.

[Physical evidence and exact parameters](evidence/repackaged_v1/completion.json).
The image was initially deployed in volatile configuration. It subsequently
became the SD default and passed uninterrupted warm boot plus 256 MiB read-only
CRC verification. [Default-boot evidence](evidence/repackaged_v1/default-boot.json).
Those historical rollback files were later removed when the banked image became the SD default. No OP063, Gen1 retest, cold power cycle or power-loss test was performed.

## Limits and reproducing measurements

The frozen release scope is Gen1/Gen2 x1; experimental Gen3 physical I/O and
performance evidence is recorded above. There is no PCI-SIG compliance, wider-link,
hotplug, power-loss or endurance qualification. The historical stopping point
did not repeat Gen1/cold-cycle qualification. Later packet-width, prefetch and
normal-ACK improvements are summarized in [performance history](performance-history.md).

Build/test commands are in the [README](../README.md). Hardware tests require
reviewed power initialization, an explicitly selected disposable unmounted SSD,
and separate deployment instructions. `scripts/profile_completion_path.py`
requires `SOFT_PCIE_TEST_SSD_SERIAL` to identify the intended test device; write
benchmarks overwrite their configured ranges. Do not run them on unknown disks.

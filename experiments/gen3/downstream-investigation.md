# Eight-slot Gen3 downstream transmit investigation

This is a chronological investigation: the original drain-before-ACK hypothesis,
LPR1 measurement, implementation and LPR2 physical result appear in order.
The normal-ACK change is complete. Latest 30-second read/write results are in
[performance history](../../docs/performance-history.md).

The physical PRF2 captures on the corrected eight-slot image locate substantial
backpressure at the DDR bridge's transmit packet CDC. They do not identify the
individual link-clock stall source. QD8 measured 454.16 MB/s, with TX stalls in
34.17% of host-clock capture cycles and next-DDR-slot starvation in only 0.51%.
See [physical counters](../../docs/evidence/prefetch_v1/write-profile.json).

## Path and ownership

The current path is bridge TX64/125 MHz → four-slot packet CDC → 64-to-32 unpacker
at 250 MHz → command/application arbitration and credit reservation → eight-slot
replay store → two-bank STP/LCRC formatter → DLLP/TLP arbitration → recovery PCS
scheduler. The final scheduler in the deployed image is `gen3_recovery_tx`, not
the separately tested `gen3_tx_schedule` module.

The unpacker can supply one DWORD per link clock while its source stays valid.
The replay store has a synchronous RAM read and elastic output pipeline, also
capable of one DWORD per clock within a packet. Whole-packet publication, RAM
read startup, and frame boundaries introduce bubbles. The PCS starts frames
only at a four-DWORD block boundary and emits 64 DWORD opportunities per 65
clocks, with additional SKP/closing overhead.

## Original hypothesis: ACK retirement drains the pipeline

Before the normal-ACK change, `pcie_soft_replay.response_ready_o` required both `TX_IDLE` and zero staged
original packets (`inflight_q == 0`). Once the ACK capture has a pending response,
`TX_IDLE` cannot launch another RAM-to-formatter copy. Already copied packets
must drain before the response retires; subsequent copies then refill the
formatter. This is deliberate ownership protection, but it imposes a throughput
penalty for normal ACKs as well as exceptional responses. Eight replay entries
and two formatter banks do not eliminate that drain/refill behavior.

A focused simulation supplies continuous 19-DWORD packets (three header plus
16 payload DWORDs), runs the unchanged replay/formatter and optional actual PCS
RTL, and injects synthetic cumulative ACKs. There are no DDR, RX or flow-control
credit limits in this experiment. ACK latency is measured from acceptance by
the PCS input, not reception by a simulated SSD. The replay timeout is extended
to 4096 clocks to isolate scheduling from retries. The first 1000 clocks are
excluded; the following 100000 clocks are counted. Reported payload-equivalent
throughput weights accepted framed DWORDs by 64 payload bytes per 21-DWORD frame;
this includes fractional boundary frames, not an NVMe benchmark.

With ACKs for every packet, that earlier RTL yielded 477.60 MB/s into an always-ready
sink at zero synthetic ACK delay, or 484.40 MB/s through the PCS. At 16 clocks
of ACK delay those rates are 363.68 and 358.00 MB/s. More ACK delay is not
monotonically worse because the capture coalesces responses and changes batching.
These results demonstrate an internal scheduling penalty without SSD credit
limits; their proximity to hardware rates does not prove the board's ACK pattern.

The cumulative-ACK sweep through the PCS at a fixed 16-clock delay gives:

| ACK every N packets | Payload-equivalent MB/s | Pending ACK blocking new copies (% clocks) |
| --- | ---: | ---: |
| 1 | 358.00 | 50.76 |
| 2 | 463.34 | 36.29 |
| 4 | 543.12 | 23.54 |
| 8 | 506.88 | 0.40 |

At eight packets, the finite replay window must wait for the grouped ACK;
removing most pending-ACK drain cycles does not remove every throughput limit.
No formatter input stall was counted in these cases. The modeled ACK batching
is a controlled stimulus, not an SSD setting or a measured peer behavior.
[Simulation evidence](../../docs/evidence/prefetch_v1/downstream-simulation.json)
records the source hashes and counters separately from physical evidence.

All production modules examined at that stage matched the hashes of the physically tested
`prefetch_gen3_board_v2` image. At that simulation-only checkpoint, no production RTL or board image was changed.
The subsequent diagnostic deployment is recorded below.

## Investigation plan at the pre-optimization stage

Instrument the link-clock domain before attributing the entire physical limit:

- Application valid blocked by completion credits, separately from replay input.
- Replay occupancy, pending/sent counts, and normal ACK versus NAK/timeout events.
- Pending response blocked by active RAM copying versus staged packets draining.
- Formatter input/output stalls and PCS frame-start/cadence/SKP waits.
- TX CDC output starvation, unpacker acceptance, and DLLP arbitration cycles.

Capture these coherently in their own 250 MHz domain, with an acknowledged
snapshot across the management CDC. Do not sample multibit live counters directly.

The likely optimization is to separate normal ACK retirement from the global
transmit drain: retire only acknowledged, already-submitted entries that no
reader references, while preserving immutable identities of staged packets.
NAK/replay/timeout transitions still need their ownership barriers. Simply
removing `inflight_q == 0` or the pending-response admission gate is unsafe;
head-relative addressing, sent/inflight accounting, sequence wrap and response
validation must be redesigned and verified together. This replay engine is
shared with Gen2, so both paths require regression coverage.

More DDR prefetch slots are not the first priority. Increasing replay depth alone
also does not remove the normal-ACK drain barrier. The investigation does not
exclude an additional physical peer-credit or ACK-latency constraint.

Reproduce ACK batching sensitivity with:

```sh
python3 tests/profile_gen3_tx.py --output build/fresh_downstream_profile \
  --pcs 1 --ack-delay 16 --ack-every 1 2 4 8
```

Use `--pcs 0 1 --ack-delay 0 16 64 128 256 --ack-every 1` for the initial
sink/timing sweep. Testbench checks frame length and payload order, and fails on
replay or PCS fault. This is a scheduling diagnostic, not PCIe compliance proof.

## Diagnostic implementation

LPR1 added counters for 32 link-clock events, including credit-versus-replay admission
stalls, captured ACK waits, copy/formatter stalls, PCS waits, and error/replay
activity. Local command operation 7 starts or freezes the bank and reads frozen
words through the existing command/response CDC. No new live multibit CDC or
packet/replay reset is introduced. See the [register contract](../../docs/registers.md#experimental-gen3-link-profiling-lpr1).
That diagnostic revision kept the normal-ACK retirement barrier unchanged for
physical attribution. LPR2 below implements concurrent normal retirement.

Focused tests check command routing without additional TLPs, frozen counter
consistency, held responses, overflow, invalid accesses and synchronous reset.
The on-target capture tool is `scripts/profile_gen3_link.py`; it requires the
explicit SSD serial guard and exclusive administrative mailbox use. It writes
only the established [8 GiB,12 GiB) scratch region in write mode. Follow the
normal clean-shutdown/kernel-stop deployment procedure; never replace active PL.

## Physical LPR1 result

The diagnostic image subsequently passed full implementation/audit and ran on
the board. After two startup-training failures, the third boot trained Gen3 x1
and enumerated NVMe. Five-second QD1/QD8 writes measured 291.69/451.27 MB/s.
At QD8, peer-credit admission stalls were **zero**, replay admission blocked
**41.13%** of link capture cycles, and the replay window was full for **41.25%**.
Captured responses waited on staged packets for **44.94%**; a pending response
blocked new copies while the copy engine was idle for **33.41%**, including
**1.24%** retirement cycles. These predicates overlap. Formatter input stalls
were zero; formatter output stalls occupied **7.46%**. No NAKs, replay events,
timeouts or faults occurred. Approximately 2.14 TLPs were submitted per processed
ACK over each workload capture; this is an aggregate ratio, not an ACK-latency
measurement or a complete peer batching trace.

This supports ACK retirement/drain as the primary internal target and rules out
peer-credit admission as a measured bottleneck in these workloads. It does not
exclude endpoint ACK timing effects. Do not simply remove ownership gates:
implement safe retirement of acknowledged, unreferenced entries while preserving
staged sequence identities, with separate barriers for NAK/replay transitions.

Existing-pattern CRC checks before/after, namespace flush, exact write accounting,
and SMART checks passed. The diagnostic image remains running and idle; SD boot
files are unchanged. [Full physical evidence](../../docs/evidence/prefetch_v1/link-profile.json)
records build hashes, scope, counters, and startup limitations. No normal-ACK
retirement optimization had been applied at that stage.

## Normal-ACK retirement implementation

Normal ACKs now retire the already-sent prefix while later originals remain
staged or are being copied. The active copy retains its latched slot and
sequence. Retiring R entries advances the head by R and reduces the sent count
by R, preserving both `head + sent` (oldest staged identity) and
`head + sent + inflight` (next unsent slot). A simultaneous wire-completion
advances the first identity and reduces inflight, preserving the second.
Only valid ACKs of the sent prefix can retire storage; a future/unsent ACK still
reports an error without releasing its packet. Invalid responses do not permit
new-copy launch on that edge.

NAKs, replay responses, pending NAK recovery and replay/normal identity changes
retain the drain barrier. Replay RAM remains unreset. An additional timer case
starts a fresh timeout when an ACK retires all older sent packets on the same
cycle a new original reaches wire completion, avoiding reuse of the older ACK's
age. Cumulative ACK arithmetic includes simultaneous packet commit and wire done.

The regression covers 4200 packets through sequence wrap at two ACK periods,
including ACKs during stalled copies, delayed wire completion, cumulative
retirement and bank reuse. A directed test covers simultaneous commit/wire/ACK,
the fresh timeout epoch, duplicate ACKs and an unsent suffix. The original RTL
fails the concurrent-retirement coverage requirement; the new RTL passes.
Existing Gen2 serializer and Gen3 frame/CRC, NAK, timeout and recovery tests pass.
All 49 repository tests and lint pass.

At a synthetic 16-clock ACK delay, Gen3 PCS simulation now sustains 652.88 MB/s
for ACKs every 1/2/4 packets, versus 358.00/463.34/543.12 MB/s previously. ACKs
every eight packets remain at 506.88 MB/s because the eight-entry window still
waits for cumulative retirement. The Gen2 serializer model improves from
290.91/326.53 MB/s (ACK every 1/4) to 372.09 MB/s for both. These are controlled
simulation service rates, not new physical benchmark claims.

The profile bank reports LPR2 so actual response wait/launch blocking can be
separated from LPR1's coincident pending-ACK/state observations. Its addresses,
other event definitions and safe frozen-read transport remain unchanged.


### Physical normal-ACK result

The fresh LPR2 build passed route and the independent reopened audit; sources
match both manifests. On ZCU104 Gen3 x1, five-second QD1/QD8 write throughput
improved from 291.69/451.27 to 333.17/562.13 MB/s (+14.22%/+24.57%). Actual ACK
wait and new-copy blocking counters are zero. Replay admission still blocks
16.33%/27.62% of capture cycles and formatter output blocks 9.52%/16.13%.
Peer credits, NAK/replay/timeout/fault and overflow counts remain zero.
Remaining investigation should distinguish finite replay-window/peer ACK latency
from PCS output service, boundary and DLLP arbitration limits; these counters do
not alone establish the best next change.

Fresh 256 MiB and sector-offset 32 MiB CRC tests, pre/post CRC, flush and exact
4,787,798,016-byte write accounting passed. SMART errors remain zero and unsafe
shutdowns remain 26. Board is healthy/idle on the new image; SD boot unchanged.
First-attempt startup succeeded, but historical startup intermittence remains
unresolved. Gen3 setup slack is only +0.004 ns. See
[physical evidence](../../docs/evidence/prefetch_v1/ack-retirement.json) for
hashes, counters and test limits. No new Gen2 physical performance is claimed.

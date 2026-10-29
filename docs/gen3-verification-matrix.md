# Gen3 NVMe verification matrix

Scope: optional Gen3 x1 backend, direct-attached NVMe SSD, supplied Linux host
integration. Initial matrix and independent training-peer campaign: 2026-10-29,
based on source revision `c835607`. This records functional verification, not
PCI-SIG certification. Existing hardware evidence applies only to its exact
images; no new synthesis, routing or hardware test is included here.

Latest full regression: **1,663 passed** (157.92 seconds), including **994 new
Gen3 peer cases** across four campaigns. Counts below describe their individual
checkpoints. All campaigns are simulation-only; production RTL is unchanged.
The earlier packet harness hash predates its documented watchdog extension;
latest source hashes are in [TX ownership evidence](evidence/gen3_tx_ownership_v1/completion.json).

## Reference basis

| Key | Reference | Use and boundary |
| --- | --- | --- |
| BASE | [PCI-SIG Base Specification catalog](https://pcisig.com/specification-overview/pci-express-base) | Select final 3.0/3.1a requirements and applicable errata for the target. Catalog located; exact normative clauses and production timer limits still need review against an accessible final edition. |
| LL | [Link Layer and Transaction Layer Test Specification 3.0](https://pcisig.com/PCIExpress/Specs/Test/ArchitectureLinkLayerandTransactionLayerTest_3.0) | Test-topic structure for replay, credits and transactions. Official listing located; detailed procedures not newly reviewed. The catalog describes incomplete coverage of all requirements. |
| PIPE | [Intel PIPE specification](https://www.intel.com/content/www/us/en/content-details/643108/phy-interface-for-the-pci-express-sata-usb-3-2-displayport-and-usb4-architectures-specification.html) | PHY/MAC interface behavior. Use a pinned revision and explicitly map the exposed GTH signals; PIPE timing is not automatically the raw-GTH contract. |
| AMD | [PG239 equalization sequences](https://docs.amd.com/r/en-US/pg239-pcie-phy/Equalization-Sequences) and [RX handshake](https://docs.amd.com/r/en-US/pg239-pcie-phy/RX-Equalization-Signals) | Preset application before rate change and adaptation completion/retry behavior. Applies to the corresponding AMD PHY interface, not all controller internals. |
| BFM | [cocotbext-pcie](https://github.com/alexforencich/cocotbext-pcie) | Candidate independent endpoint/TLP model for config, memory transactions and MSI. Requires an adapter. Vendor hard-IP models support device operation, not root-port operation; this is not a serial training/equalization model. |
| ALT | [PCIe_Scrambler](https://github.com/baselkelziye/PCIe_Scrambler) | Candidate implementation cross-check, not an authoritative oracle. Gen3 behavior, license and independence must be reviewed before reuse. Not imported by this campaign. |

The locally supplied preliminary Base 4.0 v0.3 document remains the historical
reference described in [Gen3 investigation notes](../experiments/gen3/README.md#local-preliminary-base-specification-and-scrambler).
It is not substituted for a final specification, and no vendor/specification
PDF is committed. IDs below are project tracking IDs, not normative clauses.
The reference column identifies where to establish requirements, not a claim
that each clause has already been audited.

## Status and project waivers

**Directed** means an executable checker exists for the listed behavior.
**Partial** means material coverage remains missing. **Gap** means no adequate
complete test was identified. These statuses describe coverage, not a new pass
for every historical checker. Only the campaign results below are freshly run.

**waived - outside of project scope** applies to general-purpose bridge/topology
support, Type 1 routing, multiple endpoints/functions, non-NVMe interoperability,
ASPM/suspend/wake services, AER service, INTx, hotplug/live-reset service,
diagnostic loopback/compliance patterns, and formal electrical certification.
These inherit the [Gen1/Gen2 scope decisions](gen1-gen2-compliance-matrix.md).
They do not waive safe rejection, accepted-AXI drain, packet/replay ownership,
startup reset, functional electrical robustness or error recovery relevant to
NVMe operation. Additional directly attached NVMe SSDs remain in scope.

## Requirements-to-test inventory

Evidence entries name scripts under `experiments/gen3` unless a full path is
shown. References are defined above. Do not infer coverage from a source filename
alone; open work remains until independently checked and recorded.

| ID | Requirement topic | Reference | Coverage / existing checker | Open work |
| --- | --- | --- | --- | --- |
| G3-ENC-01 | Scrambler sequence, seed and advance rules | BASE | Directed: `check_scrambler.py`, `check_training.py` | Final-edition clause mapping; independent vectors across all applicable ordered sets and reseed boundaries. |
| G3-ENC-02 | Sync headers, block alignment and reacquisition | BASE, PIPE | Partial: `check_rx_blocks.py`, `check_native_rx.py`; packet peer reacquisition | Invalid-header runs, block-slip thresholds and malformed starts across every alignment. |
| G3-ENC-03 | STP protection and length fields | BASE | Directed: `check_stp.py`, `check_stream_rx.py` | Exhaustive protected-bit/error combinations and independent expected recovery actions. |
| G3-ENC-04 | TLP/DLLP token framing and block crossings | BASE | Partial: `check_stream_rx.py`, `check_native_link.py`; packet peer at all 16 byte offsets and four payload sizes | Extend beyond existing 208 parser cases to randomized multi-packet streams, all tokens and corruption boundaries. |
| G3-ENC-05 | EIEOS/EIOS and data-stream transitions | BASE, PIPE | Partial: `check_training.py`, `check_recovery_tx.py`; new peer | Packet peer preserves committed RX storage across EDS/EIEOS/SDS; complete entry/exit state coverage and malformed sets remain open. |
| G3-ENC-06 | SKP scheduling, seed fields and drift handling | BASE, PIPE | Partial: `check_training.py`, `check_sequencing.py` | Variable SKP sequences, clock-offset stress and sustained occupancy; do not assume nominal cadence proves drift tolerance. |
| G3-LT-01 | Legacy startup to directed Gen3 speed change | BASE | Partial: `tests/test_gen3_startup.py` | Independent peer for the complete legacy negotiation; eliminate reliance on DUT-state-following stimulus. |
| G3-LT-02 | Preset acknowledgement and stable advertised coefficients | AMD, BASE | Directed: `check_equalization.py`; new peer | Wire-level checks of local advertisement and delayed/failed PHY handshakes at exact limits. |
| G3-LT-03 | Phase 1 matching TS qualification | BASE | Directed: `check_equalization.py`; new peer | Final clause audit and broader field combinations. New peer connects decoder to controller without using production TX. |
| G3-LT-04 | Phase 1 failure, cancellation and re-entry | BASE, AMD | Partial: `check_equalization.py`; new peer | Exact timeout/settle-edge integration and repeated independent attempts through the outer LTSSM. |
| G3-LT-05 | Phase 2/3 adaptation or explicit skip policy | BASE, AMD | Partial: Phase 1 handoff/skip tests | Full adaptive coefficient exchange and policy legality require review. A skip flag or handoff pulse does not verify adaptation. |
| G3-LT-06 | Recovery with active traffic and retained ownership | BASE, LL | Partial: `check_recovery_bringup.py`, `check_native_link.py`; packet peer PCS reacquisition and replay pause | Independent peer drives complete Recovery with pending credits, replay and AXI owners. |
| G3-LT-07 | Failed Gen3 negotiation and lower-speed handling | BASE | Gap: native backend does not claim runtime Gen2 fallback | Define supported failure/quarantine behavior; test no silent resume at an unsupported rate. Runtime fallback needs implementation before qualification. |
| G3-PHY-01 | Rate, clocks, electrical idle and PHY status sequencing | PIPE, AMD | Partial: `check_sequencing.py`, `check_phy_startup.py`, startup fault benches | Stale/late/missing status pulses, exact boundaries and actual PHY model integration. No stopped-reference recovery claim. |
| G3-PHY-02 | Transmit cadence, atomic drain and underflow handling | PIPE, BASE | Directed: `check_sequencing.py`, `check_integration.py`, `check_recovery_tx.py` | Sustained randomized congestion and independent wire-time checks across control/data transitions. |
| G3-DL-01 | CRC, duplicate/sequence rejection and ACK/NAK | BASE, LL | Partial: `check_dllp_oracle.py`, `check_native_link.py`; packet peer CRC bit sweeps, duplicate/future sequences and RX rollover | Extend sequence coverage to half-range boundaries, malformed lengths and broader packet/error combinations. Both RX and TX rollover now have independent checks. |
| G3-DL-02 | Replay deadline, retries and ACK retirement | BASE, LL | Partial: `check_tx_window.py`, `check_native_link.py`; packet peer ACK, NAK, timeout, pause, eight-slot reuse/selective replay and natural TX rollover | Native-wire timing at expiry/service edges, response age and packet-boundary contention. |
| G3-DL-03 | Credit initialization and UpdateFC deadlines | BASE, LL | Partial: `check_link_layer.py`, `check_native_link.py`; packet peer InitFC, credit exhaustion and corrupt UpdateFC | Single-credit TX test now covers header/data counter rollover and retries without fresh credits. Multi-class endpoint scoreboard, dropped DLLPs and wire deadlines under ACK/data contention remain open. |
| G3-TL-01 | Config, memory requests and completion validation | BASE, BFM | Partial: native-link and shared requester tests | Independent endpoint model adapter; malformed completion sweeps through native framing, not only the requester interface. |
| G3-TL-02 | Wide-path DMA completion splitting and prefetch | BASE, BFM | Directed: `tests/test_host.py` wide-path cases | Randomized end-to-end endpoint/DDR scoreboard with mixed sizes, alignments, AXI errors and resource exhaustion. |
| G3-TL-03 | MSI/read/flush ordering and noncoherent visibility | BASE, BFM | Partial: shared host benches and historical NVMe CRC | Full native-path mixed traffic, stalled B responses, interrupt policy and Linux cache visibility tests. |
| G3-CFG-01 | Host enforcement of supported endpoint features | BASE, BFM | Gap: driver policy inspection is not executable evidence | Test actual configuration writes, capability policy and safe unsupported-access outcomes. |
| G3-HW-01 | Cold/warm startup and sustained NVMe integrity | BASE | Partial: historical startup/CRC/performance evidence | Repeatable cold-cycle and longer mixed-I/O campaign on exact newly built sources. |
| G3-HW-02 | Physical margin and NVMe interoperability | BASE | Partial: one documented board/adapter/SSD setup | More NVMe models and intended operating conditions; digital simulation cannot qualify analog equalization. |

## Independent training-peer campaign

[Python peer](../tests/test_gen3_peer.py) generates scrambled Gen3 ordered-set
blocks on its own schedule. It does not inspect DUT state or instantiate the
production transmitter. A [small harness](../experiments/gen3/test_gen3_peer.sv)
connects the production training decoder to the Phase 1 controller and checks
externally visible results and transition pulses.

The first campaign has **120 parameterized cases**: 10 scenarios, two policies
(Phase 2 handoff / skip Phase 2 and 3), two valid-beat gap patterns and three
acknowledged preset labels (0, 4 and 10). Scenarios are:

- Matching TS1 pair; a single TS cannot complete the phase.
- TS2 interruption, changed fields, bad parity, wrong lane and wrong EC; each
  requires a fresh qualifying pair before success.
- Missing preset acknowledgement reaches failure rather than false success.
- Loss of PHY readiness fails the attempt; a new attempt cannot reuse the old
  acknowledgement and must qualify a new pair.
- Cancellation followed by a fresh attempt.
- EIOS loses alignment; EIEOS and a fresh TS pair restore qualification.

Decoder event/valid counts are checked independently of the controller result.
Both handoff and skip outcomes are checked, including one-shot transition counts
and stability after an additional timeout-length interval. Preset tests check
controller advertisement, not analog preset quality. The Python encoder is an
independent implementation of the historical project encoding contract; it is
not a certified protocol model. Beat gaps exercise interface pauses, not a claim
that arbitrary gaps are legal at the physical wire interface.

The model starts at the Gen3 ordered-set interface. It is **not yet a complete
endpoint BFM**: it does not perform legacy negotiation, adaptive Phase 2/3,
serial electrical behavior, TLP traffic or the full Recovery LTSSM. Those rows
remain open. No design RTL was changed by this campaign.

Three additional mutation tests alter temporary copies of the DUT to remove
single-TS rejection, lane validation or parity validation. Each must fail the
peer checker. This ensures that another downstream rejection condition cannot
silently conceal the removed check. Together with the 120 scenario combinations,
this gives 123 new pytest cases.

```sh
.venv/bin/python -m pytest -q tests/test_gen3_peer.py
```

Final regression: **792 passed**, including all 120 peer scenarios and three
mutation-detection cases. [Results and source hashes](evidence/gen3_peer_v1/completion.json).
No new hardware or analog validation is implied.

## Independent native packet-peer campaign

The [packet peer](../tests/test_gen3_packet_peer.py) independently constructs
scrambled native Gen3 ingress blocks. Its
[harness](../experiments/gen3/test_gen3_packet_peer.sv) connects the native RX,
buffered packet parser/gate and link layer. The output scoreboard checks framed
TLPs and DLLPs, including STP protection, length, sequence and CRC. Output is
observed **before the physical TX scheduler/scrambler**, not on a serial wire.
Stimulus does not read DUT internals or use the production transmitter.

The campaign adds **652 cases**:

| Cases | Checks |
| ---: | --- |
| 12 | ACK retirement, corrupt ACK rejection, NAK replay, timeout replay, credit exhaustion/UpdateFC and replay pause/resume; each with two valid-beat gap patterns. ACK retirement does not replenish credits. |
| 512 | Each of 32 LCRC bits corrupted at each of 16 byte offsets. A prior valid packet remains stored under backpressure; the corrupt packet is rejected, then a valid retry succeeds with the expected ACK/NAK sequence. |
| 96 | Each of 48 DLLP body/CRC bits corrupted for ACK and UpdateFC. Invalid packets cannot retire replay storage or restore credits; a valid follow-up succeeds. |
| 32 | At all 16 offsets, committed RX storage survives either ordered EDS exit or an invalid sync header, followed by EIEOS/SDS reacquisition and another valid packet. |

The payload is one 3DW memory-write header plus one DWORD of data. These are
bounded functional checks, not exhaustive packet coverage or production timer
qualification. PCS reacquisition and link-enable pause do not exercise complete
LTSSM Recovery, pending AXI owners or adaptive equalization. Valid-beat gaps are
interface pauses, not physical wire timing. The independent encoder implements
the project encoding contract; final normative clause review remains open.

```sh
.venv/bin/python -m pytest -q tests/test_gen3_packet_peer.py
VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin .venv/bin/python -m pytest -q tests
```

Full regression: **1,444 passed in 124.04 seconds**, including all 652 new packet
cases and the earlier training-peer campaign.
[Results and source hashes](evidence/gen3_packet_peer_v1/completion.json).
No design RTL bug was found or RTL changed in this campaign. No synthesis,
routing, deployment or hardware verification was performed.

## Native sequence and replay-ownership extension

The [sequence suite](../tests/test_gen3_packet_sequences.py) adds **202 cases**
using the same independent packet peer and framed-egress scoreboard:

- **192 cases:** duplicate, future and corrupted-duplicate packets at all 16
  offsets, with 1, 2, 7 and 32 DWORD payloads. The first valid packet remains
  backpressured while the rejected packet arrives; distinct subsequent data
  checks that rejection neither replaces storage nor advances the RX sequence.
- **9 cases:** three distinct outstanding TX packets, cumulative ACK retirement
  at each of the three positions and three DLLP offsets. A repeated ACK preserves
  the remaining owners; NAK replays only the unacknowledged suffix, with exact
  sequence/payload comparison. ACK retirement does not restore spent credits.
- **1 case:** 4,098 accepted RX packets traverse the natural 12-bit sequence
  rollover. Duplicates immediately before and after rollover are acknowledged
  without delivery. Every payload and ACK is checked; no internal state is seeded.

The harness watchdog is extended from 200 microseconds to 10 milliseconds to
allow natural rollover. The earlier packet campaign's source hashes describe
its original, shorter watchdog; the new evidence records the updated harness.
Production RTL is unchanged. These checks retain the earlier boundary: native
scrambled ingress and framed egress before the physical TX scheduler/scrambler.
They do not establish full LTSSM Recovery, exact wire-time behavior, TX sequence
rollover, maximum outstanding capacity or mixed endpoint/DDR transactions.

```sh
.venv/bin/python -m pytest -q tests/test_gen3_packet_sequences.py
```

Focused regression: **202 passed in 17.24 seconds**. Full regression: **1,646
passed in 141.42 seconds**. Exact sources are recorded in
[sequence evidence](evidence/gen3_sequence_peer_v1/completion.json).
No design RTL bug was found in this extension.

## Native TX rollover and full replay-window extension

The [TX ownership suite](../tests/test_gen3_tx_ownership.py) adds **17 cases**:

- **16 cases:** fill all eight replay slots while spare posted credits remain.
  Admission is backpressured at capacity. Retire each possible cumulative prefix
  (one through eight packets), reuse exactly those slots, and check capacity
  again. A NAK then replays exactly the eight remaining owners, including the
  replacements, with every sequence and payload checked. Two incoming DLLP byte
  offsets are exercised. Final cumulative ACK leaves no pending packet.
- **1 case:** transmit 4,098 distinct original packets with one posted header/data
  credit at a time. This naturally wraps the 12-bit TX sequence, 8-bit header
  credit counter and 12-bit data credit counter. NAKs immediately before and
  after sequence rollover replay the same packet without fresh credits. Each
  ACK frees ownership but does not restore credit; a valid cumulative UpdateFC
  restores admission. Every emitted original and retry is compared to the peer
  scoreboard. No internal DUT state is seeded or inspected.

The tests use one-DWORD MWr payloads and the existing native-ingress/framed-egress
boundary. This checks the eight-slot replay store, not DDR read-prefetch depth,
wire-time deadlines or full LTSSM Recovery. Mixed packet sizes under maximum
occupancy, invalid/future ACK containment and endpoint/DDR integration remain
separate coverage work. Production RTL and the harness are unchanged.

```sh
.venv/bin/python -m pytest -q tests/test_gen3_tx_ownership.py
```

Focused regression: **17 passed in 16.79 seconds**. Full regression: **1,663
passed in 157.92 seconds**. Exact source hashes are recorded in
[TX ownership evidence](evidence/gen3_tx_ownership_v1/completion.json).
No design RTL bug was found in this extension; no hardware test was performed.

## Next implementation order

1. Extend the independent peer to the outer LTSSM, with scheduling based on
   observed transmitted ordered sets rather than internal state numbers.
2. Extend native packet error injection to mixed packet sizes, sequence windows
   and ACK/replay/UpdateFC boundary contention with wire-time assertions.
3. Adapt an independent endpoint transaction model to the native TLP boundary;
   test the wide DDR path, configuration policy and MSI ordering end to end.
4. Establish final-spec clause references and exact production timer assertions.
   Keep unsupported adaptive/fallback behavior visibly open.
5. Run a separately authorized, source-matched hardware campaign after the
   simulation work; preserve existing physical evidence and project waivers.

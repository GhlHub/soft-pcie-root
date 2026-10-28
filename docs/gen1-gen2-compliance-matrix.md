# Gen1/Gen2 compliance coverage matrix

Initial inventory: 2026-10-28, source revision `b6b0e7e`. This is a map of
existing verification and remaining work, **not a declaration of PCIe compliance**.
No new simulation or physical qualification was performed to create this matrix.

## Scope and interpretation

The target is the `ENABLE_GEN3=false` x1 backend: Gen1 and Gen2, VC0,
MPS128, RCB64, a directly attached endpoint, 32-bit host packet interfaces and
two DDR read-prefetch slots. See the [IP contract](ip-guide.md),
[register contract](registers.md) and [verification history](verification.md).
Gen3-specific parser, framing, equalization and wide-host-path tests do not
establish Gen1/Gen2 coverage. Gen1 startup in a Gen3 image is not a sustained
Gen1 data-path qualification.

**Normative baseline remains open.** Before calling any row compliant, select
the applicable PCI Express Base Specification revision, errata, form-factor
requirements and compliance test revision. Exact clause references for every
row are pending that selection. The locally supplied preliminary specification
is not used as a final normative authority. Requirement IDs below are project
tracking IDs, not specification clause numbers. This initial inventory is not
an exhaustive list of normative requirements.

Status meanings:

- **Directed:** concrete assertions exist for the behavior described. Does not
  mean exhaustive coverage or a newly recorded pass.
- **Partial:** related tests exist, but a material part of the stated topic is
  unverified.
- **Gap:** no adequate dedicated evidence identified in this review.
- **Excluded:** outside the documented product scope. This does not establish
  that omission is permitted by the specification; applicability needs review.
- **Sample:** historical physical evidence for one setup and exact image only.
- **—:** not applicable to that speed-specific test topic.

The Gen1/Gen2 columns describe applicability of the available coverage, not two
independent hardware passes. Common unit tests are shared evidence. Only the
integrated link bench explicitly runs both speed selections. Each row's open
work is required before closing that topic against its eventual normative clauses.

## Physical layer and link training

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| PHY-01 | Serial encoding, disparity and invalid-code handling | Gap | Gap | Integrated tests operate at decoded GTH symbols [L] | Exercise actual transceiver codec and error indications; symbol benches do not verify serial 8b/10b behavior. |
| PHY-02 | Electrical TX/RX compliance | Gap | Gap | Functional SSD link only [HW] | Compliance-pattern, eye, jitter, receiver tolerance and applicable electrical tests using appropriate equipment. |
| PHY-03 | Reference clock, SSC and clock compensation | Partial | Partial | Scrambler SKP handling [S]; working example [HW] | Independent clock-offset/SSC tests and SKP insertion/removal limits; scrambler SKP tests alone are insufficient. |
| PHY-04 | Receiver detection, polarity and alignment | Partial | Partial | Logical Detect/training [T] | Actual receiver-detect outcomes, polarity reversal, alignment faults and physical timeout boundaries. |
| PHY-05 | Scrambler sequence and control-symbol treatment | Directed | Directed | Independent polynomial model, COM reset, SKP hold, stalls and roundtrip [S] | Map reset/advance rules and all applicable ordered sets to normative clauses. |
| LT-01 | TS qualification and x1 link/lane negotiation | Directed | Directed | Invalid symbols/IDs, TS1 count, TS2/Idle and L0 [T, L] | Complete legal/illegal ordered-set combinations and all qualification boundaries. |
| LT-02 | LTSSM timer and counter boundaries | Partial | Partial | Selected counts/timeouts in [T, G, L] | At-limit and one-cycle-before/after tests at both real clock rates; document accelerated bench parameters separately. |
| LT-03 | Force Gen1 and peer speed capability | Directed | Directed | Force-Gen1 and Gen1-only peer cases [G] | Broader capability combinations and repeated negotiation campaigns. |
| LT-04 | Gen2 directed speed change and idle handshake | — | Directed | TS2 count, peer idle, EIOS/EIEOS, rate control [G, L, R] | Normative symbol/timer boundary checks and actual GTH sequencing fault injection. |
| LT-05 | Gen2 de-emphasis selection | — | Partial | Peer preference exercised [G] | Verify emitted analog settings and all required negotiation combinations. |
| LT-06 | Failed speed change and downgrade | — | Directed | Gen2 timeout fallback and peer-directed downgrade [G] | Repeated failures, boundary arrival of TS and ownership stress with active traffic. |
| LT-07 | Recovery with outstanding traffic | Partial | Partial | Ownership preservation, retraining, replay resumption [L, G] | Full Recovery state/transition coverage with errors, credits and traffic at each boundary. |
| LT-08 | Fundamental reset / PERST sequencing | Partial | Partial | Reset sequencer [Z] and example boot [HW] | Clause-mapped timings, cold cycles and endpoint reset interactions. No safe arbitrary live reset is claimed. |
| LT-09 | Hot Reset, Disabled and Compliance states | Gap | Gap | No complete dedicated conformance suite identified | Determine required behavior, audit implementation, then add state-entry/exit and ordered-set tests. |
| LT-10 | Loopback | Excluded | Excluded | Unsupported request fails closed in [T] | Determine whether exclusion is permissible for the intended compliance target; rejection is not loopback verification. |
| LT-11 | ASPM and power-management transitions | Excluded | Excluded | Product limitations [IP] | Audit required baseline behavior and advertised capabilities; test mandatory behavior even if optional modes are omitted. |

## Data link layer

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| DL-01 | TLP LCRC and DLLP CRC | Directed | Directed | Independent CRC models and wire checks [C, L] | Clause-map bit/byte order and extend corrupted-field coverage; optional external oracle is not protocol VIP. |
| DL-02 | Whole-packet acceptance, duplicates and bad LCRC | Directed | Directed | Corrupt completion drop/NAK, duplicate suppression [L]; receive capacity [Q] | Systematic truncation, framing, sequence and corruption combinations with no application side effects. |
| DL-03 | ACK/NAK capture and cumulative retirement | Directed | Directed | Capture, normal ACK retirement and simultaneous edges [A, P] | Independently check all legal/illegal sequence values and timing boundaries. |
| DL-04 | Replay order, sequence wrap and storage ownership | Directed | Directed | Sent/unsent distinction, cumulative ACK, NAK, 12-bit wrap, stalls and concurrent commit [P] | Longer randomized scoreboard campaigns and combined fault injection. |
| DL-05 | Replay timeout and retry exhaustion | Partial | Partial | Timer replay, packet-boundary wait, exhaustion quarantine/retrain [P, L] | Verify specification-derived timer values and retry behavior at both speeds, packet sizes and boundary events. |
| DL-06 | ACK scheduling and latency limits | Partial | Partial | Integrated ACK behavior and capture [L, A] | Independent latency-limit assertions under maximum RX/TX load and coincident DLLP demand. |
| DL-07 | Flow-control initialization | Directed | Directed | InitFC1/2, P/NP/Cpl classes, no premature active [F] | Malformed, reordered, missing and boundary-timed initialization DLLPs; normative timeout checks. |
| DL-08 | Credit accounting, wrap and infinite credits | Directed | Directed | Header/data accounting, 8/12-bit wrap, infinite Cpl credit, replay not double-charged [F, L] | Cross-check all advertised limits and long mixed-class traffic against an independent scoreboard. |
| DL-09 | UpdateFC scheduling and snapshots | Partial | Partial | Prompt/periodic return, stalled snapshots, consecutive returns [F] | Check normative UpdateFC deadlines and thresholds, not just bench-local cycle limits. |
| DL-10 | Receive capacity and application backpressure | Directed | Directed | Validated packet buffering, stalls, credit returns [Q, F, L] | Prove advertised capacity against worst-case packet mix and concurrent return/admission. |
| DL-11 | Corrupt/unknown DLLPs and link-state interactions | Partial | Partial | CRC infrastructure and selected Recovery/link-loss tests [C, F, L] | Dedicated DLLP type/reserved-field/CRC corruption matrix across initialization, L0 and Recovery. |

## Transaction layer and configuration

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| TL-01 | Memory and Configuration Type 0 request format | Directed | Directed | CfgRd/Wr, MRd64, 3DW below 4 GiB, header stalls [N, L] | Exhaustive legal field/byte-enable combinations and independent packet decoding. |
| TL-02 | Completion matching and unexpected completions | Directed | Directed | Wrong tag, completer identity, malformed completion and timeout quarantine [N] | Complete tag/requester/completer/status/length/byte-count/lower-address cross-product. |
| TL-03 | Completion status and CRS | Partial | Partial | CRS requester behavior [N]; driver vendor-ID retry handling [D] | Directed end-to-end tests for success, UR, CA, CRS and illegal status combinations. |
| TL-04 | Completion timeout and late completions | Partial | Partial | Timeout retains quarantine; tags not prematurely reused [N] | Map implemented timeout policy to normative ranges and supported configuration; inject late packets at each boundary. |
| TL-05 | MPS128 and split read completions / RCB64 | Directed | Directed | 512-byte read splitting, encoded 4096-byte request, payload tests [B, L] | Sweep lengths/alignments and completion metadata against an independent model. |
| TL-06 | Byte enables and unaligned data | Directed | Directed | First/last byte enables, lengths, bank stalls and alignments [B, H] | Validate every legal/illegal byte-enable rule, including short requests. |
| TL-07 | 4 KiB boundary and address-range validation | Directed | Directed | Crossing, high/out-of-range, truncated and oversized requests rejected before AXI [B] | Clause-map malformed versus unsupported handling and all edge addresses. |
| TL-08 | Zero-byte memory read / ordering flush | Directed | Directed | No stale payload or AXI read, completion and prior-write fence [B] | Independent completion-field checks under errors and concurrent traffic. |
| TL-09 | Ordering across writes, reads and MSI | Partial | Partial | Accepted/held writes and all B responses precede MSI/read/flush; B error suppresses MSI [B, H] | Full applicable PCIe ordering table, traffic-class/attribute audit and independent mixed-traffic scoreboard. |
| TL-10 | Poison, ECRC, prefixes, reserved encodings and messages | Gap | Gap | Selected unsupported/address-type rejection [B] is insufficient | Inventory each encoding and required discard/completion/error-reporting action; add explicit cases. |
| CFG-01 | Endpoint configuration access and capability policy | Partial | Partial | Type 0 request tests [N]; driver 1/2/4-byte accesses, MPS128 policy, RO/No-Snoop disabled [D] | Executable driver tests for access boundaries, capability traversal, policy enforcement and errors. |
| CFG-02 | Standard Root Port configuration/capability contract | Gap | Gap | Driver exposes direct endpoint bus 1; explicitly no fabricated bridge configuration [D] | Determine normative Root Port obligations and assess missing configuration/error/power-management facilities. Working Linux enumeration does not close this gap. |
| CFG-03 | Type 1 routing, switches and multiple functions | Excluded | Excluded | Direct endpoint only [IP, D] | Audit required unsupported-request behavior. Requester Type 1 encoding tests do not demonstrate routing support. |
| CFG-04 | AER, legacy INTx, hotplug and PME | Excluded | Excluded | Documented feature limits [IP]; PME compliance evidence not established | Separately determine optional versus mandatory behavior and reporting; do not infer compliant omission. |
| INT-01 | MSI/MSI-X memory-write delivery | Partial | Partial | MSI address/vector interception, ordering and error suppression [B]; Linux SSD operation [HW] | Mask/pending/vector boundary tests and protocol error cases. Endpoint MSI-X table behavior belongs to the endpoint. |

## System safety and physical evidence

These rows supplement protocol coverage; AXI/CDC correctness is not a substitute
for PCIe compliance.

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| SYS-01 | Accepted AXI ownership survives link loss | Directed | Directed | Held AW/AR, accepted W/R/B drain, early/late RLAST and error quarantine [B, H] | Combined reset/recovery/error stress. Never reset away accepted ownership. |
| SYS-02 | Packet ownership across clock domains | Directed | Directed | Packet CDC, command XPM and host-link benches [H] | Clock-ratio/phase sweeps and reset sequencing; simulation cannot prove metastability behavior. |
| SYS-03 | Noncoherent DMA and Linux visibility | Partial | Partial | Driver contract [D] and Gen2 I/O/CRC [HW] | Dedicated cache-maintenance and ordering stress; latest Gen1 physical qualification remains open. |
| HW-01 | Sustained speed-specific NVMe I/O and integrity | Gap | Sample | Exact Gen2 images and CRC/performance results [HW] | Fresh force-Gen1 and Gen2 tests from the same source manifest; historical evidence is not a current-source pass. |
| HW-02 | Cold/warm start, Recovery and interoperability | Gap | Partial | Selected Gen2 boots and one SSD/adapter setup [HW] | Repeated cold/warm cycles, Recovery under traffic, additional endpoints and environmental coverage. |
| HW-03 | Formal compliance testing | Gap | Gap | No formal compliance results identified | Applicable PCI-SIG protocol/electrical test program and traceable reports. |

## Evidence index and executable tests

Test links identify source assertions, not standalone pass certificates. The
reported 85-test repository regression includes Gen3 and software tests and is
**not an 85-test Gen1/Gen2 compliance suite**.

| Key | Source / executable selector |
| --- | --- |
| C | [CRC/model tests](../tests/test_pcie_soft.py): `test_crc_stream`; [optional pinned external oracle](../scripts/check_pcie_soft_oracle.py) and [source lock](../tests/pcie_soft/reference.lock.json) |
| S | [Scrambler/model tests](../tests/test_pcie_soft.py): `test_scrambler_stalls_and_symbols`, `test_scrambler_roundtrip` |
| T | [Training bench](../tests/pcie_soft/tb_link_training.sv): `tests/test_pcie_soft.py::test_link_training` |
| G | [Gen2 training bench](../tests/pcie_soft/tb_gen2_training.sv): `tests/test_pcie_soft.py::test_gen2_training` |
| R | [Rate-control bench](../tests/pcie_soft/tb_rate_control.sv): `tests/test_pcie_soft.py::test_rate_control` |
| Z | [Root reset bench](../tests/pcie_soft/tb_root_reset.sv): `tests/test_pcie_soft.py::test_root_reset_sequence` |
| L | [Integrated symbol-level link bench](../tests/pcie_soft/tb_root_link.sv): `tests/test_pcie_soft.py::test_integrated_root_link` (Gen1 and Gen2 parameters) |
| Q | [RX capacity bench](../tests/pcie_soft/tb_receive_capacity.sv): `tests/test_pcie_soft.py::test_receive_capacity` |
| A | [ACK capture](../tests/pcie_soft/tb_ack_capture.sv): `tests/test_pcie_soft.py::test_ack_capture`; [ACK retirement tests](../tests/test_ack_retire.py): both tests |
| P | [Replay bench](../tests/pcie_soft/tb_replay.sv): `tests/test_pcie_soft.py::test_replay_ownership`; serializer overlap/banks: `test_tx_overlap`, `test_packet_tx_banks` in that file |
| F | [Flow-control bench](../tests/pcie_soft/tb_flow_control.sv): `tests/test_pcie_soft.py::test_vc0_flow_control` |
| N | [Requester bench](../tests/pcie_soft/tb_requester.sv): `tests/test_pcie_soft.py::test_root_requester` |
| B | [DDR bridge bench](../tests/host/tb_ddr_bridge.sv): `tests/test_host.py::test_ddr_bridge` |
| H | [Host tests](../tests/test_host.py): `test_ddr_pipeline`, `test_ddr_banked_stalls`, `test_completion_tx_profile`, `test_host_link`, `test_host_axi`, `test_cdc_packet`, `test_cmd_cdc` |
| D | [Linux driver](../software/driver/zcu104-soft-pcie.c) and [driver contract](../software/driver/README.md); code inspection is not executable compliance evidence |
| IP | [Supported scope and exclusions](ip-guide.md) |
| HW | [Repackaged Gen2 completion](evidence/repackaged_v1/completion.json), [default boot](evidence/repackaged_v1/default-boot.json), [later Gen2 ACK-retirement measurement](evidence/prefetch_v1/ack-retirement-gen2.json); each applies only to its recorded image/source |

With the [documented toolchain](../README.md#build-and-test) available, run the
focused common protocol tests with:

```sh
.venv/bin/python -m pytest -q tests/test_pcie_soft.py tests/test_ack_retire.py
.venv/bin/python -m pytest -q \
  tests/test_host.py::test_ddr_bridge \
  tests/test_host.py::test_ddr_pipeline \
  tests/test_host.py::test_ddr_banked_stalls \
  tests/test_host.py::test_completion_tx_profile \
  tests/test_host.py::test_host_link \
  tests/test_host.py::test_host_axi \
  tests/test_host.py::test_cdc_packet \
  tests/test_host.py::test_cmd_cdc
```

`make test` runs the full repository regression, including tests outside this
matrix. Preserve source revision, configuration, tool versions and results for
any future coverage claim. Physical tests require a separately authorized run
and exact source/bitstream manifests.

## Suggested closure order

1. **P0 — Define the target and applicability.** Pin normative revisions and add
   exact clauses to each row. Audit the Root Port configuration contract,
   unsupported features and required error reporting (CFG-02 through CFG-04).
   Split topics into individual requirements as needed; do not report a coverage
   percentage while the normative requirement inventory is incomplete.
2. **P0 — Verify protocol timing and error handling.** Add independent timer
   boundary assertions for LTSSM, ACK, replay and UpdateFC at both speeds.
   Build table-driven malformed TLP/DLLP and completion-matching tests, checking
   rejection, response, sequence/credit ownership and absence of DDR side effects.
3. **P1 — Exercise state transitions with traffic.** Combine Recovery, speed
   changes, retries, credit exhaustion and AXI stalls; establish required Hot
   Reset/Disabled/Compliance behavior. Preserve accepted ownership invariants.
4. **P1 — Close configuration and ordering coverage.** Test driver policy,
   completion metadata, MSI boundaries and applicable ordering rules with an
   independent scoreboard. Keep optional-feature exclusions explicit.
5. **P2 — Obtain physical evidence.** Build matching Gen1/Gen2 configurations;
   qualify startup, traffic and Recovery on more endpoints, then obtain the
   applicable electrical and formal compliance measurements. Start equipment
   and test-program planning early; P2 is not a claim of lower compliance importance.

A row closes only with a clause-defined expected result, reproducible test,
recorded pass on identified sources/configuration, and disposition of its open
limitations. Functional SSD throughput or an equivalence test alone cannot
close a compliance requirement.

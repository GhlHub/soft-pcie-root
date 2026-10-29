# Gen1/Gen2 compliance coverage matrix

Initial inventory: 2026-10-28, source revision `b6b0e7e`. This is a map of
existing verification and remaining work, **not a declaration of PCIe compliance**.
The initial inventory did not run new tests. The subsequent NVMe-scope
regression campaign below adds simulation evidence; no new physical qualification
is claimed.
The subsequent project-scope review limits closure work to reliable communication
with a directly attached NVMe SSD using the supplied Linux integration.

## Scope and interpretation

The target is the `ENABLE_GEN3=false` x1 backend: Gen1 and Gen2, VC0,
MPS128, RCB64, a directly attached endpoint, 32-bit host packet interfaces and
two DDR read-prefetch slots. See the [IP contract](ip-guide.md),
[register contract](registers.md) and [verification history](verification.md).
Gen3-specific parser, framing, equalization and wide-host-path tests do not
establish Gen1/Gen2 coverage. Gen1 startup in a Gen3 image is not a sustained
Gen1 data-path qualification.

The project target is a single NVMe endpoint using memory transactions and
MSI/MSI-X, not a general-purpose PCIe hierarchy or PCI-SIG certification.
Feature waivers below apply to both speeds and to positive feature-support tests.
They do not waive safe handling of unexpected traffic, invalid input or link loss.
Existing regression cases remain enabled, including cases for waived features.
NVMe controller commands and queue management are handled by Linux's NVMe driver;
this matrix covers the soft PCIe transport and host integration.

**Normative baseline remains open for in-scope protocol behavior.** Before
calling any row compliant, select the applicable PCI Express Base Specification
revision and relevant errata/form-factor requirements. Formal compliance test
selection is waived below. Exact clause references for active rows are pending
that selection. The locally supplied preliminary specification
is not used as a final normative authority. Requirement IDs below are project
tracking IDs, not specification clause numbers. This initial inventory is not
an exhaustive list of normative requirements.

Status meanings:

- **Directed:** concrete assertions exist for the behavior described. Does not
  mean exhaustive coverage or a newly recorded pass.
- **Partial:** related tests exist, but a material part of the stated topic is
  unverified.
- **Gap:** no adequate dedicated evidence identified in this review.
- **waived - outside of project scope:** no feature implementation or positive
  qualification test is planned for the NVMe project. This is a project waiver,
  not a specification exemption, successful test or compliance claim.
- **Sample:** historical physical evidence for one setup and exact image only.
- **—:** not applicable to that speed-specific test topic.

The Gen1/Gen2 columns describe applicability of the available coverage, not two
independent hardware passes. Common unit tests are shared evidence. Only the
integrated link bench explicitly runs both speed selections. Open work in active
rows remains required; waived rows are removed from the project closure backlog
and must be reopened if the project scope changes.

## Physical layer and link training

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| PHY-01 | Serial encoding, disparity and invalid-code handling | Gap | Gap | Integrated tests operate at decoded GTH symbols [L] | Exercise actual transceiver codec and error indications; symbol benches do not verify serial 8b/10b behavior. |
| PHY-02 | Electrical compliance certification | waived - outside of project scope | waived - outside of project scope | Functional SSD link only [HW] | Formal compliance-pattern, eye-mask, jitter and receiver-tolerance qualification is outside this functional NVMe project. Functional signal integrity remains active in PHY-06. |
| PHY-03 | Reference clock, SSC and clock compensation | Partial | Partial | Scrambler SKP handling [S]; working example [HW] | Independent clock-offset/SSC tests and SKP insertion/removal limits; scrambler SKP tests alone are insufficient. |
| PHY-04 | Receiver detection, polarity and alignment | Partial | Partial | Logical Detect/training [T] | Actual receiver-detect outcomes, polarity reversal, alignment faults and physical timeout boundaries. |
| PHY-05 | Scrambler sequence and control-symbol treatment | Directed | Directed | Independent polynomial model, COM reset, SKP hold, stalls and roundtrip [S] | Map reset/advance rules and all applicable ordered sets to normative clauses. |
| PHY-06 | Functional physical link robustness | Partial | Partial | Working SSD setup [HW]; symbol-level fault tests [L] | Retain receiver detection, alignment, actual clock/SSC compatibility and sustained integrity testing on the intended board/adapter. Investigate electrical margin when functional results require it; certification waiver does not establish adequate margin. |
| LT-01 | TS qualification and x1 link/lane negotiation | Directed | Directed | Invalid symbols/IDs, TS1 count, TS2/Idle and L0 [T, L] | Complete legal/illegal ordered-set combinations and all qualification boundaries. |
| LT-02 | LTSSM timer and counter boundaries | Partial | Partial | Selected counts/timeouts in [T, G, L] | At-limit and one-cycle-before/after tests at both real clock rates; document accelerated bench parameters separately. |
| LT-03 | Force Gen1 and peer speed capability | Directed | Directed | Force-Gen1 and Gen1-only peer cases [G] | Broader capability combinations and repeated negotiation campaigns. |
| LT-04 | Gen2 directed speed change and idle handshake | — | Directed | TS2 count, peer idle, EIOS/EIEOS, rate control [G, L, R] | Normative symbol/timer boundary checks and actual GTH sequencing fault injection. |
| LT-05 | Gen2 de-emphasis selection | — | Partial | Peer preference exercised [G] | Verify emitted analog settings and all required negotiation combinations. |
| LT-06 | Failed speed change and downgrade | — | Directed | Gen2 timeout fallback and peer-directed downgrade [G] | Repeated failures, boundary arrival of TS and ownership stress with active traffic. |
| LT-07 | Recovery with outstanding traffic | Partial | Partial | Ownership preservation, retraining, replay resumption [L, G]; additional bounded cases [V] | Full Recovery state/transition coverage with errors, credits and traffic at each boundary. |
| LT-08 | Fundamental reset / PERST sequencing | Partial | Partial | Reset sequencer [Z] and example boot [HW] | Clause-mapped timings, cold cycles and endpoint reset interactions. No safe arbitrary live reset is claimed. |
| LT-09 | Disabled-state safety and unexpected training controls | Gap | Gap | No complete dedicated suite identified | Verify safe handling without stale DMA or lost ownership. Hot Reset service and Compliance-mode support are separately waived in LT-12/LT-13. |
| LT-10 | Loopback support and qualification | waived - outside of project scope | waived - outside of project scope | Unsupported request fails closed in [T] | Diagnostic loopback service is not needed by the NVMe data path. Retain the existing rejection test and safe unexpected-control handling in LT-09. |
| LT-11 | ASPM, PCIe low-power entry/exit and system suspend/resume | waived - outside of project scope | waived - outside of project scope | Product limitations [IP] | Target is active-link NVMe I/O. Low-power operation is not qualified; verify host policy keeps unsupported modes disabled under CFG-05. This does not waive ordinary startup or link faults. |
| LT-12 | Hot Reset as an operational reset/recovery service | waived - outside of project scope | waived - outside of project scope | No safe live reset is claimed [IP] | Project recovery uses controlled shutdown/global restart. Do not claim hot-reset recovery; startup PERST and safe handling of unexpected reset/link loss remain active in LT-08/LT-09/SYS-01. |
| LT-13 | Compliance-mode entry/exit and test patterns | waived - outside of project scope | waived - outside of project scope | No formal qualification evidence | Used for formal PHY qualification, outside the functional NVMe target. Unexpected training controls still require safe handling in LT-09. |

## Data link layer

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| DL-01 | TLP LCRC and DLLP CRC | Directed | Directed | Independent CRC models and wire checks [C, L]; additional bounded cases [V] | Clause-map bit/byte order and extend corrupted-field coverage; optional external oracle is not protocol VIP. |
| DL-02 | Whole-packet acceptance, duplicates and bad LCRC | Directed | Directed | Corrupt completion drop/NAK, duplicate suppression [L]; receive capacity [Q]; additional bounded cases [V] | Systematic truncation, framing, sequence and corruption combinations with no application side effects. |
| DL-03 | ACK/NAK capture and cumulative retirement | Directed | Directed | Capture, normal ACK retirement and simultaneous edges [A, P]; additional bounded cases [V] | Independently check all legal/illegal sequence values and timing boundaries. |
| DL-04 | Replay order, sequence wrap and storage ownership | Directed | Directed | Sent/unsent distinction, cumulative ACK, NAK, 12-bit wrap, stalls and concurrent commit [P] | Longer randomized scoreboard campaigns and combined fault injection. |
| DL-05 | Replay timeout and retry exhaustion | Partial | Partial | Timer replay, packet-boundary wait, exhaustion quarantine/retrain [P, L]; additional bounded cases [V] | Verify specification-derived timer values and retry behavior at both speeds, packet sizes and boundary events. |
| DL-06 | ACK scheduling and latency limits | Partial | Partial | Integrated ACK behavior and capture [L, A] | Independent latency-limit assertions under maximum RX/TX load and coincident DLLP demand. |
| DL-07 | Flow-control initialization | Directed | Directed | InitFC1/2, P/NP/Cpl classes, no premature active [F] | Malformed, reordered, missing and boundary-timed initialization DLLPs; normative timeout checks. |
| DL-08 | Credit accounting, wrap and infinite credits | Directed | Directed | Header/data accounting, 8/12-bit wrap, infinite Cpl credit, replay not double-charged [F, L] | Cross-check all advertised limits and long mixed-class traffic against an independent scoreboard. |
| DL-09 | UpdateFC scheduling and snapshots | Partial | Partial | Prompt/periodic return, stalled snapshots, consecutive returns [F]; additional bounded cases [V] | Check normative UpdateFC deadlines and thresholds, not just bench-local cycle limits. |
| DL-10 | Receive capacity and application backpressure | Directed | Directed | Validated packet buffering, stalls, credit returns [Q, F, L]; additional bounded cases [V] | Prove advertised capacity against worst-case packet mix and concurrent return/admission. |
| DL-11 | Corrupt/unknown DLLPs and link-state interactions | Partial | Partial | CRC infrastructure and selected Recovery/link-loss tests [C, F, L]; additional bounded cases [V] | Dedicated DLLP type/reserved-field/CRC corruption matrix across initialization, L0 and Recovery. |

## Transaction layer and configuration

| ID | Topic | Gen1 | Gen2 | Existing evidence | Open work / limitation |
| --- | --- | --- | --- | --- | --- |
| TL-01 | Memory and Configuration Type 0 request format | Directed | Directed | CfgRd/Wr, MRd64, 3DW below 4 GiB, header stalls [N, L] | Exhaustive legal field/byte-enable combinations and independent packet decoding. |
| TL-02 | Completion matching and unexpected completions | Directed | Directed | Wrong tag, completer identity, malformed completion and timeout quarantine [N]; additional bounded cases [V] | Complete tag/requester/completer/status/length/byte-count/lower-address cross-product. |
| TL-03 | Completion status and CRS | Partial | Partial | CRS requester behavior [N]; driver vendor-ID retry handling [D]; additional bounded cases [V] | Directed end-to-end tests for success, UR, CA, CRS and illegal status combinations. |
| TL-04 | Completion timeout and late completions | Partial | Partial | Timeout retains quarantine; tags not prematurely reused [N]; additional bounded cases [V] | Map implemented timeout policy to normative ranges and supported configuration; inject late packets at each boundary. |
| TL-05 | MPS128 and split read completions / RCB64 | Directed | Directed | 512-byte read splitting, encoded 4096-byte request, payload tests [B, L] | Sweep lengths/alignments and completion metadata against an independent model. |
| TL-06 | Byte enables and unaligned data | Directed | Directed | First/last byte enables, lengths, bank stalls and alignments [B, H]; additional bounded cases [V] | Validate every legal/illegal byte-enable rule, including short requests. |
| TL-07 | 4 KiB boundary and address-range validation | Directed | Directed | Crossing, high/out-of-range, truncated and oversized requests rejected before AXI [B] | Clause-map malformed versus unsupported handling and all edge addresses. |
| TL-08 | Zero-byte memory read / ordering flush | Directed | Directed | No stale payload or AXI read, completion and prior-write fence [B] | Independent completion-field checks under errors and concurrent traffic. |
| TL-09 | Ordering across writes, reads and MSI | Partial | Partial | Accepted/held writes and all B responses precede MSI/read/flush; B error suppresses MSI [B, H] | Full applicable PCIe ordering table, traffic-class/attribute audit and independent mixed-traffic scoreboard. |
| TL-10 | Poison, reserved encodings and unsupported packet safety | Gap | Gap | Selected unsupported/address-type rejection [B] is insufficient; additional bounded cases [V] | Inventory received encodings and verify safe rejection/error handling without DDR side effects. Positive support for optional services is waived in TL-11; poison and malformed-input safety remain active. |
| TL-11 | Optional ECRC service, TLP-prefix services and non-NVMe message features | waived - outside of project scope | waived - outside of project scope | No positive feature qualification claimed | Positive support tests are waived for services not enabled by this integration. LCRC/DLLP CRC, poison handling and safe rejection/parsing of unexpected packets remain active in DL-01/TL-10. Review any newly enabled endpoint feature before use. |
| CFG-01 | Endpoint configuration access and capability policy | Partial | Partial | Type 0 request tests [N]; driver 1/2/4-byte accesses, MPS128 policy, RO/No-Snoop disabled [D] | Executable driver tests for access boundaries, capability traversal, policy enforcement and errors. |
| CFG-02 | General-purpose standard Root Port bridge configuration | waived - outside of project scope | waived - outside of project scope | Driver exposes direct endpoint bus 1; no fabricated bridge configuration [D] | Supplied Linux host driver and direct NVMe enumeration define the project interface. Full bridge capability/register emulation and generic hierarchy discovery are not project goals. Endpoint config and policy tests remain active in CFG-01/CFG-05. |
| CFG-03 | Type 1 routing, switches and multiple functions | waived - outside of project scope | waived - outside of project scope | Direct endpoint only [IP, D] | No switch, downstream hierarchy or multifunction enumeration support is planned. Retain existing Type 1 encoding tests; unsupported accesses must remain safely rejected under CFG-05/TL-10. |
| CFG-04 | AER service, legacy INTx, hotplug and PME wake | waived - outside of project scope | waived - outside of project scope | Feature limits [IP]; no PME qualification | NVMe uses MSI/MSI-X with fixed attachment. AER software recovery, legacy interrupts, live insertion/removal and wake services are not supported goals. Error containment and accepted-AXI drain remain active. |
| CFG-05 | Enforce the supported endpoint feature policy | Gap | Gap | Direct-endpoint and MPS/attribute policy [D] | Verify actual Linux configuration does not enable unsupported link power modes/services, unexpected configuration requests fail safely, and the selected SSD works with MSI/MSI-X. A waiver does not by itself disable a feature in Linux or hardware. |
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
| HW-02 | Cold/warm start, Recovery and NVMe interoperability | Gap | Partial | Selected Gen2 boots and one SSD/adapter setup [HW] | Repeated cold/warm cycles and Recovery under traffic on the target setup; additional NVMe SSD models and intended operating conditions remain useful interoperability coverage. Arbitrary endpoint qualification is waived in HW-04. |
| HW-03 | Formal PCI-SIG compliance testing | waived - outside of project scope | waived - outside of project scope | No formal compliance results identified | Certification and the formal protocol/electrical test program are not project deliverables. Active protocol and hardware-integrity gaps are unaffected. |
| HW-04 | Arbitrary non-NVMe endpoint and topology interoperability | waived - outside of project scope | waived - outside of project scope | Project uses a direct NVMe SSD [HW] | GPU, NIC, switch, multi-endpoint and general-purpose PCIe interoperability campaigns are outside scope. Additional direct NVMe SSD testing remains in HW-02. |

## NVMe-scope regression campaign

The new [Gen1/Gen2 coverage suite](../tests/test_gen12_coverage.py) passes
**584 parameterized cases**, using 125 MHz and 250 MHz unit-test clocks. These
are two simulation clock settings, not physical negotiated links. Existing
integrated-link tests separately exercise speed selection. CRC vectors are
constructed in Python using zlib CRC32 and the independent polynomial CRC16
model already used by the repository.

| Active topics | Newly verified subcases | Remaining limits |
| --- | --- | --- |
| DL-01/DL-02/DL-10/DL-11 | All 176 single-bit mutations of a selected TLP's sequence/header/payload/LCRC; 22 truncation points; bad END, embedded control, PHY error, valid-CRC length mismatch, oversized payload, future/duplicate sequence and valid nullification. All 48 DLLP body/CRC bit mutations are rejected. | One selected TLP shape and DLLP body, not every legal format/type, multi-bit corruption or serial codec error. |
| DL-02/DL-03/DL-10 | ACK/NAK counts and response sequence checked; an earlier packet remains intact under backpressure; a valid retry is accepted with correct metadata and storage drains without leaks. | End-to-end ACK scheduling/latency under maximum contention remains open. |
| TL-02/TL-03/TL-06/TL-10 | All 15 nonzero requester byte-enable masks; TC, digest, poison, attributes, BCM, format, length, byte count and lower-address rejection; wrong tag/requester/type isolation; extra/missing data; UR/CA/memory-CRS outcomes; held responses and quarantine. | This is the one-DWORD requester, not the full endpoint-to-DDR completer sweep. Not all completion field combinations are covered. |
| TL-04 | No timeout before wire completion or while timeout ticks are disabled; exact 64-enabled-tick deadline; late-completion quarantine; completion just before/on deadline; malformed, header-only, UR, wrong-tag and link-loss arbitration at deadline. | Accelerated timeout value verifies edge behavior, not the normative production timeout range or integrated Gen2 tick divider. |
| DL-05/LT-07 | Replay deadlines at 16 and 512 cycles; unsent packets do not start timer; PHY hold freezes it; expiry retains ownership and replays original payload; ACK at expiry/service edge cancels replay. | Full Recovery transitions, response-age adjustment and normative speed-dependent replay limits still need coverage. |
| DL-09 | UpdateFC at configured 3/16/1024/4000-cycle boundaries; TX-disable pause; stable held offer; credit return wakes scheduling. | Module scheduling boundary only; wire-level deadlines under DLLP contention still need verification. |

The full final regression passed **669 tests**, and repository lint plus real-XPM
elaboration passed. [Recorded results and source hashes](evidence/gen12_coverage_v1/completion.json).

Counts include repeated clock/parameter settings and are not a measure of
requirements coverage. These subcases are verified; the broad matrix rows
retain their remaining limitations. Reproduce with:

```sh
.venv/bin/python -m pytest -q tests/test_gen12_coverage.py
```

The deadline tests reproduced a requester bug at both clock rates: a matching
completion on the timeout edge returned success but retained `fault_o`, blocking
subsequent commands. Completion acceptance now cancels that coincident timeout
fault in both data and header-only paths. Malformed matching completions still
quarantine; wrong-tag and late completions do not clear timeout; link loss has
final priority. No accepted ownership or packet validation is bypassed.

This functional RTL change subsequently passed a fresh Gen3 build and temporary
board validation, including 28,000 configuration reads and NVMe I/O/CRC checks
([evidence](evidence/requester_fix_v1/completion.json)). The exact timeout edge
was not injected on the SSD. New Gen1/Gen2 backend hardware validation remains
outstanding; historical bitstream/source manifests are unchanged.
The campaign does not close driver configuration policy, full LTSSM transitions,
all ordering/CDC combinations, or the remaining physical Gen1/Gen2 tests.

## Evidence index and executable tests

Test links identify source assertions, not standalone pass certificates. The
historical 85-test repository regression included Gen3 and software tests; the
new suite adds 584 parameterized cases. Neither count is a compliance score.

| Key | Source / executable selector |
| --- | --- |
| V | [New coverage suite](../tests/test_gen12_coverage.py): all five test functions; [requester](../tests/pcie_soft/tb_requester_coverage.sv), [RX faults](../tests/pcie_soft/tb_rx_fault_matrix.sv), [UpdateFC](../tests/pcie_soft/tb_fc_timer_coverage.sv), [replay timer](../tests/pcie_soft/tb_replay_timer_coverage.sv) benches |
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

## Suggested closure order for the NVMe project

1. **P0 — Define the active protocol contract.** Pin specification references for
   in-scope packet, link and ordering behavior. Verify the supplied host driver
   enforces the supported endpoint configuration (CFG-01/CFG-05). Waived bridge,
   power-management and certification features are not prerequisites for project
   completion. Keep their waivers visible rather than calling them compliant.
2. **P0 — Verify protocol timing and error handling.** Add independent timer
   boundary assertions for LTSSM, ACK, replay and UpdateFC at both speeds.
   Build table-driven malformed TLP/DLLP and completion-matching tests, checking
   rejection, response, sequence/credit ownership and absence of DDR side effects.
3. **P1 — Exercise state transitions with traffic.** Combine Recovery, speed
   changes, retries, credit exhaustion and AXI stalls. Verify unexpected training
   controls and link loss fail safely. Preserve accepted ownership invariants;
   live Hot Reset/remove support remains waived.
4. **P1 — Close configuration and ordering coverage.** Test completion metadata,
   MSI boundaries, noncoherent DMA and applicable ordering rules with an
   independent scoreboard. Optional-service waivers do not waive error containment.
5. **P2 — Obtain matching NVMe hardware evidence.** Build matching Gen1/Gen2
   configurations; qualify startup, traffic, integrity and Recovery on the target
   setup, then extend to additional direct NVMe SSDs and intended operating
   conditions. Formal certification and non-NVMe interoperability are waived.

An active row closes with a defined expected result, reproducible test, recorded
pass on identified sources/configuration, and disposition of its open limitations.
A waived row records a scope decision only. No tests are deleted or skipped by
this documentation change. Functional SSD throughput or an equivalence test
alone cannot close an active protocol requirement.

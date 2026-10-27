# Experimental Gen3 x1 investigation

This directory contains the optional experimental Gen3 x1 backend, its build
recipes, tests and chronological bring-up records. The frozen release remains
Gen1/Gen2 x1; current shared RTL changes are development beyond that baseline.

## Current design and reproduction

The current Gen3 host uses 64-bit host packet transfers, eight 64-byte DDR read
prefetch slots, an eight-entry shared replay store, two framing banks and normal
ACK retirement concurrent with later original packets. Latest 30-second QD8
throughput with the RX pipeline is **737.09 MB/s read / 565.70 MB/s write**.
The preceding ACK-retirement measurement was 745.36/567.71 MB/s. See the consolidated
[performance history](../../docs/performance-history.md) and
[current verification](../../docs/verification.md).

From the repository root with Vivado 2026.1 available, use fresh output names:

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -log build/gen3_package_next.log -journal build/gen3_package_next.jou \
  -tclargs build/gen3_package_next
vivado -mode batch -source experiments/gen3/build_host.tcl \
  -log build/gen3_board_next.log -journal build/gen3_board_next.jou \
  -tclargs build/gen3_board_next build/gen3_package_next/core
python3 experiments/gen3/host_sources.py check build/gen3_package_next/sources.json
python3 experiments/gen3/host_sources.py check build/gen3_board_next/sources.json
```

The unified package provides one `soft_pcie_root:1.1` catalog entry. In a manual block
design, double-click it and select **Enable experimental Gen3**; the experimental board
recipe sets `CONFIG.ENABLE_GEN3=true` explicitly. The default board recipe sets it
false. The optional packaging argument `1` sets the initial checkbox value only. Earlier
sections below describing separate native host packages refer to historical builds. The
unified 1.1 package has passed customization and synthesis/CDC checks for both
selections; the physical measurements above predate it. Its Gen3-enabled configuration
has also passed full synthesis, place-and-route, bitstream generation and an independent
checkpoint audit ([evidence](../../docs/evidence/catalog_gen3_v1/implementation.json)).
The later [startup correction](startup-stabilization.md) passed ten controlled
warm-start/read-only NVMe CRC trials on a fresh, audited unified image.
Use the packaged block-design cell for AXI automation; see
the [standalone wrapper limitation](../../docs/ip-guide.md#optional-gen3-packaging).

Freeze RTL/scripts/constraints throughout the build. These commands build only;
they do not program a board. Do not replace PL while Linux owns the host.
The startup correction still needs cold-cycle and broader qualification. Full
Recovery remains incomplete. The startup-tested image had +0.002 ns Gen3 setup
margin; the subsequent RX pipeline image below achieves +0.073 ns.
The SD default remains the historical Gen2 image.

### Receive timing refactor after the startup-tested image

The development RX now computes its fixed 32-bit LFSR advance independently of
SKP, selecting hold/advance once. Unscrambled ordered sets bypass descrambling.
A classification register carries each input DWORD and its metadata together,
adding one cycle of receive latency while retaining one DWORD per cycle.
EIEOS/SDS/EIOS and TS1/TS2 checks accumulate across words; the final word still
requires every previously checked field. Parser EDS/error feedback remains at
the consumer stage so its timing relative to decoded output is preserved.
Pipeline valid and control resets are synchronous; packet ownership and RAM
reset behavior are unchanged.

Vivado 2026.1 isolated synthesis on XCZU7EV-2, with a 4 ns clock, produced:

| RX revision | LUTs | FFs | Estimated internal WNS | Worst-path logic levels |
| --- | ---: | ---: | ---: | ---: |
| Startup-tested source (`12fb5dd`) | 563 | 342 | -0.945 ns | 23 |
| Fixed LFSR transform and raw ordered-set bypass | 580 | 342 | +1.939 ns | 10 |
| Plus classification pipeline and accumulated validation | 425 | 394 | +1.893 ns | 9 |

These are unplaced synthesis estimates for the isolated receiver, with no I/O
delay constraints, not full-design routed WNS. The extra pipeline also moves
input classification into registered logic. Its slightly lower estimated WNS
than the intermediate version is accompanied by lower LUT use. The earlier
full-design +0.002 ns result and physical evidence still describe the unchanged
startup-tested image, not this refactor.

The refactor subsequently passed fresh unified packaging, full synthesis and
place-and-route, and an independent reopened audit. Routed Gen3 setup/hold is
**+0.073/+0.011 ns**; Gen1 startup is +0.630/+0.011 ns. The limiting path is now
the TX recovery formatter's LFSR-to-correction path. Whole-design utilization is
11,219 LUTs, 10,491 FFs, 540 control sets, two RAMB36 and one RAMB18.

The audited image negotiated Gen3 x1 on its first controlled warm startup and
passed NVMe CRC and all eight matched performance/integrity jobs. QD1/QD8 reads
were 595.54/737.09 MB/s and writes 341.83/565.70 MB/s, within 1.11% of the preceding
ACK-retirement measurements. Exact write accounting and unchanged SMART error
counters passed. The board runs this image; SD boot files are unchanged.
This is one startup and short I/O testing, not cold-cycle, endurance or compliance
qualification. See [implementation and physical evidence](../../docs/evidence/rx_pipeline_v1/completion.json).

Native RX vectors cover framing, SKP, EDS, delivery gaps and retained packets;
native-link tests cover config/completion, ACK/NAK and CRC corruption. New tests
check every single-bit mutation of EIEOS/SDS/EIOS and TS1/TS2, including unchecked
training fields, with and without delivery gaps, plus reset/disable pipeline
flush. Startup, equalization and Recovery regressions also pass.

Reproduce isolated synthesis and focused regressions with fresh outputs:

```sh
vivado -mode batch -source experiments/gen3/synth_native_rx.tcl \
  -tclargs build/native_rx_synth_next
.venv/bin/python -m pytest -q tests/test_gen3_startup.py
.venv/bin/python experiments/gen3/check_native_rx.py
.venv/bin/python experiments/gen3/check_native_link.py
```

The sections below retain earlier investigation stages and test-time restoration
states. Their uses of “current” refer to the named stage, not the latest build.
Equalization-only probes are separate diagnostic images without Linux/NVMe DMA.

## Reproduce the PHY probes

With Vivado on PATH, run each command with a fresh output directory. Keep all
generated AMD sources and logs under ignored `build/`.

```sh
vivado -mode batch -source experiments/gen3/probe_gt.tcl \
  -log build/gen3_raw.log -journal build/gen3_raw.jou \
  -tclargs build/gen3_raw raw
vivado -mode batch -source experiments/gen3/probe_gt.tcl \
  -log build/gen3_pcie.log -journal build/gen3_pcie.jou \
  -tclargs build/gen3_pcie pcie
```

Both probes target the ZCU104 device and existing X0Y15 lane, a 100 MHz
reference, QPLL1, and nominal 8 GT/s with a 32-bit user interface. They generate
and synthesize the standalone GT, without a PCIe controller hard block. The
`pcie` probe deliberately attempts the unsupported `128B130B` encoding value;
the caught customization errors are expected with Vivado 2026.1. The Wizard
restores the previous RAW configuration before generation. `encoding-probe.txt`
records this outcome. Successful synthesis is only a tool feasibility result.

## Initial findings

Vivado 2026.1 / GT Wizard 1.7 revision 23 accepts the nominal configuration, but
rejects `128B130B` for both public encoding parameters. Internal vendor HDL
constants with that name do not establish a supported configuration interface.
Both RAW and PCIe-mode probes completed out-of-context synthesis on 2026-10-25.
Neither result includes full-design implementation or physical validation.

Generated primitive settings differ materially between the modes:

| Setting | RAW, PCIe mode disabled | RAW, PCIe mode enabled |
| --- | --- | --- |
| PCS_PCIE_EN | FALSE | TRUE |
| TX_DATA_WIDTH / RX_DATA_WIDTH | 32 / 32 | 20 / 20 |
| TXOUT_DIV / RXOUT_DIV | 1 / 1 | 4 / 4 |
| Nominal reported user clock | 250 MHz | 250 MHz |

The PCIe-mode primitive includes separate Gen3 PCS configuration attributes;
its static reset values are not evidence of the active Gen3 datapath. Native
rate transitions, clock selection, header/data-valid behavior, and equalization
control still need validation. Exposing the ports is not sufficient to prove
that they work independently of AMD's controller integration.

The RAW configuration establishes a possible alternative: implement block
framing in fabric. It does not solve receiver detection, electrical idle,
Gen1/Gen2 startup, rate changes, or PCIe equalization.

## Proposed architecture

Keep the host AXI/DDR and packet ownership interfaces. Introduce a physical
coding layer boundary below packet/data-link handling, with distinct legacy
symbol and Gen3 block implementations. The current 16-bit symbol serializer and
parser cannot simply be widened and reused as Gen3 wire framing.

1. **PHY adapter:** explicit Gen1/Gen2/Gen3 requested and applied rates; independent
   management clock; rate completion, PLL lock, electrical idle, receiver detect,
   polarity, and equalization controls. Decide between the native PCIe PCS and
   RAW/fabric PCS only after validating the standalone GTH behavior.
2. **Gen3 block layer:** 128b/130b framing, block alignment, scrambling,
   ordered-set handling, SKP clock compensation, and Gen3 packet delimiters.
   For a RAW 32-bit interface, 16 blocks occupy 65 cycles; backpressure and
   continuous idle/ordered-set generation must account for this cadence.
   RX needs real clock compensation; an ordinary asynchronous FIFO alone is
   not an indefinite solution to independent reference-clock drift.
3. **Training and equalization:** extend the LTSSM with Gen3 negotiation and
   Recovery.Equalization, required preset/coefficient exchanges, bounded
   timeouts, and fallback. Startup still requires a working legacy path.
   Do not set the advertised Gen3 capability before this path is complete.
4. **Packet/data-link adaptation:** retain validated packet boundaries, credits,
   sequence numbers, ACK/NAK and replay ownership, while replacing the wire
   framing. Audit bandwidth and timer units at every clock/rate boundary.
   The existing 32-bit host path is a separate potential throughput limit.
5. **Management:** expose requested/applied rate, equalization phase, block-lock
   status and error counters. Linux must see the actually negotiated speed.

New fabric control state uses synchronous resets; packet memories stay unreset.
Recovery must not clear accepted AXI transactions, retry storage, credits or
payload ownership. Native PHY reset/clock sequencing requires its own review;
the existing stopped-clock reset exception is not permission to reset datapaths
asynchronously.

## Required evidence before integration

- Check framing, scrambling, training and equalization against a PCI Express
  Base Specification covering Gen3. Obtain independent known-answer vectors or
  endpoint/VIP behavior; a matching custom transmitter/receiver is insufficient.
- Simulate the GT adapter through legacy startup, 8 GT/s entry and fallback,
  including missing lock, stale completion, electrical idle and timeout cases.
- Test block alignment across all bit offsets, malformed headers, ordered sets,
  clock drift/SKP handling, packet corruption and replay during recovery.
- Run the existing packet/credit/AXI ownership regression suite on integration.
- Synthesize and route a fresh complete design with a frozen source manifest.
- Separately qualify the physical FMC/adapter/SSD path at 8 GT/s. Existing Gen2
  I/O and CRC results do not qualify Gen3 signal integrity or equalization.

No PHY loopback, Gen3 link training, board programming or physical Gen3 I/O has
been performed by these probes. A local preliminary Base Specification is now
available (see below); independent full-link wire-level validation remains
outstanding.

## Public references and first control experiment

Intel publishes [PIPE revision 7.1](https://cdrdv2-public.intel.com/643108/643108_PIPE_Arch_Spec_Rev_7_1.pdf).
Section 8.27 specifies the transmit cadence: with a 32-bit interface at 8 GT/s,
16 blocks are followed by one invalid cycle. `gen3_tx_cadence.sv` implements
that scheduling rule with synchronous state reset. It requires a continuous
producer, including idle/ordered-set data, and is not a ready/valid queue.
Electrical-idle entry/drain and the GTH interface mapping are not implemented.
This PIPE timing rule must not be assumed to describe exposed GTH ports without
an adapter and separate validation.

```sh
mkdir -p build/gen3_cadence
iverilog -g2012 -s test_tx_cadence -o build/gen3_cadence/test.vvp \
  experiments/gen3/gen3_tx_cadence.sv experiments/gen3/test_tx_cadence.sv
vvp build/gen3_cadence/test.vvp
verilator --lint-only --Wall experiments/gen3/gen3_tx_cadence.sv
```

Simulation passed 192 scheduling periods, idle restarts and reset at nonzero
phase; module lint passed. This tests cadence only, not encoding or PCIe compliance.

[cocotbext-pcie](https://github.com/alexforencich/cocotbext-pcie) provides system
transactions and vendor hard-IP interface models. It is useful for future
host/endpoint transaction tests, but does not supply the serial Gen3 training
and equalization oracle needed here. PIPE is an interface reference, not a
replacement for all Base Specification protocol requirements.

## Local preliminary Base Specification and scrambler

The user supplied PCI Express Base Specification Revision 4.0 Version 0.3,
dated February 19, 2014. Its revision history identifies Revision 3.1 as the
baseline. It contains the 8 GT/s requirements needed for this investigation;
draft 16 GT/s provisions are outside this experiment's scope. This is a draft
reference, not evidence of compliance with a final standard or later errata.
The PDF is locally excluded from Git and must not be included in a release.

Relevant sections:

| Section | Use |
| --- | --- |
| 4.2.2.1 | Block header and transmitted bit order |
| 4.2.2.2.1 | Receive block alignment |
| 4.2.2.3 | Data-stream framing and error recovery |
| 4.2.2.4, Figure 4-18 | Scrambling and ordered-set exceptions |
| 4.2.6.4.2 | Recovery.Equalization, downstream/upstream roles |
| 4.2.7.2 | SKP handling at 8 GT/s |
| Appendix C.2, page 998 | Independent lane-0 scrambler vectors |

`gen3_scrambler.sv` is an experimental 32-bit lane-0 scrambler/descrambler with
a synchronous control reset and one elastic output register. It handles
per-byte advance/XOR selection and reseeding after an accepted word. The caller
must classify ordered sets, select training DC-balance exceptions, and identify
the final EIEOS word. Headers must bypass this interface. Payload output data
is unreset and invalid after reset. These local registers do not own packets;
integration must preserve the established packet/replay ownership contract.

```sh
python3 experiments/gen3/check_scrambler.py /path/to/local-draft.pdf
```

The runner extracts the independent tables from the local PDF into a fresh
ignored build directory; it does not redistribute the tables or vendor sample
code. The original RTL uses a serial polynomial recurrence. Simulation checks
all 128 published output bytes and DWORD-boundary states, inverse decoding,
mixed XOR masks, output stalls, SKP-style state hold, bypass with advance,
post-word reseeding and reset. Simulation and module lint passed. This is
component validation only: ordered-set classification, DC-balance selection,
block alignment, native GTH mapping and full-link equalization remain pending.

## RAW block packing and alignment acquisition

`gen3_tx_gearbox.sv` packs fixed 130-bit blocks into a continuous sequence of
32-bit words, with header bit 0 first, followed by header bit 1 and payload bits
0 through 127. It supports elastic input/output handshakes for component testing.
It does not accept variable-size SKP blocks or flush a partial final word.
The native GTH adapter must guarantee uninterrupted physical transmission and
implement electrical-idle entry; a physical transmitter cannot honor arbitrary
fabric stalls. Sixteen full blocks pack exactly into 65 output words.

`gen3_eieos_detect.sv` finds a complete 8 GT/s EIEOS across arbitrary word
boundaries. It reports the final bit's offset in the accepted input word so a
future block extractor can preserve trailing bits. It retains history across
delivery gaps, invalidates history synchronously on reset, and provides an
explicit search gate for the Locked phase. It does not itself implement the
Unaligned/Aligned/Locked state machine, SDS detection, variable-size SKP
adjustment, polarity correction, or Recovery training gating. A stream
discontinuity must invalidate its history.

```sh
python3 experiments/gen3/check_framing.py
```

The transmitter passed an independent serial-bit scoreboard over 1,024 blocks
(133,120 bits), including both legal headers, all word/block boundary phases,
continuous output under continuous supply, independent stalls and complete
drain. The detector passed all 32 input bit offsets, back-to-back EIEOS,
each of 130 single-bit corruptions, random non-EIEOS data, search gating,
delivery gaps and reset during a candidate pattern. Both modules passed lint.
These tests do not pair the custom transmitter with the custom receiver as
their correctness oracle. Data/history storage is unreset; synchronous control
state establishes validity. No full-design synthesis or board deployment has
been performed for these modules.

## Receive block extraction

`gen3_rx_blocks.sv` combines EIEOS acquisition with block extraction and
Unaligned/Aligned/Locked state. It handles RAW 32-bit words, emits the acquired
EIEOS, preserves the trailing bits from its final word, and locks on a complete
SDS ordered set. It rejects undefined headers and an ordered-set header directly
after SDS. While locked it does not search payload bits for EIEOS. An explicit
restart invalidates physical coding state for Recovery; packet, replay and AXI
ownership are outside this module and must not be reset by that signal.

Received SKP ordered sets are extracted at their actual lengths of 8, 12, 16,
20 or 24 symbols. The extractor validates the repeated SKP symbols and allowed
SKP_END positions, then consumes the three trailing symbols before the next
header. Its output carries up to 24 symbols plus a length, rather than silently
assuming every received block is 130 bits. Scrambling, SKP data parity and LFSR
diagnostics remain downstream responsibilities.

The output is a pulse interface with no backpressure. A downstream stage must
accept every block or explicitly quarantine overflow. Blocks remain scrambled;
this module does not validate TLPs or permit memory effects. Error and block
pulses can coincide when an error follows a completed block within one input
word; downstream packet validation must prioritize the error. Global reset and
restart are synchronous, and history/payload storage is unreset.

```sh
python3 experiments/gen3/check_rx_blocks.py
vivado -mode batch -source experiments/gen3/synth_rx.tcl \
  -log build/gen3_rx_synth.log -journal build/gen3_rx_synth.jou \
  -tclargs build/gen3_rx_synth
```

The word-based implementation registers input alongside parallel EIEOS search,
then extracts blocks from a bounded bit buffer. Output events occur one clock
after the corresponding RAW word is accepted. A delivery gap does not cancel
that pending word. During acquisition an EIEOS match supersedes a tentative
block at an older alignment; locked data never uses this acquisition override.

Independent serialized stimuli check all 32 acquisition offsets, training blocks,
SDS and subsequent data, an EIEOS pattern embedded across locked data blocks,
all five SKP lengths followed by data, illegal headers, reacquisition, malformed
SKP termination, shifted-EIEOS reacquisition before lock, global/local restart and
delivery gaps. Simulation and lint pass.
The initial bit-unrolled prototype passed functional tests but synthesized to
37,524 LUTs and 550 FFs with estimated setup slack of -121.829 ns against a
4 ns clock. That result rejected the architecture for hardware integration.
The replacement word-based implementation, including its EIEOS detector,
synthesized to 2,889 LUTs and 573 FFs with estimated setup/hold slack of
+0.072/+0.078 ns against a 4 ns clock (Vivado 2026.1, XCZU7EV-2).
Source hashes were checked unchanged across that build. These are standalone
synthesis estimates, not routed or physical evidence; external input/output
delays and integrated clock skew are not covered. The setup margin is narrow.
Full LTSSM/equalization, physical GTH operation, downstream framing and pipeline
integration are still required before this can establish a Gen3 link.

References: AMD [UG576, GTH transceivers](https://docs.amd.com/v/u/en-US/ug576-ultrascale-gth-transceivers)
and [PG182, GT Wizard](https://docs.amd.com/r/en-US/pg182-gtwizard-ultrascale/Product-Specification).
Vendor documentation and generated sources are not redistributed here.

## Receive data path integration

The next implementation stage adds these components:

| Component | Implemented scope |
| --- | --- |
| `gen3_stp.sv` | STP generation/checking, frame CRC/parity, EDS recognition |
| `gen3_stream_rx.sv` | Unaligned byte-token parsing across Data Blocks; SDP/STP/EDB/EDS/IDL; deferred TLP completion |
| `gen3_packet_gate.sv` | Whole-packet LCRC/length/sequence validation, MPS128 guard, retained packet queue |
| `gen3_data_rx.sv` | Connected descrambled-data receiver with DLLP CRC validation |

The parser emits provisional body data including LCRC. A packet is committed
only after the following symbol excludes nullification and the gate validates
the complete packet. A valid EDB with the nullified LCRC discards the candidate.
Recovery abort discards an uncommitted candidate while preserving committed
packets, output stalls and receive sequence state. Global reset is separate.
Payload RAM remains unreset; control resets are synchronous.

STP tests use independent polynomial division for all 2,048 length encodings and
one-, two- and three-bit protected-field corruption cases. Stream tests cover
all 16 byte positions within a Data Block, packet/DLLP boundaries, malformed
tokens and delayed completion. Gate tests cover CRC/length errors, duplicate
and future sequences, queue exhaustion, nullification, MPS violations and
Recovery ownership. The connected path passes 40 TLP/DLLP frames with
independent CRCs, byte/block crossings and back-to-back packets. Module and
integrated lint pass. The receive path has not yet undergone synthesis/timing
qualification as a whole.

```sh
python3 experiments/gen3/check_all.py --spec /path/to/local-draft.pdf
```

This is not a complete receiver from the transceiver pins: ordered-set
classification, descrambling policy, SKP parity and Data/OS transition validation
must still connect the physical block layer to this Data-stream interface.

## Native PCIe PHY interface investigation

UG576 Chapter 6 points to the generated AMD PCIe PHY wrapper as an integration
reference. An inspection-only reference was generated locally under ignored
build output. Its native PCIe PCS uses GT control bits for data-valid, block
start and sync headers. These are distinct from the generic gearbox header
ports. The initial rejection of a public `128B130B` encoding selection therefore
does not establish that the native PCS is inaccessible.

`probe_native_gt.tcl` generates the standalone ZCU104 GTH with native TXDATA,
RXDATA and control ports, external reset/user-clocking interfaces, PCIe mode,
and QPLL1 settings for the nominal 8 GT/s configuration. It passed synthesis
with Vivado 2026.1. It is a port/configuration feasibility probe, not a functional
multirate PHY: the probe now exposes channel reference, CPLL reset/power-down
and DRP clock ports, and that revision also passed standalone synthesis. The
generated attributes still select QPLL1 for both Gen1/2 and Gen3. Exposing CPLL
ports does not change that selection or prove legacy startup. PLL selection,
common reset/rate feedback, receiver detection and equalization control still
need full PHY integration and simulation. The latest probe also exposes native
BUFGT CE/reset/mask/divider outputs and the COMMON `pcierateqpll1_in` request;
it passed standalone synthesis. The management sequencing and clock wrapper
below are separate components, not yet connected to a fully initialized GTH. The inspected controller reference used
GTY, so its mappings must be verified against GTHE4 rather than assumed portable.
No AMD controller or generated vendor source is included in the release.

## Selectable Phase 1 equalization shortcut

The local draft, section 4.2.6.4.2.1.1, explicitly permits a downstream port to
skip phases 2 and 3 based on platform/channel characteristics. This remains a
reasonable experimental policy for a short connection, not evidence that the
channel works at 8 GT/s. Phase 1 and the subsequent Recovery states still apply.

`gen3_eq_phase1.sv` implements downstream x1 Phase 1 with synchronous reset:

- Latches the skip policy for each attempt and waits for confirmation that the
  advertised preset is effective at the pins. Preset/FS/LF/post-cursor fields
  come from the PHY adapter; this module does not invent GTH tap mappings.
- Allows 500 ns of initial receive stabilization by default. Requires Gen3 PHY
  readiness, block alignment and two consecutive valid EC=01 TS1s with matching
  symbols 6 through 9. Other training sequences or lost qualification break the
  pair. Permitted intervening SKP/EIEOS do not break the pair. The upstream TS
  validator must not reject a TS merely because a reserved bit is nonzero.
- With the shortcut selected, requests Recovery.RcvrLock and sets the prescribed
  phase-success/complete status bits. A separate `phases23_skipped` flag makes
  clear that phases 2 and 3 were skipped rather than adaptively optimized.
- Without the shortcut, requests handoff to a phase 2 engine, which is not yet
  implemented. This is not a complete full-equalization mode.
- Times out after 24 ms and requests Recovery.Speed. The outer LTSSM must clear
  successful-speed-negotiation and perform fallback; this component cannot
  declare L0 or reset packet/replay ownership.
- If PHY readiness drops after preset acknowledgement, fails the attempt and
  requests Recovery.Speed immediately. This experimental fail-closed policy
  prevents reuse of an acknowledgement after the PHY loses readiness; a new
  attempt requires a new acknowledgement. It does not implement fallback itself.
- Exposes sticky per-attempt `failure_reason` and a saturating 16-bit
  `ts_events` count. Reasons are 0 none, 1 PHY unavailable at timeout,
  2 preset unacknowledged at timeout, 3 unaligned at timeout, 4 no qualifying
  pair at timeout, and 5 PHY readiness lost after acknowledgement. Timeout
  reasons describe the condition at expiry, not the entire attempt history.
  Reset or a new attempt clears diagnostics; cancellation leaves them readable.

The clock must continue running at the configured frequency throughout Phase 1.
All inputs require synchronous delivery; preset acknowledgement must refer to
this attempt. An independent management-clock watchdog and the PHY's receiver
acquisition deadline remain integration requirements. Cancellation invalidates
only this attempt. No packet memory is reset by this controller.

Tests cover fixed-preset advertisement, policy latching, mismatched symbols,
invalid/nonconsecutive training sequences, alignment loss, stale entry events,
cancellation, missing preset/PHY readiness, the exact timeout boundary and
synchronous reset. Simulation, lint and the full experimental component
regression pass with the final field-match check. No physical equalization
has been performed.

`python3 experiments/gen3/check_equalization.py` runs the directed boundary
tests plus 2,376 matrix cases. The matrix sweeps preset labels P0 through P10,
both skip/handoff policies, acknowledgement delays of 0/1/7/17 cycles, and
settling intervals of 0/2/125 cycles (125 is 500 ns at 250 MHz). Nine scenarios
cover a valid pair with an intervening gap, changed symbols, invalid TS1,
alignment loss and reacquisition, PHY readiness loss, missing acknowledgement,
persistent misalignment, absent TS1 and absent PHY readiness. It checks settings
and policy latching, pulse acknowledgements, diagnostic clearing/persistence,
and single-cycle handoff/fallback indications. The standard experimental
regression now includes this runner, which saves source hashes and a result
manifest in a fresh ignored build directory.

The preset sweep uses synthetic acknowledged PHY fields. It exercises control
logic for each label, not actual preset-to-GTH tap mappings or analog channel
quality; it cannot select a best preset. The implementation still needs the
native preset-apply/query path, training ordered-set integration and physical
measurements. AMD's [PHY equalization sequence documentation](https://docs.amd.com/r/en-US/pg239-pcie-phy/Equalization-Sequences)
places preset application during electrical idle before the rate change; the
Phase 1 acknowledgement contract must be connected to that earlier operation,
not interpreted as permission to first apply a preset during Phase 1.

```sh
mkdir -p build/gen3_eq
iverilog -g2012 -s test_eq_phase1 -o build/gen3_eq/test \
  experiments/gen3/gen3_eq_phase1.sv experiments/gen3/test_eq_phase1.sv
vvp build/gen3_eq/test
verilator --lint-only --Wall experiments/gen3/gen3_eq_phase1.sv
```

## PHY rate/clock sequencing and Data-stream scheduling

`gen3_phy_rate.sv` runs from the independent management clock. A held request
selects Gen1, Gen2 or Gen3 (rate codes 0, 1 and 2). It first requests transmit
quiescence and waits for a drain acknowledgement. Only then does it assert
transmit electrical idle, wait for its acknowledgement/hold time, and change
RX/TXRATE. A changed rate requires a fresh native busy-to-idle transition;
a stale high level does not complete the request. PLL lock, TX/RX reset-done,
Gen3-ready status and measured user-clock readiness qualify completion. A
same-rate request rechecks readiness without demanding a nonexistent transition.

All waits are bounded. Faults remain latched and preserve the requested idle
state; a drain timeout never asserts electrical idle over an unfinished packet.
This controller does not reset packet RAM, replay or AXI ownership. A normal
fallback is a new LTSSM request through the same sequence. A fatal sequencer
fault is quarantined, not automatically cleared by a local reset. Cold startup,
receiver detection, PLL calibration and safe system shutdown remain outside it.

`gen3_clock_watch.sv` uses a registered Gray counter in the observed clock domain
and two synchronizer stages in the management domain. Two consecutive frequency
measurement windows must pass. `gen3_phy_control.sv` connects this observer to
the rate controller for the shared TX/RX user-clock arrangement. Defaults assume
50 MHz management and 125 MHz Gen1 / 250 MHz Gen2 and Gen3 user clocks. The
actual generated native configuration must establish these rates before use.
The observer detects a sustained missing/wrong clock during qualification;
it does not implement safe stopped-reference recovery or continuous runtime
monitoring. Gray-bus max-delay/bus-skew constraints and reviewed request/drain
CDC bridges are required when integrating it into the board design.

`gen3_native_clock.sv` instantiates BUFG_GT driven by native BUFGT outputs, rather
than fabric logic that guesses the clock divider from requested speed. Its
PCLK inputs correspond to the low three divider bits and mask bit 0. The generated
reference provides this mapping; the complete GTHE4 wiring and dynamic clock
behavior still need verification. The standalone wrapper synthesizes successfully.
COMMON QPLL rate/reset/power-down feedback, PCS control/header wiring and cold
reset sequencing are not connected by `gen3_phy_control.sv`.

`gen3_tx_schedule.sv` implements common-reference Gen3 x1 Data-stream scheduling:

- Buffers one complete framed packet of up to 64 DWORDs before transmission.
  Input contains framing tokens, TLP/DLLP bytes, CRC and optional EDB; creating
  those fields is the responsibility of the packet formatter, still pending.
- Emits SDS, scrambled Data Blocks, IDL padding, correctly placed EDS and SKP
  ordered sets. Schedules SKPs every 372 blocks and accumulates pending SKPs
  during a packet. Each in-stream SKP is preceded by EDS and followed by Data.
  Metadata contains the LFSR state and parity of scrambled Data Block payloads.
- Supplies the 32-bit, 64-valid-cycles-per-65-clocks cadence through the scrambler
  pipeline. There is no output backpressure. This PIPE cadence still requires
  validation against the actual native GT interface before direct connection.
- Finishes accepted packet collection/transmission before a requested stop,
  closes the stream with EDS/EIEOS, and waits for physical drain acknowledgement.
  This exit is for Recovery, not power-management EIOS. Training TS generation,
  training DC balance and training-mode SKP scheduling remain separate work.
- Retains its unreset packet bank after the final PCS word. `retire_i` must be
  generated by a downstream tracker only after that packet's physical completion;
  `tx_packet_last_o` is a PCS acceptance marker, not permission to free replay
  ownership. Retirement returns the captured packet ID. The single-outstanding
  tracker must not deliver stale/duplicate retirements. Partial-bank overflow or
  an invalid retirement latches a fault without discarding accepted storage.

Control resets are synchronous; reset is for cold initialization only. A fatal
fault or stop is not permission to reset away ownership. The prototype uses one
bank and waits for retirement before accepting another frame; higher throughput
will require integrating the existing packet/replay bank ownership scheme.

Run the focused tests with:

```sh
python3 experiments/gen3/check_sequencing.py
```

They check fresh/stale rate acknowledgements, Gen3 entry and Gen2/Gen1 fallback,
clock-frequency qualification, stopped clocks, bounded faults, delayed packet
retirement, stop during collection, and retained partial packets on overflow.
An independent Python decoder checks captured scrambled words, continuous packet
data, EDS/SKP transitions, parity, LFSR state and cadence. Tests use both a short
stress interval and the normal 372-block interval. The full experimental suite,
focused simulations and module lint pass.

Standalone Vivado 2026.1 synthesis on XCZU7EV-2 produced:

| Component | LUTs | Registers | Other |
| --- | ---: | ---: | --- |
| TX scheduler including cadence/scrambler | 291 | 153 | 40 LUTs used as memory |
| Connected rate controller/clock observer | 155 | 163 | Two clock domains |
| Native clock wrapper | 0 | 0 | One BUFG_GT; tool-inserted synchronization |

Scheduler estimated setup/hold slack is +1.832/+0.033 ns at 4 ns. These are
out-of-context synthesis estimates without routed clock skew or external I/O
constraints, not timing closure for the full PHY. Source hashes were frozen
and verified unchanged across the builds. Reproduce with fresh output paths:

```sh
vivado -mode batch -source experiments/gen3/synth_sequencing.tcl \
  -log build/gen3_sequencing.log -journal build/gen3_sequencing.jou \
  -tclargs build/gen3_sequencing
vivado -mode batch -source experiments/gen3/probe_native_gt.tcl \
  -log build/gen3_native.log -journal build/gen3_native.jou \
  -tclargs build/gen3_native
```

## Integrated transmit transport and rate control

`gen3_tx_path.sv` now connects the Data-stream scheduler, tagged completion
boundary, management rate controller and user-clock observer. It provides a
single experimental transport top with separate management and user clocks.
This is a fabric/PHY interface integration, not a complete native GTH wrapper
or PCIe link. Packet input is still preframed, and the LTSSM must provide Data
Stream permission only after training/equalization has completed.

The stop request, Gen3 permission and drain acknowledgement are registered in
their source domains before two-stage synchronization. A new management request
cannot reuse the preceding drain acknowledgement. The scheduler closes the
stream only after finishing accepted packet collection/transmission, and drain
is acknowledged only when its ownership is empty, the legacy path is drained,
and the external physical pipeline reports empty. Electrical idle and a rate
change follow this acknowledgement; they cannot cancel a pending packet.

`gen3_tx_completion.sv` assigns a monotonically increasing 32-bit submission
token when the final packet word reaches the PCS boundary. The external PHY
completion tracker must return that exact token only after physical completion.
A matching completion retires the scheduler bank and returns its original
packet ID. Early, mismatched or duplicate completions fault without releasing
pending ownership. Token exhaustion faults rather than wrapping. Recovery and
rate changes do not reset the counter or packet bank. Cold initialization must
also clear the downstream completion pipeline; no safe live reset is implied.

The native interface inspected so far has no packet-level physical completion
output. Therefore this top deliberately exposes `complete_i/complete_token_i`
and `wire_empty_i` as PHY contracts, rather than fabricating completion from
PCS acceptance or an unqualified delay. The simulation supplies them with an
independent behavioral sink. A validated native physical-completion mechanism,
COMMON reset/rate feedback, cold PHY initialization, native PCS mapping and
training/Data-stream arbitration remain necessary before a board image can use
this transport. No GTH serial timing model or physical link was tested here.

```sh
python3 experiments/gen3/check_integration.py
vivado -mode batch -source experiments/gen3/synth_integration.tcl \
  -log build/gen3_integration.log -journal build/gen3_integration.jou \
  -tclargs build/gen3_integration
```

The integration test covers a rate request halfway through packet collection,
delayed physical completion, final ordered-set drain, Gen3/Gen2/Gen1 changes,
rapid successive management requests, packet identity and tokens retained
across Recovery, and rejection of a stale completion for a subsequent packet.
The latter retains the packet bank and ends in a drain timeout without forcing
electrical idle. The full experimental regression and integrated lint pass.

Standalone synthesis with frozen, verified source hashes uses 471 LUTs and
393 registers, including 40 LUTs used as memory. Estimated setup/hold slack is
+1.980/+0.033 ns for the 250 MHz user clock; Gray-bus skew slack is +3.858 ns
against a 4 ns bound. There is no routed clock skew or external I/O timing
coverage in these out-of-context estimates.

The CDC review found and fixed combinational sources on the three internal
control crossings by registering them before synchronization. The final report
has no critical findings. It retains one multi-bit Gray-counter warning, with
explicit max-delay/bus-skew constraints, and six external PHY status-input
warnings. These are not waived or advertised as a clean full-PHY CDC audit;
the actual wrapper and its clock/port constraints must complete that review.
Only first-stage synchronizer pins have single-bit false-path exceptions; no
whole-clock false paths are applied. The synthesis script checks expected
synchronizer/Gray-bus structure before applying its constraints.

## Recovery and native receive integration

The [Recovery diagnostic](recovery-bringup.md) connects continuous TS1/TS2-to-SDS
transmission and native receive descrambling/ordered-set validation to the
packet receiver. Earlier logical-idle and InitFC1 probes are historical stages.
The later Data Link diagnostic completed InitFC1/InitFC2, UpdateFC, a configuration
read, a validated completion, and ACK exchange with the SSD at Gen3 x1.

## Data Link and host integration status

Three physical configuration-read trials returned `a80d144d` with successful
completion status and no pending replay ownership. Captures contained 360, 360,
and 357 framed DLLPs, respectively, with no DLLP CRC errors. Independent capture
decoding validated the transmitted request and received completion LCRCs.
See [the sanitized evidence](evidence/datalink-config-read.json) for exact image
hash, timing, source hashes, and limitations. That image exercised no DMA.

The experimental implementation now includes:

- Registered DLLP formatting, flow-control initialization and updates, and
  lossless ACK/NAK scheduling.
- Eight outstanding outbound TLPs using the shared Gen2 BRAM replay store,
  two-bank Gen3 sequence/LCRC framing, cumulative ACK-confirmed ownership,
  timeout/NAK replay, and quarantine after retry exhaustion.
- Native scrambled configuration transactions, with corrupted-LCRC injection
  demonstrating NAK/replay and exactly one accepted request in simulation.
- A native PHY adapter and experimental package around the existing host, DDR,
  command/packet CDC, and CSR shell. The generated shell changes only the top
  module name and root-port module type; qualified source files remain unchanged.

The full host image `gen3_host_board_v6` passed routed timing and completed
Linux/NVMe operation at Gen3 x1. Linux discovered the endpoint and namespace,
allocated a 64 MiB host memory buffer, and initialized four I/O queues. Tests
passed for the existing 256 MiB CRC pattern, a fresh 256 MiB CRC write/readback,
a 32 MiB write/readback at a 512-byte sector offset, explicit namespace flush,
and post-flush verification. A 30-second read transferred 13.0 GB at 434 MB/s.
Exactly 288 MiB was written in previously authorized scratch ranges; SMART media
and error-log counts remained zero. The single-outstanding transmitter limits
write throughput: the 256 MiB CRC write measured 119 MB/s.

Two of three temporary boots reached Gen3 NVMe operation; the third-attempt
256 MiB CRC check also passed. One repeat boot failed during legacy Gen1
startup before Gen3/Data Link activation.
This confirms that startup reliability remains an open issue even though the
Gen3 data path operated successfully. See the [host evidence](evidence/nvme-host.json)
for trial counts, exact image/source hashes, timings, throughput and limitations.
This is experimental operation, not a qualified release.

Timing closure required separating training disparity from packet data, removing
validation-dependent ingress/output-data enables, and simplifying the parser's
overflow check. Malformed-token suppression and whole-packet validation remain
unchanged; 208 parser cases and a 6,745-cycle old/new observable comparison pass.
Final setup/hold slack is +0.067/+0.011 ns at Gen3 and +0.687/+0.011 ns at Gen1.
Utilization is 11,201 LUTs, 9,979 FFs, one RAMB36, one RAMB18 and one GTH, with
no URAM, DSP or PCIe hard controller.

To reproduce the experimental host build, use fresh output directories:

```sh
vivado -mode batch -source experiments/gen3/package_host.tcl \
  -tclargs build/gen3_host_package_new
vivado -mode batch -source experiments/gen3/build_host.tcl \
  -tclargs build/gen3_host_board_new build/gen3_host_package_new/core
```

The build freezes source hashes, audits packet/command CDC and DDR ownership
structure, checks both Gen3 and Gen1 startup timing, and withholds the image on
failed timing, critical CDC, DRC, or bus-skew checks. New custom control resets
are synchronous; packet storage is not reset.

Remaining limitations include intermittent legacy startup, unimplemented full
phases 2/3 and live Recovery/fallback, and a conservative single-outstanding
transmitter in the historical `gen3_host_board_v6` image. The current RTL
uses the matching Gen2-capacity window described below. Replay exhaustion
retains ownership in quarantine. There is no
safe live PL replacement, hot removal, or stopped-reference recovery. Passing
simulation or implementation does not establish electrical compliance.

No Gen3 capability is advertised by the qualified core. Hardware tests use
temporary JTAG programming and leave the SD default unchanged. Full-host testing halts Linux cleanly, catches the next boot at kernel
entry, programs the experimental PL before Linux owns DMA, then resumes boot.
Never substitute an image under a running driver. Qualified Gen2 Linux/NVMe
was restored and the 256 MiB CRC pattern reverified at 403 MB/s, with zero
I/O in flight and unchanged SMART error counters. Details are in the host evidence.

See [the open-source review](open-source-review.md) for reviewed upstream
implementations and the optional independent DLLP encoder/CRC test.

## Matched Gen2/Gen3 performance test

The same fio 3.38 direct/libaio, single-job, 1 MiB, 30-second QD1/QD8 tests
were repeated on `gen3_host_board_v6`. The baseline is the recorded qualified
Gen2 banked-DDR test; these are historical comparisons, not interleaved trials.

| Test | Gen2 MB/s | Gen3 MB/s | Change |
| --- | ---: | ---: | ---: |
| Read QD1 | 380.80 | 389.64 | +2.3% |
| Read QD8 | 428.65 | 433.82 | +1.2% |
| Write QD1 | 200.24 | 106.51 | -46.8% |
| Write QD8 | 259.17 | 121.38 | -53.2% |

All eight performance/integrity jobs passed, including both fresh CRC writes,
sector-offset verification, namespace flush and post-flush CRC. Exact write
accounting was 7,147,094,016 bytes. SMART media errors and error-log entries
remained zero; unsafe shutdown count was unchanged. Two startup attempts failed
before the successful benchmark boot; no benchmark I/O ran on those attempts.

That single-packet Gen3 implementation provided little read improvement and much
slower writes. Its single-outstanding transmit/replay path is a likely write
bottleneck, but attributing the measured loss requires profiling. The small
read gains are not statistically established by this single comparison.
See [the sanitized comparison evidence](evidence/performance-comparison.json).

Qualified Gen2 Linux was restored afterward; a 256 MiB CRC read passed and
the SSD was idle. The SD boot default was unchanged.

## Matching Gen2 transmit capacity

At the transmit-capacity stage, the host path reused `pcie_soft_replay` and
`pcie_soft_ack_capture` unchanged; normal-ACK retirement was optimized later. It retains eight TLPs in a 64-DWORD-per-slot synchronous-read BRAM
store, with two original packets allowed ahead of PCS submission completion.
The Gen3-specific `gen3_tlp_source` has two framing banks, allowing collection
and CRC calculation for the next packet to overlap transmission of the head.
Only one replay store is instantiated; there are no parallel Gen2/Gen3 copies.
The old `gen3_replay_tx` remains only as a historical standalone test reference.

| Capacity at this stage | Gen2 | Gen3 window revision |
| --- | ---: | ---: |
| Unacknowledged transmit TLPs | 8 | 8 |
| Transmit staging banks | 2 | 2 |
| DDR completion slots | 2 | 2 |
| Outstanding DDR AXI bursts | 2 | 2 |

Validated cumulative ACK/NAK processing alone retires replay slots. Native
PCS submission is an eligibility/progress event, not electrical wire proof.
Configuration requests keep their own sequence identity and still wait for
peer acknowledgment before delivering a queued completion to the requester.
Pauses do not reset ownership. Retry exhaustion remains quarantined; this
change does not implement full Recovery or resolve intermittent startup.

`check_tx_window.py` verifies eight retained packets, two occupied staging
banks, cumulative ACK, partial NAK replay, timeout, ACK during a stalled replay,
sequence wrap, partial-packet pause and invalid-ACK/retry-exhaustion quarantine.
It independently checks 4,109 framed packets against zlib LCRC and expected
payload/sequence values. Full experimental regression and six reused Gen2
replay/ACK/serializer tests also pass. Historical performance tables above
refer to the older single-outstanding image, not this new window.

The `gen3_window_board_v1` image passed full synthesis, routing and structural,
CDC, DRC and bus-skew audits. Gen3 setup/hold slack is +0.003/+0.010 ns (narrow
positive setup margin); Gen1 is +0.563/+0.010 ns. The shared replay payload uses
one RAMB18. Total utilization is 11,601 LUTs, 10,092 FFs, one RAMB36 and two
RAMB18s: approximately +400 LUTs, +113 FFs and +1 RAMB18 versus the earlier
single-packet image. No qualified Gen2 source changed.

The first temporary boot reached Gen3 NVMe operation. All eight matched fio
performance/integrity jobs passed, with exact write accounting of 14,127,464,448
bytes, successful flush, and unchanged SMART counters. Measured performance:

| Test | Qualified Gen2 MB/s | Single-packet Gen3 MB/s | Eight-slot Gen3 MB/s |
| --- | ---: | ---: | ---: |
| Read QD1 | 380.80 | 389.64 | 389.45 |
| Read QD8 | 428.65 | 433.82 | 433.82 |
| Write QD1 | 200.24 | 106.51 | 200.06 |
| Write QD8 | 259.17 | 121.38 | 260.49 |

The write regression is recovered to approximately Gen2 throughput. This
supports the earlier single-packet window as the main source of that slowdown;
it does not establish where the remaining throughput ceiling lies. Intermittent
legacy startup and full Recovery remain unresolved. See the exact build,
capacity, validation and restoration details in [the window evidence](evidence/tx-window.json).

Qualified Gen2 was restored and its 256 MiB CRC check passed after the window
test. The SSD was idle and the SD boot default was unchanged.

## RX64 receive path: physical performance test

The shared host receive path now packs link DWORD pairs before CDC and consumes
64 bits per 125 MHz host cycle through the pending queue and DDR payload
preparation. Full Gen2 and Gen3 builds passed route and reopened audits; Gen3
setup/hold slack is +0.062/+0.010 ns. Whole-packet validation and AXI ownership
remain enforced. This does not change the 32-bit completion transmit path.

Temporary physical tests passed all eight NVMe benchmark/integrity jobs on each
image. Gen3 read QD1/QD8 reached 612.22/741.81 MB/s, versus the prior eight-slot
RX32 image's 389.45/433.82 MB/s: +57.2%/+71.0%. Gen3 write QD1/QD8 remained
200.43/260.30 MB/s. The runs used the same direct/libaio, 1 MiB, one-job,
30-second settings. These are historical before/after comparisons. Gen2 QD8
read/write remained 428.68/260.14 MB/s.

Existing/fresh/sector-offset/post-flush CRC passed, write accounting matched
exactly, and SMART error and unsafe-shutdown counts were unchanged. A separate
read-only counter capture reproduced 738.75 MB/s with no DMA fault or overflow.
Gen3 booted on the first attempt in this test, but the known intermittent
startup issue remains unresolved. No new full Recovery, equalization phases 2/3,
compliance, cold-cycle or endurance qualification is claimed.

At the end of the RX64 trial, the running image was RX64 Gen2, with a further 256 MiB
read-only CRC pass. SD boot files still select the previous image.
[Implementation](../../docs/evidence/rx64_v1/implementation.json) and
[physical evidence](../../docs/evidence/rx64_v1/completion.json) record exact
hashes, results and limitations.

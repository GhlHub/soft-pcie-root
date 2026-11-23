# x2 development

The x2 implementation is integrated into `main`. Commit `4d99851` and the
annotated tag `x1-hardware-validated-2026-11-08` identify the x1 baseline
and its documented hardware validation scope.

The ZU15EG `gen1-x2` package connects the two-lane native PHY at X1Y4/X1Y5 to
the Gen1 x2 link, a fixed 64-bit link-side packet interface and the 128-bit
host/DDR path. All three staged ZU15EG profiles passed reopened route audits
and negotiated their intended rates on the physical board with a Samsung
990 EVO 1 TB. Read-only NVMe integrity and throughput checks passed at Gen1,
Gen2 and Gen3 x2. The successful Gen2 and Gen3 runs enabled PCIe before the
Linux driver probe. The ZU15EG version 1.2 catalog includes both x2 rate
backends and both x1 choices, with Gen1/Gen2 x1 as the default.
[ZU15EG catalog](../examples/zu15eg/README.md#vivado-ip-catalog)
[Gen1 x2 evidence](evidence/zu15eg_gen1_x2_v1/completion.json)
[Gen2 x2 evidence](evidence/zu15eg_gen2_x2_v1/completion.json)
[Gen3 x2 evidence](evidence/zu15eg_gen3_x2_v1/completion.json)

The [ZU15EG example](../examples/zu15eg/README.md) records physical Gen1, Gen2
and Gen3 x1 results. The [OOC measurement report](x2-resource-measurement.md)
describes the earlier standalone Gen3 x2 routes.

## Implemented component work

- `LANE_ID=0/1` in the Gen3 scrambler, training transmitter/receiver, native
  receiver and Recovery transmitter. Lane 0 remains the default. Lane 1
  uses its own seed and training lane number; receivers check that identity.
  These parameters identify a logical lane, not a physical pin. Lane reversal
  and the initial assignment must be resolved by the future common LTSSM.
- `pcie_lane_stripe`: configurable one/two-lane byte interleave/deinterleave.
  Data-stream bytes are consecutive across logical lanes; ordered sets must
  be generated per lane and never sent through this data-only mapper.
- `pcie_lane_deskew`: bounded per-lane candidate FIFOs, common-record tag
  checking, alignment deadline, sticky overflow/mismatch quarantine and
  candidate-only abort. Payload RAM is not reset. It accepts validated,
  descrambled records after SKP removal, not raw PIPE words. The same SDS
  epoch must supply the first aligned record of each lane. It is not an
  ordered-set classifier or a complete physical-layer deskew implementation.
- Independent byte mapping and scrambler oracles, two real training decoders,
  wrong-lane rejection, skew/stall/wrap/fault/reacquisition simulations and
  lane-1 Recovery wire/cadence/CRC/atomic-stop checks.
- ZU15EG target mapping recorded in the [example notes](../examples/zu15eg/README.md)
  from the companion board workspace, without changing that workspace.

Run focused checks with `.venv/bin/python -m pytest -q tests/test_multilane.py`.
The original x1 tests retain default parameters and independent oracles.

## Shared training and GUI development

- `gen3_multilane_startup` coordinates fixed-width Gen1 receiver detection,
  polling, width/link/lane assignment, per-lane polarity, Configuration and
  Recovery, including the Gen2 rate transition in the `gen2-x2` stage. Both
  lanes must qualify. The coordinator checks rate agreement, malformed TS,
  missing receivers and absolute Recovery deadlines. Logical lane
  order is fixed; lane reversal and width fallback are not implemented.
- `gen3_multilane_eq` coordinates real lane-specific Gen3 training codecs and
  Phase 1/2/3 engines. All lanes cross the Phase 1 barrier together; completion
  requires every lane. PHY loss, alignment loss, invalid training and shared
  deadlines defeat cached success. Configuration is sampled at attempt entry;
  cancellation requires a fresh entry. The Gen3 x2 port uses its equalization
  fields and per-lane coefficients in the continuous packet and training PCS.
- `LINK_WIDTH` metadata, GUI validation and HDL propagation support values 1/2.
  The deliberate `gen1-x2` stage sets `ENABLE_GEN3=1`, `LINK_WIDTH=2` and
  `X2_GEN1_BRINGUP=1`. It selects real serial vectors and the wide host
  interface while fixing the native PIPE rate at Gen1. The `gen2-x2` stage
  selects `X2_GEN2_BRINGUP=1` in place of `X2_GEN1_BRINGUP` and enables shared
  rate negotiation. The `gen3-x2` stage selects `X2_GEN3_BRINGUP=1` and
  qualifies both lanes through Gen3 startup. All other x2 combinations hit
  the elaboration guard.
- Independent Gen1 peers exchange real encoded training sequences with delayed
  lanes and polarity inversion. Gen3 peers generate lane-specific scrambled TS
  and exercise delayed/faulted lanes, configuration changes and cancellation.
  PHY adaptation is behavioral; analog equalization is not simulated.

Run focused training and GUI checks:

```sh
.venv/bin/python -m pytest -q tests/test_multilane_training.py tests/test_link_width_gui.py
make width-metadata VIVADO=/tools/Xilinx/2026.1/Vivado/bin/vivado WIDTH_METADATA_OUTPUT=build/width_metadata_next
```

The metadata command requires a fresh output directory.
This packages only parameter metadata from the actual root and exercises the
production GUI callback with real IPX objects. It does not generate a PHY or
validate a complete IP build. Root parameter tests blackbox unavailable vendor
modules only to exercise the guard; they are not root-port functional simulations.

## Gen1 x2 decoded-symbol link

`pcie_soft_link` uses the two-lane startup controller and a four-symbol packet
framer/parser when `LINK_WIDTH=2`. The receive path descrambles each lane,
removes corrected SKP ordered sets, and deskews the lanes before packet parsing.
The link retains the shared requester, flow control and replay ownership. Recovery
discards tentative receive data while preserving complete queued packets.

The independent peer exchanges configuration and memory traffic using both
lanes. It checks aligned operation, a three-cycle lane 1 delay, independent
SKP correction on each lane, bad CRC, replay and same-rate Recovery. The peer
also drives separate receiver-detect and fresh P0 acknowledgements through
the native PIPE adapter. The board stage connects the same adapter to the
generated PHY and uses the fixed-width x2 host path.

Run the link and PIPE checks with
`.venv/bin/python -m pytest -q tests/test_pcie_soft.py tests/test_legacy_x2_packets.py tests/test_legacy_x2_pipe.py`.
The first CDC-clean native Gen1 x2 checkpoint passed all **2,173** regression tests in
331.23 seconds. The synthesized board audit verified both GTH lanes, the
wide AXI path and the command and packet CDC structures, with zero
unwaived critical CDC findings.

The reopened route audit found DP0 and DP1 reversed at the generated PHY
interface. The native wrapper now maps the physical pins and each per-lane
PIPE data and status field to the corresponding logical lane. A simulation
using the generated PHY port signature reproduced the reversal with the
earlier wrapper and passed with the corrected one.

The native PHY broadcasts one TX power-ready status to both lanes. The
wrapper now synchronizes it once. It still requires each lane's receiver
detect and P0 acknowledgement. The corrected design passed synthesis and the
reopened timing, CDC and lane-pin audit. On hardware, two 256 MiB reads matched
the x1 checksum and the namespace write counters stayed constant. The
fixed-width DDR bridge ran at 125 MHz on Gen1 x2.

The decoded-symbol link routed out of context at 125 MHz on
`xczu15eg-ffvb1156-2-i` with +0.491 ns internal setup and +0.040 ns internal
hold slack, 5,967 LUTs, 2,413 registers and one RAMB18E2. The timing
report covers paths within the link. External ports, PHY and host CDC remain
outside this route. Reproduce with a fresh output directory:

```sh
python3 scripts/route_x2_blocks.py build/x2_gen1_link_ooc_next \
  --part xczu15eg-ffvb1156-2-i --targets pcie_soft_link
```

## Gen2 x2 decoded-symbol link

`gen3_native_x2_rate` issues the shared PIPE Rate command after both receive
lanes enter electrical idle. It waits for a low PHYSTATUS baseline, then
requires a fresh acknowledgement from each lane before applying the rate to
the link state machine. Separate tests cover stuck status, missing replies
and loss of transmit idle. The independent symbol peer qualifies Gen2 startup,
Gen2-to-Gen1-to-Gen2 Recovery with a configuration read pending, and packet
traffic with and without three cycles of lane skew. These tests model PIPE
status and train the digital link.

The first Gen2-enabled decoded link routed out of context at 250 MHz with
−1.740 ns internal setup slack and +0.041 ns hold slack. The worst path runs
from lane 1 training decode through receive alignment and the packet parser
to the NAK register. An input register isolated deskew and reduced the setup
violation to −1.074 ns. The Gen2 x2 stage now uses a word-oriented receiver.
It classifies starts and ends, aligns wire data into DWORDs, and registers
CRC and length results before publishing a packet. A complete frame already
in the pipeline survives an abort of the following candidate. A synchronous,
unreset RAM delivers one DWORD per cycle across queued packet boundaries.

The revised link routed at 250 MHz with **+0.367 ns internal setup**,
**+0.032 ns hold** and **+1.458 ns pulse-width** slack on
`xczu15eg-ffvb1156-2-i`. It uses 3,675 LUTs, 2,780 registers and 1.5 BRAM tiles.
The tests cover aligned and skewed rate changes, TLP and DLLP CRC faults,
truncation, nullified short words, queue exhaustion, and Recovery alongside
packet publication. PHY, PS integration and board timing are outside this
link-only route.

The first full board route passed the synthesized structure and CDC checks.
It measured −0.198 ns setup, +0.004 ns hold and +0.543 ns pulse-width slack.
The worst path runs from a GTH receive status output to a width adapter
clock enable. The next build registers PIPE data, control and status together
and uses fixed group shifts in the narrowing adapters. The adapters still
accept the next input beat on the edge that consumes the last output group.
That build passed the reopened route audit at 250 MHz (+0.194 ns setup) and
125 MHz (+0.351 ns setup), with +0.012 ns hold in both modes and zero
unwaived critical CDC findings. The endpoint reported 5.0 GT/s x2 over JTAG
and again in Linux during the read-only NVMe checkout. The first several
warm starts timed out. The successful test measured 472.23 and 589.85 MB/s
at QD1 and QD8. [Gen2 x2 hardware evidence](evidence/zu15eg_gen2_x2_v1/completion.json)

Reproduce the 250 MHz decoded-link timing run with a fresh output directory:

```sh
python3 scripts/route_x2_blocks.py build/x2_gen2_link_ooc_next \
  --part xczu15eg-ffvb1156-2-i --targets pcie_soft_link --legacy-gen2
```

## Gen3 x2 integration

The Gen3 stage negotiates the rate at Gen1. After EIOS and electrical idle,
Phase 0 requires fresh preset and coefficient-query acknowledgements from
both lanes. The shared PIPE controller then requires fresh rate-change
acknowledgements from both lanes before handing the wire to Gen3. The Gen3
transmit engines retain their cadence and scrambler position across Phase 1,
adaptive Phase 2/3, and Recovery. The packet path uses the same lane mapping
as Gen1 and Gen2 and presents 64-bit packet beats to the fixed-width x2
host path. Gen3 selection occurs before a legacy Data Link owner is active.

The bonded receiver removes lane-specific SKP, deskews matching ordered sets
and word positions, then validates EDS and whole-packet integrity across the
aggregate stream. The encoded peer tests cover Phase 0 with staggered lane
replies, adaptive EQ, configuration completion, and peer-initiated same-rate
Recovery with a configuration read outstanding. A local simulation using the
generated PHY port declaration also passed Gen1 receiver detect through Gen3
x2 packet I/O, including the board wrapper's lane remap and one same-rate
Recovery. The native scenario is now part of
`tests/test_gen3_x2_post_port.py`. It checks the transmitted Phase 0 preset
and eight EIOS sets on both lanes before the shared rate change, then
exchanges configuration and application packets. The transceiver responses
are behavioral.

The standalone Gen3 packet port passed its 250 MHz internal route with
+0.092 ns setup and +0.042 ns hold
slack after the TX LCRC transform was changed. The integrated native board
build passed packaging and synthesis. Registering the diagnostic source mux
on PCLK cleared the synthesized CDC findings. The next route reported
−0.404 ns setup and +0.001 ns hold slack. Its worst path passed from legacy
receive training through link admission into host transmit backpressure.
The buffered transmit boundary and shorter training, replay submission,
and fault paths reduced this to −0.143 ns across 53 endpoints. Post-route
optimization reached −0.033 ns across 24 endpoints. The current source
registers the Gen3 transmit scramble mask, computes the legacy scrambler
advance before symbol selection, and shortens the RX idle-prefix scan.
The resulting full Gen3 x2 board image passed reopened timing, CDC, pin,
and routing checks. Setup slack was +0.329 ns in Gen1 and +0.056 ns in Gen2
and Gen3. Hold slack was +0.010 ns in all modes. The full regression passed
2,486 tests. The initial physical run timed out in Configuration.Complete
while still training at Gen1.
[ZU15EG implementation evidence](evidence/zu15eg_gen3_x2_v1/implementation.json)

The startup correction retains each lane's eight qualified received TS2s
and rate fields until the local transmit requirement finishes. The new
finite-burst peer reproduces the receive-status race on the previous RTL
and covers the minimum receive count. The corrected route passed its
independent audit with +0.327 ns Gen1 and +0.006 ns Gen2/Gen3 setup slack,
and +0.012 ns hold slack in all modes. All 2,498 regression tests passed.
[Startup correction evidence](evidence/zu15eg_gen3_x2_v1/startup-qualification.json)

The board then reached Gen3 Phase 1. A diagnostic image captured a
continuation word without a block start on each lane before either aligned.
The decoder now discards these initial partial words until it sees a block
start and acquires a complete EIEOS. The same framing error remains fatal
after alignment. The wire-peer regression covers both cases.
[Physical equalization failure record](evidence/zu15eg_gen3_x2_v1/equalization-diagnostic.json)

The receiver correction passed all 2,502 regression tests and the reopened
audit with +0.555 ns Gen1 and +0.021 ns Gen2/Gen3 setup slack. The corrected
image reached 2.5 GT/s x2 when forced to Gen1. Automatic Gen3 warm trials
timed out in Polling.Configuration.
[Correction and warm trial evidence](evidence/zu15eg_gen3_x2_v1/receiver-boundary.json)

The passive Polling.Configuration diagnostic image passed that state on a
warm run and reached Gen3 adaptive equalization. The parallel packet receiver
could latch a framing fault on the initial partial block and carry the fault
into the post-equalization handshake. The integrated native PIPE peer reproduced
this post-equalization failure. The corrected receiver waits for the first
valid block start on each lane, and the same simulation completes configuration
and application traffic with and without a packet-active Recovery event.
[Polling diagnostic hardware trace](evidence/zu15eg_gen3_x2_v1/polling-diagnostic.json)

The exact corrected image passed the reopened audit with +0.139 ns Gen1
setup, +0.024 ns Gen2/Gen3 setup and +0.011 ns hold slack in all modes. The
full regression passed 2,510 tests. On a warm PL reload, Gen3 x2 reached L0
and Linux confirmed 8.0 GT/s on both lanes. Both direct 256 MiB reads matched
the lower-rate checksums. One 30-second 1 MiB sequential direct read job per
queue depth measured 668.04 MB/s at QD1 and 678.91 MB/s at QD8, with zero
writes and a healthy idle finish.
[Gen3 x2 implementation](evidence/zu15eg_gen3_x2_v1/packet-receiver-start.json)
[Gen3 x2 hardware evidence](evidence/zu15eg_gen3_x2_v1/completion.json)

## Further validation and packaging

1. Verify startup and sustained Recovery through the integrated native Gen3
   PHY, including bad or missing lanes, reversal policy, and block loss.
   Preserve all-lane qualification and accepted ownership.
2. Verify cold-start repeatability for the audited Gen2 and Gen3 x2 images.
3. Exercise the Gen3 x2 64-bit aggregate framing and replay with sustained
   traffic and compare it with the previous stages. The
   [RX repair](x2-rx-timing-fix.md) and the TX LCRC revision closed their
   respective standalone internal timing paths.
4. `pcie_x2_host_path` connects
   64-bit link beats through packet-preserving width adapters and whole-packet
   CDC to `pcie_ddr_bridge_x2`, with 128-bit packet and DDR AXI paths. It uses
   explicit final occupancy and four RAM banks, preserving byte enables,
   accepted AXI drain and all-B-before-MSI. The subsequent OOC host route met
   its internal constraints. Gen1 x2 verified the integrated wide host path.
   Sustained DDR throughput at Gen3 x2 remains to be measured separately
   from end-to-end NVMe throughput.
5. Add independent end-to-end x2 peer simulation covering Gen1 startup through Gen3,
   negotiated width/rate, per-lane EQ, sustained striped packets, token
   boundaries, corrupted lane data, finite credits, replay/NAK/sequence wrap,
   AXI stalls/errors, MSI ordering and packet-active Recovery. Cover all four
   catalog modes and validate parameter combinations during customization.
6. Route the version 1.2 catalog board designs, reopen checkpoints for
   timing and CDC audits, and verify negotiated links on hardware.

The widening in items 3 and 4 is a build-time choice, not a runtime response
to negotiated speed. Existing Gen1/Gen2 x1 and Gen3 x1 builds retain their
current packet, CDC and DDR AXI widths. Gen1 training or lower-rate operation
within a Gen3 x2 build must preserve its fixed interface widths and ownership.

The intended x2 capacities are 2 GB/s in each internal aggregate path and
about 1.97 GB/s per direction on the Gen3 wire before packet overhead. They
are architectural targets, not measured throughput. The existing x1 physical
results and frozen provenance manifests remain historical evidence only.

The encoding work follows the locally available Base Specification sections
4.2.2.3/4.2.2.4 and the lane deskew requirements in 4.2.4.11. The specification
file stays ignored. Public background on physical-layer responsibilities is
available in [AMD PG346](https://docs.amd.com/r/en-US/pg346-cpm-pcie/Physical-Layer).

## Validation checkpoint — 2026-11-08

- Full regression: **1,756 passed in 250.07 seconds**, including 35 new
  component checks. Command:
  `VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin .venv/bin/python -m pytest -q tests`.
- `make lint` with the same `VIVADO_BIN`: passed, including real-XPM elaboration.
- HDL format check: 133 files, zero changes required, token equivalence passed.
- `git diff --check`: passed.

An earlier run lacked the Vivado executable path and exposed the lane-check
mutation test's old source matcher. The path and matcher were corrected; the
full result above is the subsequent combined run. The negative mutation test
still proves that removing training lane qualification is detected.

No integrated x2 peer, IP customization, synthesis, implementation, CDC audit,
bitstream or board test is claimed by this checkpoint.


## Shared training checkpoint — 2026-11-08

- Full regression: **1,843 passed in 260.68 seconds**, including 87 new
  shared-training and GUI/parameter-guard checks. Command:
  `VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin .venv/bin/python -m pytest -q tests`.
- `make lint` with the same environment: passed for both training widths and
  existing RTL, including real-XPM elaboration.
- HDL formatting: 135 files checked, zero changes required; token equivalence
  passed. `git diff --check` passed.
- Vivado 2026.1 metadata-only check passed actual RTL inference, x1 default,
  1/2 range and production GUI-to-HDL propagation using real IPX objects.
  Local output: `build/x2_width_metadata_v1`; this is not a full IP build.

These results cover the separate shared training stages and guarded width
selection. At that checkpoint, integrated x2 startup/rate change, packets,
synthesis/implementation, CDC audit and physical verification remained outstanding.


## Gen3 x2 packet and host datapaths

These modules are exclusive to the future `ENABLE_GEN3=1, LINK_WIDTH=2`
backend. Existing x1 packet, CDC and DDR AXI widths remain unchanged. The only
functional shared-RTL edit is a default-preserving stored-beat width parameter
in `pcie_soft_replay`; its ownership and ACK-retirement logic is unchanged.

| Boundary | Data per beat | Occupancy |
| --- | --- | --- |
| Destriped RX stream | 64 bits | Eight consecutive bytes, no backpressure |
| Validated link TLP / replay input | 64 bits | `words=1/2`; non-final beats contain two DWORDs |
| Formatted TX stream | 64 bits | `words=1/2`; final unused DWORD is zero |
| Host packet / DDR AXI | 128 bits | Packet `words=1..4`; AXI uses byte strobes |

`gen3_x2_recovery_tx` feeds paired PCS transmitters with striped packet bytes
and lane-specific scrambling. Both lanes accept and retire the aggregate
beat together. A test checks two full beats, a one-DWORD final beat, and the
striped EDS token before SKP and stream shutdown. The transmit block routed
out of context at 250 MHz with +0.191 ns setup and +0.044 ns hold slack on
`xczu15eg-ffvb1156-2-i`. The Gen3 receive bonding, rate/equalization handoff
and root integration are pending.

The receive parser accepts eight bytes per valid cycle into a circular buffer,
with token/body and finish/next-token overlap. Predecoded token metadata,
registered packet events and synchronous packet RAM replace the initial
byte-unrolled implementation; see the [RX repair](x2-rx-timing-fix.md).
It checks paired x2 idle symbols, framing CRC/parity, end-of-block EDS placement, DLLP CRC, TLP LCRC/shape and sequence.
Nullification and candidate abort cannot discard committed packets. Its input
must already be descrambled, deskewed and checked for per-lane block/ordered-set
transitions; those PHY responsibilities remain in integration items 1/2.
The physical transmitter must still place framed output into lane blocks and
schedule ordered sets. Framed submission alone never retires replay ownership.

The link layer keeps low-volume configuration commands on the existing 32-bit
requester through explicit adapters. Application traffic, replay and formatting
remain two DWORDs per cycle. The host wrapper uses independent reset-release
chains for the link/host clocks and whole-packet FIFO publication. Only global
cold reset may clear their ownership; link pauses must not reset either side.
Host `link_active_i` and DMA admission must already be synchronized to host clk.

Buffering is explicit: eight replay slots retain up to 256 payload bytes each;
two formatter banks also hold 256 bytes each. RX validation retains sixteen
256-byte slots. Each CDC has four 256-byte packet slots. The DDR read window
increases from the Gen3 x1 eight RCB64 slots to sixteen (1 KiB of payload).
These capacities support the simulated traffic; measured DDR service latency
and sustained bandwidth are still needed before claiming sufficient buffering
or a throughput target. The initial OOC route exposed byte-unrolled parser and
RAM-inference problems. The subsequent [RX repair](x2-rx-timing-fix.md) closes
standalone internal setup timing; integrated timing and interface hold closure
remain outstanding.

`pcie_ddr_bridge_x2` starts from the reviewed x1 ownership implementation and
uses separate four-bank payload/read storage. Future ownership fixes must be
reviewed for both bridges. Packet memories remain unreset. Tests use independent
byte/address scoreboards rather than the widened logic as an oracle.

Run `make test-x2-datapath` and `make lint-x2`. The simulation covers all legal
x2 token offsets (and rejects idle-to-token starts on lane 1), corrupted CRC and
framing, nullification, queue overflow, candidate abort, uninterrupted traffic
through sequence wrap, credit/requester arbitration, ACK/NAK/retry ownership,
four DWORD address offsets, all MPS128 write lengths, byte masks, RCB64/4-KiB
reads, malformed requests, AXI stalls/errors and link-loss drain. Host CDC tests
exercise both 250/125 MHz clocks and an unequal clock ratio, plus paused clocks.
This is datapath simulation; full x2 PHY startup-to-I/O simulation remains item 6.


### Datapath validation checkpoint — 2026-11-08

- Full regression: **2,100 passed in 274.11 seconds**, including **257 new
  x2 datapath tests**. Command:
  `VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin .venv/bin/python -m pytest -q tests`.
- `make lint` with the same environment passed, including x1/x2 RTL and real-XPM
  elaboration. Final x2 lint and affected host-clock-crossing tests also passed.
- TX tests explicitly reject intra-packet formatter bubbles when output is
  ready and compare all framed bytes/LCRC against an independent oracle.
- HDL formatting: 147 files, token equivalence passed; `git diff --check` passed.

No synthesis, place-and-route, implemented CDC audit, board access or hardware
throughput measurement was performed. Items 3/4 supply simulated datapaths;
items 1/2/5 must connect them before the root can elaborate as x2, followed by
item 6 full PHY/startup-to-I/O simulation. The existing x2 root guard remains.

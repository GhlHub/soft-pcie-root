# x2 development

Work is on `dev/pcie-x2`. The preserved x1 baseline is commit `4d99851`,
annotated tag `x1-hardware-validated-2026-11-08`. That tag labels the existing
hardware-validated x1 lineage and its documented limits; it is not a new
hardware run or a frozen qualification of all development changes.

**This branch does not yet implement an integrated x2 root port.** The
catalog now exposes `LINK_WIDTH=1/2`, with x1 as the default and x2 root
elaboration explicitly blocked. Shared x2 training stages are simulated;
complete Gen1-to-Gen3 link startup and physical packet operation are not yet
integrated. The separate 64-bit packet and 128-bit host/DDR datapaths now have
functional simulation coverage; this is not a timing or throughput measurement.
The user subsequently requested local place-and-route resource measurements.
See [the OOC measurement report](x2-resource-measurement.md) for scope and
results. Integrated implementation and physical testing remain outstanding;
physical testing awaits the ZU15EG board.

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
  same-rate Recovery. Both lanes must qualify; rate agreement, malformed TS,
  missing receivers and absolute Recovery deadlines are checked. Logical lane
  order is fixed; lane reversal and width fallback are not implemented.
- `gen3_multilane_eq` coordinates real lane-specific Gen3 training codecs and
  Phase 1/2/3 engines. All lanes cross the Phase 1 barrier together; completion
  requires every lane. PHY loss, alignment loss, invalid training and shared
  deadlines defeat cached success. Configuration is sampled at attempt entry;
  cancellation requires a fresh entry. This is a separate equalization stage,
  not the outer rate-change LTSSM or packet handoff.
- `LINK_WIDTH` metadata, GUI validation and HDL propagation support values 1/2.
  x2 requires `ENABLE_GEN3`; the root has both a simulation fatal and an
  unresolved-backend elaboration guard. The root still has scalar serial ports and selects its existing x1 paths;
  separate x2 packet/host modules are not yet selected by the root. No x2 choice silently generates an x1 backend.
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

## Required integration work

1. Integrate the shared startup and equalization stages into a common PHY/rate-
   change LTSSM and packet handoff. Preserve shared deadlines, all-lane
   qualification, no-backend-reset-after-L0 and startup-only fallback ownership.
2. Generate an actual two-lane PHY with a common clock/reset/rate controller,
   per-lane PIPE/EQ interfaces and correct constraints. Connect classified
   records to deskew, including variable-length SKP removal and synchronized
   SDS/EDS handling. Verify bad/missing lanes, reversal policy and block loss.
3. **Datapath implemented, root/PHY integration pending:** Gen3 x2 aggregate
   framing/parser/formatter processes 64 bits per cycle. `gen3_data_rx_x2`
   validates complete packets before publication; `gen3_link_layer_x2` connects
   credit admission, requester arbitration, 64-bit replay and formatting. Only
   Gen3 x2 will select these modules. The subsequent OOC route found severe
   RX setup violations at 250 MHz; see [resource measurements](x2-resource-measurement.md).
4. **Datapath implemented, root selection pending:** `pcie_x2_host_path` connects
   64-bit link beats through packet-preserving width adapters and whole-packet
   CDC to `pcie_ddr_bridge_x2`, with 128-bit packet and DDR AXI paths. It uses
   explicit final occupancy and four RAM banks, preserving byte enables,
   accepted AXI drain and all-B-before-MSI. The subsequent OOC host route met
   its internal constraints; integrated timing, CDC and actual DDR bandwidth
   remain unverified.
5. Connect the existing GUI `LINK_WIDTH` to real serial port vectors, PHY
   selection, packet/AXI widths, interface metadata and constraints. Remove the
   explicit x2 elaboration guard only once the backend is connected and tested.
   Preserve x1 defaults and source identity.
6. Add independent end-to-end x2 peer simulation: Gen1 startup through Gen3,
   negotiated width/rate, per-lane EQ, sustained striped packets, token
   boundaries, corrupted lane data, finite credits, replay/NAK/sequence wrap,
   AXI stalls/errors, MSI ordering and packet-active Recovery. Test both GUI
   choices and reject unsupported parameter combinations during customization.
7. After source freeze and board availability, perform fresh package generation,
   implementation, independent checkpoint/CDC audit and board validation.
   Establish actual negotiated x2 width before attributing throughput to x2.

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

The receive parser consumes eight bytes each cycle, including token/body and
finish/next-token transitions. It checks paired x2 idle symbols, framing
CRC/parity, end-of-block EDS placement, DLLP CRC, TLP LCRC/shape and sequence.
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
or a throughput target. The subsequent OOC route confirms that byte-unrolled CRC/parser critical paths
and RAM inference require restructuring; see [measurements](x2-resource-measurement.md).

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

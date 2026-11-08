# x2 development

Work is on `dev/pcie-x2`. The preserved x1 baseline is commit `4d99851`,
annotated tag `x1-hardware-validated-2026-11-08`. That tag labels the existing
hardware-validated x1 lineage and its documented limits; it is not a new
hardware run or a frozen qualification of all development changes.

**This branch does not yet implement an integrated x2 root port.** The
catalog now exposes `LINK_WIDTH=1/2`, with x1 as the default and x2 root
elaboration explicitly blocked. Shared x2 training stages are simulated;
complete Gen1-to-Gen3 link startup, enumeration, packet operation and throughput
are not yet integrated.
Implementation verification and physical testing are deferred until the
ZU15EG board is available. No synthesis/place-and-route or board writes are
part of this checkpoint.

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
  unresolved-backend elaboration guard. The scalar serial ports and x1 packet
  paths have not been widened. No x2 choice silently generates an x1 backend.
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
3. Widen the aggregate Gen3 framing/parser/formatter path to 64 bits at
   250 MHz. Handle two DWORDs per cycle, all token/header positions, DLLP/TLP
   boundaries, CRC, packet validation, replay submission/completion and ACK
   retirement. A serializer into the existing DWORD parser cannot sustain x2.
4. Widen host packet CDC and DDR AXI to 128 bits at 125 MHz for the x2 build.
   Replace final-single-DWORD assumptions with explicit final-beat occupancy.
   Preserve byte enables, unaligned offsets, noncoherent DMA, accepted AR/AW/W
   drain, packet ownership and all-B-before-MSI. Evaluate prefetch and replay
   bytes using measured memory latency; a width converter alone is insufficient.
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
selection. Integrated x2 startup/rate change, packets, synthesis/implementation,
CDC audit and physical verification remain outstanding.

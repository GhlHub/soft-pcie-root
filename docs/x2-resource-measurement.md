# Gen3 x2 resource measurement — 2026-11-09

The RX result below is the original baseline. A subsequent
[RX repair](x2-rx-timing-fix.md) reduces it to 1,517 LUTs and one BRAM,
with +0.081 ns internal setup slack. Historical measurements are retained.

The user requested local place-and-route measurements after the simulated
Gen3 x2 datapath checkpoint. These runs use Vivado 2026.1 and
`xczu15eg-ffvb1156-2-e`, from the companion board mapping. The physical speed
and temperature grade still need confirmation from the device marking.

The x2 root elaboration guard remains in place. A complete integrated root
cannot yet be built: the two-lane PHY, outer rate-change controller and root
selection are unfinished. This measurement runs synthesis, placement, physical
optimization and routing on six separate out-of-context (OOC) blocks, using
unchanged RTL from `cdaa0e4`. It is not a full board implementation or physical
verification. Hardware testing still awaits the board.

## Method and limits

- All link/training blocks use a 4 ns clock. The host wrapper uses 8 ns host and
  4 ns link clocks. External port delays and board clock insertion are not
  specified, so slack only describes constrained internal paths.
- The host recipe bounds each Gray-pointer crossing with 4 ns datapath maximum
  delay and 4 ns bus skew. It cuts asynchronous reset to reset pins and the
  first diagnostic fault synchronizer input. It does not cut whole domains.
  Bundled RAM paths retain nominal related-clock timing; their asynchronous
  CDC timing is **not qualified** by this measurement.
- Each run copies RTL and scripts into a fresh immutable source snapshot and
  records SHA256 hashes. Routed checkpoints and detailed reports stay under
  ignored `build/`; the compact evidence records report hashes.
- Resource sums across separate routes are an estimate for these blocks only.
  Integration can change optimization and duplication. The PHY/GTH, PS, clock
  and reset infrastructure, complete root controls and other integration logic
  are excluded. No bitstream or board write is produced.

Reproduce all six block routes in a fresh directory:

```sh
python3 scripts/route_x2_blocks.py build/x2_ooc_next
```

Use `--targets` to select blocks and `--part` to change the device. The script
rejects an existing output directory. Review `results.json` for completion and
individual timing/DRC/CDC reports for violations; route completion does not
mean timing closure.

## Results

All six blocks completed routing with zero routing errors. The sum is
**115,054 LUTs (33.71%) and 51,710 registers (7.58%)**,
plus one block RAM tile (0.13%) and no DSPs. LUT counts include 652 memory LUTs.
This is a subtotal of separate blocks, not integrated device utilization.

| Block | LUTs | Registers | BRAM tiles | Setup slack (ns) | Hold slack (ns) |
|---|---:|---:|---:|---:|---:|
| `gen3_data_rx_x2` | 75,320 | 33,181 | 0 | -24.489 | +0.042 |
| `gen3_link_layer_x2` | 16,095 | 6,546 | 1 | -0.013 | +0.039 |
| `pcie_x2_host_path` | 20,604 | 9,882 | 0 | +1.025 | +0.038 |
| `gen3_multilane_startup` | 209 | 135 | 0 | +1.171 | +0.043 |
| `gen3_multilane_eq` | 2,624 | 1,362 | 0 | +0.045 | +0.044 |
| `pcie_lane_deskew` | 202 | 604 | 0 | +1.793 | +0.046 |

All blocks have zero unclocked registers and zero unconstrained internal
endpoints in `check_timing`; external I/O timing remains unconstrained.
RX, TX/link and host each report the OOC no-routable-loads DRC warning
(RTSTAT-10); no DRC errors are reported. Other blocks have no DRC findings.

Measurements and report hashes: [measurement.json](evidence/x2_ooc_v1/measurement.json).
Frozen input hashes: [source-manifests.json](evidence/x2_ooc_v1/source-manifests.json).
The non-host results are from `build/x2_ooc_route_v1`; the host result is
from `build/x2_ooc_host_route_v5`, which supersedes the earlier host runs
with the final constraint recipe. RTL hashes match across both snapshots.

### Findings

The RX buffer failed RAM inference: its two writes in one clocked process
expanded 1,024 × 32 bits into 32,768 registers. The final RX route uses no
block RAM. Its worst path runs from `state_q_reg[0]` to
`memory_reg[223][9]`, through 95 logic levels, with 28.472 ns data delay
(8.719 ns logic, 19.753 ns routing). There are 33,304 failing setup endpoints.
Repairing memory inference and restructuring/pipelining the byte-unrolled
parser are prerequisites for 250 MHz operation. Packet RAM must remain
unreset and whole-packet validation/publication must be preserved.

TX/link control has one failing setup endpoint, from replay sequence state
to the formatter checksum memory, at −0.013 ns. This is still a timing
failure, despite being much smaller than the RX violation.

The host CDC report contains one critical CDC-10 finding for combinational
logic before `tx_fault_sync_reg[0]`, four CDC-6 Gray-bus warnings and 276
CDC-15 bundled-data warnings. The four reported Gray-bus skew values range
from 0.337 to 0.469 ns against 4 ns bounds. These figures do not replace an
independent ownership/CDC audit, including the diagnostic synchronizer and
bundled RAM crossings. Nominal internal timing success is not CDC sign-off.

No RTL was changed for this measurement. The earlier 2,100-test regression
remains the functional checkpoint; it was not rerun for documentation and
build-script additions. No hardware throughput claim follows from these
resource counts.

# Gen3 x2 RX timing repair — 2026-11-09

The first x2 RX route exposed two architectural problems: an eight-byte
serial combinational parser and failed packet RAM inference. The baseline
used 75,320 LUTs and 33,181 registers, with −24.489 ns setup slack at 250 MHz.
That result is retained in [the original measurement](x2-resource-measurement.md).

## Architecture

The revised `gen3_data_rx_x2` has three distinct stages:

1. A 32-byte circular ingress buffer stores eight bytes per valid cycle.
   Idle/nullifier classification and token validation are computed at ingress.
   Token metadata is stored for each possible halfword position. Tokens that
   cross an input beat are decoded when the next valid beat arrives; the parser
   cannot consume them until all four bytes are buffered. Data, block positions
   and metadata share the same buffer epoch and are not reset.
2. A word-oriented parser emits registered packet events. It can consume a
   four-byte STP and eight body bytes together, process eight body bytes per
   cycle, and finish a prior packet while starting the next. Nullifier/token
   overlap and minimum-packet streams do not need inserted idle gaps. The
   overflow check uses exact even-byte occupancy cases rather than an arithmetic
   chain after token selection.
3. Packet CRC/length/sequence validation operates on the registered events.
   Payload writes are registered into a 512 × 64-bit simple dual-port RAM in
   the default geometry. Its synchronous read port can deliver consecutive
   64-bit beats, with stable data and metadata under backpressure.

The complete declared body, LCRC, header length, nullification and sequence
checks still precede publication. Duplicate ACK and future-sequence NAK
behavior are retained. Abort/start discard ingress and the current candidate;
committed packets, queue readout and expected sequence survive. A registered
RAM write already belonging to a committed packet must not be cancelled by a
later abort. Payload RAM is never reset. Only global cold reset clears queue
ownership. Existing x1 RTL, TX, host/DDR paths and the x2 root guard are unchanged.

The default queue remains sixteen slots of 64 DWORDs. Small parameterized queues
can reject traffic when full; the sustained-rate checks use the default geometry.
No DDR bandwidth, full-root timing or physical throughput claim follows from
this standalone RX result.

## Verification

Vivado 2026.1, `xczu15eg-ffvb1156-2-e`, 4 ns link clock, default sixteen
64-DWORD slots. Final local output: `build/x2_rx_fix_route_v6`.

| RX metric | Original route | Repaired route |
|---|---:|---:|
| LUTs (including LUT memory) | 75,320 | 1,517 |
| Registers | 33,181 | 496 |
| BRAM tiles | 0 | 1 |
| DSPs | 0 | 0 |
| Internal setup slack | −24.489 ns | +0.081 ns |
| Internal hold slack | +0.042 ns | +0.047 ns |
| Worst setup data delay | 28.472 ns | 3.900 ns |
| Worst setup logic levels | 95 | 14 |

All 2,078 routable nets are routed, with zero routing errors. Setup/hold failing
internal endpoints are zero; no clocks or internal timing endpoints are missing.
The OOC no-routable-loads warning (RTSTAT-10) remains; there are no DRC errors.
The 81 ps setup margin is narrow and does not guarantee integrated timing.

The reopened zero-delay interface audit (`build/x2_rx_fix_audit_v6b`) also
reports +0.081 ns setup slack, with all input/output delays specified. It
reports **−0.135 ns hold slack on 338 input-origin paths**: 330 from `data_i`,
four from `position_i`, two from `start_stream_i`, and two from `valid_i`.
No violating path starts at an internal register. OOC input stubs have no
real upstream clock-to-Q or route delay; the audit deliberately assumes zero
minimum arrival delay. This is not interface hold sign-off. Real PHY clocking,
input delays and hold closure remain integration work; no false paths or
multicycle exceptions were added to make RX timing pass.

Final frozen-source regression: **2,153 passed in 290.42 seconds**, including
53 new RX tests.
Verilator lint/real-XPM elaboration passed. HDL formatting checks cover 147
files with token equivalence; the RX-specific tests cover 171 cases.

Compact measurements and source/report hashes are in
[evidence/x2_rx_fix_v1/measurement.json](evidence/x2_rx_fix_v1/measurement.json).

New independent-stream tests cover sustained nullified traffic at several
alignments and lengths, minimum-size packets, EDS without following input,
valid-input bubbles and DLLP bursts, aborts at different pipeline positions,
committed-packet read throughput, and parameterized queue/storage wrap.
Existing corruption, replay/duplicate, sequence-wrap, queue-full and stalled
output checks remain in the regression.

Reproduce the route and additional timing audit with fresh output directories:

```sh
python3 scripts/route_x2_blocks.py build/x2_rx_next --targets gen3_data_rx_x2
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch \
  -source scripts/audit_x2_rx.tcl \
  -tclargs build/x2_rx_next/gen3_data_rx_x2/routed.dcp build/x2_rx_next_audit
VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin .venv/bin/python -m pytest -q tests
VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin make lint
```

The primary route uses the same OOC 4 ns clock as the baseline. The additional
reopened-checkpoint audit applies zero input/output delays relative to that
clock, including input-to-register predecode paths. These are ideal boundary
budgets, not a model of the future PHY or board clocks. Integration must allocate
real interface delays and close timing again. Hardware testing remains deferred
until the ZU15EG board is available. The earlier TX/link −0.013 ns violation and
host CDC review are separate outstanding items.

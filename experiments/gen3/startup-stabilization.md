# Gen3 startup correction

The startup-corrected unified 1.1 image passed ten controlled warm-start trials on
ZCU104 with the OP047 adapter and Samsung 990 EVO. Every trial negotiated Gen3 x1,
enumerated NVMe and verified an existing 256 MiB CRC32C pattern using direct,
read-only I/O. Total verified data was 2.5 GiB. SSD writes were zero; SMART media
errors, error-log entries and unsafe-shutdown counts did not increase.
[Exact implementation and physical evidence](../../docs/evidence/startup_fix_v1/completion.json).

## Failure and correction

The failure occurred during initial Gen1 link negotiation in the experimental
Gen3 backend, before the transition to Gen3 speed and equalization. Stabilizing
this stage required preserving completed receive qualification while local
transmission finished. This correction did not change equalization presets or
extend training timeouts; the separate Gen1/Gen2 backend is unchanged.

Configuration.Complete requires eight consecutive qualified received TS2s and
completion of the local transmit requirement. Previously, the receiver's good-TS
counter was cleared when the peer started sending logical idle. If this coincided
with the local transmit counter reaching sixteen, neither cycle satisfied both
conditions together. The state subsequently timed out and returned to Detect.

The corrected experimental startup LTSSM retains the completed receive
qualification until it leaves Configuration.Complete. Before eight matching TS2s,
malformed or mismatched sequences still clear the count. Unsupported control
requests, PHY loss and synchronous reset retain their existing behavior. No
packet RAM, replay ownership, DMA ownership or accepted-AXI drain behavior changed.

The earlier peer model kept sending TS2s until the DUT advanced, hiding this
window. The new finite-burst peer enters idle independently. The original RTL
fails the sixteen-TS2 case; the corrected RTL passes it and the eight/twenty-four
cases, while rejecting seven TS2s. Seven additional guard cases check malformed
sequences, lane/rate/control mismatches, unsupported controls after qualification,
PHY loss and reset. The tests also cover the existing equalization fault cases
and Recovery/data-link bring-up.

Run the 25 focused cases with:

```sh
.venv/bin/python -m pytest -q tests/test_gen3_startup.py
```

All 74 repository tests, lint and XPM elaboration passed. The native root also
exposes passive `LGS1` legacy state history through the existing diagnostic CDC;
see [register decoding](../../docs/registers.md#experimental-gen1-startup-diagnostics).

## Implementation and board test scope

Fresh package and full board synthesis passed. The initial route missed setup
by 0.028 ns and withheld its bitstream. A subsequent
`phys_opt_design -directive AggressiveExplore` followed by
`route_design -directive Explore` on the same frozen design closed timing. The
result was written to fresh outputs and independently reopened and audited.

| Mode | Setup slack | Hold slack |
| --- | ---: | ---: |
| Gen3 | +0.002 ns | +0.011 ns |
| Gen1 startup | +0.427 ns | +0.011 ns |

Resources: 11,341 LUTs, 10,411 FFs, 536 control sets, two RAMB36, one RAMB18 and
one GTH. CDC, bus skew, DRC, routing, structure and source-manifest checks passed.
The image retains the 64-bit host packet path and eight read-prefetch slots.

Each physical trial flushed and cleanly halted Linux, performed a system warm
reset, independently verified the pre-kernel CPU stop, programmed the audited
bitstream, then resumed Linux. Trial 4 required a debugger resume retry while the
CPU remained at kernel entry; trial 5 required a target-enumeration retry before
programming. Neither caused another link-training attempt. No failed Gen3 link
startups occurred in the ten completed trials.

The board was left running the corrected Gen3 image. SD boot files remain
unchanged, so a normal reboot restores the historical Gen2 SD default. No new
throughput benchmark was run; earlier performance figures belong to earlier images.

Ten warm starts are a bounded test, not proof that every possible startup failure
is eliminated. Cold power cycling, temperature variation, endurance and compliance
remain unqualified. Full PCIe Recovery remains incomplete, and +0.002 ns is a very
narrow Gen3 setup margin.

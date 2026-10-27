# Experimental Gen3 Recovery and receive-path bring-up

This record describes its named historical investigation stage. For the latest
full-host design and measured results, see [performance history](../../docs/performance-history.md).
Statements about unchanged sources or a restored board refer to that stage.

This extends the Phase 1 diagnostic through Recovery.RcvrLock,
Recovery.RcvrCfg and Recovery.Idle. It is still an isolated, temporary JTAG
experiment. The original idle-only image had no PS, AXI, DMA or transmit
TLP/DLLP interface. Later diagnostic stages add DLLP/TLP transmission as
described below. The qualified Gen1/Gen2 release and SD default are unchanged.

The latest [Data Link configuration-read evidence](evidence/datalink-config-read.json)
records three successful Gen3 configuration reads, InitFC1/2, UpdateFC and ACK
exchange with valid packet CRCs. These trials contain no DMA. Current full-host
integration status is maintained in the [experimental README](README.md#data-link-and-host-integration-status).

## Physical result — 2026-10-26

The `gen3_recovery_board_v6` image reached logical-idle L0 in all five P4
trials on the ZCU104/OP047 and Samsung 990 EVO. Each completed Phase 1,
received 33–35 valid TS2s and reached Recovery.Idle/L0 without a Recovery
failure or clock-watchdog fault. Measured PCLK was 250 MHz.

No CRC-validated DLLPs were captured during the one-millisecond observation
window. This meets our local physical idle-entry criterion; it does not establish peer
L0, Data Link initialization,
sustained traffic or Gen3 NVMe operation. Each attempt counted two receive-error
pulses before the monitored RcvrCfg/Idle/L0 states; an error in those states
would have terminated the attempt with failure 11. These five successful starts
do not supersede the earlier evidence of intermittent Gen1 startup.

Final routed timing was +0.041/+0.012 ns setup/hold at Gen3 and
+0.610/+0.012 ns at Gen1. Utilization was 5,253 LUTs, 6,230 FFs and one GTH,
with no BRAM, URAM, DSP or PCIe controller hard block. Critical CDC checks
passed; reviewed Gray-counter and held-data crossings remain explicitly bounded.
The full experimental regression passed with the final source.

Linux was flushed and halted before temporary JTAG programming. The qualified
Gen2 image was restored afterward; Linux enumeration and a 16 MiB direct SSD
read passed. The SD boot files were unchanged.

Exact hashes, trials and limitations are in
[the compact evidence](evidence/recovery-idle-bringup.json). Raw laboratory
captures and the frozen source snapshot remain under ignored build output.

## Passive RX follow-up — 2026-10-26

The `gen3_rx_diag_board_v3` image adds an ILA and activity counters. The first
full-rate transition capture and three subsequent qualified captures all reached
local L0. The transition trace shows valid SDS/idle progression without native
RX or parser errors. Its full-trial counters recorded 250,152 RXVALID cycles,
246,304 PHY data-valid and accepted words, 245,493 decoded DWORDs and 61,374
Data Blocks. Framed DLLP and DLLP CRC-failure counts were both zero.

Three captures qualified on decoded-valid and nonzero data retained 168, 167
and 168 words across the complete trial, including the final stream close.
Every retained word was EDS (`0090801f`); all other decoded data was logical
idle. Thus no packet tokens reached the decoder, rather than DLLPs merely
failing CRC or being discarded by the packet parser. Continuous accepted-word
counts also rule out a receiver that simply stopped forwarding data.

This still does not identify the peer's internal LTSSM state. In particular,
the SSD can send idle while waiting in Recovery.Idle for our transmitted
SDS/idle stream. The local draft's section 4.2.6.4.5 gives that state a 2 ms
timeout, longer than this diagnostic's 1 ms observation. A useful next test is
a TX-side SDS/idle trace plus an observation longer than 2 ms, before assuming
the peer reached L0 or adding multiple new protocol features.

The ILA changed placement enough to expose a transmit DC-balance timing path.
A mathematically equivalent small-disparity calculation removed a serial wide
addition; simulated before/after TX traces were byte-for-byte identical.
The final full regression passed. Final setup/hold slack was 0.000/0.011 ns
at Gen3 and 0.180/0.011 ns at Gen1: passing, but with effectively no reported
Gen3 setup margin. The diagnostic uses 7,481 LUTs, 10,752 FFs, 71 RAMB36 and
one RAMB18, primarily for trace storage. No critical CDC or DRC failures.

[Compact receive evidence](evidence/receive-idle-diagnostic.json) records the
source hashes, counters, trace summaries and limitations. Raw captures remain
private under ignored build output. The qualified Gen2 Linux image was restored;
NVMe enumeration and a 16 MiB direct read passed, with zero outstanding I/O.
SD boot files were unchanged. This does not upgrade the qualified release.

## TX trace and extended observation — 2026-10-26

`gen3_tx_observe_board_v9` extends the observation to 5 ms and captures the
native TX interface. Five trials reached local L0 and completed the observation;
two additional attempts timed out during Gen1 startup. All Gen3 trials had
failure code zero and no CRC-validated DLLPs. The dedicated post-L0 training
trigger never fired. Its untriggered export is not treated as valid trace data.

An independent decoder acquired the captured TX EIEOS and checked the subsequent
continuous scrambler sequence. The trace contained 24 TS2s, one SDS, 1,506 Data
Blocks and six SKPs, with no framing, SDS, TS2-field, idle-data, SKP-state or
parity errors. The last TS2 ended at sample 2050, SDS at 2054 and the first
Data Block at 2058. This verifies the captured fabric-to-PHY words, not the
serialized electrical signal or the peer's internal receiver.

The stop-triggered trace reached local L0 cycle 1,250,000, confirming 5 ms at
250 MHz. That trial accepted 1,230,920 PHY words and decoded 1,227,449 data
DWORDs, with zero framed DLLPs and zero DLLP CRC errors. Two captures qualified
on decoded-valid/nonzero data each retained 833 EDS words across the entire
trial. There were no other nonzero decoded data words or packet tokens.
No received training event was detected after local L0 in the dedicated trial.

These results weaken the hypothesis that the SSD is waiting in Recovery.Idle
and then taking its 2 ms timeout. They do not prove its internal L0/Data Link
state or establish the reason for missing DLLPs. The next useful experiment is
a bounded InitFC transmit exchange with receive credits backed by actual storage,
before introducing TLP/replay or host traffic. Missing our transmit InitFC alone
still does not explain the absence of peer InitFC under the specification rules.

The larger trace exposed a tight TX population-count path. A balanced nibble
count and adder tree preserved the simulated native TX trace byte-for-byte;
the full experimental regression passed. Final Gen3 setup/hold was 0.000/0.011 ns,
Gen1 0.199/0.011 ns. Reported Gen3 setup margin is effectively zero. The image
uses 6,865 LUTs, 9,456 FFs and 93 RAMB36s, predominantly trace storage.

One generated ILA configuration crossing required explicit review. It connects
the storage-qualification comparator's configuration SRL to its four-stage
capture-clock path. Its predicate is programmed before arming and held fixed
throughout capture. `audit_ila_config_cdc.tcl` checks the exact source, destination,
clocks, check ID and four stage names before creating that one diagnostic waiver;
it rejects every other unreviewed critical crossing. This is an independently
reviewed held-configuration exception, not a blanket AMD-IP waiver. The default
board recipe retains its strict rejection; the final checkpoint was audited and
finalized separately, with the finalization script and waiver archived beside it.
Before/after CDC reports, frozen source snapshots and all rejected builds remain
in ignored build output. No timing-failing or unaudited image was programmed.

The qualified Gen2 image was restored after testing. Linux NVMe enumeration and
a 16 MiB direct read passed, with zero outstanding I/O afterward. SD boot files
were unchanged. [Compact evidence](evidence/tx-idle-extended-observation.json)
records all seven attempts, exact hashes, TX decode and receive counters.

## Integration

`gen3_recovery_tx.sv` keeps a single scrambler and cadence across TS1, TS2,
SDS and logical-idle Data Blocks. It inserts EDS before in-stream SKP or the
final EIOS. A separate scrambler initialized at the training/Data handoff would
not preserve the wire sequence. This source has no packet ownership to retire;
it does not resolve the physical-completion contract of `gen3_tx_path.sv`.

`gen3_native_rx.sv` accepts the native PHY's DWORD, block-start, sync-header
and valid signals. It acquires on a complete EIEOS, validates TS1/TS2, starts
Data reception after SDS, and checks in-stream SKP parity and LFSR state.
The connected `gen3_data_rx.sv` validates framing, DLLP CRCs and whole TLPs.
Its buffered mode uses `gen3_stream_buffered_rx.sv`, a sixteen-byte circular
ingress buffer with parallel aligned token decoding and DWORD payload output.
This avoids the original four-byte combinational state-machine chain. The
original byte parser remains available for component/reference tests.
The packet gate selects a DWORD-input mode with the buffered parser: body
beats are four bytes, STP and body are separate, and finish follows the last
body beat. It performs a parallel DWORD CRC update and prepares header/declared
length checks ahead of commit. Interface violations quarantine the candidate.
The byte-input gate remains available and both modes pass the ownership tests.
SKP resumption requires an EDS recognized by the packet parser, not merely an
EDS-looking payload DWORD. Malformed block starts/headers, missing EDS,
ordered sets directly after SDS, and malformed SKPs abort the provisional
candidate. Committed receive ownership is preserved in the RTL/simulation.
The diagnostic consumes packet outputs without host effects; synthesis can
remove their unused storage. It is not a physical packet-ownership test.

The optional `RECOVERY_ENABLE` mode of `gen3_eq_bringup.sv`:

- Waits for eight qualifying post-equalization TS1/TS2 sequences.
- Sends TS2 and requires eight matching peer TS2s with speed-change clear.
- Requires at least sixteen transmitted TS2s after receiving a peer TS2,
  with the transmit count restarted by an intervening EIEOS.
- Sends SDS and logical idle; requires eight received idle symbols and
  sixteen transmitted idle symbols after receiving idle before recording L0.
- Observes for a bounded interval, then sends EDS/EIOS and stops.

Phase 2/3 remain skipped. Recovery timeouts/errors stop this diagnostic;
there is no automatic full-link fallback or reset of a live owned data path.
The old equalization-only mode remains the default for component tests.
The board wrapper selects the extended diagnostic.

## Reproduce simulation

```sh
python3 experiments/gen3/check_native_rx.py
python3 experiments/gen3/check_recovery_tx.py
python3 experiments/gen3/check_recovery_bringup.py
python3 experiments/gen3/check_all.py --spec /path/to/local-draft.pdf
```

The receive oracle independently constructs scrambled wire bytes and CRCs.
It covers all five SKP lengths, delivery gaps, malformed headers, SKP parity
and state errors, missing EDS, illegal post-SDS transitions and premature
block starts. A committed TLP is held under output backpressure across each
later error and must drain intact. The transmit oracle independently decodes
TS1/TS2, SDS, idle, EDS, SKP and EIOS across the continuous scrambler state.
The integration test also checks missing TS2, malformed TS2 identifiers and
missing peer SDS/idle timeouts. The buffered parser passes 208 semantic framing
cases, while native RX tests cover all sixteen TLP start offsets and the
shortest SKP turnaround. A one-cycle deferred EDS check accommodates the
buffered parser latency; an invalid transition suppresses the following data
word and aborts the provisional candidate.
The modeled partner is not an independent serial transceiver/VIP model.

## Diagnostics

The original status layout remains, with added macro states 16 RcvrCfg,
17 Recovery.Idle and 18 logical-idle L0. Terminal states remain 14 finished
and 15 failed. Additional failure codes are 8 post-EQ lock timeout,
9 TS2/configuration timeout, 10 idle timeout and 11 receive/PHY failure.
These are diagnostic state codes, not software-visible PCIe capability bits.

Before entering Recovery.Idle the second 128-bit snapshot remains the last
training sequence. After that point it contains:

| Bits | Meaning |
| --- | --- |
| 127:96 | `52454333` (`REC3`) |
| 95:80 | Valid received DLLP count, saturating |
| 79:64 | Receive-error count, saturating |
| 63:32 | Last CRC-validated DLLP body |
| 31:24 | Current consecutive received idle-symbol count |
| 18 | Receiver Data Stream state |
| 17 | Sticky logical-idle L0 reached |
| 16 | Sticky Recovery.Idle reached |
| 15:0 | Valid TS2 count, saturating |

DLLP/error counters freeze when stopping. L0 here means the physical-layer
idle criterion only: the diagnostic does not complete Data Link initialization,
exchange flow-control credits or issue NVMe commands.

## Passive receive trace

The board build enables `GEN3_RX_DIAGNOSTICS`: an 8,192-sample, thirteen-probe
ILA on PCLK, with one input pipeline stage and optional capture qualification. Only probes
1, 2 and 11 have trigger comparators; the other probes capture data only.
It does not change transmit behavior. All custom counter resets are synchronous.
Counters cover RcvrCfg, Recovery.Idle and local L0, freeze outside those states,
and clear on the next isolated trial reset. They are 32-bit counters; the bounded
handshake/observation duration cannot overflow them.

| Probe | Meaning |
| --- | --- |
| 0 | Raw native PHY RX DWORD |
| 1 | Descrambled RX DWORD; meaningful with event bit 17 |
| 2 | Events/status, layout below |
| 3 | Cycles with PHY RXVALID |
| 4 | Cycles with PHY RXDATAVALID |
| 5 | Accepted RX pipeline words |
| 6 | Decoded Data DWORDs |
| 7 | Accepted Data Block starts |
| 8 | Complete framed DLLPs before CRC checking |
| 9 | DLLP CRC failures |
| 10 | Native TX DWORD presented to the PHY |
| 11 | TX/events layout below |
| 12 | Current macro-state elapsed PCLK cycles |

Event probe: bits 4:0 state; 6:5 rate; 7 RXVALID; 8 RXDATAVALID;
9 native block start; 11:10 native sync header; 12 PHY ready; 13 RX electrical
idle; 14 accepted pipeline valid; 15 aligned; 16 stream-start event;
17 decoded DWORD valid; 18 receiver stream active; 19 packet parser active;
20 parsed EDS; 21 received EIOS; 22 native receive error; 23 parser error;
24 validated DLLP; 25 framed DLLP before CRC; 26 framing error;
27 packet-gate error; 28 DLLP CRC error; 31:29 reserved zero.
TX/events probe: bit 0 TX valid; 1 TX block start; 3:2 TX sync header;
4 TX electrical idle; 5 experiment reset; 10:6 macro state; 12:11 rate;
13 PHY ready; 14 TX TS2 complete; 15 TX EIEOS complete; 16 TX idle DWORD;
17 RX stream start; 18 native RX error; 19 parser error; 20 RX EIOS;
21 RX training event; 22 valid TS1; 23 valid TS2; 24 RX aligned;
25 RX stream active; 31:26 reserved zero. These probes observe the native
fabric-to-PHY interface, not the serial lane. The board now selects a 5 ms
observation (`OBSERVE_CYCLES=1250000`), exceeding the 2 ms Recovery.Idle timeout.
Historical V6 and passive-RX V3 results above used 1 ms.

Raw and decoded data belong to different pipeline stages. Use their respective
valid signals, not a same-row comparison, when analyzing captures.

The local preliminary specification, sections 3.2.1 and 3.3.1, requires FC_INIT1
transmission independently of receiving peer InitFC1, with each P/NP/Cpl triplet
at least every 34 microseconds excluding Recovery/Configuration time. Missing
local transmit FC initialization prevents completion but does not by itself
explain zero received DLLPs. The earlier V6 image lacked raw activity counters;
its zero validated count cannot distinguish silence from filtered RX traffic.

## Remaining full-root integration

Connect transmit framing, DLLP/flow-control initialization, ACK/NAK/replay and
native PHY completion without retiring replay ownership at mere PCS acceptance.
Add live Recovery/fallback with accepted-AXI drain, connect the host/CSR path,
and qualify independent full-link behavior and physical I/O before advertising
Gen3 support in the released root port.


## Bounded InitFC1 probe

The next diagnostic image transmits VC0 InitFC1-P, InitFC1-NP and InitFC1-Cpl
triplets after the local Recovery.Idle exit. Each DLLP occupies the first eight
bytes of a Data Block, with idle in the remaining bytes. Packets are spaced by
at least 1024 PCLK cycles; at 250 MHz a triplet repeats in approximately 12.5 us.
Scrambling, parity, SKP insertion and EDS/EIOS closure remain active. A stop
request completes an already-started DLLP before closing the stream.

Advertised credits are PH=1, PD=8 (128 bytes), NPH=1 and NPD=1. The existing
16-slot, 64-DWORD packet queue backs these advertisements, remains stalled
throughout the experiment, and retains validated packets across stream abort.
After transmission stops, the queue drains to the diagnostic trace, whose new
probe 13 observes every output DWORD; TX event bits 26/27 indicate valid/last.
Packet RAM is not reset. An unexpected packet response terminates the test with
failure code 12; this does not reset accepted ownership. Completion credits use
the root-port infinite encoding (zero), with no outbound requests and therefore
no legitimate outstanding completions. This is not a general completion sink.

This probe deliberately never transmits InitFC2, ACK/NAK, UpdateFC or TLPs. It
does not complete Data Link initialization or establish a usable Gen3 root port.
The purpose is to determine whether the SSD responds to valid local InitFC1.
The finite observation window and cold isolated trial reset remain required.

The full simulation regression passes, including five InitFC1 stop timings,
ordered credit triplets, CRC, wire scrambling, SKP parity and triplet spacing.
The three wire packets also match the pinned cocotbext-pcie DLLP encoder.
The physical test completed four successful five-millisecond Gen3 observations;
two additional attempts timed out during Gen1 startup. Each successful trial
received 611,182–611,189 framed DLLPs, with zero DLLP CRC errors. The validated
DLLP counter saturated at 65,535. The two receive errors recorded before the
monitored recovery interval remain; none of the successful trials stopped with
a receive-path failure. The stop trace confirms 1,250,000 local L0 cycles.

The transition trace independently decodes six transmitted InitFC1 DLLPs in
P/NP/Cpl order with correct credits, CRC, scrambling, padding and SKP parity.
The first SSD InitFC1-P appears after the first local InitFC1-P. The SSD later
switches to InitFC2-P/NP/Cpl. Its advertisements are PH=127, PD=512, NPH=127,
NPD=60, with infinite completion credits. All six received packet types have
independently checked CRCs. The two sparse traces filled after roughly 4,092
DLLPs, so they cover the early exchange rather than the entire observation;
terminal counters and the stop trace provide evidence for the later interval.

This strongly supports missing local InitFC1 as the explanation for the earlier
idle-only image receiving no DLLPs. It does not establish a complete Gen3 Data
Link: this probe deliberately withholds InitFC2, and the peer keeps sending
InitFC2. The next integration step is the real flow-control initialization state
machine, together with ACK/NAK and receive/replay ownership before enabling TLP
traffic or any Linux/NVMe host effects.

The fresh routed image meets Gen3 setup/hold timing at 0.002/0.014 ns and Gen1 at
0.223/0.014 ns. It uses 7,835 LUTs, 9,599 FFs and 100 RAMB36 blocks (trace RAM);
the packet gate retains 648 LUTRAMs. There are no critical CDC findings, no CDC
waivers applied, no DRC errors/critical warnings, and bus-skew checks pass.
The frozen source manifest and source snapshot match the programmed image.

Qualified Gen2 Linux was restored after testing. Gen2x1 NVMe enumeration and a
16 MiB direct read passed at 213 MB/s, with zero outstanding I/O. SD boot files
were unchanged. Machine-readable evidence is in
[evidence/initfc1-probe.json](evidence/initfc1-probe.json).

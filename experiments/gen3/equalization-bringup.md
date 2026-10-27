# ZCU104 equalization-only bring-up

This record describes its named historical investigation stage. For the latest
full-host design and measured results, see [performance history](../../docs/performance-history.md).
Statements about unchanged sources or a restored board refer to that stage.

This page records the v12 Phase 1 image. The current board wrapper additionally
enables the [Recovery diagnostic](recovery-bringup.md); new builds must be
evaluated against that scope. The archived v12 source manifest and input
snapshot identify the exact Phase 1-only implementation.

This experimental image has no PS, AXI master, packet transport, Linux host
interface or NVMe data path. It is intended to measure whether the SSD and the
ZCU104 can negotiate Gen3 and complete the short-channel Phase 1 equalization
policy. It is not a complete Gen3 root port and must not be used with the Linux
PCI host driver. The qualified Gen1/Gen2 image remains separate.

## Current physical result — 2026-10-25

The `gen3_eq_board_v12` image completed Gen3 Phase 1 equalization with the
Samsung 990 EVO on ZCU104/OP047. Every preset P0–P10 succeeded at least once.
Across the initial P4 trial, eleven-preset sweep and four retries, 12 of 16
attempts reached Gen3 and passed Phase 1. Four stopped during Gen1 startup,
before preset application. All attempts that reached Gen3 passed Phase 1;
this does not establish reliable startup, margin or long-term stability.
The nominal 250 MHz PCLK was confirmed by 640 edges per 256 reference cycles.
The decoded peer stream subsequently included TS2s.

Phases 2/3 are deliberately skipped. The transmitter stops after a 1 ms
post-Phase-1 observation. There is no sustained Gen3 L0, packet/replay path,
Linux/NVMe data transfer, BER measurement or compliance qualification.
Terminal RX alignment and saturated event counts are not stability metrics.

The final diagnostic image uses 4,010 LUTs and 5,728 FFs, with no BRAM, URAM or
DSPs. Gen3 setup/hold slack is +0.096/+0.012 ns; Gen1 is +0.520/+0.012 ns.
The internal startup clock is constrained at 250 MHz. Routed CDC has no
critical findings, and no internal endpoints or clocks are unconstrained.
All twelve integration cases and both generated-reset dependency cases pass.

[Compact evidence and source hashes](evidence/equalization-startup-and-phase1.json)
include all sweep/retry outcomes. The qualified Gen2 image was restored;
Linux/SSH, Gen2 x1 enumeration and a 16 MiB direct read passed. SD boot files
were not changed. The next reliability issue is the intermittent Gen1 startup
timeout; full Gen3 transport integration remains separate work.

## Hardware path

The build generates AMD `pcie_phy` 1.0 locally for its supported ZU9EG target,
selecting GTH x1, 100 MHz reference, Gen3, QPLL1 and channel X0Y15. It reads the
generated PHY RTL into a ZU7EV build. The initial image used unmodified
PHY RTL. The observation-only v7 revision adds ports and free-running clock counters
with `instrument_eq_phy.py`. From v8, the build also explicitly enables the
startup-clock correction described below. Original and adapted source hashes
are recorded locally. This migration method follows
AMD's [supported-device guidance](https://docs.amd.com/r/en-US/pg239-pcie-phy/Targeted-Supported-Devices).
The generated wrapper supplies native PCS, reset/calibration, clocks, rate
sequencing and transmitter preset/query support. There is no PCIe controller
hard block. Generated AMD files remain under ignored `build/` and retain their
upstream notices.

`gen3_eq_board` connects that PHY to the training-only `gen3_eq_bringup`:

1. JTAG VIO arms one attempt. The management clock is the buffered 100 MHz
   adapter reference. PHY reset is held for 1 ms and SSD PERST for 100 ms.
2. A synchronous-reset copy of the legacy startup LTSSM performs receiver
   detection and Gen1 x1 training. An experimental legacy codec handles EQ TS
   symbol 6 and inserts SKP between training sequences.
3. The experiment requests a directed speed change using EQ TS1/TS2. It waits
   for matching peer speed-change sequences and sends EIOS before idle.
4. While idle, it applies the selected preset and queries the effective
   coefficients. Only after both PHY acknowledgements does it request Gen3.
5. After the PHY rate-completion indication, it sends Gen3 EIEOS and TS1s with
   the actual queried preset/coefficient information. The transmitter implements
   scrambling, TS1 parity, DC balancing, periodic EIEOS, SKP and 64/65 cadence.
6. The receiver acquires on a complete EIEOS and validates decoded TS1 fields
   and parity. `gen3_eq_phase1` requires two matching EC=01 TS1s.
7. On success, it sends EC=00 TS1s for 1 ms to observe Recovery.RcvrLock, then
   transmits EIOS and stops. On Phase 1 failure it stops with the result retained.
   It never transitions into a Gen3 data-stream or data-link-active state.

The selected preset is used for both the local transmitter and the preset hint
sent to the endpoint before the rate change. Local tap values are obtained from
AMD's apply/query interface, not guessed from a label. Phases 2/3 remain skipped.
This experiment does not implement adaptive coefficient search or a general
fallback/retrain policy. A new trial requires disarming and cold-resetting this
isolated image and SSD; it cannot preserve a live Linux/DMA session.

## Simulation

```sh
python3 experiments/gen3/check_training.py
python3 experiments/gen3/check_eq_bringup.py
python3 experiments/gen3/check_equalization.py
```

Training tests compare 2,048 transmitted TS1s, 65 EIEOS and five SKP ordered
sets against a separate byte-level reference, including all three DC-correction
choices. Loopback additionally checks reception. The integration test includes
legacy startup, preset apply/query ordering, idle exit, rate transition, Phase 1
and stop, plus missing apply/query/rate acknowledgements, absent Gen3 input and
corrupted TS1 parity, missing P0 completion, absent receiver and absent Gen3
negotiation. This integration partner models handshakes and training;
it is not a GT serial model or independent PCIe compliance VIP.

## Fresh board build

```sh
vivado -mode batch -source experiments/gen3/build_eq_board.tcl \
  -log build/eq-board.log -journal build/eq-board.jou \
  -tclargs build/eq-board
```

The output directory must not exist. The build records and rechecks source
hashes, requires exactly one GTH and no PCIe controller hard primitive, and
reports utilization, timing, CDC, bus skew and route status. Review CDC and
clock coverage before deployment; synthesis and routing alone are not physical
proof. Do not edit build inputs during a run.

The PHY's broad reference/PCLK clock-group exceptions are deliberately not
loaded. Custom crossings use synchronizers, a held-data snapshot mailbox and
bounded Gray-counter paths. Generated PHY crossings must also be reviewed.
The build checks routed setup and hold in both the 250 MHz Gen3 and 125 MHz
Gen1 modes. Dynamic clock switching still requires physical validation.

## JTAG controls and observations

`gen3_eq_vio` runs from the management clock. Output probe 0 is `arm` (default
0); output probe 1 selects preset P0-P10 (default P4). Set the preset while
unarmed, then arm. Disarm between attempts. Reserved preset labels hold the PHY and SSD in reset and assert diagnostic
bit 0. The output image retains the established SSD2-disable
sideband value; SSD2 must remain empty.

Input probes 0 and 1 contain a coherent 256-bit PCLK snapshot captured through
request/acknowledge toggles. Probe 0 is status and probe 1 is the last decoded
training sequence. In status, bits 4:0 are the experiment state, 9:5 the legacy
startup state, 11:10 the requested PHY rate, 12 PHY ready, 13 RX aligned,
14 Phase 1 success, 15 Phase 1 failure, 18:16 Phase 1 failure reason and 22:19
the bring-up failure reason. Bits 26:23 count matching post-equalization TS1s,
up to eight. The remaining fields capture timer low bits, DC balance, peer/local
FS/LF, queried coefficients, last legacy rate, TS event count and magic `4551`.

Experiment states: 0 startup, 1 Recovery lock, 2 Recovery configuration,
3 EIOS, 4 electrical idle, 5 preset apply, 6 query gap, 7 query, 8 rate arm,
9 rate wait, 10 Phase 1 entry, 11 Phase 1, 12 post-equalization observation,
13 stop, 14 finished, 15 failed. Bring-up failure reasons: 1 startup timeout,
2 negotiation timeout, 3 peer-idle timeout, 4 preset/query timeout, 5 rate
handshake timeout, 6 Phase 1 failure, 7 legacy startup failure.

Input probe 2 reports measured PCLK edges per 256 reference-clock cycles in
bits 31:16 (nominal 320 at Gen1, 640 at Gen3); bit 7 is the mailbox/clock
watchdog fault. A 25 ms stalled mailbox forces cold reset and holds the SSD
in reset. This depends on the reference clock continuing to run; stopped-
reference recovery is not supported. These diagnostics do not measure BER,
eye opening, analog voltage swing, or PCIe compliance.

Before programming, cleanly shut down the running Linux image and ensure its
host driver no longer owns the endpoint or DMA. Do not load this image into a
live Linux host session. Use the private board handoff to select the correct
hardware target. A temporary test does not replace the SD default.


## First physical trial — 2026-10-25

The `gen3_eq_board_v4` build passed the full experimental regression, routed
setup/hold checks and source-manifest verification. It uses 3,487 LUTs and
4,656 flip-flops, with no BRAM, URAM or DSPs. Gen3 setup/hold slack is
+0.041/+0.010 ns; Gen1 is +0.541/+0.010 ns. CDC has no critical findings;
held-data and Gray-bus warnings remain explicitly constrained and reviewed.
The design contains one GTH channel and no PCIe controller hard block.

After Linux was synced, the SSD cache flushed and Linux halted, the image
was programmed temporarily over JTAG. VIO responded and a cold P4 trial was
armed. Management-clock logic released PHY reset, but no PCLK activity or
snapshot progress was observed. The watchdog subsequently asserted and held
the PHY and SSD in reset. No receiver detection, preset acknowledgement,
Gen3 rate change or equalization was demonstrated. The root cause is not yet
identified; internal GT power-good, PLL-lock and reset-state observations are
needed to distinguish startup failures. Sweeping presets at this point would
not test equalization.

The bitstream SHA-256 is
`c688935f817830d550df27a09721ee7171e0ee1245106d62e63a26c714b2eb3c`.
This result is a failed PHY-startup trial, not physical Gen3 qualification.
No SD files or partitions were changed.

The qualified Gen2 image was restored after the trial. Linux boot, SSH access,
Gen2 x1 SSD enumeration and a 16 MiB direct read were verified. No I/O remained
in flight after that read. This recovery check does not validate the Gen3 image.


## PHY startup diagnostics

The diagnostic revision adds VIO inputs 3 (`phy_diag_last`) and 4
(`phy_diag_seen`), both 64 bits. `last` follows synchronized diagnostic levels
until the watchdog fires, then retains the pre-reset observation. `seen` ORs
levels while armed, showing whether individual flags were ever asserted.
Disarming clears both. These are diagnostic levels, not an atomic protocol
snapshot; `seen` must not be interpreted as a coherent FSM code.

| Bits | Meaning |
| --- | --- |
| 2:0 | PHY reset FSM: 0 idle, 1 power-good, 2 PLL lock, 3 divider-reset done, 4 TX/RX reset done, 5 TX sync start, 6 TX sync done, 7 PHY status |
| 3 / 4 | Reference reset released / internal reset released |
| 5 / 6 / 7 | Synchronized CPLL / QPLL0 / QPLL1 lock |
| 8 / 9 / 10 | Divider / TX / RX reset done |
| 11 / 12 | TX sync done / PHY status |
| 13 / 14 | CPLL power-down / reset asserted |
| 15 / 16 | QPLL power-down / reset asserted |
| 17 / 18 | TX divider reset / GT reset asserted |
| 19 / 20 / 21 | User-ready / TX sync start / reset FSM idle |
| 22 / 23 | Synchronized power-on sequence complete / internal-clock reset released |
| 24 / 25 / 26 | Raw GT power-good / PCLK reset released / TX phase-interpolator power-down |
| 32 | Raw GT power-good (duplicate at wrapper boundary) |
| 33 / 34 | GT BUFG clock-enable / reset requests |
| 35 / 36 | GT BUFG clock-enable / reset masks |
| 39:37 | GT PCLK divider request |
| 40 / 41 / 42 | Raw TXOUTCLK / internal clock / PCLK counter bit 7 |

A high `seen` bit 40–42 indicates at least 128 edges of that clock since
configuration, not a frequency measurement or proof of continuous operation.
Counters are observational and do not reset the PHY. The existing PCLK frequency
measurement remains separate. Bits 27–31 are reserved zero. AMD-generated
instrumented files and their original copies remain in ignored build output.


### Startup-clock diagnosis and correction

The observation-only v7 image reproduced the first failure with diagnostic
value `000000250507f001`. Raw GT power-good was asserted, but neither PLL
locked, CPLL/QPLL reset and power-down stayed asserted, and raw TXOUTCLK,
internal clock and PCLK showed no activity. The reset FSM remained at state 1;
its internal power-on sequence had not completed.

The generated wrapper selected TXOUTCLK's programmable-divider source even
while holding its PLLs in reset. The reset sequencer depended on that clock
to complete its power-on wait before releasing those same resets. The v8 build
therefore passes `--startup-reference` to the local preparation script. It
selects reference-clock output (`TXOUTCLKSEL=3`) during CPLL reset and restores
the normal programmable-divider output (`5`) when CPLL reset deasserts. This
is a local experimental adaptation, not a claim about all AMD PHY versions.
The qualified Gen1/Gen2 RTL is unchanged.

A focused test uses the locally generated reset-controller RTL and a behavioral
clock/PLL dependency model. It reproduces the original deadlock and verifies
completion with reference-clock startup. It is not a primitive timing or
serial-link simulation:

```sh
python3 experiments/gen3/check_phy_startup.py \
  build/eq-board/phy_reference/phy_reference.gen/sources_1/ip/gen3_reference_phy
```

The generated 1 MHz `intclk` timing constraint is also replaced by a 250 MHz
constraint. Reopened v7 routed timing passed this stricter check at
+0.106 ns setup and +0.012 ns hold; subsequent builds apply it before placement.


The v8 physical trial confirmed CPLL/QPLL1 lock, completion of PHY reset,
and 320 PCLK edges per 256 reference cycles (125 MHz). The watchdog remained
clear. The attempt timed out in Detect before Gen1 training, so no Gen3 rate
transition or equalization was reached.

From v9, the upper diagnostic bits also retain MAC-side observations:

| Bits | Meaning |
| --- | --- |
| 63:56 | Saturating count of PCLK cycles with PHYSTATUS asserted after SSD reset release |
| 55:53 | Last RXSTATUS sampled with PHYSTATUS during a detect request (v10 onward) |
| 52 / 51 | Detect request ever asserted / PHYSTATUS seen during a detect request |
| 50 | Registered current detect request |
| 49:48 | Registered current PIPE power-down request |
| 47 | RXVALID ever asserted |
| 46 / 45 / 44 / 43 | Registered RX electrical idle / TX electrical idle / PHY ready / PHYSTATUS |

The counters and flags reset with the cold experiment reset. The v9 RXSTATUS latch included power transitions; v10 restricts that latch to
cycles when detection is requested. Interpret it alongside the detect flag and
event count. Multi-bit observations may be transient while
running and should be interpreted after settling.


From v10, snapshot input 1 contains the most recent 16 legacy-state transitions
while the requested rate is Gen1. The newest byte is at bits 7:0; each byte
contains the new legacy state in bits 4:0, PHYSTATUS in bit 5, detect request in
bit 6 and power-down request bit 1 in bit 7. Zero leading bytes are unused after
cold reset. At Gen3 it continues to report the last decoded Gen3 training
sequence. This distinguishes a terminal Detect state from the polling or
configuration attempt that preceded it.


The v10 history (`c1 02 03 00 01`) demonstrated entry into Polling.Active and
Polling.Configuration. The detect-specific latch recorded receiver-present
code 3, and two PHY status cycles were observed. The earlier terminal Detect
state was not proof of a missing detection response: the legacy LTSSM continued
running after the experiment had failed. From v11, legacy history and MAC
observations freeze at experiment termination. The whole-startup deadline is
100 ms at 125 MHz, allowing the individual 12 ms Detect quiet, 24 ms polling
active and 48 ms polling configuration timers to operate before the experiment
aborts. This does not relax training-sequence validation.


The v11 trial reached Gen1 L0 and completed the directed Recovery exchange,
then timed out waiting for a complete peer EIOS in fabric even though the
synchronized native PHY reported RX electrical idle. From v12, this Gen1-only
transition accepts either a current-Recovery EIOS or native RX electrical-idle
detection, followed by a fresh 125-PCLK-cycle (1 us) guard. The guard begins
after the peer-idle indication, not merely on entry to the local idle state.
Stale EIOS state is cleared before the Recovery configuration phase.

This follows the supplied Base specification's Recovery.Speed idle-detection
alternatives and minimum post-peer-idle interval. UG576's RXELECIDLE port
contract permits direct detection at 2.5 Gb/s; this policy is not generalized
to higher-rate idle detection. Directed tests now include native idle without
visible EIOS, no idle indication, and late-arriving idle. All twelve integration
cases pass. This is still a training-only experiment without packet ownership.

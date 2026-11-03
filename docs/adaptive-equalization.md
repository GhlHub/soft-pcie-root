# Adaptive equalization and startup Gen2 fallback

This development revision adds downstream Gen3 Phase 2/3 negotiation and an
automatic lower-speed startup path. On 2026-11-02, a fresh Gen3-enabled build
passed synthesis, route, an independent checkpoint audit and temporary ZCU104
hardware testing. Three controlled warm startups reached Gen3 x1; normal NVMe
I/O and CRC checks passed. Physical Gen2 fallback and injected live Recovery
remain unqualified. The image subsequently became the verified SD default; no flash update was needed.

## Review corrections after the deployed image

The source now fixes three issues found after the `adaptive_eq_v2` SD image:

- The fallback adapter preserves the backend's established link-up/DL-active
  indication during bounded Gen1/Gen2 rate changes. It pauses new configuration
  command admission, retains accepted owners and reports switch failure as inactive.
- Evaluation rejects any invalid, wrong-EC, mismatched or rejected TS event,
  including a single event that cannot form a pair. Completion requires a fresh
  matching pair after the observation interval; silence cannot complete evaluation.
- PHY loss and absolute phase deadlines override simultaneous success. The parent
  handles failure first. An exhausted request deadline also overrides success and
  leaves the controller active for its next bounded retry.

Regressions reproduce the previous failures, check both fallback rate directions
with a real configuration read pending (`tests/test_gen3_fallback.py`), and
check clean retry after malformed
training, silence followed by fresh training, PHY/deadline completion collisions
and request-timeout retry ownership (`tests/test_gen3_adaptive_eq.py`, cases
10–17). These are simulation results. The corrected
source passed the 1,718-test full run and a final 23-case focused run (one
additional case), lint and real-XPM elaboration. It subsequently passed fresh
synthesis, routing, reopened-checkpoint audit and temporary hardware validation
as `adaptive_review_v1`; the SD default still uses the earlier image.

### Review-fix hardware validation — 2026-11-02

All source manifests match. Three controlled warm startups negotiated Gen3 x1
and passed 256 MiB read-only CRC checks. All eight matched benchmark/integrity
jobs and 28,000 Linux-driver configuration reads passed. SMART error and
unsafe-shutdown counters were unchanged; exactly 27,423,408,128 written bytes
matched block accounting. The board remains running this temporary JTAG image.

| Measurement | Previous SD image | Review fixes |
| --- | ---: | ---: |
| Gen3/Gen2 setup slack | +0.101 ns | +0.041 ns |
| Gen1 setup slack | +0.409 ns | +0.204 ns |
| Worst hold slack | +0.014 ns | +0.010 ns |
| QD1 read | 589.33 MB/s | 591.48 MB/s |
| QD8 read | 733.38 MB/s | 737.37 MB/s |
| QD1 write | 340.19 MB/s | 339.90 MB/s |
| QD8 write | 562.68 MB/s | 563.84 MB/s |

Timing passes with less margin; these single-run throughput differences do not
establish a performance gain. Resources: 16,116 LUTs, 12,367 FFs, 671 control sets,
three BRAM tiles and one GTH. No additional postroute optimization was used.
CDC, DRC, bus skew, routing and timing coverage passed the independent audit.

See [exact evidence](evidence/adaptive_review_v1/completion.json) and
[source hashes](evidence/adaptive_review_v1/sources.json). Physical fallback,
injected Recovery, malformed-training/deadline-collision fault injection and
cold-cycle/electrical qualification remain open. SD and flash were not updated;
the installed Linux driver was retained.

Final pre-publication checks on 2026-11-03 passed all **1,719 tests in 233.25
seconds**, lint, real-XPM elaboration and all 131 HDL formatting checks.
Hardware source manifests still match.

## Equalization behavior

`GEN3_TX_PRESET` now selects the **initial** transmitter preset (default 4).
The packaged native backend enables `ADAPTIVE_EQ`; the standalone training
bench's default remains the historical Phase-1/skip policy for regression.

After Phase 1 qualifies the peer, the new `gen3_eq_adapt` controller:

1. Sends EC=2 and accepts a new setting only after two matching valid TS1s.
   It applies preset requests 0–10, or coefficients satisfying the advertised
   FS/LF bounds. Invalid settings are reflected with Reject Coefficient Values
   without changing the physical transmitter. Coefficient application sends
   pre-, main- and post-cursor values on consecutive PHY clocks. A query confirms
   the setting before the controller advertises it as applied.
2. Enters EC=3 after a matching pair from the endpoint. It requests the peer's
   current preset initially, waits at least 1 us for settling, then requires a
   fresh matching accepted pair. Received Use Preset does not determine whether
   that request was accepted.
3. Invokes the PHY RX adaptation handshake. A proposal is sent to the peer and
   qualified again before adaptation restarts. After adaptation succeeds, a
   100 us clean-training observation with at least eight matching pairs must
   pass. Rejection, loss of alignment, corruption or an ordinary request timeout
   tries the next preset, wrapping 10 to 0. At most eleven requests are issued;
   PHY proposals count against that bound. This is a bounded search, not an
   exhaustive characterization or a guarantee that each preset is visited once.
4. Returns to the normal TS1/TS2/logical-idle startup sequence only on success.
   Missing PHY acknowledgements, exhausted attempts and phase deadlines fail
   visibly and make startup fallback eligible.

The ordinary request deadline is 1.5 ms. Up to two final evaluations may exceed
that deadline, because the generated PHY's adaptation dwell is 2,000,000 PCLK
cycles (8 ms at 250 MHz). Phase 3's absolute 24 ms deadline is never restarted.
Phase 2 has a 32 ms deadline. TX apply/query has a bounded 125-cycle watchdog;
meeting the protocol's pin-to-pin response requirement still needs measurement
including decoder, CDC and PHY delays. These are not software timeouts: the
existing 50 ms configuration-completion allowance remains unchanged.

TS encoding carries Use Preset and Reject bits with parity, and applies changed
fields at TS boundaries. Peer requests to reset the EIEOS interval are honored
in Phase 2; a separate counter preserves the maximum 65,536-TS interval.
All new control resets are synchronous. Packet RAM remains unreset.

The generated AMD RX-EQ controller proposes a configured link-partner preset;
its completion flag alone does not establish channel quality. The surrounding
controller adds error-driven retries and a clean-training test. That test is
**not** an eye measurement, BER qualification or proof of electrical compliance.
Final-edition normative review, broader SSD/channel testing, analog margin and
physical response timing remain open.

## Startup fallback and ownership

The native wrapper shares **one generated PHY/GTH** between the Gen3 engine and
a separate `pcie_soft_link` Gen1/Gen2 engine. The latter is held unused until a
Gen3 startup failure has closed the data stream and entered electrical idle.
A guard interval, fresh rate acknowledgement and P1-detect/P0 acknowledgements
precede legacy training. Gen1 negotiation then upgrades to Gen2 when supported;
a Gen1-only peer can remain at Gen1. Missing or stale rate acknowledgements
quarantine the attempt. There is no automatic retry back to Gen3 in this boot.

Backend selection is permanently locked out after Gen3 first reaches L0 or
asserts DL-active. Commands cannot be accepted before the selected backend is
active. Consequently fallback never resets or migrates an accepted requester,
replay entry, packet or AXI owner. A later Gen3 failure uses bounded same-rate
Recovery or quarantine, **not live Gen3-to-Gen2 migration**. PERST and PHY reset
are not pulsed to force fallback. Stopped-clock recovery remains unsupported.

The Gen3-enabled host shell retains 64-bit packet CDC paths and eight 64-byte
read-prefetch slots even when the negotiated link is Gen2 or Gen1. The extra
legacy packet engine costs resources; measured whole-example utilization is
reported below. The default Gen3-disabled package still selects its original
Gen1/Gen2 backend and smaller host buffers.

SRP1 rate status 0x50 reports fallback in bit 2 and Gen2 in bit 0. In fallback,
the informational LTSSM state uses the legacy state encoding; native adapter
state 30 means a rate transition and 31 means rate-transition failure. Native
state 20 identifies adaptive equalization. PHY diagnostic rate/detect/idle fields
follow the selected backend. The force-Gen1 policy is synchronized before the
fallback engine uses it; it does not bypass the initial Gen3 attempt.

## Verification and references

Directed controller tests cover broken pairs, preset/coefficients application,
illegal settings, missing acknowledgement, cancellation, PHY loss, phase timeout,
rejected-request exhaustion, proposals and extended adaptation dwell. Combined
startup tests proceed through adaptation and then retain requester, replay and
DDR ownership through three live same-rate Recovery scenarios.

An independent procedural symbol partner exercises the fallback backend at
Gen1 and Gen2, including configuration/memory traffic, CRC, ACK/NAK, replay,
duplicate suppression and retraining. Additional tests cover entry from either
PHY rate, stale/missing rate acknowledgements and the native wrapper's lockout
after Gen3 L0. The wrapper lockout tests mock the PHY and force only the startup
status boundary; they do not model analog negotiation. The combined Gen3 peer
uses production TX and state-aware stimulus, not an independent full LTSSM BFM.

Initial adaptive-EQ checkpoint: **1,711 tests passed in 237.37 seconds**, followed by a focused
backend/controller rerun after the final policy synchronizer addition. `make
lint` and the standalone Recovery check passed. Fresh Vivado 2026.1 packaging
passed integrity/source-hash checks; Gen3-enabled packaged RTL elaboration
passed with zero critical warnings or errors. Elaboration reported 121 warnings,
principally unused vendor branches and trimmed signals; it is not synthesis,
place-and-route or physical validation. The subsequent hardware campaign is
recorded below.

Run `make test lint`, plus
`.venv/bin/python experiments/gen3/check_recovery_bringup.py`.
Fresh packaging uses `make ip IP_OUTPUT=build/<fresh-name>`.

PHY interface basis: AMD PG239 [TX signals](https://docs.amd.com/r/en-US/pg239-pcie-phy/TX-Equalization-Interface-Ports),
[RX signals](https://docs.amd.com/r/en-US/pg239-pcie-phy/RX-Equalization-Signals),
and [equalization sequences](https://docs.amd.com/r/en-US/pg239-pcie-phy/Equalization-Sequences).
Protocol implementation was cross-checked against the locally supplied
preliminary Base Specification's coefficient rules and downstream Phase 2/3
state descriptions. The preliminary document is not redistributed or treated
as final compliance authority.

## Routed and physical validation — 2026-11-02

Evidence: [completion.json](evidence/adaptive_eq_v2/completion.json) and
[exact hardware source hashes](evidence/adaptive_eq_v2/sources.json). The source
was an uncommitted development worktree; the base Git revision alone does not
identify the tested image. Vivado 2026.1 used a fresh unified package with
Gen3 enabled and initial TX preset 4.

The first synthesis audit found two critical CDC-10 paths: the combinational
Gen3/fallback rate mux fed the generated PHY's reference-clock synchronizers.
The selected rate is now registered in PCLK with synchronous reset, before
that boundary. Rate changes remain in electrical idle and await PHYSTATUS.
Both findings disappeared without new waivers. All 65 focused controller,
fallback, wrapper and startup tests passed after the fix, including a check
that rate changes between clocks cannot propagate immediately to the PHY.

The second fresh build passed timing, CDC, DRC, bus skew, routing, clock coverage,
packet RAM and accepted-owner structure audits. The build now explicitly checks
Gen2 fallback at 250 MHz in addition to Gen1 startup and Gen3.

| Routed mode | Setup WNS | Hold slack |
| --- | ---: | ---: |
| Gen1 startup | +0.409 ns | +0.014 ns |
| Gen2 fallback | +0.101 ns | +0.014 ns |
| Gen3 | +0.101 ns | +0.014 ns |

Whole ZCU104 example: **16,117 LUTs, 12,367 registers, 3 BRAM36-equivalent tiles,
675 control sets, one GTH and no hard PCIe controller**. The previous
requester-fix image used 11,245 LUTs, 10,491 registers and 2.5 BRAM tiles; this
comparison includes all intervening development, not just the fallback engine.

Temporary JTAG deployment followed clean Linux halt, independently verified
kernel-entry stop, programming and resume. All **three controlled warm startups**
negotiated Gen3 x1 and passed the existing 256 MiB read-only CRC pattern with
zero SSD writes and stable SMART counters during those checks.

The same fio benchmark used for the requester-fix image ran one job, direct
libaio, 1 MiB blocks, 30 seconds per throughput test:

| Test | Previous requester fix | Adaptive EQ image |
| --- | ---: | ---: |
| QD1 read | 589.63 MB/s | 589.33 MB/s |
| QD8 read | 733.45 MB/s | 733.38 MB/s |
| QD1 write | 339.49 MB/s | 340.19 MB/s |
| QD8 write | 564.16 MB/s | 562.68 MB/s |

All eight throughput/integrity jobs passed, including fresh 256 MiB CRC,
32 MiB sector-offset CRC and post-flush verification. Exactly 27,397,193,728
written bytes were accounted for. There were 28,000 driver-mediated
configuration reads, split before and after I/O. SMART media errors, error-log
entries, critical warnings and unsafe-shutdown count remained unchanged.

These measurements establish normal operation on this SSD/channel. They do
not exercise physical Gen2 fallback, injected live Recovery, electrical margin,
BER, cold-power startup or endurance. The board retained its existing Linux
driver; the new early-quarantine software branch was not deployed in this
campaign. The image subsequently became the SD default; see below.

## SD default deployment — 2026-11-02

The audited bitstream is installed at `/adaptive-eq-v2/system.bit`. The new
boot script preserves the FMC readiness check and loads PL before Linux.
Bitstream and script SHA-256 readback passed after remount and after an
unattended warm reboot. The new Linux boot ID and
`soft_pcie.image=adaptive_eq_v2` marker confirmed the selected boot branch;
Gen3 x1 enumeration and 256 MiB read-only NVMe CRC passed with zero SSD writes
and unchanged SMART counters. Persistent SD ext4 root remains read/write.

Bootloader, kernel, device tree and installed driver were retained. No QSPI
flash programming was needed. The FAT boot partition was unmounted afterward.
This is a warm-boot test, not cold-power-cycle qualification; no UART CRC
observation is claimed. See [default-boot evidence](evidence/adaptive_eq_v2/default-boot.json).

Before committing the deployment, the full regression passed again: **1,711
tests in 248.25 seconds**. Lint, real-XPM elaboration, all 131 HDL formatting
checks, local documentation links and hardware source manifests passed.

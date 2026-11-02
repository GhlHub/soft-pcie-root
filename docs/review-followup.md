# Gen3 design-review follow-up

Development changes dated 2026-11-02 address the review's Recovery, fixed-preset
policy and configuration-failure latency findings. This document records the
initial simulation/package checkpoint. The later adaptive-EQ revision includes
these RTL changes and passed route/audit and normal Gen3 NVMe I/O. Injected
Recovery and the new Linux fault branch remain model-tested, not physically
qualified. See the subsequent hardware campaign linked below.

Subsequent development implements [adaptive equalization and startup-only Gen2
fallback](adaptive-equalization.md). The fixed-preset limitations below describe
the first follow-up checkpoint, not the latest native backend. Live migration
after Gen3 L0 remains unsupported.

## Same-rate Recovery

After reaching Gen3 L0, a PCS/framing error, a peer training sequence, or a loss
of PHY readiness can enter the new `RLOCK` state (19). The transmitter finishes
an in-progress packet, closes its data stream with EDS, sends EIEOS and TS1,
then proceeds through received training qualification, TS2 and logical idle.
A single `HANDSHAKE_TIMEOUT` deadline covers the entire attempt, including
repeated errors. Its production value is 6,000,000 cycles (24 ms at 250 MHz).
A new error on the first resumed L0 cycle starts a new bounded attempt.

The host-facing DL-active indication remains asserted during this bounded pause
once flow control has initialized. It means the current Data Link ownership
epoch remains valid; it does not mean packets are presently on the wire. New
link-side command/TLP admission and requester timeout ticks pause. Existing
requester state, sequence numbers, replay entries, credits, committed RX packets,
CDC storage and DDR completion slots remain owned. Accepted AXI transactions
continue to drain. Unacknowledged sent packets remain subject to the existing
ACK/NAK/replay mechanism after resumption; Recovery alone retires nothing.

Fatal link-layer/formatter faults, EIOS, unsupported rate/equalization requests,
or expiration still quarantine. DL-active then falls and the existing host
logic drains accepted AXI owners. No local ownership reset, PERST, Gen2 fallback,
reference-clock restart, adaptive equalization or peer-reset recovery is added.
The fixed-preset training path is not full PCIe Recovery qualification.

The integration tests cover corrupted headers, peer-initiated training,
temporary PHY-not-ready, missing training, persistent corruption and immediate
repeat Recovery at presets 0, 4 and 10. Two sent but unacknowledged packets and a
configuration requester survive successful attempts, retire through a native
peer ACK, and receive the expected completion. An eight-slot RX64/TX64 DDR
bridge driven by the controller's real DL-active output retains an accepted
64-byte read, accepts its R beats during Recovery, and returns exact completion
bytes after resumption with one AR transaction. That DDR request enters at the
validated-packet interface; it is not a complete serial endpoint/DDR scoreboard.
The outer training partner uses production TX and state-aware startup stimulus,
so this does not close the independent full-LTSSM peer gap.

A separate independent PCS-output decoder checks seven mid-packet Recovery
request positions, exact packet preservation, EDS/EIEOS/TS1/SDS ordering,
scrambling and 64/65 transmit cadence. Packet and payload RAM remain unreset;
new Recovery control resets are synchronous.

## Fixed TX preset selection

The unified catalog now exposes `GEN3_TX_PRESET`, an integer 0 through 10,
enabled in the GUI when `ENABLE_GEN3` is selected. Default 4 preserves the
previous setting. It propagates through the packaged HDL to the preset apply
handshake before the Gen3 rate change. Invalid values are rejected by the GUI,
package metadata and native-root elaboration check.

This explicitly remains a fixed-preset, Phase-1/skip-Phase-2/3 laboratory policy.
The new selection is not adaptive equalization, a promise of channel margin,
or runtime rate fallback. Only preset 4 has previous physical evidence.
Preset-label simulation does not characterize analog quality. Broader SSD and
channel qualification, final-edition normative skip-policy review, and adaptive
Phase 2/3 remain open.

AMD's [PG239 equalization sequence](https://docs.amd.com/r/en-US/pg239-pcie-phy/Equalization-Sequences)
places preset apply after electrical-idle assertion and before rate change;
the existing acknowledged apply/query sequence is retained. That PHY guide
does not certify this custom MAC's skip policy. No new vendor/specification
material is imported into the repository.

## Prompt configuration fault reporting

SRP1 now completes a busy software-facing mailbox with status 4 and sticky
quarantine when its synchronized status observes DL inactive or a link error.
A matching completed reply retains priority over this early-fault path. The
core-side command and response state machine is not reset or cancelled: it
still drains the eventual response exactly once, even after software has seen
the failure. New submission remains blocked and the late response cannot clear
quarantine or overwrite the reported fault.

The Linux callback recognizes quarantine even without a done bit and reports
failure immediately. The 50 ms requester timeout, approximately 335 ms mailbox
watchdog and 400 ms software guard remain unchanged, as requested. A silent
endpoint or stopped/unresponsive path without an observable status fault can
still hold off interrupts until the existing timeout. This improves known-fault
latency, not the worst-case latency of every configuration access.

Sleeping inside the callback is not introduced: Linux's
[PCI configuration wrappers](https://github.com/torvalds/linux/blob/v6.6/drivers/pci/access.c)
can already hold the PCI raw spinlock with local interrupts disabled. The driver
retains its own mailbox serialization. An executable C/MMIO model uses the actual
callback to check normal/delayed replies, CRS, fault-only status, link failure,
unchanged timeout budget, permanent quarantine after a late reply, and Device
Control masking. CSR tests exercise both link loss and error indication after
command acceptance, including late-response drain.

## Validation boundary

The full repository regression passed **1,691 tests in 209.39 seconds**;
`make lint` passed. This adds 28 tests to the previous 1,663-test baseline.
Fresh Vivado 2026.1 packaging passed integrity and source-hash checks. Actual
catalog customization passed for Gen3 off/default preset 4 and Gen3 on/preset
10, including generated HDL and outstanding-read metadata. Vivado requires
literal `true`/`false` validation results here; the initial numeric Boolean
callback was corrected and its unit test strengthened. The five focused GUI,
Linux callback and management tests passed again after that correction.
These package checks generated output products; they did not run synthesis.

Reproduce local checks with:

```sh
VIVADO_BIN=/tools/Xilinx/2026.1/Vivado/bin make test lint
.venv/bin/python experiments/gen3/check_recovery_bringup.py
```

Focused tests are in `tests/test_gen3_startup.py`,
`tests/test_gen3_live_recovery_tx.py`, `tests/test_gen3_preset_gui.py`,
`tests/test_management.py` and `tests/test_linux_config_poll.py`.
Those initial packaging checks did not establish routed or physical operation,
and that checkpoint made no board or media changes. Subsequent build, physical
I/O and SD deployment evidence is recorded in [adaptive equalization](adaptive-equalization.md).

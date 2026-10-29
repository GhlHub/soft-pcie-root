# Open-source references for experimental Gen3

This record describes its named historical investigation stage. For the latest
full-host design and measured results, see [performance history](../../docs/performance-history.md).
Statements about unchanged sources or a restored board refer to that stage.

Reviewed on 2026-10-25. None of the reviewed projects provides a verified,
drop-in soft Gen3 root-port PHY for this ZCU104 design. They can still help
with independent verification, protocol implementation and test scenarios.
The qualified Gen1/Gen2 release is unchanged.

## Reviewed sources

| Project and pinned revision | License | Useful scope and limits |
| --- | --- | --- |
| [cocotbext-pcie](https://github.com/alexforencich/cocotbext-pcie/tree/4befa5eb60f12bc7e1050509defbb9afc33a15a9) | MIT | Independent DLLP/TLP models and transaction testing. Its DLLP encoder is now used below. It does not validate GTH serial timing or equalization. |
| [LitePCIe](https://github.com/enjoy-digital/litepcie/tree/586d7a454222d719d04c9d1012eef3f189fd863e) | BSD-2-Clause | Useful host, DMA and interface architecture reference. The reviewed UltraScale+ PHY wrapper generates AMD `pcie4_uscale_plus`; it does not implement our missing soft Gen3 LTSSM/PCS. |
| [openPCIE](https://github.com/chili-chips-ba/openPCIE/tree/d66d4c3e119026ad44a919cf0edc4c8869d40409) | BSD-3-Clause; bundled dependencies have separate licenses | Useful legacy PHY initialization and interface references. The reviewed `2.rtl/0.common.opensource/src/pcie/pcie_core.sv` instantiates `PCIE_2_1`, so that path still uses a hard PCIe controller. Its GTP implementation is not a GTHE4 Gen3 adapter. |
| [openCologne-PCIE](https://github.com/chili-chips-ba/openCologne-PCIE/tree/9032f33b2998d653d975bd7e561d68054706f953) | BSD-3-Clause; check dependency notices separately | Soft MAC/DLL and tests are useful references for arbitration, flow-control initialization and replay scenarios. Its stated commitment is Gen1 endpoint operation, with Gen2 best effort and automatic speed training unimplemented. Its legacy framing and GateMate PHY cannot replace Gen3 PCS. |
| [PCIe-Gen-5-Phy](https://github.com/akramemad1/PCIe-Gen-5-Phy/tree/cc3cefac9d6b0170a9768bb2fbacae2cff56c722) | MIT in `PCIe_5_Phy_Lay/LICENSE` | Contains actual Gen3 datapath and equalization phase logic, making it a useful research reference. It requires substantial review before reuse; see findings below. No hardware qualification was established in this review. |

The existing optional `wyvernSemi/pcievhost` comparison remains useful for
legacy CRC/scrambling and link behavior. Its Gen1/Gen2 model does not supply
Gen3 128b/130b or equalization verification. See the existing
`tests/pcie_soft/reference.lock.json` for its pin and GPL license treatment.

### Gen3/Gen5 candidate review findings

In the pinned `PCIe-Gen-5-Phy` revision, `rtl/LFSR_8_gen3.v` assigns `lfsr_q`
from both combinational and clocked processes. Verilator lint of that module
fails with `BLKANDNBLK` and also reports width, combinational nonblocking
assignment and latch warnings. Its asynchronous reset also conflicts with
this project's synchronous control-reset policy. These are specific findings
about that module, not an assessment of every module in the repository.

The reviewed `verification/settings.svh` defaults both partner maximum
generations to Gen1. Those defaults alone do not substantiate Gen3 test
coverage. Training symbols, bit ordering, scrambler advance rules, timeout
behavior and PIPE handshakes must be independently checked before adapting
any implementation. No RTL from this candidate was imported.

## Adopted independent DLLP oracle

`check_dllp_oracle.py` loads the upstream, unmodified `core/dllp.py` directly
from an external checkout. It verifies both the Git revision and the module
SHA-256 against `open_source_oracles.lock.json` before importing it. It does
not require the cocotb runtime or copy upstream code into project RTL.

The upstream encoder supplies ACK, NAK and all nine InitFC1/InitFC2/UpdateFC
Posted, Non-Posted and Completion DLLP bodies and CRCs. The local adapter
adds Gen3 framing and drives `gen3_data_rx` through a dedicated RTL testbench.
The local framing is not independently validated by this upstream encoder.

Results: **8,624 cases passed**: 176 valid packets and 8,448 single-bit
corruptions. Coverage includes all 16 byte offsets, DWORD input gaps, selected
ACK/NAK sequence boundaries, varied VC0 unscaled credits, and every bit of
each six-byte DLLP body/CRC. Checks require exact decoded bodies for valid
packets and rejection without DLLP delivery for each corrupted packet.
This does not test multi-bit corruption, flow-control state transitions,
replay behavior, serial encoding, or a complete link.

Reproduce with an external checkout in ignored build output:

```sh
git clone https://github.com/alexforencich/cocotbext-pcie build/cocotbext-pcie
git -C build/cocotbext-pcie checkout --detach 4befa5eb60f12bc7e1050509defbb9afc33a15a9
python3 experiments/gen3/check_dllp_oracle.py --source build/cocotbext-pcie
```

The runner creates a fresh output directory containing vectors and a result
manifest. Icarus Verilog and Python are required. The dependency is optional
and is not downloaded by the standard component regression.

The subsequent [Gen3 verification matrix](../../docs/gen3-verification-matrix.md)
records independently written training and native packet peers, including replay,
credit, corruption and rollover checks. Those tests do not import additional
third-party RTL or implement a complete endpoint BFM. The list below records
the remaining applications considered at this historical review stage.

## Next applications and remaining gaps

1. Extend independent transaction models to check the upcoming transmit
   formatter and replay/credit integration. Preserve complete-packet
   validation and accepted ownership throughout Recovery.
2. Use the openCologne DLL scenarios as a checklist for independently written
   arbitration, NAK/replay and flow-control tests. Review reset and ownership
   semantics before considering source reuse.
3. Compare Gen3 training and equalization state transitions with the Gen5
   candidate, using the local specification as authority. That comparison
   cannot substitute for independently passing tests or native PHY validation.

Native GTHE4 cold initialization, PLL/rate feedback, PCS mapping, clock
cadence and serial drain still require locally generated AMD references and
device-specific verification. None of the reviewed transaction models fills
the physical-completion contract exposed by `gen3_tx_path`: an AXI/PCS
acceptance handshake or a PCIe Completion TLP is not proof that the final
symbols have left the transmitter. A validated physical drain mechanism is
still required before releasing ownership or changing rate.

No full-link, routed or physical Gen3 qualification is claimed. Upstream
licenses must be retained if source is later copied; the current change
imports no third-party RTL or source text into the release.

# ZU15EG x2 integration target

Development only. No x2 bitstream, implementation result or board validation
exists for this example. Implementation verification is deferred until the
board is available, as requested on 2026-11-08.

The board reference is the companion `zu15eg_board` workspace: core/carrier
schematics named `xczu15eg_core_v1_0` and `xczu15eg_f_v1_0`, carrier J25 FMC HPC.
Its `docs/design/op063-fmc-compatibility.md` and
`docs/reports/op063_compatibility_2026-10-23/validation.json` record the reviewed
mapping below. They are source documentation/device-database checks, not
physical PCIe evidence. No vendor PDFs or generated AMD IP are copied here.

| SSD A logical lane | FMC pair | GTH bank/lane | TX P/N | RX P/N |
| --- | --- | --- | --- | --- |
| 0 | DP0 | 228/0 | R4/R3 | T2/T1 |
| 1 | DP1 | 228/1 | P6/P5 | P2/P1 |

SSD A GBTCLK0 uses L8/L7, bank 228 REFCLK0. The existing isolated x1 board
experiment uses GTHE4_CHANNEL_X1Y4 and GTHE4_COMMON_X1Y1/IBUFDS0_GTHE4.
The two-lane generated PHY must be checked against the selected part's device
sites before accepting its constraints. REFCLK1 is a separate AD9523 route.

The companion project currently builds for `xczu15eg-ffvb1156-2-e`; its board
manual/device compatibility probe uses `xczu15eg-ffvb1156-2-i`. Confirm the
physical device marking before a board-specific build. The PL GTH path is
separate from the PS PCIe connection to the carrier's onboard M.2 socket.

The documented NVMe adapter is OP063 SSD A, with 100 MHz common reference
clock and fixed 1.8 V VADJ. The companion workspace also describes an FH1223
adapter; it must not be assumed to have OP063 clock/power/reset behavior.
Confirm the installed adapter before deployment. Existing ZCU104 OP047
power initialization does not qualify OP063 or this carrier.

Still needed: generated two-lane PHY, vector serial top-level ports, GPIO and
reset/power constraints, PS/DDR/clock integration, board audit, Linux device
tree and a physical startup/CRC procedure. See [x2 development](../../docs/x2-development.md).

# Register and address contract (ABI 1)

Registers are 32-bit, aligned, little-endian AXI accesses. Unknown/unimplemented
register offsets return SLVERR; do not scan the address space with devmem.
Use the Linux host driver for normal operation.

| Example address | Block |
| --- | --- |
| 0xA0000000–0xA0000FFF | S_AXI / SRP1 configuration mailbox |
| 0xA2000000–0xA2000FFF | S_MEM+0 / DBR1 control and MSI |
| 0xA3000000–0xA3FFFFFF | S_MEM+0x01000000 / endpoint BAR window |
| PCI 0–0x7FFFFFFF | Identity-mapped host DDR DMA range |
| PCI 0xFEE00000 | MSI target, intercepted before DDR |

## SRP1 offsets

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x00 / 0x04 | RO | Magic 0x53525031 / ABI 0x00010000 |
| 0x08 | RO | bit 0 link; bit 1 DL active; bit 2 error; bits 7:3 informational LTSSM |
| 0x0C | RO | PHY diagnostic levels and heartbeat counter width |
| 0x10 | RW | bit 0 enable; bit 1 force Gen1 (change while disabled) |
| 0x18 / 0x1C | RO | Measured link-clock sample / management measurement window |
| 0x20 / 0x24 | RW | Command address low/high |
| 0x28 | RW | Command write data |
| 0x2C | RW | bits 2:0 opcode, 7:4 byte enables, 31:16 BDF |
| 0x30 | WO | bit 0 submit |
| 0x34 | RO | bit 0 busy, bit 1 done, bit 2 quarantine, bits 10:8 result status |
| 0x38 | RO | Result data |
| 0x40–0x4C | RO | Completion diagnostic DWORDs |
| 0x50 | RO | bit 0 Gen2, bit 1 rate-idle/busy, bit 2 fallback, bit 3 Gen2 capable |

Opcodes 0/1 are memory read/write; 2/3 configuration Type 0 read/write. Historical
Type 1 opcode encodings 4/5 exist in the mailbox but Type 1 topology is unsupported.
The host driver supports 1/2/4-byte configuration operations, CRS vendor-ID retries
and the single direct endpoint. Status 0 success, 1 UR, 2 CA/other, 3 timeout,
4 link loss, 5 bad command, 6 malformed completion, 7 CRS. Mailbox timeout does not
cancel accepted ownership. Diagnostic multi-bit status is not an atomic control
interface.

## DBR1 offsets (S_MEM+0)

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x00 / 0x04 | RO | Magic 0x44425231 / ABI 0x00010000 |
| 0x10 | RW | bit 0 DMA enable |
| 0x14 | RO | bit 0 DMA fault, bit 1 PIO fault, bit 2 DMA idle, bit 3 link active |
| 0x20 | RO | MSI pending bits |
| 0x24 | RW | MSI mask |
| 0x28 | WO | MSI acknowledge, write-one-to-clear |
| 0x80 | RW | PRF1 counters: bit 0 enable, bit 1 clear strobe |
| 0x84 | RO | Counter overflow bitmap |
| 0x88 / 0x8C | RO | PRF1 magic 0x50524631 / host clock 125000000 Hz |
| 0x100–0x17C | RO | 32 profiling counters, see below |

Counter order is defined by `NAMES` in `scripts/profile_completion_path.py`:
cycles, read_active, slot_empty_wait, slot_ready, tx_stall, tx_dwords,
payload_dwords, completions, ar_bursts, ar_stall, r_beats, r_bursts, r_wait,
r_first_wait, pending_one, pending_two, slots_full, issue_slots_full, rx_empty,
rx_copy, check_fence, read_requests, drain, r_first, queued_blocked,
rx_backpressure, writer_busy, write_outstanding, fault, link_active, check, msi.
Counters wrap; use bounded captures and reject overflow. Freeze before readback.
Categories overlap. `(pending_one+2*pending_two)/r_bursts` estimates mean burst
residence in host cycles, with capture-boundary bias. TX stalls measure the host
completion handshake, not every internal transmitter wait or wire utilization.

# Register and address contract (ABI1)

Registers are32-bit, aligned, little-endian AXI accesses. Unknown/unimplemented
register offsets return SLVERR; do not scan the address space with devmem.
Use the Linux host driver for normal operation.

| Example address | Block |
| --- | --- |
| 0xA0000000–0xA0000FFF | S_AXI / SRP1 configuration mailbox |
| 0xA2000000–0xA2000FFF | S_MEM+0 / DBR1 control and MSI |
| 0xA3000000–0xA3FFFFFF | S_MEM+0x01000000 / endpoint BAR window |
| PCI0–0x7FFFFFFF | Identity-mapped host DDR DMA range |
| PCI0xFEE00000 | MSI target, intercepted before DDR |

## SRP1 offsets

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x00 / 0x04 | RO | Magic0x53525031 / ABI0x00010000 |
| 0x08 | RO | bit0 link; bit1 DL active; bit2 error; bits7:3 informational LTSSM |
| 0x0C | RO | PHY diagnostic levels and heartbeat counter width |
| 0x10 | RW | bit0 enable; bit1 force Gen1 (change while disabled) |
| 0x18 / 0x1C | RO | Measured link-clock sample / management measurement window |
| 0x20 / 0x24 | RW | Command address low/high |
| 0x28 | RW | Command write data |
| 0x2C | RW | bits2:0 opcode,7:4 byte enables,31:16 BDF |
| 0x30 | WO | bit0 submit |
| 0x34 | RO | bit0 busy, bit1 done, bit2 quarantine, bits10:8 result status |
| 0x38 | RO | Result data |
| 0x40–0x4C | RO | Completion diagnostic DWORDs |
| 0x50 | RO | bit0 Gen2, bit1 rate-idle/busy, bit2 fallback, bit3 Gen2 capable |

Opcodes0/1 are memory read/write;2/3 configuration Type0 read/write. Historical
Type1 opcode encodings4/5 exist in the mailbox but Type1 topology is unsupported.
The host driver supports1/2/4-byte configuration operations, CRS vendor-ID retries
and the single direct endpoint. Status0 success,1 UR,2 CA/other,3 timeout,
4 link loss,5 bad command,6 malformed completion,7 CRS. Mailbox timeout does not
cancel accepted ownership. Diagnostic multi-bit status is not an atomic control
interface.

## DBR1 offsets (S_MEM+0)

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x00 / 0x04 | RO | Magic0x44425231 / ABI0x00010000 |
| 0x10 | RW | bit0 DMA enable |
| 0x14 | RO | bit0 DMA fault, bit1 PIO fault, bit2 DMA idle, bit3 link active |
| 0x20 | RO | MSI pending bits |
| 0x24 | RW | MSI mask |
| 0x28 | WO | MSI acknowledge, write-one-to-clear |
| 0x80 | RW | PRF1 counters: bit0 enable, bit1 clear strobe |
| 0x84 | RO | Counter overflow bitmap |
| 0x88 / 0x8C | RO | PRF1 magic0x50524631 / host clock125000000Hz |
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

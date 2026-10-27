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
| 0x88 / 0x8C | RO | Profiling magic: PRF1 0x50524631 or wide-path PRF2 0x50524632 / host clock 125000000 Hz |
| 0x90 | RO | New configurable build: bits 7:0 packet DWORDs/beat; bits 15:8 read slots; upper bits zero. Only read on a known new image; older PRF1 images lack this offset. |
| 0x100–0x17C | RO | 32 profiling counters, see below |

Counter order is defined by `NAMES` in `scripts/profile_completion_path.py`:
cycles, read_active, slot_empty_wait, slot_ready, tx_stall, tx_dwords,
payload_dwords, completions, ar_bursts, ar_stall, r_beats, r_bursts, r_wait,
r_first_wait, pending_one, pending_two, slots_full, issue_slots_full, rx_empty,
rx_copy, check_fence, read_requests, drain, r_first, queued_blocked,
rx_backpressure, writer_busy, write_outstanding, fault, link_active, check, msi.
Counters wrap; use bounded captures and reject overflow. Freeze before readback.
Categories overlap. For the two-slot configuration only, `(pending_one+2*pending_two)/r_bursts` estimates mean burst
residence in host cycles, with capture-boundary bias. TX stalls measure the host
completion handshake, not every internal transmitter wait or wire utilization.

In the 64-bit receive-path development revision, `rx_copy` still counts active
consumer **cycles**, each accepting one or two DWORDs. It is not a DWORD or byte
counter. The TX DWORD/payload counters retain their original 32-bit units.

The optional Gen3 package reports **PRF2**. `tx_dwords` counts accepted host
**beats**, and `payload_dwords` counts beats containing any payload, including
the upper-lane payload sharing a beat with the third header DWORD. Neither is a
byte count. `slots_full` and `issue_slots_full` use the configured slot limit.
`pending_one` and `pending_two` still count exactly one or two AXI read owners;
they omit occupancy above two. The profiling tool detects PRF2, reads 0x90 and
reports null for payload-byte and burst-residence estimates that these counters
cannot supply. Use fio byte accounting for measured throughput. In pipelined
mode `read_requests` counts issuance setup, `slot_empty_wait` counts an active
read window awaiting its next complete slot, and `queued_blocked` describes
parser occupancy rather than completion-sink occupancy.

## Experimental Gen3 link profiling (LPR1)

The diagnostic Gen3 revision adds **local command operation 7** through SRP1's
existing command mailbox. It emits no PCIe request. Stage the local address in
0x20/0x24, data in 0x28, configuration 0x000000F7 in 0x2C, and submit through
0x30 as usual. Poll 0x34 and read the response from 0x38. This interface requires
exclusive administrative access to SRP1; do not race Linux PCI configuration
operations or another mailbox user. Existing command CDC ownership and timeout
quarantine remain in effect. These commands require an active link through the
existing mailbox and are not a stopped-clock recovery mechanism.

| Local address | Operation/result |
| --- | --- |
| 0x00 | Read magic: historical 0x4C505231 (`LPR1`), current 0x4C505232 (`LPR2`) |
| 0x04 | Read running flag, bit 0 |
| 0x08 | Read link clock frequency, 250000000 Hz |
| 0x0C | Read sticky per-counter overflow bitmap |
| 0x10, data 1 | Clear all counters/overflow and start |
| 0x10, data 0 | Freeze all counters together in the link domain |
| 0x100–0x17C | Read frozen counters 0–31 at four-byte intervals |

Counter reads while running, invalid addresses, and control values other than
0/1 return local status 2. The bank freezes before the command response crosses
back to management; each subsequent read uses the same held bank. There is no
new live multibit CDC. Events are registered one cycle before counting, and the
stop edge counts the preceding sampled event. All new resets are synchronous.
32-bit counters wrap after about 17.18 seconds at 250 MHz; overflow is sticky.
The supplied profiler limits captures to ten seconds plus bounded overhead and
rejects overflow. Event predicates overlap and must not be summed as disjoint
lost cycles.

Counter order (also defined in `scripts/profile_gen3_link.py`): cycles, active,
app_valid, app_accept, app_credit_stall, app_replay_stall, replay_full,
ack_pending, ack_wait_copy, ack_wait_staged, ack_blocks_new_copy, ack_retire,
nak_retire, timeout, replaying, copy_accept, copy_formatter_stall,
formatter_valid, formatter_blocked, pcs_tlp_accept, tlp_submitted, dllp_accept,
dllp_blocked, pcs_idle, pcs_block_boundary_wait, pcs_cadence_wait, pcs_skp_wait,
pcs_skp_due_wait, replay_nonempty, sent_nonempty, fault, app_command_stall.

`ack_pending` includes captured ACK or NAK. In historical LPR1, `ack_wait_copy` means a captured
response with replay TX not idle; `ack_wait_staged` means it has copied packets
still in flight. `ack_blocks_new_copy` means a captured response while replay TX
is idle, including the retirement cycle itself. ACK/NAK retire counters count
processed responses, not the number of entries cumulatively freed. `replay_full`
is total retained entries, not just sent/unacknowledged packets. Formatter stalls
include DLLP arbitration and PCS readiness. PCS idle is the registered emitted
idle indication. PCS acceptance/submission is not independent physical-wire
proof. `app_credit_stall` excludes a packet already admitted; `app_replay_stall`
requires credits/admitted ownership, so the two admission categories are distinct.

The normal-ACK retirement revision reports `LPR2` (0x4C505232). Addresses and
counter order remain unchanged. In LPR2, `ack_wait_copy` and `ack_wait_staged`
count only captured responses for which `response_ready` is low, and
`ack_blocks_new_copy` counts a pending response that actually inhibits launch
from TX_IDLE. Successful normal ACK retirement can therefore overlap an active
copy or staged packets without being counted as a stall. LPR1's historical
counters describe coincident pending responses and states; compare those
predicates carefully rather than treating both versions as identical.
`scripts/profile_gen3_link.py` accepts both revisions and records the magic.

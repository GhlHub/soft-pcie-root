# Performance graphics

Use [the ACK-retirement comparison](linkedin-ack-retirement-gen2-gen3.png) for
the latest measured Gen2/Gen3 comparison. Its conceptual hardware illustration
is not a photograph of the tested board. The accompanying
[generation prompt](linkedin-ack-retirement-gen2-gen3-prompt.txt) records the
requested content.

| Image card | Read MB/s | Write MB/s | Evidence |
| --- | ---: | ---: | --- |
| Originally shared Gen2 | 428.3 | 259.7 | [Packaged baseline](../evidence/repackaged_v1/completion.json) |
| Gen2 with ACK retirement | 428.3 | 260.2 | [Gen2 measurement](../evidence/prefetch_v1/ack-retirement-gen2.json) |
| Gen3 with ACK retirement | 745.4 | 567.7 | [Gen3 measurement](../evidence/prefetch_v1/ack-retirement-performance.json) |

All values are rounded decimal MB/s from sequential 1 MiB, QD8, direct/libaio,
one-job, 30-second runs on ZCU104 with a Samsung 990 EVO 1 TB. These are
historical comparisons, not interleaved statistical trials. Gen2 throughput is
essentially unchanged. Gen3 gains include packet-width and prefetch changes;
they are not an ACK-retirement-only or link-rate-only comparison.

**Gen3 is pending further stabilization.** These physical measurements predate
the unified version 1.1 catalog package, which still needs its own route and
board verification. See the [performance history](../performance-history.md)
and [verification scope](../verification.md).

## Earlier assets

- `linkedin-performance-gen2-gen3.png` and its `-v2` revision are superseded
  drafts. Their middle card uses the earlier RX64 Gen2 measurement,
  428.7/260.1 MB/s, rather than the later default Gen2 ACK-retirement build.
- [Historical LinkedIn draft](linkedin-post.md) and
  [marketing asset notes](linkedin-marketing-v2.md) describe the original
  packaged Gen2 launch.
- `linkedin-soft-pcie.svg` and `.png` show the older transmit-buffering baseline,
  rounded to 428.6/260.1 MB/s. The SVG remains editable.

## Latest graphic alt text

Three cards compare originally shared Gen2, Gen2 with ACK retirement, and
experimental Gen3 with ACK retirement. Read/write figures are respectively
428.3/259.7, 428.3/260.2, and 745.4/567.7 MB/s. An amber banner says
“Gen3 pending further stabilization.” Gen2 uses 32-bit host packet paths and two
prefetch slots; Gen3 uses 64-bit paths and eight slots. The footer states that
no hard PCIe block or vendor PCIe controller IP is used.

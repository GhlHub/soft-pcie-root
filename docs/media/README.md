# Performance graphics

The current [Gen3 x1 graphic](linkedin-soft-pcie.png) is the README lead image
and is suitable for sharing. Its editable [SVG](linkedin-soft-pcie.svg) and
[renderer](../../scripts/render_graphic.py) use the requester-fix hardware
[evidence](../evidence/requester_fix_v1/completion.json) as the numeric source.
Regenerate with `python3 scripts/render_graphic.py` (Pillow and DejaVu Sans).

It shows **733.45 MB/s read / 564.16 MB/s write**, sequential 1 MiB, QD8,
direct/libaio, one job, 30 seconds per workload on ZCU104 with Samsung 990 EVO
1 TB. These are separate read/write tests, not simultaneous aggregate bandwidth.
The diagram is conceptual; it is not a photograph or an electrical schematic.
The qualification note retains Gen3's experimental status. The latest image was
temporarily programmed; SD still selects RX metadata.

Alt text: A dark blue Gen3 x1 soft PCIe performance card shows 733.45 MB/s
sequential read and 564.16 MB/s sequential write. Linux and DDR connect through
soft PCIe RTL and one GTH to an NVMe SSD. It states that no hard PCIe controller
or vendor PCIe controller IP is used and includes workload and qualification
scope. See the [current post draft](linkedin-gen3-current.md).

## Historical ACK-retirement comparison

Use [the ACK-retirement comparison](linkedin-ack-retirement-gen2-gen3.png) for
the historical ACK-retirement Gen2/Gen3 comparison. Its conceptual hardware illustration
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
the unified version 1.1 catalog package. Later unified Gen3 images passed routing,
startup and physical I/O/CRC tests; the RX metadata image reached +0.136 ns WNS
and 734.84/564.79 MB/s QD8 read/write. The graphic retains its original historical
figures. See the [performance history](../performance-history.md)
and [verification scope](../verification.md).

## RX parser timing graphic

The [RX parser timing graphic](linkedin-rx-parser-timing-v2.png) and
[post/evidence notes](linkedin-rx-parser-timing.md) describe the +0.090 to
+0.136 ns timing improvement and 6,745-entry equivalence comparison. Its 85-test
count belongs to that build. Later simulation-only verification increased the
repository regression to 1,663 tests without changing that hardware evidence.

## Earlier assets

- `linkedin-performance-gen2-gen3.png` and its `-v2` revision are superseded
  drafts. Their middle card uses the earlier RX64 Gen2 measurement,
  428.7/260.1 MB/s, rather than the later default Gen2 ACK-retirement build.
- [Historical LinkedIn draft](linkedin-post.md) and
  [marketing asset notes](linkedin-marketing-v2.md) describe the original
  packaged Gen2 launch.
- `linkedin-soft-pcie-gen2-baseline.svg` and `.png` show the older transmit-buffering baseline,
  rounded to 428.6/260.1 MB/s. The SVG remains editable.

## Historical comparison alt text

Three cards compare originally shared Gen2, Gen2 with ACK retirement, and
experimental Gen3 with ACK retirement. Read/write figures are respectively
428.3/259.7, 428.3/260.2, and 745.4/567.7 MB/s. An amber banner says
“Gen3 pending further stabilization.” Gen2 uses 32-bit host packet paths and two
prefetch slots; Gen3 uses 64-bit paths and eight slots. The footer states that
no hard PCIe block or vendor PCIe controller IP is used.

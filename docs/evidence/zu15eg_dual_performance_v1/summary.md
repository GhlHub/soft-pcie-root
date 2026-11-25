# ZU15EG simultaneous NVMe read performance

Two fio 3.38 workers per drive, one per Cortex-A53 core. Each worker ran
30 seconds of direct sequential reads with 1 MiB I/O, libaio, queue depth 4,
and a separate 4 GiB range. Both negotiated link speeds and widths were checked
before and after each run. All reported runs recorded zero SSD writes.

| PCIe mode on both links | 990 EVO 1 TB (MB/s) | 990 PRO 2 TB (MB/s) | Combined (MB/s) |
| --- | ---: | ---: | ---: |
| Gen1 x2 | 295.23 | 318.41 | 613.64 |
| Gen2 x1 | 427.14 | 429.45 | 856.59 |
| Gen2 x2 | 589.03 | 603.29 | 1,192.33 |
| Gen3 x1 | 727.84 | 702.04 | 1,429.89 |
| Gen3 x2 | 758.51 | 764.96 | 1,523.47 |

Socket A uses the Samsung 990 EVO 1 TB, and socket B uses the Samsung 990 PRO 2 TB.
All runs used RAM Linux 6.6.70. Gen1 x2 and Gen2 x2 used the same programmable image.
The Gen3 x1 image adds a register to distribute synchronized startup reset release.
The Gen3 x2 image passed routing with +0.001 ns setup margin.

[Per-worker results and artifact hashes](completion.json)

## Full-DDR Gen3 x2 retest

Both SSDs passed direct reads into verified upper-DDR buffers and matched
their previous 256 MiB checksums. The SWIOTLB usage and high-water counters
were zero after the fio runs. Each drive still reported a 252 KiB Linux
hardware request limit.

| IRQ placement A / B | 990 EVO (MB/s) | 990 PRO (MB/s) | 4 GiB DMA total (MB/s) | 2 GiB DMA total (MB/s) | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU 0 / CPU 0 | 913.75 | 868.34 | 1,782.09 | 1,501.11 | +18.7% |
| CPU 0 / CPU 2 | 913.75 | 868.32 | 1,782.07 | 1,440.10 | +23.7% |

Each condition used one 30-second trial with the same four-worker IO
settings as the 2 GiB DMA retest. CPU utilization fell from about
97–98% to about 8–12% per core. Both drives recorded zero writes.
[Full-DDR measurements](gen3-x2-full-ddr.json) · [2 GiB DMA reference](gen3-x2-irq-affinity.json)

## Posted receive credit comparison

The 8/64 setting doubles the posted-write window from four to eight
128-byte TLPs per port. The benchmarks retained the four-worker read
workload above and verified both SSDs against their known checksums.

| Mode on both ports | DMA-accessible DDR | 4/32 combined (MB/s) | 8/64 combined (MB/s) | Gain |
| --- | ---: | ---: | ---: | ---: |
| Gen2 x2 | 2 GiB | 1,192.33 | 1,424.63 | +19.5% |
| Gen3 x2 | 4 GiB | 1,785.26 | 2,487.04 | +39.3% |

The Gen2 comparison uses the earlier single-run 4/32 result and the median
of three 8/64 runs. The Gen3 comparison uses two builds from the same source,
one per setting, with three trials per build. Both Gen3 builds verified
upper-DDR DMA and recorded zero SWIOTLB usage. All trials recorded zero
host writes. [Gen2 measurements](gen2-x2-credit8.json) ·
[Gen3 measurements](gen3-x2-posted-credit-compare.json)

# Repeatable random I/O benchmark

The `randrw-4k-70r30w-qd32-15m.fio` preset defines a 900-second mixed random
workload: 4 KiB requests, 70% reads and 30% writes, one libaio job, queue depth
32, direct I/O, no ramp period, fixed random seed 20261027, and a 4 GiB working
region beginning at 8 GiB. It is a project comparison preset using fio, not
an industry certification or a full-drive steady-state test. Reads and writes
run concurrently; the results are not separate pure-read/pure-write maxima.

**This job overwrites bytes [8 GiB, 12 GiB) on `/dev/nvme0n1`.** Run only with
explicit write authorization on an identified expendable drive, after checking
its identity, capacity, mount/holder/swap state and idle hardware. Do not run
against an occupied filesystem or RAID member. The laboratory drive has an
inactive historical partition signature; that does not imply authorization for
other drives. No formatting or partition changes are part of this procedure.

After those checks, use fio 3.38 and a fresh output directory:

```sh
fio docs/benchmarks/randrw-4k-70r30w-qd32-15m.fio \
  --output-format=json --output=RUN/result.json \
  --write_bw_log=RUN/bandwidth --write_iops_log=RUN/iops \
  --write_lat_log=RUN/latency
```

Replace `RUN` with the new output directory. The preset requests one-second
averaged logs and completion-latency percentiles. Retain the JSON report and
logs, exact job settings, image identity, link speed/width, fio/kernel versions,
drive model/firmware, and before/after SMART and block counters. Flush the drive
at completion, check zero fio errors, reconcile written bytes against block
sectors, and confirm the controller returns to healthy idle. An existing CRC
pattern outside the working region can check for collateral corruption; it
does not verify the newly written random payload.

For comparison, keep block size, mix, queue depth, working region, runtime,
seed, buffer settings, CPU/software environment and logging unchanged. Record
SSD temperature and previous workload because drive state can affect results.
The fixed seed does not guarantee identical I/O scheduling. For statistical
comparisons, repeat runs with the same conditioning procedure and report
variation. Do not compare these numbers directly with the project's 1 MiB
sequential benchmarks.

## TX transform baseline, 2026-10-27

The current Gen3 x1 TX transform image completed the full 900-second preset on
a Samsung 990 EVO 1 TB, firmware 0B2QKXJ7, Linux 6.6.70 and fio 3.38.

| Direction | IOPS | MB/s (decimal) | Mean completion latency | p99 completion latency | p99.9 completion latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Read | 29,457.75 | 120.66 | 0.749 ms | 0.848 ms | 2.212 ms |
| Write | 12,623.33 | 51.71 | 0.722 ms | 0.807 ms | 0.831 ms |

Combined: 42,081.09 IOPS / 172.36 MB/s. Exactly 46,534,705,152 bytes were
written. Zero fio errors; flush, exact block write accounting, healthy idle,
and an independent 256 MiB read-only CRC outside the test region passed. SMART
warnings, media errors and error-log entries stayed zero; unsafe shutdowns
stayed unchanged. Composite temperature rose from about 36 to 44 degrees C
with no thermal-management transitions. The random-written payload itself was
not CRC-verified.

fio CPU usage was 40.47% user plus 59.36% system, nearly one CPU core. This
measurement may therefore include a CPU/software bottleneck and is not proof
of the PCIe datapath's maximum random-I/O capacity. Approximate combined IOPS
from one-second samples averaged 45,519, 40,850 and 39,919 across the three
five-minute windows. Preserve the full-duration comparison rather than
selecting the fastest opening interval. Gen3 remains experimental and pending
further stabilization/qualification.

[Sanitized run evidence](../evidence/tx_transform_v1/random-rw-15m.json). Raw
fio reports and time-series logs are retained in the ignored local laboratory
run directory `build/lab/random_rw_15m_v1/results`.

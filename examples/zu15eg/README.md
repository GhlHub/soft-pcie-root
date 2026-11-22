# ZU15EG soft PCIe bring-up

The x1 build targets the XCZU15EG Core V1.0 / F V1.0 carrier with an
Opsero OP063 and one NVMe SSD in socket A. Confirm the adapter model,
socket, carrier revision and FPGA marking before loading the image.
See [x2 development](../../docs/x2-development.md) for the two-lane design
and verification status.

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

The x1 example uses `xczu15eg-ffvb1156-2-i`, the device in the board
manual. The PL GTH path is separate from the PS PCIe connection to the
carrier's onboard M.2 socket.

OP063 supplies the 100 MHz common reference clock. Verify the carrier's
fixed 1.8 V VADJ at C309 before programming. The OP063 profile drives the
active-high SSD A reset on R10 and the active-high SSD B regulator
disable on M11. Other adapters may use different sidebands even if their
data lanes reach the same transceiver.

With an FMC card present, the carrier selects FMC TDO for the JTAG return.
If the chain scan fails, power off, remove the card and compare the scan
after powering up again. If the FPGA reappears, check the card's TDI-to-TDO
continuity before proceeding with the card fitted.

## Vivado IP catalog

Generate version 1.2 with all four modes using a fresh output directory.
The example selects the corresponding catalog mode from its build profile.

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -tclargs build/zu15eg_catalog_1_2 0 zu15eg catalog
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_gen3_x2 build/zu15eg_catalog_1_2/core dp01-passive gen3-x2
```

| Build profile | PCIe mode |
| --- | --- |
| `legacy` | Gen1/Gen2 x1 (default) |
| `gen2-x2` | Gen1/Gen2 x2 |
| `gen3` | Gen3 x1 |
| `gen3-x2` | Gen3 x2 |

Use the stage-specific package below for the fixed-rate `gen1-x2` build.
Choose the FMC pin profile for the installed adapter. The hardware results
on this page identify the stage-specific images used for those measurements.
[Vivado customization and AXI interface](../../ip/soft_pcie_root/README.md#zu15eg-catalog)

## Build x1

From the repository root with Vivado 2026.1 on PATH, use fresh output
directories.

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -tclargs build/zu15eg_ip 0 zu15eg
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_legacy build/zu15eg_ip/core op063-a legacy
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_gen3 build/zu15eg_ip/core op063-a gen3
vivado -mode batch -source scripts/audit_zu15eg_x1.tcl \
  -tclargs build/zu15eg_legacy/routed.dcp build/zu15eg_legacy_audit
vivado -mode batch -source scripts/audit_zu15eg_x1.tcl \
  -tclargs build/zu15eg_gen3/routed.dcp build/zu15eg_gen3_audit
```

The package generates the native PHY on a ZU9EG reference device with the
same GTH sites because Vivado does not expose that PHY generator directly
on ZU15EG. The assembled design is synthesized and routed for ZU15EG.

The first local OP063-A builds passed route and reopened audits on
2026-11-21. Setup and hold slack were +0.100/+0.013 ns for the legacy
backend and +0.223/+0.011 ns for the Gen3 backend. The legacy route was
restarted from its saved synthesis checkpoint. Confirm the installed
adapter before using the OP063-specific sidebands.

## Stage the first boots

Start each trial from a clean boot. Use the board's matching PS/DDR
initialization, temporary PL configuration and a Linux initramfs with the
existing soft PCIe driver and NVMe support. Compile
[`soft-pcie.dts`](soft-pcie.dts) against the Linux kernel's Xilinx device
tree includes. UART0 provides the console. HP0 DMA is noncoherent and
the host advertises only the lower 2 GiB DDR aperture to the endpoint.

| Stage | Backend | Setup before enabling the host |
| --- | --- | --- |
| Gen1 x1 | Legacy | Set SRP1 control at `0xa0000010` to `0x2` while disabled. The driver sets bit 0 and preserves bit 1. |
| Gen2 x1 | Legacy | Use the reset default with force-Gen1 clear. |
| Gen3 x1 | Gen3 | Use the reset default and verify that startup reached 8 GT/s. |

For each stage, verify actual speed and width from the endpoint's PCIe
Link Status, check that Linux found an NVMe controller on the soft host
at `0001:01:00.0`, and compare checksums from two complete direct reads
of the same range on the identified, unmounted namespace. Check for DMA
or configuration faults before advancing. The Gen1 x2 stage uses the
separate build below.

## Physical x1 checkout

On 2026-11-21, the ZU15EG carrier enumerated a Samsung 990 EVO 1 TB
through FMC DP0 at Gen1, Gen2 and Gen3 x1. At each rate, Linux 6.6.70
read the same 256 MiB range twice directly. All six checksums matched
and the namespace write counters stayed constant. Gen3 x1 remained
active and idle with NVMe interrupts delivered and healthy root/DDR status.

The test used volatile JTAG images with the FMC reset and power pins
undriven, since the adapter's model was unconfirmed. Both FMC reference
clock inputs were active, and the carrier detected the card. Physical
VADJ measurement and validation of the OP063-specific sidebands remain
open for this setup. [Recorded hardware evidence](../../docs/evidence/zu15eg_x1_v1/completion.json)

The Gen3 x1 read baseline is **556.57 MB/s at QD1** and **707.04 MB/s at QD8**.
Both jobs ran for 30 seconds with 1 MiB sequential direct I/O through fio/libaio.
The ZCU104 adaptive review-fix image measured 591.48 and 737.37 MB/s with the
same workload and SSD model. The ZU15EG measured 5.9% lower at QD1 and 4.1% lower
at QD8 across the two board setups. [ZU15EG hardware evidence](../../docs/evidence/zu15eg_x1_v1/completion.json)
[ZCU104 benchmark history](../../docs/performance-history.md#comparable-physical-benchmarks)

## Gen1 x2 development stage

The `gen1-x2` build fixes PIPE RATE to Gen1 and uses the full 128-bit DDR
interface. The `dp01-passive` profile connects DP0, DP1 and GBTCLK0 while
leaving the FMC sidebands undriven. Use fresh directories for each command.

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -tclargs build/zu15eg_x2_ip 1 zu15eg gen1-x2
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_gen1_x2 build/zu15eg_x2_ip/core dp01-passive gen1-x2
vivado -mode batch -source scripts/audit_zu15eg_gen1_x2.tcl \
  -tclargs build/zu15eg_gen1_x2/routed.dcp build/zu15eg_gen1_x2_audit
```

Read the endpoint's PCIe Link Status to confirm Gen1 x2 before using the
Linux driver to check the namespace. The DBR1 packet-capacity value for
this build is `0x1004`.

On 2026-11-22, the ZU15EG established Gen1 x2 with a Samsung 990 EVO 1 TB.
Endpoint configuration space and Linux sysfs both reported 2.5 GT/s on two
lanes. Two direct 256 MiB reads matched the earlier x1 checksum. Sequential
1 MiB direct reads measured **271.89 MB/s at QD1** and **306.15 MB/s at QD8**
with the same 30-second fio/libaio workload. Namespace write counters stayed
constant, and the root and DDR bridge passed the final idle check. The
reopened checkpoint passed with +0.076 ns setup and +0.016 ns hold slack.
[Gen1 x2 hardware evidence](../../docs/evidence/zu15eg_gen1_x2_v1/completion.json)

### Four-core Gen1 comparison

The same board, SSD and RAM Linux image ran four fio/libaio workers at both
widths, one pinned to each Cortex-A53 core. The 30-second trials used 1 MiB
direct sequential reads with a separate 4 GiB range per worker. Linux
confirmed 2.5 GT/s at each width.

| Aggregate queue depth | Gen1 x1 | Gen1 x2 | x2 gain |
| ---: | ---: | ---: | ---: |
| 4 | 213.65 MB/s | 305.59 MB/s | 43.03% |
| 8 | 213.76 MB/s | 305.74 MB/s | 43.03% |
| 16 | 213.66 MB/s | 305.59 MB/s | 43.03% |

QD8 reports the median of two runs at each width. The x2 result was within
0.2% of the earlier single-core result of 306.15 MB/s. The busiest core
stayed below 11% across the captures. Both widths passed the direct-read
checksum checks and recorded zero SSD writes. These measurements include
the host datapaths of the two staged implementations.
[Four-core measurement evidence](../../docs/evidence/zu15eg_gen1_x2_v1/four-core-comparison.json)

## Gen2 x2 development stage

The `gen2-x2` package links the same two GTH lanes and host bridge. It starts
at Gen1, then negotiates Gen2 with the endpoint. Both lanes must complete the
shared PIPE rate change. The board flow targets 250 MHz link timing and
checks the 125 MHz startup mode before bitstream generation. Decoded-symbol
simulation passed. The reopened route passed with +0.194 ns setup slack at
250 MHz, +0.351 ns at 125 MHz, and +0.012 ns hold slack in both modes.

The endpoint configuration space reported Gen2 x2 after the volatile JTAG
load. The link failed to retrain after the RAM Linux firmware reset. A
PL-only reload with the processor system already initialized reproduced
the training failure. The clock was still running at 125 MHz and both PHY
receivers were detected. A further PL-only reload of the same image with
Gen1 forced reached 2.5 GT/s x2 and read the endpoint configuration space.
A warm Gen2 boot after that successful Gen1 control still failed to train.
[Gen2 x2 implementation and link evidence](../../docs/evidence/zu15eg_gen2_x2_v1/implementation.json)

In a subsequent RAM boot, a startup trace enabled the link before loading
the Linux driver. The same image negotiated 5.0 GT/s x2 and the driver bound
to the live link. Both 256 MiB direct reads matched the Gen1 x2 checksum.
The 30-second sequential read workload measured **472.23 MB/s at QD1** and
**589.85 MB/s at QD8**. The namespace write counters stayed at zero. This was
one successful warm run. Cold-start repeatability remains open.
[Gen2 x2 hardware evidence](../../docs/evidence/zu15eg_gen2_x2_v1/completion.json)

### Four-core Gen2 comparison

The same board, SSD, and RAM Linux image ran 30-second direct sequential
1 MiB reads at both widths. All four Cortex-A53 cores were online, with one
fio/libaio worker pinned to each core. Each worker read a separate 4 GiB
range. Linux confirmed 5.0 GT/s and the expected width before each set.

| Aggregate queue depth | Gen2 x1 | Gen2 x2 | x2 gain |
| ---: | ---: | ---: | ---: |
| 4 | 426.98 MB/s | 590.41 MB/s | 38.28% |
| 8 | 427.19 MB/s | 590.74 MB/s | 38.28% |
| 16 | 426.99 MB/s | 590.46 MB/s | 38.28% |

QD8 reports the median of two runs at each width. The Gen2 x2 QD8 result
was close to the earlier single-core result of 589.85 MB/s. The busiest
core stayed below 23% across the captures. These measurements compare the
two staged implementations, including their different host datapaths.
Both widths passed the direct-read checksum checks with zero SSD writes.
[Four-core measurement evidence](../../docs/evidence/zu15eg_gen2_x2_v1/four-core-comparison.json)

### Build the Gen2 x2 image

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -tclargs build/zu15eg_gen2_x2_ip 1 zu15eg gen2-x2
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_gen2_x2 build/zu15eg_gen2_x2_ip/core dp01-passive gen2-x2
vivado -mode batch -source scripts/audit_zu15eg_gen1_x2.tcl \
  -tclargs build/zu15eg_gen2_x2/routed.dcp build/zu15eg_gen2_x2_audit gen2-x2
```

## Gen3 x2 development stage

The `gen3-x2` package uses the same two lanes and wide AXI bridge. It
negotiates Gen3 from Gen1, qualifies both lanes during PHY rate change and
equalization, and runs the bonded 64-bit Gen3 packet path. The first reopened
route met timing in all three modes.

| Link mode | Clock | Setup slack | Hold slack |
| --- | ---: | ---: | ---: |
| Gen1 | 125 MHz | +0.329 ns | +0.010 ns |
| Gen2 | 250 MHz | +0.056 ns | +0.010 ns |
| Gen3 | 250 MHz | +0.056 ns | +0.010 ns |

The passive profile passed the pin, routing and CDC checks. The first
volatile Gen3 image timed out in Configuration.Complete while still at
Gen1, before the rate change. [Implementation evidence](../../docs/evidence/zu15eg_gen3_x2_v1/implementation.json)

The TS2 startup correction got the board through Configuration.Complete
and into Gen3 Phase 1. The per-lane failure record showed that the receiver
started inside a block on both lanes. The next image discards incoming
continuation words until it sees a block start. The wire-peer tests continue
to reject a continuation without a start after alignment.
[Equalization failure record](../../docs/evidence/zu15eg_gen3_x2_v1/equalization-diagnostic.json)

The receiver correction passed the reopened audit with +0.021 ns setup
slack at Gen2 and Gen3. The same image enumerated the SSD at forced Gen1 x2.
Three automatic Gen3 warm trials stopped in Gen1 Polling.Configuration,
including a trial after the forced-Gen1 control.
[Receiver correction and board trial evidence](../../docs/evidence/zu15eg_gen3_x2_v1/receiver-boundary.json)

A subsequent diagnostic warm boot passed Polling.Configuration and Gen3
Phase 1, then failed before L0. An integrated native PIPE test reproduced
the later failure by starting inside a peer block. The packet receiver
runs alongside the equalization receiver, so it now also waits for the
first valid block start on each lane. Existing framing checks govern the
rest of the stream.
[Polling diagnostic image and hardware trace](../../docs/evidence/zu15eg_gen3_x2_v1/polling-diagnostic.json)

The corrected image passed the reopened audit with +0.139 ns Gen1 setup,
+0.024 ns Gen2/Gen3 setup, and +0.011 ns hold slack in all modes. All 2,510
regression tests and real-XPM lint and elaboration passed.
[Implementation evidence for the tested image](../../docs/evidence/zu15eg_gen3_x2_v1/packet-receiver-start.json)

The corrected image reached Gen3 x2 on a warm PL reload. Linux reported
8.0 GT/s x2, both direct 256 MiB reads matched the earlier stages, and the
namespace write counters stayed at zero. The link was healthy and idle
after the runs. Cold-start repeatability and physical VADJ measurement
remain open. [Gen3 x2 hardware evidence](../../docs/evidence/zu15eg_gen3_x2_v1/completion.json)

The routed x2 board design uses 50,677 LUTs (14.85%), 29,620 flip-flops
(4.34%), 3.5 block RAM tiles and two GTH channels. The earlier routed Gen3 x1
image uses 16,120 LUTs (4.72%), 12,367 flip-flops (1.81%), three block RAM
tiles and one GTH channel. Both builds use zero DSP and UltraRAM blocks.

The 30-second 1 MiB direct fio/libaio reads measured **668.04 MB/s at QD1**
and **678.91 MB/s at QD8**. Compared with the earlier Gen3 x1 run on the
same carrier and SSD, Gen3 x2 was 20.0% faster at QD1 and 4.0% slower at QD8.
The separate runs leave repeatability and the limiting stage open.
[Gen3 x1 baseline](../../docs/evidence/zu15eg_x1_v1/completion.json)

A follow-up on the same Gen3 x2 image isolated a host-side limit in the
original single-core RAM Linux setup. With CPUs 0 and 1 online, two QD4
fio jobs on CPU 0 reached **573.92 MB/s**. Splitting those same jobs across
the two CPUs reached **918.07–920.80 MB/s** in repeated 10-second trials and
**921.21 MB/s** in a 30-second trial. Both jobs used 1 MiB direct reads and
separate 4 GiB ranges. Linux mapped each CPU to a distinct NVMe submission
queue and kept the parent PCIe interrupt on CPU 0. The experiment varies both
CPU and submission-queue parallelism.

Four workers pinned across four CPUs stayed near 918 MB/s at aggregate QD8
and QD16. At the higher rate, the DDR bridge applied receive backpressure
for about 0.3% of host cycles. The counters show that heavy bridge input
backpressure was absent. The cause of the roughly 920 MB/s ceiling remains
open. The board finished at Gen3 x2 with CPU 0 online and zero SSD writes.
[Host scaling evidence](../../docs/evidence/zu15eg_gen3_x2_v1/host-scaling.json)

### Two-thread Gen3 comparison

Both widths ran two 30-second trials with two fio threads pinned to CPUs 0
and 1, one per core. Each thread used QD4 and a separate 4 GiB range with
1 MiB direct sequential reads through libaio. Linux confirmed 8.0 GT/s and
the expected lane width. The median aggregate-QD8 result was **734.56 MB/s
at Gen3 x1** and **920.87 MB/s at Gen3 x2**, a **25.36%** x2 gain. Both
widths passed the checksum checks with zero SSD writes.
[Two-thread measurement evidence](../../docs/evidence/zu15eg_gen3_x2_v1/two-thread-comparison.json)

### Build the Gen3 x2 image

```sh
vivado -mode batch -source ip/soft_pcie_root/package.tcl \
  -tclargs build/zu15eg_gen3_x2_ip 1 zu15eg gen3-x2
vivado -mode batch -source examples/zu15eg/build.tcl \
  -tclargs build/zu15eg_gen3_x2 build/zu15eg_gen3_x2_ip/core dp01-passive gen3-x2
vivado -mode batch -source scripts/audit_zu15eg_gen1_x2.tcl \
  -tclargs build/zu15eg_gen3_x2/routed.dcp build/zu15eg_gen3_x2_audit gen3-x2
```

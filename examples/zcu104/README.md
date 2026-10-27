# ZCU104 Linux/NVMe example

The example instantiates the packaged `soft_pcie_root` IP alongside the ZCU104
PS preset, 50/125 MHz clock wizard, reset controller and AXI interconnects. It
connects one FMC LPC transceiver lane to SSD1. Linux runs on the PS and owns
system RAM, GEM Ethernet and the NVMe software stack. No SATA/switch/R5 packet
pool from any other project is required.

## Hardware used

ZCU104 Rev C, XCZU7EV-2FFVC1156; Opsero OP047 Rev D; Samsung 990 EVO 1 TB MZ-V9E1T0.
VADJ was physically checked at 1.8 V; U-Boot telemetry was 1.797 V. SSD2 remains empty.
The original measured source baseline was `txdouble_v1`; subsequent Gen2 and
experimental Gen3 builds are recorded in the
[performance history](../../docs/performance-history.md) and
[validation](../../docs/verification.md).

| Signal | Mapping |
| --- | --- |
| Lane 0 | FMC DP0, GTHE4_CHANNEL_X0Y15 |
| 100 MHz reference | V8/V7, common X0Y3, IBUFDS0_GTHE4 |
| FPGA active-high PERST_A | F17, LVCMOS18 |
| Legacy SSD2-disable helper | J16, LVCMOS18, fixed high |
| DDR | PS HP0, 128-bit at 125 MHz, noncoherent |
| IRQ | PL IRQ0, GIC SPI89 |

## Adapter compatibility

[Opsero's OP047 page](https://opsero.com/product/fpga-drive-fmc-dual/) says that
OP047 is discontinued and replaced by [OP063 FPGA Drive FMC Gen4](https://opsero.com/product/fpga-drive-fmc-gen4/).
The tested board remains OP047 Rev D. Its available D.1 schematic documents an
SSD2-control inverter; a Rev D label alone does not establish the exact assembly.
Keep SSD2 empty and verify polarity/power before relying on the helper signal.
The legacy `OP063` comments in some preserved RTL/XDC came from the initial
adapter identification; they do not establish OP063 hardware testing.

OP063 supports higher speeds, but **the frozen release supports at most Gen2 x1**. The
ZCU104 LPC example uses only SSD1 lane 0. OP063 has not been tested here, and its
EEPROM/power requirements must be reviewed. The supplied U-Boot initializer
accepts exact OP047 identification and refuses other cards; do not bypass that
check or rewrite an OP063 EEPROM to impersonate OP047. Extending that policy and
qualifying OP063 is future work. Experimental Gen3 x1 has been tested with OP047;
wider links remain future work.
[Current Opsero documentation](https://docs.opsero.com/op063/).

## Build the packaged-IP example

From the repository root, after sourcing Vivado 2026.1:

```sh
make ip IP_OUTPUT=build/ip_v1
make hardware OUTPUT=build/zcu104_v1 IP_REPO=build/ip_v1/core
make hardware-audit HARDWARE_OUTPUT=build/zcu104_v1 AUDIT_OUTPUT=build/audit_v1
```

Use new output names for each attempt. Sources are hashed at build start and
rechecked before accepting outputs. The audit reopens the routed checkpoint;
no PCIe hard macro may appear. Output includes system.bit, system.xsa, reports
and sources.json. The full example's resource count includes management/DDR/CDC,
not just the protocol engine.

For optional Gen3 packaging and its separate board recipe, see the
[integration guide](../../docs/ip-guide.md#optional-gen3-packaging) and
[experimental build instructions](../../experiments/gen3/README.md#current-design-and-reproduction).
The default commands above still select Gen1/Gen2. Latest shared RTL changes
have Gen3 physical evidence, not a new default-Gen2 hardware qualification.

## Linux and first boot

See [Linux instructions](../../software/linux/README.md) for the pinned Buildroot
flow, FMC VADJ initialization, module identity and PL-first device tree. Build
artifacts alone do not configure the board. Use the documented boot profile and
verify power/reset/reference on the actual assembly before installing an SSD.

Start with both SSD sockets empty. Configure and physically measure VADJ 1.8 V;
verify SSD supply/reference/reset as equipment permits. Cleanly shut down Linux
and switch off before fitting/removing the adapter or SSD. Load PL before Linux
binds the PCI host node. Check link speed/width, SSD identity, MSI activity and
SMART health before using an unmounted expendable drive for I/O tests.

Never reprogram PL, stop its reference, locally reset the active bridge or remove
the SSD while Linux owns it. The module pins itself after probe; use clean reboot
or shutdown for global recovery. Loading a new bitstream requires requalification
of the matching build, not just a successful synthesis message.

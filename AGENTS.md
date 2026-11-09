# Soft PCIe release workspace

Read README.md, docs/ip-guide.md, docs/registers.md, examples/zcu104/README.md and
docs/verification.md first. This repository is the authoritative development source.
Local board/deployment handoff, when available, is in ignored build/lab/HANDOFF.md. The
frozen release stops at Gen1/Gen2 x1. Current development also includes optional
Gen3 and shared RTL changes; see docs/performance-history.md and
docs/verification.md. Do not rewrite frozen provenance manifests to qualify later
code. Historical physical tests cover both Gen3 and a default Gen2 ACK-retirement
build; these are short I/O/CRC tests, not full qualification. The later unified 1.1
catalog/checkbox packaging has now been routed; its startup-corrected Gen3 image
passed ten controlled warm-start/read-only CRC trials. See
docs/evidence/startup_fix_v1/completion.json (+0.002 ns Gen3 setup margin).
The later RX metadata SD-default image passed physical I/O/CRC and warm boot
with +0.136 ns Gen3 WNS; see docs/evidence/rx_metadata_v1/completion.json.
Requester timeout fix subsequently passed a fresh Gen3 route/audit and temporary
board validation (28,000 config reads and NVMe I/O/CRC); see
docs/evidence/requester_fix_v1/completion.json. Exact
timeout-edge injection is simulation-only. A fresh default Gen2 package build
with this fix remains outstanding; later Gen2 fallback testing uses the
Gen3-enabled package and its 64-bit/eight-slot host path.
Latest full regression: 1,719 passed (233.25 seconds, 2026-11-03); lint/XPM and
131 HDL format checks pass. See docs/gen3-verification-matrix.md.
Later fallback-ownership/evaluation-priority fixes passed fresh route/audit and
three Gen3 startups plus I/O; see docs/evidence/adaptive_review_v1/completion.json.
Malformed-training/deadline collisions remain simulation-only. The review fixes became the SD
default on 2026-11-03; unattended warm boot and CRC passed. See
docs/evidence/adaptive_review_v1/default-boot.json.
Current development adds adaptive Phase 2/3 and startup-only Gen2 fallback.
Fresh route/audit and three controlled Gen3 startups/I/O passed 2026-11-02;
subsequent diagnostic tests passed forced Gen2 fallback and one packet-active
same-rate Recovery event. The normal image passed 33 verified I/O jobs and was
restored after diagnostic testing. See docs/hardware-coverage.md.
The earlier adaptive-EQ SD deployment also passed warm boot and CRC.
See docs/evidence/adaptive_eq_v2/default-boot.json. Existing Linux driver retained.
No fallback after Gen3 L0.
Cold-cycle, endurance, full Recovery and compliance qualification remain open.

Reusable sources: ip/soft_pcie_root/rtl; packaging: ip/soft_pcie_root/package.tcl;
board build/audit/constraints: examples/zcu104; Linux integration: software/.
Do not weaken whole-packet validation, credit/replay ownership, all-B-before-MSI,
noncoherent DMA or accepted-AXI drain. Packet RAM stays unreset. Never reset away
accepted ownership. No safe live reset/remove or stopped-reference recovery.

Original source license Apache-2.0; Linux host driver GPL-2.0-only; retain notices.
AMD IP is generated locally and not committed. No vendor/specification PDFs,
private deployment addresses, raw laboratory logs or credentials in releases.
Use fresh build outputs. Freeze RTL/scripts/constraints during hardware builds;
source manifests must match. Passing simulation or route is not physical proof.

Local builds/tests are authorized by normal development requests. Board/media
writes and publishing require user instructions. Do not infer access to a board
or a repository account from the existence of this example. No automatic SSD
formatting or service provisioning. See Makefile for reproducible commands.

Packaged example_zcu104_v1 subsequently passed physical Gen2 x1 I/O/CRC tests.
See docs/verification.md and docs/evidence/repackaged_v1/completion.json.
The image subsequently became the SD default; automatic warm boot and 256 MiB
read-only CRC passed. See the default-boot.json evidence beside completion.json.

## Session handoff — 2026-11-06

- Latest published commit: `8aacfa4` on `main`, pushed to `origin/main`.
  It includes hardware coverage tools/evidence and removes the experimental
  label from documentation and the current performance graphic. Describe
  Gen3 x1 as hardware-validated on the documented setup, retaining explicit
  qualification limits. The existing Vivado GUI display strings were not
  changed; documentation refers to the stable `ENABLE_GEN3` parameter.
- Last observed board state (2026-11-03): normal `adaptive_review_v1` SD image
  restored, Gen3 x1, healthy/idle, final 256 MiB read-only CRC passed. See
  `docs/evidence/hardware_coverage_v1/restored.json`. This is historical state,
  not a live availability check. Diagnostic images did not change SD/flash.
- Additional coverage: 33 normal-image verified I/O jobs; forced startup
  Gen2 fallback with eight I/O/integrity jobs and 14,000 configuration reads;
  one same-rate Recovery entry/return during active CRC reads. Two new
  overlay-control tests passed; the full regression count above is the
  earlier checkpoint, not a rerun including these tests.
- Gen3 x2 discussion was planning only; no implementation was requested or
  started. Current DDR AXI and host packet paths are 64-bit/125 MHz (1 GB/s);
  link packet processing is 32-bit/250 MHz (1 GB/s). Suggested x2 architecture:
  128-bit/125 MHz host and DDR AXI paths plus 64-bit/250 MHz aggregate link
  processing, each 2 GB/s. Existing PS HP0 is 128-bit/125 MHz; width conversion
  alone cannot remove the upstream bottleneck. Gen3 x2 has about 1.97 GB/s
  per direction before packet overhead. Reassess prefetch/replay bytes and
  measure sustained DDR bandwidth; doubled buffering is an initial estimate,
  not a verified requirement or throughput guarantee.
- No ongoing task or hardware build was left by this session. This handoff
  update is local and uncommitted unless a later session commits it.

## x2 development — 2026-11-08

The x1 handoff was committed as `4d99851` and tagged
`x1-hardware-validated-2026-11-08`; development is on `dev/pcie-x2`.
Read `docs/x2-development.md` before continuing. Lane-aware Gen3 codecs and
standalone striping/deskew components are simulation work, not an integrated
x2 root port. GUI width selection and shared Gen1 startup/Gen3 equalization
stages now have simulation coverage. The GUI defaults to x1; x2 requires Gen3
and root elaboration explicitly rejects it until integration is complete.
The separate Gen3 x2 64-bit packet/replay and 128-bit host/DDR datapaths now
have simulation coverage. Two-lane PHY/rate-change integration, root selection
and full end-to-end x2 peer simulation remain outstanding. Do not advertise x2
operation from the component tests. The board reference is the companion
ZU15EG workspace; extracted mapping is in `examples/zu15eg/README.md`.
The user initially deferred implementation verification until board availability,
then requested local PNR resource measurements on 2026-11-09. See
`docs/x2-resource-measurement.md`; physical verification remains deferred.
Development checkpoint validation: 1,756 tests passed (250.07 s), including
35 new component checks; lint/real-XPM and 133 HDL format checks passed.
These results do not close the outstanding integrated x2 simulation work.

Latest shared-training checkpoint: 1,843 tests passed (260.68 s), including
87 new training/GUI checks; lint/real-XPM, 135 HDL format checks and Vivado
metadata-only parameter propagation passed. Integrated x2 remains blocked.

User constraint: packet/host/DDR widening applies only to the Gen3 x2 build
(`ENABLE_GEN3=1`, `LINK_WIDTH=2`). Preserve existing widths for all x1 builds.
Interface widths are fixed at build time, including during lower-rate training.

Gen3 x2 datapath checkpoint: 2,100 tests passed (274.11 s), including 257 new
x2 tests; lint/real-XPM and 147 HDL formatting checks passed. Items 3/4 now
provide separate 64-bit packet and 128-bit host/DDR datapaths. Existing x1
widths remain unchanged; shared replay DATA_WIDTH defaults to 32. Root selection,
two-lane PHY/rate-change integration and full startup-to-I/O simulation remain
outstanding, so retain the x2 root elaboration guard. No implementation or
physical verification was performed. See docs/x2-development.md for contracts.

Local OOC PNR checkpoint — 2026-11-09: six separate x2 blocks routed on
xczu15eg-ffvb1156-2-e, totaling 115,054 LUTs and 51,710 registers, one BRAM
tile, no DSPs. RX fails setup by 24.489 ns (register-expanded packet RAM and
95-level parser path); TX/link fails by 0.013 ns. Host internal slack is
+1.025 ns, but CDC remains unqualified. No integrated root or board build.
RTL is unchanged from cdaa0e4. See docs/x2-resource-measurement.md and its
compact evidence before attempting timing fixes or making x2 readiness claims.

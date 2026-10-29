# Contributing

Keep protocol ownership, all-B-before-MSI ordering and accepted-AXI drain intact.
Run portable regressions and full Vivado/XPM checks for affected logic. A new
feature or throughput claim needs matched parameters, source hashes and explicit
simulation versus physical evidence. Preserve failed build evidence locally.

Map new protocol tests to the [Gen1/Gen2](docs/gen1-gen2-compliance-matrix.md)
or [Gen3](docs/gen3-verification-matrix.md) matrix. Record source hashes and
boundaries of the model; preserve historical evidence instead of rewriting it
to match a newer tree. The standard `make test` includes the independent Gen3
peers and rollover tests. Set `VIVADO_BIN` to the installed Vivado `bin` directory
for checks that need AMD simulation tools.

Original-code contributions use Apache-2.0; Linux host-driver contributions retain
GPL-2.0-only. Do not add vendor-generated IP, private keys, board access details,
PCI-SIG PDFs or GPL test-oracle source to synthesized RTL. Keep build outputs ignored.
No blanket false paths, DRC severity reductions or live reset of accepted owners.

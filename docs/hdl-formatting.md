# HDL formatting

All tracked `.sv`, `.v`, `.svh` and `.vh` files use the repository's
`.verible-format` settings: four-space indentation and continuation, a target
100-column line length, consistent operator spacing, and aligned assignments
and connections. Inherited-type port names stay grouped with their declaration.
Generated files under ignored build directories are not formatted.

Use [CHIPS Alliance Verible](https://github.com/chipsalliance/verible/releases),
version `v0.0-4296-g0f262651`, with its `bin` directory on `PATH` or supplied as
`VERIBLE_BIN`:

```sh
VERIBLE_BIN=/path/to/verible/bin make format-hdl
VERIBLE_BIN=/path/to/verible/bin make format-hdl-check
```

The formatter wrapper checks convergence and uses `verible-verilog-diff` to
verify identical HDL tokens before writing any files. Check mode makes no edits
and fails if formatting would change a file. No automatic tool download is
performed. The large diagnostic XOR in `gen3_eq_bringup.sv` exceeds Verible's
line-wrapping search limit; that module retains manual long-line wrapping while
receiving the other formatting rules. Long string literals and comments may
exceed the column target.

The 2026-10-28 pass reformatted 121 tracked HDL files, including shared host,
link and management logic, Gen3 RTL, board examples and testbenches. All HDL
files passed token comparison against commit `90c0f4d`. All 85 regression tests,
repository lint and real-XPM elaboration passed. This is a presentation
change, not a reset, ownership, protocol, timing or logic redesign.

Historical hardware source manifests intentionally retain the exact pre-format
hashes used for those builds. The formatted working tree has different byte
hashes and should not be represented as matching those manifests. No new
synthesis, PNR or physical qualification is claimed for the formatted files.
See [formatting evidence](evidence/format_v1/completion.json).

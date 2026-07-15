# Pre-built PYNQ-Z2 bitstreams (one per encoder precision)

`encode_eth_openjls_b<N>.bit.bin` is the EncodeOverEthernet demo synthesized
with the OpenJLS encoder at `BITNESS = N` (8..16), converted to the raw `.bin`
the Linux FPGA manager loads (bootgen, no boot header). The name ties the
artifact to the whole demo (`encode_eth_openjls`), not just the core, and the
`b<N>` suffix is the precision.

These are **committed build products**: regenerating all nine is a multi-hour
synth+impl sweep, so they live in-tree so the hardware-in-the-loop sweep
(`../../../Verification/run_hil_sweep.py`) can reload each depth on the board
without rebuilding. The Tcl remains the source of truth — an entry here is only
as current as the last `build_all_bitness.sh` run.

Rebuild (all depths, or a subset):

```sh
../build_all_bitness.sh            # 8..16
../build_all_bitness.sh 8 12 16    # subset
```

Not every depth is guaranteed to close timing / fit on the `xc7z020-1`; the
build script reports and skips any that don't, so this directory may legitimately
hold fewer than nine files.

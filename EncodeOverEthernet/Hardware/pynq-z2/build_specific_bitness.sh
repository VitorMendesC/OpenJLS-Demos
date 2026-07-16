#!/usr/bin/env bash
# Build the PYNQ-Z2 deploy artifacts for ONE encoder precision, from the Tcl
# sources to the exact files the board consumes:
#   1. bitstream  vivado build.tcl --bitstream --bitness N   (the slow step)
#   2. .bin       bootgen  — the raw image the Linux FPGA manager accepts
#                 (it rejects legacy raw .bit; only PYNQ's Python Overlay
#                 class converts those in software)
#   3. overlay    dtc      — openjls.dtso -> openjls.dtbo    (bitness-independent)
#
# Output (scp these to the board; board_setup.sh consumes exactly these names):
#   bitstreams/encode_eth_openjls_b<N>.bit.bin
#   openjls.dtbo
#
# This is the single-depth path — "I want to flash one board at BITNESS N".
# For the whole-corpus multi-depth build the HIL sweep reloads, use
# build_all_bitness.sh. Why per-depth bitstreams at all: BITNESS is a synth-time
# generic, and the DMA MM2S stream width moves with it — see INTERNALS.md.
#
# --no-bitstream skips steps 1-2 (no synthesis) and builds only the overlay,
# for when build_all_bitness.sh already produced the .bit.bin files (it does not
# build the overlay). It then checks the expected .bit.bin is present.
#
# Usage:
#   ./build_specific_bitness.sh                    # BITNESS 8: bitstream + overlay
#   ./build_specific_bitness.sh 12                 # BITNESS 12: bitstream + overlay
#   ./build_specific_bitness.sh --no-bitstream 12  # overlay only; expect b12 .bin
#
# Requires dtc, plus vivado + bootgen unless --no-bitstream (host shims into the
# vivado_box distrobox provide the latter two).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_BIT="$HERE/build/encode_ethernet.runs/impl_1/design_encode_ethernet_wrapper.bit"
OUT_DIR="$HERE/bitstreams"

b=8
build_bitstream=1
for arg in "$@"; do
  case "$arg" in
    -n|--no-bitstream) build_bitstream=0 ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]]; then b="$arg"
      else echo "unknown argument: '$arg' (expected a bitness 8..16 or --no-bitstream)" >&2; exit 2; fi ;;
  esac
done
if [ "$b" -lt 8 ] || [ "$b" -gt 16 ]; then
  echo "bitness must be in 8..16 (got '$b')" >&2; exit 2
fi

mkdir -p "$OUT_DIR"
out="$OUT_DIR/encode_eth_openjls_b${b}.bit.bin"

if [ "$build_bitstream" = 1 ]; then
  echo "=== 1/3 bitstream (BITNESS $b) ==="
  # build.tcl gates on post-route WNS, so a produced .bit is already timing-clean.
  rm -f "$WRAPPER_BIT"
  vivado -mode batch -source "$HERE/build.tcl" -tclargs --bitstream --bitness "$b"
  [ -f "$WRAPPER_BIT" ] || { echo "no bitstream produced (timing/fit?) — see build/ logs" >&2; exit 1; }

  echo "=== 2/3 .bin (bootgen) ==="
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp "$WRAPPER_BIT" "$tmp/system.bit"
  echo 'all: { system.bit }' > "$tmp/system.bif"    # bootgen's input list: one bitstream
  ( cd "$tmp" && bootgen -image system.bif -arch zynq -process_bitstream bin -w )
  mv "$tmp/system.bit.bin" "$out"
  echo "-> ${out#"$HERE"/}"
else
  echo "=== bitstream skipped (--no-bitstream) ==="
fi

echo "=== 3/3 overlay (dtc) ==="
dtc -@ -O dtb -o "$HERE/openjls.dtbo" "$HERE/openjls.dtso"
echo "-> openjls.dtbo"

# In --no-bitstream mode the .bin must come from elsewhere; say so plainly.
if [ "$build_bitstream" != 1 ] && [ ! -f "$out" ]; then
  echo
  echo "note: ${out#"$HERE"/} is not present — build it with" >&2
  echo "      ./build_specific_bitness.sh $b   or   ./build_all_bitness.sh $b" >&2
fi

echo
echo "artifacts for BITNESS $b — scp to the board (then run board_setup.sh $b):"
[ -f "$out" ] && echo "  $out" || echo "  $out   (MISSING — see note above)"
echo "  $HERE/openjls.dtbo"

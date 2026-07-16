#!/usr/bin/env bash
# Build one PYNQ-Z2 bitstream per encoder precision (BITNESS 8..16) and stage
# each as bitstreams/encode_eth_openjls_b<N>.bit.bin — the committed artifacts
# the HIL sweep (../../Verification/run_hil_sweep.py) reloads on the board. Then
# compile the shared, precision-independent overlay (openjls.dtbo) once, so this
# script is self-contained: same outputs as build_specific_bitness.sh, every
# depth. For a single precision, use build_specific_bitness.sh instead.
#
# Each depth is a full synth+impl run (this design only closes timing with the
# Congestion_SpreadLogic_high strategy build.tcl sets), so the whole sweep is
# hours. A depth that fails to fit or close timing is reported and skipped, not
# fatal — you still get every depth that built. Higher depths use more PL and
# may be the ones that don't close on the -1 speed grade.
#
# Usage:
#   ./build_all_bitness.sh                # all depths 8..16
#   ./build_all_bitness.sh 8 12 16        # only these depths
#
# Requires vivado + bootgen + dtc on PATH (host shims into the vivado_box
# distrobox provide vivado + bootgen).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_BIT="$HERE/build/encode_ethernet.runs/impl_1/design_encode_ethernet_wrapper.bit"
OUT_DIR="$HERE/bitstreams"

mkdir -p "$OUT_DIR"

DEPTHS=("$@")
[ ${#DEPTHS[@]} -eq 0 ] && DEPTHS=(8 9 10 11 12 13 14 15 16)

ok=(); fail=()
for b in "${DEPTHS[@]}"; do
  echo "================ BITNESS $b ================"
  rm -f "$WRAPPER_BIT"

  if ! vivado -mode batch -source "$HERE/build.tcl" -tclargs --bitstream --bitness "$b"; then
    echo "!! BITNESS $b: vivado build failed"; fail+=("$b"); continue
  fi
  if [ ! -f "$WRAPPER_BIT" ]; then
    echo "!! BITNESS $b: no bitstream produced (timing/fit?)"; fail+=("$b"); continue
  fi

  # bootgen: emit the raw .bin (no boot header) the Linux FPGA manager accepts.
  tmp="$(mktemp -d)"
  cp "$WRAPPER_BIT" "$tmp/system.bit"
  echo 'all: { system.bit }' > "$tmp/system.bif"
  if ! ( cd "$tmp" && bootgen -image system.bif -arch zynq -process_bitstream bin -w ); then
    echo "!! BITNESS $b: bootgen failed"; fail+=("$b"); rm -rf "$tmp"; continue
  fi
  mv "$tmp/system.bit.bin" "$OUT_DIR/encode_eth_openjls_b${b}.bit.bin"
  rm -rf "$tmp"
  echo "== BITNESS $b -> bitstreams/encode_eth_openjls_b${b}.bit.bin"
  ok+=("$b")
done

# The overlay is precision-independent (UIO nodes + DMA buffers), so build it
# once here rather than per depth. Independent of the loop above, so it runs
# even if some depths failed to close timing.
echo "================ overlay (dtc) ================"
if dtc -@ -O dtb -o "$HERE/openjls.dtbo" "$HERE/openjls.dtso"; then
  echo "== overlay -> openjls.dtbo"; overlay_ok=1
else
  echo "!! overlay: dtc failed"; overlay_ok=0
fi

echo
echo "==================== summary ===================="
echo "built:   ${ok[*]:-(none)}"
echo "failed:  ${fail[*]:-(none)}"
echo "overlay: $([ "${overlay_ok:-0}" = 1 ] && echo openjls.dtbo || echo FAILED)"
[ ${#fail[@]} -eq 0 ] && [ "${overlay_ok:-0}" = 1 ]

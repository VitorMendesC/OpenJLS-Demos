# PYNQ-Z2 (Zynq-7020)

Build the FPGA artifacts, flash the board, encode images. Two scripts do the
work: `build_specific_bitness.sh` on the dev machine, `board_setup.sh` on the
board.

The design: PS7 GEM handles Ethernet; the OpenJLS encoder (`openjls_axis_regs`,
BITNESS 8) and an AXI DMA in Scatter/Gather mode sit in the PL on a 50 MHz
fabric clock. The CPU only shuttles bytes between the socket and the DMA — the
encode is 100% hardware. **The [`INTERNALS.md`](INTERNALS.md) doc explains why
each of those choices is what it is, walks the manual bring-up the scripts
automate, and covers porting to another board** — read it if a step fails or
you're changing the design.

## Contents

* `build_specific_bitness.sh` — build the board files (bitstream + overlay) for
  **one** precision. This is the quickstart path below.
* `build_all_bitness.sh` — build them for **every** precision (8..16): a
  bitstream per depth plus the shared overlay, staged for the HIL sweep.
* `board_setup.sh` — [in `../../Verification/`](../../Verification/board_setup.sh);
  one-shot board bring-up.
* `build.tcl` / `design_encode_ethernet.tcl` — recreate the Vivado project and
  its block design (the Tcl is the source of truth; the project is never
  committed).
* `openjls.dtso` — the device tree overlay source.

## Quickstart

Requires `vivado`, `bootgen`, and `dtc` on the dev machine, and a board on the
network with the demo `Software/` and the `u-dma-buf` module (`u-dma-buf.ko`)
already on it. `<N>` is the encoder precision (8..16); start with 8.

**1. Build the artifacts** (dev machine, from this directory):

```sh
./build_specific_bitness.sh 8
# -> bitstreams/encode_eth_openjls_b8.bit.bin
#    openjls.dtbo
```

**2. Copy them to the board** (default PYNQ login `xilinx` / `xilinx`; the board
is `192.168.3.1` over USB or `pynq` over Ethernet):

```sh
BOARD=xilinx@192.168.3.1
scp bitstreams/encode_eth_openjls_b8.bit.bin "$BOARD:~/bitstreams/"
scp openjls.dtbo "$BOARD:~/"
scp -r ../../Software "$BOARD:~/"      # first time only
```

**3. Bring the board up** (on the board, as root — one command per boot):

```sh
# scripts use $HOME, so under sudo pass it through explicitly
sudo env HOME=$HOME ./board_setup.sh 8       # 8 = encoder BITNESS to load
# -> "BOARD READY — BITNESS 8, buffers up, server listening on :19020"
```

`board_setup.sh` loads the PL, applies the overlay, frees the CMA pool, loads
`u-dma-buf`, verifies the buffers, and starts the server — idempotent, safe to
re-run.

**4. Encode** (from the host):

```sh
./ojls_client <board-ip> image.pgm    # writes image.jls
```

For the full byte-exact-vs-CharLS sweep across every precision, see
[`../../Verification/`](../../Verification/README.md).

## Building every precision

BITNESS is baked in at synthesis, so each precision is its own bitstream.
`build_all_bitness.sh` builds them all (hours — each is a full synth+impl),
stages `bitstreams/encode_eth_openjls_b<N>.bit.bin` for the HIL sweep to reload,
and compiles the shared overlay once at the end — so it's self-contained, same
outputs as `build_specific_bitness.sh` but for every depth. Why per-precision,
and why the 50 MHz clock and SG mode: see [`INTERNALS.md`](INTERNALS.md).

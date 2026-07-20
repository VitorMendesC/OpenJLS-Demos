# OpenJLS Ethernet demo — software

Two plain-C programs, no vendor libraries:

| Program | Runs on | Role |
|---|---|---|
| `ojls_server` | the board (Linux on the PS) | receives raw images over TCP, encodes them with the OpenJLS core in the PL via AXI DMA, returns the `.jls` stream |
| `ojls_client` | any host | sends a PGM, saves the returned `.jls`, reports throughput |

The server reaches the hardware **only through generic Linux interfaces** —
[UIO](https://www.kernel.org/doc/html/latest/driver-api/uio-howto.html) for
registers and [u-dma-buf](https://github.com/ikwzm/udmabuf) for DMA buffers —
so the same source runs unmodified on any board: porting is a block design +
device tree job, not a software one.

## Building

One Makefile builds both programs; you need `ojls_client` on your host and
`ojls_server` on the board. Each side runs `make` and ignores the binary it
doesn't use:

```sh
make            # on your host  -> ojls_client (native)
make            # on the board  -> ojls_server (native; a PYNQ image has gcc)
```

If the board has no toolchain (or no time to compile), cross-compile the server
on your host instead of the board-side `make`, then copy it over:

```sh
make CROSS_COMPILE=arm-linux-gnueabihf-   # 32-bit ARM (Zynq-7000)   -> scp ojls_server to the board
make CROSS_COMPILE=aarch64-linux-gnu-     # 64-bit ARM (Zynq UltraScale+)
```

Any C11 compiler + POSIX libc works — there's nothing board-specific in the
source. See the [demo README](../README.md) for how this fits the full setup.

## What the block design must provide

The server assumes the hardware side is the `openjls_axis_regs` wrapper
(`ThirdParty/OpenJLS/Sources/axi/openjls_axis_regs.vhd`) fed by a Xilinx AXI DMA:

* **AXI DMA in Scatter/Gather mode.** The server builds a descriptor ring per
  channel (in a third u-dma-buf, below), so one logical transfer chains past
  the 64 MiB a 26-bit length register allows — an image is bounded by the DMA
  buffers, not the DMA. The MM2S ring is framed (SOF/EOF) so the pixels present
  as one TLAST packet however many descriptors they span; the S2MM ring is
  walked after TLAST to sum the encoded byte count.
* MM2S stream width = the wrapper's `s_axis_pixel` width (8 bits for BITNESS 8,
  16 bits for BITNESS 9–16); S2MM stream width = `OUT_WIDTH` (default 64).
* DMA interrupts to the PS are **optional** — the server polls, and sleeps on
  the UIO interrupt instead when one is wired.
* `openjls_axis_regs`'s `s_axi_ctrl` register bank reachable from the PS (any base
  address; the device tree carries it).

## Device tree

Three kinds of nodes, addresses/sizes taken from your Address Editor
(concrete overlays live under `../Hardware/<board>/`):

```dts
/* openjls_axis_regs register bank */
openjls@43c00000 {
    compatible = "generic-uio";
    reg = <0x43c00000 0x1000>;
};

/* AXI DMA registers; interrupts optional */
dma@40400000 {
    compatible = "generic-uio";
    reg = <0x40400000 0x10000>;
    /* interrupt-parent = <&intc>; interrupts = <0 29 4>; */
};

/* DMA buffers — pixels in, bitstream out, and the SG descriptor rings.
 * Each node draws from its own exclusive reserved-memory carveout
 * (`shared-dma-pool` + `no-map`), so allocation is deterministic — no CMA
 * sizing or fragmentation. The catch: the kernel only honors reserved-memory
 * it sees at EARLY boot, so the overlay must be applied by the bootloader
 * (U-Boot), not at runtime — a configfs overlay would reserve nothing.
 * Keep each size a power of two, matching its pool.
 * See ../Hardware/pynq-z2/INTERNALS.md and openjls.dtso for the boot flow. */
reserved-memory {
    #address-cells = <1>; #size-cells = <1>; ranges;
    ojls_tx_pool: ojls-tx@10000000 {
        compatible = "shared-dma-pool";
        reg = <0x10000000 0x08000000>;  /* 128 MiB: max input image raw size */
        no-map;
    };
    ojls_rx_pool: ojls-rx@18000000 {
        compatible = "shared-dma-pool";
        reg = <0x18000000 0x08000000>;  /* 128 MiB: worst-case output is raw
                                           +25% + slack, so effective max
                                           input is ~102 MiB */
        no-map;
    };
    ojls_desc_pool: ojls-desc@ffc0000 {
        compatible = "shared-dma-pool";
        reg = <0x0FFC0000 0x00040000>;  /* 256 KiB: SG descriptor rings */
        no-map;
    };
};

udmabuf-ojls-tx {
    compatible = "ikwzm,u-dma-buf";
    device-name = "udmabuf-ojls-tx";
    size = <0x08000000>;
    memory-region = <&ojls_tx_pool>;
};
udmabuf-ojls-rx {
    compatible = "ikwzm,u-dma-buf";
    device-name = "udmabuf-ojls-rx";
    size = <0x08000000>;
    memory-region = <&ojls_rx_pool>;
};
udmabuf-ojls-desc {
    compatible = "ikwzm,u-dma-buf";
    device-name = "udmabuf-ojls-desc";
    size = <0x00040000>;
    memory-region = <&ojls_desc_pool>;
};
```

Two gotchas:

* `generic-uio` only binds if the kernel command line (or a modprobe config)
  contains `uio_pdrv_genirq.of_id=generic-uio`.
* `u-dma-buf` is an out-of-tree module. The PYNQ-Z2 build ships a prebuilt
  `u-dma-buf.ko` (in `Hardware/pynq-z2/`) you just copy to the board; for a
  different kernel, build one from <https://github.com/ikwzm/udmabuf> and
  `insmod`/`modprobe` it before starting the server. The server opens
  `udmabuf-ojls-{tx,rx,desc}` by name; override any with
  `--tx-buf`/`--rx-buf`/`--desc-buf`.

## Running

On the board:

```sh
./ojls_server                 # defaults: port 19020, UIO names "openjls" and "dma"
./ojls_server --loopback      # no hardware: echo server for protocol testing anywhere
```

On the host:

```sh
./ojls_client <board-ip> image.pgm            # writes image.jls
./ojls_client -n 100 <board-ip> image.pgm     # 100 round trips, throughput figure
```

The client accepts binary PGM (P5), 8- or 16-bit; bitness is derived from the
PGM `maxval` (override with `-b`) and must match the `BITNESS` the core was
synthesized with — the server tells you (`bitness does not match hardware`)
if it doesn't. Decode/verify the result with any JPEG-LS implementation,
e.g. CharLS.

## Wire protocol

Fixed 20-byte little-endian header, then the payload:

| offset | size | field | notes |
|---|---|---|---|
| 0 | 4 | magic | `"OJLS"` (0x4F4A4C53) |
| 4 | 2 | version | 1 |
| 6 | 1 | type | 1 = encode request, 2 = response |
| 7 | 1 | status | 0 = OK (see `common/ojls_proto.h`) |
| 8 | 2 | width | pixels |
| 10 | 2 | height | pixels |
| 12 | 1 | bitness | 8–16 |
| 13 | 3 | reserved | zero |
| 16 | 4 | payload_len | bytes after the header |

Request payload: raw pixels, row-major, right-justified little-endian, 1
byte/pixel for bitness 8 and 2 bytes/pixel for 9–16. Response payload: the
`.jls` stream (empty when status ≠ 0, with the reason in `status`).

## Porting checklist

1. Rebuild the block design for your board (see `../Hardware/` for examples):
   `openjls_axis_regs` + AXI DMA per the requirements above.
2. Write the device tree overlay with your addresses; keep `openjls` and
   `dma` in the node names, or pass `--regs`/`--dma` instead.
3. Build and load u-dma-buf for your kernel; add the three buffer nodes
   (tx/rx/desc), each backed by its own reserved-memory carveout, and make
   sure your bootloader applies the overlay at boot.
4. `make` on the board (or cross-compile) and run `ojls_server`.

Nothing in `Software/` should need changes — if it does, that's a bug worth
reporting.

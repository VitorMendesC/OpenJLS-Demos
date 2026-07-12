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

```sh
make                                      # native (host tools, or directly on the board)
make CROSS_COMPILE=arm-linux-gnueabihf-   # cross for 32-bit ARM (e.g. Zynq-7000)
make CROSS_COMPILE=aarch64-linux-gnu-     # cross for 64-bit ARM (e.g. Zynq UltraScale+)
```

Any C11 compiler + POSIX libc works. On a PYNQ image you can simply `make`
on the board itself.

## What the block design must provide

The server assumes the hardware side is the `openjls_axi` wrapper
(`ThirdParty/OpenJLS/Sources/axi/openjls_axi.vhd`) fed by a Xilinx AXI DMA:

* **AXI DMA in Direct Register mode** (Scatter/Gather disabled).
* **Width of buffer length register ≥ 26 bits** — with the default 14 bits
  any image over 16 KiB silently truncates the transfer length.
* MM2S stream width = the wrapper's `s_axis` width (8 bits for BITNESS 8,
  16 bits for BITNESS 9–16); S2MM stream width = `OUT_WIDTH` (default 64).
* DMA interrupts to the PS are **optional** — the server polls, and sleeps on
  the UIO interrupt instead when one is wired.
* `openjls_axi`'s `s_axi` register bank reachable from the PS (any base
  address; the device tree carries it).

## Device tree

Three kinds of nodes, addresses/sizes taken from your Address Editor
(concrete overlays live under `../Hardware/<board>/`):

```dts
/* openjls_axi register bank */
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

/* DMA buffers — one for pixels in, one for the bitstream out */
udmabuf-ojls-tx {
    compatible = "ikwzm,u-dma-buf";
    device-name = "udmabuf-ojls-tx";
    size = <0x02000000>;  /* 32 MiB: fits 4096x4096 @ 2 B/pixel */
};
udmabuf-ojls-rx {
    compatible = "ikwzm,u-dma-buf";
    device-name = "udmabuf-ojls-rx";
    size = <0x02800000>;  /* raw size + 25% + slack for incompressible input */
};
```

Two gotchas:

* `generic-uio` only binds if the kernel command line (or a modprobe config)
  contains `uio_pdrv_genirq.of_id=generic-uio`.
* `u-dma-buf` is an out-of-tree module — build it once for your kernel from
  <https://github.com/ikwzm/udmabuf> and `insmod`/`modprobe` it before
  starting the server. A single buffer also works (the server splits it in
  half), as do explicit names via `--tx-buf`/`--rx-buf`.

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
   `openjls_axi` + AXI DMA per the requirements above.
2. Write the device tree overlay with your addresses; keep `openjls` and
   `dma` in the node names, or pass `--regs`/`--dma` instead.
3. Build and load u-dma-buf for your kernel; add the two buffer nodes.
4. `make` on the board (or cross-compile) and run `ojls_server`.

Nothing in `Software/` should need changes — if it does, that's a bug worth
reporting.

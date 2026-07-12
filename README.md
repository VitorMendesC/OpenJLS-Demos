# OpenJLS-Demos

Demo projects for [OpenJLS](https://github.com/VitorMendesC/OpenJLS), the
open-source JPEG-LS (ITU-T T.87) hardware encoder. Each project lives in its
own directory; the encoder core is shared by all of them as a submodule
pinned at the verified commit.

## Projects

| Path | Project |
|---|---|
| [`EncodeOverEthernet/`](EncodeOverEthernet/) | Stream raw images to a board over Ethernet, encode them in the FPGA, stream the `.jls` files back. |
| `ThirdParty/OpenJLS` | The encoder core (submodule), used by every project. |

## EncodeOverEthernet

The CPU only moves bytes between the network and the AXI DMA — the encoding
is 100% in hardware:

```
host                         board (PS)                    board (PL)
ojls_client  ── TCP ──►  ojls_server  ── AXI DMA MM2S ──►  openjls_axi
   .jls      ◄── TCP ──      │        ◄── AXI DMA S2MM ──      │
                             └── AXI-Lite: dims, apply, status ─┘
```

* `EncodeOverEthernet/Software/` — portable C server (board) + client
  (host). Board-agnostic — see its
  [README](EncodeOverEthernet/Software/README.md) for the porting checklist.
* `EncodeOverEthernet/Hardware/pynq-z2/` — PYNQ-Z2 (Zynq-7020): Vivado
  project regeneration script, device tree overlay, bring-up notes. Other
  boards get sibling directories.

## Getting started

```sh
git clone --recursive https://github.com/VitorMendesC/OpenJLS-Demos
```

Then follow `EncodeOverEthernet/Hardware/<your-board>/README.md` to build
the bitstream and `EncodeOverEthernet/Software/README.md` to build and run
the applications. No directory for your board yet? The porting checklist in
the software README lists the few things a new block design and device tree
must provide — the software runs unmodified.

## Why a separate repository?

The core repository stays pure, vendor-independent VHDL with its
verification suite. Demos are inherently vendor- and board-specific: block
designs, constraint files, device trees. Vivado projects are regenerated
from exported Tcl scripts, so no Xilinx-generated sources are committed
here.

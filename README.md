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
┌─ host ───────┐            ┌─ board (PS) ─┐                     ┌─ board (PL) ─┐
│              │─── TCP ───►│              │─── AXI DMA MM2S ───►│              │
│ ojls_client  │            │ ojls_server  │◄─── AXI DMA S2MM ───│ openjls_axi  │
│              │◄─── TCP ───│              │◄──── AXI-Lite ─────►│              │
│              │   (.jls)   │              │ dims, apply, status │              │
└──────────────┘            └──────────────┘                     └──────────────┘
```

* `EncodeOverEthernet/Software/` — portable C server (board) + client
  (host). Board-agnostic — see its
  [README](EncodeOverEthernet/Software/README.md) for the porting checklist.
* `EncodeOverEthernet/Hardware/pynq-z2/` — PYNQ-Z2 (Zynq-7020): Vivado
  project regeneration script, device tree overlay, bring-up notes. Other
  boards get sibling directories.

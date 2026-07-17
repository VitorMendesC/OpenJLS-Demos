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

Stream raw images to a board over TCP, encode them 100% in the FPGA, stream the
`.jls` files back. The [`EncodeOverEthernet/`](EncodeOverEthernet/README.md)
README is the single end-to-end setup guide — it stands up both the software
(portable C client + server) and the hardware (a PYNQ-Z2 build is provided,
other boards get sibling directories) and links to the per-part reference docs.

# PYNQ-Z2 internals, manual bring-up, and porting notes

The [README](README.md) gets you a running board with the pre-built scripts.
This document is the reference behind those scripts: what each one automates
step by step, *why* the design is the way it is, and what to change to port it
to another board. Read this if a script fails, if you're modifying the block
design, or if you're bringing the demo up on different hardware.

## The design, and why it's shaped this way

PS7 GEM handles Ethernet; `openjls_axis_regs` (the OpenJLS encoder wrapped with
an AXI-Lite register bank, BITNESS 8, max 65535×65535) and an AXI DMA sit in the
PL on a **50 MHz** fabric clock.

**Why 50 MHz and not the ~83 MHz the PS can supply.** The OpenJLS `byte_stuffer`
has a deep, high-fanout combinational path that will not close timing faster on
this `-1` speed grade. It is a core-logic limit, not a fit or congestion one —
the part is only ~25% full. `build.tcl` refuses to stage a bitstream whose
post-route WNS is negative, so this limit can't be shipped by accident; if you
raise the clock, the build fails rather than producing an unreliable bitstream.

**Why Scatter/Gather.** SG lets the DMA chain descriptors, so one transfer is no
longer capped at the 64 MiB a 26-bit length register allows. An image is bounded
only by the `u-dma-buf` sizes, and thus by how much DRAM the board reserves (see
[Large images and the CMA pool](#large-images-and-the-cma-pool)).

**Why the S2MM status stream is disabled** (`c_sg_include_stscntrl_strm 0`).
This is the hard-won one: with the AXI-Ethernet-style SG control/status
side-channel enabled, S2MM withholds descriptor completion until the source
drives a per-packet status word on `s_axis_s2mm_sts` — but the BD ties that
slave stream off. So S2MM receives all the encoded data and the encoder's TLAST
correctly (bytes are byte-perfect in DRAM) but never writes RXEOF, stays
RUNNING, and the server times out. MM2S is unaffected because its counterpart
`m_axis_mm2s_cntrl` is a master output, harmless when ignored — which is why
only S2MM stalled. **Do not re-enable the status/control stream** unless you
also drive `s_axis_s2mm_sts`.

**Why a bitstream per precision.** BITNESS is a synth-time generic. The
encoder's `s_axis_pixel_tdata` is `8 * ceil(BITNESS/8)` bits wide — 8 bits for
BITNESS 8, 16 bits for 9..16 (a 9-bit sample sits losslessly in a 16-bit
container) — so the DMA MM2S stream width has to move with it. `build.tcl` sets
both together from `--bitness`. An AXIS data-width converter does *not* buy
build-once robustness here: only its slave side auto-propagates width; the
master TDATA width is a fixed IP parameter you'd have to size per precision
anyway, recreating the problem. `m_axis_jls` (and thus S2MM) is a fixed 64 bits
regardless of BITNESS. See [`../../Software/README.md`](../../Software/README.md)
for the full list of requirements the design satisfies.

## Files

* `openjls.dtso` — device tree overlay: `generic-uio` nodes for
  `openjls_axis_regs` (0x4000_0000) and the AXI DMA (0x4040_0000), plus three
  `u-dma-buf` buffers (`udmabuf-ojls-tx` pixels in, `udmabuf-ojls-rx` bitstream
  out, `udmabuf-ojls-desc` the SG descriptor rings).
* `design_encode_ethernet.tcl` — the block design (`write_bd_tcl` export, pinned
  to Vivado 2025.2). Source of truth; the generated project is never committed.
* `build.tcl` — recreates the Vivado project from it in `./build/` (git-ignored):
  adds the core sources from `ThirdParty/OpenJLS`, sources the block design,
  retargets it to `--bitness`, generates the HDL wrapper, and (with
  `--bitstream`) implements and gates on timing.
* `build_specific_bitness.sh` — one precision, sources → the two board files
  (`.bit.bin` + `.dtbo`). Wraps `build.tcl` + `bootgen` + `dtc`. `--no-bitstream`
  builds only the overlay (for when the `.bit.bin` already exists).
* `build_all_bitness.sh` — the same, looped over BITNESS 8..16, staging every
  `bitstreams/encode_eth_openjls_b<N>.bit.bin` the HIL sweep reloads, plus the
  shared overlay once at the end.

## Manual bring-up (what the scripts automate)

### On the development machine

`build_specific_bitness.sh N` does all of this for one precision (and
`build_all_bitness.sh` for every precision); the steps below are what they run.

1. **Bitstream** — build the project with the bitstream:

   ```sh
   vivado -mode batch -source build.tcl -tclargs --bitstream --bitness 8
   ```

   The wrapper is the top, so the file is named after it:

   ```
   build/encode_ethernet.runs/impl_1/design_encode_ethernet_wrapper.bit
   ```

2. **`.bit` → `.bin`** — the Linux FPGA manager on current kernels rejects raw
   `.bit` files (only the legacy `/dev/xdevcfg` accepted those; PYNQ's Python
   `Overlay` class converts them in software), so convert with bootgen, which
   ships with Vivado:

   ```sh
   cd build/encode_ethernet.runs/impl_1
   cp design_encode_ethernet_wrapper.bit system.bit    # short, stable name
   echo 'all: { system.bit }' > system.bif             # bootgen input list
   # -process_bitstream bin : raw .bin (no boot header)   -arch zynq : Zynq-7000
   # -w : overwrite                                       (zynqmp for UltraScale+)
   bootgen -image system.bif -arch zynq -process_bitstream bin -w
   # -> system.bit.bin
   ```

3. **Overlay** — compile the device tree overlay:

   ```sh
   dtc -@ -O dtb -o openjls.dtbo openjls.dtso
   ```

4. Copy the artifacts and the `Software/` directory to the board over `scp`
   (default PYNQ login `xilinx` / `xilinx`). The board is `192.168.3.1` over the
   USB gadget, or the `pynq` hostname / its DHCP address over Ethernet:

   ```sh
   BOARD=xilinx@192.168.3.1   # or xilinx@pynq over Ethernet
   scp bitstreams/encode_eth_openjls_b8.bit.bin "$BOARD:~/bitstreams/"
   scp openjls.dtbo u-dma-buf.ko "$BOARD:~/"
   scp -r ../../Software "$BOARD:~/"
   ```

   (Paths are relative to `EncodeOverEthernet/Hardware/pynq-z2/`.) Alternatively
   `git clone --recursive` the repo on the board and build there.

### On the board (as root)

`board_setup.sh` ([`../../Verification/board_setup.sh`](../../Verification/board_setup.sh))
does all of this in one idempotent command. The steps below are what it runs,
in the order that matters.

1. **See what already owns the PL address windows.** Do **not** trust
   `grep 4000 /proc/iomem` — `generic-uio` maps registers without reserving
   them, so UIO squatters never appear there. Check the driver instead:

   ```sh
   cat /sys/class/uio/uio*/name    # what UIO devices exist right now
   ```

   The stock PYNQ image ships a whole-PL UIO node, `fabric` at 0x4000_0000,
   which overlaps our register bank. It is **harmless** — two UIO devices can
   map the same window, and the server picks its device by name — so no need to
   remove it. (To remove it anyway:
   `echo 40000000.fabric > /sys/bus/platform/drivers/uio_pdrv_genirq/unbind`.)
   Just don't also have PYNQ's full Python overlay (`base.bit`) driving the PL.

2. **Load the bitstream first**, then the overlay, so devices probe against
   hardware that exists:

   ```sh
   cp system.bit.bin openjls.dtbo /lib/firmware/
   echo 0 > /sys/class/fpga_manager/fpga0/flags
   echo system.bit.bin > /sys/class/fpga_manager/fpga0/firmware
   cat /sys/class/fpga_manager/fpga0/state     # expect "operating"

   mkdir /sys/kernel/config/device-tree/overlays/openjls
   echo openjls.dtbo > /sys/kernel/config/device-tree/overlays/openjls/path
   ```

3. **UIO**: the PYNQ image normally boots with
   `uio_pdrv_genirq.of_id=generic-uio` already on the kernel command line —
   check `grep generic-uio /proc/cmdline`. If it's missing, `setup_bootargs.sh`
   adds it to the bootargs (see [Large images and the CMA pool](#large-images-and-the-cma-pool)),
   or `modprobe uio_pdrv_genirq of_id=generic-uio` when it's a module.
   Then:

   ```sh
   ls -l /dev/uio*
   cat /sys/class/uio/uio*/name    # among them, expect "openjls" and "dma"
   ```

4. **Free the CMA pool held by zocl-drm** — the one non-obvious boot hazard.
   The stock image's `zocl-drm` driver grabs and *fragments* the CMA pool at
   boot, so the 176 MiB `rx` buffer fails to allocate even when the pool is
   nominally large enough (`dmesg`: `cma_alloc ... ret:-16` then `-12`). Unbind
   it **before** the first `u-dma-buf` insmod, and compact if the kernel
   supports it:

   ```sh
   systemctl stop jupyter 2>/dev/null || true
   echo axi:zyxclmm_drm > /sys/bus/platform/drivers/zocl-drm/unbind
   sync; echo 3 > /proc/sys/vm/drop_caches
   [ -w /proc/sys/vm/compact_memory ] && echo 1 > /proc/sys/vm/compact_memory
   ```

5. **u-dma-buf** — the DMA-buffer kernel module. The quickstart doesn't build
   this on the board (the board may have no internet, and a `.ko` is tied to one
   exact kernel anyway): a pre-built `u-dma-buf.ko` is committed next to this
   file and `board_setup.sh` just loads it. It was built against the PYNQ image's
   kernel, `6.6.10-xilinx-v2024.1-g3c0eca68c652` (its `vermagic`; check yours
   with `uname -r`). `insmod` refuses a module whose `vermagic` doesn't match the
   running kernel, so **rebuild it if you change the kernel or port to another
   board** — that's the only time you need this:

   ```sh
   # on a machine with this board's kernel headers (out-of-tree module)
   git clone https://github.com/ikwzm/udmabuf
   cd udmabuf && make          # -> u-dma-buf.ko ; commit/scp it in place
   ```

   Confirm it loaded: `ls /sys/class/u-dma-buf/` should list
   `udmabuf-ojls-{tx,rx,desc}`. These buffers are large (128 + 176 MiB); if the
   `-tx`/`-rx` entries are missing, the pool was too small or too fragmented —
   see below.

6. **Run**:

   ```sh
   cd Software && make
   ./ojls_server
   ```

   The server verifies the `"OJLS"` ID register before opening the socket, so a
   successful start already proves the AXI-Lite path.

### From the host

```sh
./ojls_client <board-ip> image.pgm    # writes image.jls
```

The strongest end-to-end check: encode an image from the core's golden suite
(`ThirdParty/OpenJLS/Verification/Golden model`) and `cmp` the result against
its CharLS-generated `.jls` reference — OpenJLS is byte-exact against CharLS, so
the files must be identical. The [HIL sweep](../../Verification/README.md)
automates this across every precision.

### Undo / reload

```sh
rmdir /sys/kernel/config/device-tree/overlays/openjls   # remove overlay
# reload a new bitstream via fpga0/firmware, then re-apply the overlay
```

For swapping precisions on an already-set-up board (overlay + `u-dma-buf` stay
loaded, only the PL image and server cycle), the HIL sweep uses the lighter
`board_reload.sh` instead of a full `board_setup.sh`.

## Large images and the CMA pool

With Scatter/Gather the DMA is no longer the limit, so the largest image the
board can encode is set by the two DMA buffers, which `u-dma-buf` carves out of
the kernel **CMA pool**. The admission rule the server enforces is:

```
input  <= udmabuf-ojls-tx.size
output <= udmabuf-ojls-rx.size   (worst case ~ input + 25% + slack)
```

The overlay ships 128 MiB (tx) + 176 MiB (rx) + 256 KiB (desc) ≈ **304 MiB**,
so the encoder accepts images up to a **128 MiB raw** frame — comfortably past
every image in the golden corpus. The buffers only allocate if the CMA pool is
at least that big; the stock image defaults to `cma=128M`, which is too small.

**Grow the pool** on the kernel command line (persistent). `setup_bootargs.sh`
does exactly this — it edits the `bootargs=` line in the FAT `boot` partition's
`uEnv.txt` (which U-Boot imports at boot), seeding from the running command line
so `root=…` is kept and adding `cma=320M` (and `generic-uio`) only if absent. To
do it by hand, or to set a different size, edit that line to add `cma=320M`, then
reboot and confirm:

```sh
grep cma /proc/cmdline
cat /sys/kernel/debug/cma/*/count 2>/dev/null   # pages in the pool
```

The board has **512 MiB** total, so `cma=320M` leaves ~192 MiB for Linux — tight
for the stock Ubuntu userspace. If the system is unstable or the alloc still
fails, stop the services the demo doesn't need:

```sh
systemctl disable --now jupyter.service pynq-x11.service lightdm 2>/dev/null || true
free -m    # confirm headroom before raising cma further
```

Note the buffers need their span **contiguous**, not just free by total:
`CmaFree` can report more than 176 MiB and the `rx` alloc still fail because no
single 176 MiB run is available. Unbinding zocl-drm and compacting (step 4
above) is what makes a contiguous span; a fresh reboot gives the cleanest pool.
`CONFIG_COMPACTION` is absent on some stock kernels (no
`/proc/sys/vm/compact_memory`) — then only a reboot defragments.

**Pushing higher.** The ceiling is `DRAM − (Linux working set)`, split ~1 : 1.25
between tx and rx (the output guard). Each extra 100 MiB of image needs ~225 MiB
more CMA. On a fully slimmed userspace (~80–100 MiB) the board can reach roughly
a **180–190 MiB** image (`cma=448M`, tx 192 / rx 248 MiB). To change it: edit
the three `size` fields in `openjls.dtso`, recompile the overlay
(`dtc -@ -O dtb -o openjls.dtbo openjls.dtso`), and set `cma=` to at least their
sum. Measure the real Linux floor with `free -m` under load first —
over-reserving CMA will OOM the board, not just fail the alloc.

## Porting to another board

The software is board-agnostic (see
[`../../Software/README.md`](../../Software/README.md) for its checklist); this
directory is what's PYNQ-Z2-specific. To bring the demo up on a different Zynq /
Zynq-MPSoC board, give it a sibling directory under `Hardware/` and adapt:

* **Part and board preset** — `build.tcl` sets `-part xc7z020clg400-1` and the
  `tul.com.tw:pynq-z2` board part; `design_encode_ethernet.tcl` bakes the PS7
  configuration (DDR, GEM, clocks) from that preset. Regenerate the PS block for
  your board's preset rather than hand-editing PCW values.
* **Fabric clock** — 50 MHz is this `-1` part's ceiling for the `byte_stuffer`
  path. A faster speed grade may close higher; a slower one may need less.
  `build.tcl` gates on WNS, so raising
  `PCW_*FPGA0_PERIPHERAL_FREQMHZ` and rebuilding will *tell you* if it doesn't
  close — trust that gate rather than shipping a violating bitstream.
* **DRAM and the CMA pool** — the 128/176 MiB buffer sizes and `cma=320M` assume
  512 MiB of DDR. Scale the three `openjls.dtso` `size` fields and `cma=` to your
  board's DRAM and target image size (see the section above).
* **The CMA boot hazard is PYNQ-specific** — `zocl-drm` grabbing the pool is a
  stock-PYNQ-image thing. On a different rootfs the culprit (if any) differs;
  the general fix is the same: free/compact CMA before the first `u-dma-buf`
  insmod. `board_setup.sh`'s zocl-drm unbind is a no-op where it isn't bound.
* **UIO on the command line** — `uio_pdrv_genirq.of_id=generic-uio` must be in
  bootargs (or modprobed). Different images vary in whether it's built in.
* **Precision** — nothing precision-specific is board-specific; the per-BITNESS
  bitstream story (above) carries over unchanged.

What does *not* change: the block-design topology (encoder + AXI DMA in SG mode,
status stream off), the overlay's node structure, and the whole `Software/`
tree.

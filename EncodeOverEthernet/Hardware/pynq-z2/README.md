# PYNQ-Z2 (Zynq-7020)

Contents:

* `openjls.dtso` — device tree overlay: `generic-uio` nodes for `openjls_axis_regs`
  (0x4000_0000) and the AXI DMA (0x4040_0000), plus three `u-dma-buf`
  buffers (`udmabuf-ojls-tx` pixels in, `udmabuf-ojls-rx` bitstream out,
  `udmabuf-ojls-desc` the SG descriptor rings).
* `design_encode_ethernet.tcl` — the block design (`write_bd_tcl` export,
  pinned to Vivado 2025.2).
* `build.tcl` — recreates the Vivado project from it in `./build/`
  (git-ignored): adds the core sources from `ThirdParty/OpenJLS`, sources
  the block design, generates the HDL wrapper.

  ```sh
  vivado -mode batch -source build.tcl                       # project only
  vivado -mode batch -source build.tcl -tclargs --bitstream  # + bitstream
  ```

Block design summary: PS7 GEM handles Ethernet; `openjls_axis_regs` (BITNESS 8,
max 65535x65535) + AXI DMA (Scatter/Gather mode, no IRQs — the server polls)
sit in the PL on a 50 MHz fabric clock. The clock is 50 MHz (not the ~83 MHz the
PS can supply) because the OpenJLS `byte_stuffer` has a deep, high-fanout
combinational path that will not close timing faster on this `-1` speed grade —
it is a core-logic limit, not a fit or congestion one (the part is ~25% full).
`build.tcl` refuses to stage a bitstream whose post-route WNS is negative, so
that limit can't be shipped by accident. SG lets the DMA chain descriptors, so
one transfer is no longer capped at the 64 MiB a 26-bit length register allows;
an image is bounded only by the `u-dma-buf` sizes, and thus by how much DRAM the
board reserves (see "Large images and the CMA pool" below). See
[`../../Software/README.md`](../../Software/README.md) for the full list of
requirements the design satisfies.

## Bring-up on the stock PYNQ SD image

### On the development machine

1. **Bitstream → `.bin`** — build the project with the bitstream:

   ```sh
   vivado -mode batch -source build.tcl -tclargs --bitstream
   ```

   This writes the bitstream (the wrapper is the top, so the file is named
   after it) to:

   ```
   build/encode_ethernet.runs/impl_1/design_encode_ethernet_wrapper.bit
   ```

   The Linux FPGA manager on current kernels rejects raw `.bit` files (only
   the legacy `/dev/xdevcfg` accepted those; PYNQ's Python `Overlay` class
   converts them in software), so convert it to a `.bin` with bootgen, which
   ships with Vivado:

   ```sh
   cd build/encode_ethernet.runs/impl_1

   # Give it a short, stable name so the board-side steps below stay simple.
   cp design_encode_ethernet_wrapper.bit system.bit

   # A .bif is just bootgen's input list: here, one bitstream and nothing else.
   echo 'all: { system.bit }' > system.bif

   # -process_bitstream bin : emit a raw .bin (no boot header) next to the .bit
   # -arch zynq             : Zynq-7000 (PYNQ-Z2); use zynqmp for UltraScale+
   # -w                     : overwrite any existing output
   bootgen -image system.bif -arch zynq -process_bitstream bin -w
   # -> system.bit.bin
   ```

2. **Overlay** — compile the device tree overlay:

   ```sh
   dtc -@ -O dtb -o openjls.dtbo openjls.dtso
   ```

3. Copy `system.bit.bin`, `openjls.dtbo`, and the `Software/` directory to
   the board over `scp` (default PYNQ login `xilinx` / `xilinx`). The board
   is `192.168.3.1` over the USB gadget, or the `pynq` hostname / its DHCP
   address over Ethernet — substitute whichever you're on:

   ```sh
   BOARD=xilinx@192.168.3.1   # or xilinx@pynq over Ethernet

   scp build/encode_ethernet.runs/impl_1/system.bit.bin "$BOARD:~/"
   scp openjls.dtbo "$BOARD:~/"
   scp -r ../../Software "$BOARD:~/"
   ```

   (Paths are relative to this directory, `EncodeOverEthernet/Hardware/pynq-z2/`.)
   Alternatively `git clone --recursive` the repo on the board directly and
   build there.

### On the board (as root)

**The short way** — [`../../Verification/board_setup.sh`](../../Verification/board_setup.sh)
does everything below (load PL, apply overlay, free the CMA pool, load
`u-dma-buf`, verify the buffers, start the server) in one idempotent command.
Copy it to the board alongside the artifacts from step 3 and run it once per
boot:

```sh
# scripts use $HOME, so under sudo pass it through explicitly
sudo env HOME=$HOME ./board_setup.sh 8       # 8 = encoder BITNESS to load
# -> "BOARD READY — BITNESS 8, buffers up, server listening on :19020"
```

It also handles the one non-obvious boot hazard: the stock image's `zocl-drm`
driver grabs and fragments the CMA pool at boot, so it unbinds that first —
otherwise the 176 MiB `rx` buffer fails to allocate even though the pool is
nominally large enough. The rest of this section explains, step by step, what
the script automates.

4. Sanity: see what already owns the PL address windows. **Do not** trust
   `grep 4000 /proc/iomem` here — `generic-uio` maps registers without
   reserving them, so UIO squatters never appear in `/proc/iomem`. Check the
   driver instead:

   ```sh
   cat /sys/class/uio/uio*/name    # what UIO devices exist right now
   ```

   The stock PYNQ image ships a whole-PL UIO node, `fabric` at 0x4000_0000,
   which overlaps our register bank. It is **harmless** — two UIO devices can
   map the same window, and the server picks its device by name — so no need
   to remove it. (If you prefer it gone:
   `echo 40000000.fabric > /sys/bus/platform/drivers/uio_pdrv_genirq/unbind`.)
   Just don't also have PYNQ's full Python overlay (`base.bit`) actively
   driving the PL at the same time.

5. **Load the bitstream first**, then the overlay, so the devices probe
   against hardware that exists:

   ```sh
   cp system.bit.bin openjls.dtbo /lib/firmware/
   echo 0 > /sys/class/fpga_manager/fpga0/flags
   echo system.bit.bin > /sys/class/fpga_manager/fpga0/firmware
   cat /sys/class/fpga_manager/fpga0/state     # expect "operating"

   mkdir /sys/kernel/config/device-tree/overlays/openjls
   echo openjls.dtbo > /sys/kernel/config/device-tree/overlays/openjls/path
   ```

6. **UIO**: the PYNQ image normally boots with
   `uio_pdrv_genirq.of_id=generic-uio` already on the kernel command line —
   check `grep generic-uio /proc/cmdline`. If it's missing, add it to the
   bootargs, or `modprobe uio_pdrv_genirq of_id=generic-uio` when it's a
   module. Then:

   ```sh
   ls -l /dev/uio*
   cat /sys/class/uio/uio*/name    # among them, expect "openjls" and "dma"
   ```

7. **u-dma-buf** (out-of-tree module, needs the kernel headers package):

   ```sh
   git clone https://github.com/ikwzm/udmabuf
   cd udmabuf && make && insmod u-dma-buf.ko
   ls /sys/class/u-dma-buf/  # expect udmabuf-ojls-{tx,rx,desc}
   ```

   These buffers are large (128 + 176 MiB) and come from the kernel CMA pool,
   so this step **fails to create the nodes** unless the pool has been grown —
   see "Large images and the CMA pool" below. If the directory is missing the
   `-tx`/`-rx` entries, check `dmesg | grep -i cma` for an allocation failure.

8. **Run**:

   ```sh
   cd Software && make
   ./ojls_server
   ```

   The server verifies the `"OJLS"` ID register before opening the socket,
   so a successful start already proves the AXI-Lite path.

### From the host

```sh
./ojls_client <board-ip> image.pgm    # writes image.jls
```

The strongest end-to-end check: encode an image from the core's golden
suite (`ThirdParty/OpenJLS/Verification/Golden model`) and `cmp` the result
against its CharLS-generated `.jls` reference — OpenJLS is byte-exact
against CharLS, so the files must be identical.

### Large images and the CMA pool

With Scatter/Gather the DMA is no longer the limit — a transfer chains
descriptors past the 64 MiB per-transfer cap — so the largest image the board
can encode is set by the two DMA buffers, which `u-dma-buf` carves out of the
kernel **CMA pool**. The admission rule the server enforces is:

```
input  <= udmabuf-ojls-tx.size
output <= udmabuf-ojls-rx.size   (worst case ~ input + 25% + slack)
```

The overlay ships 128 MiB (tx) + 176 MiB (rx) + 256 KiB (desc) ≈ **304 MiB**,
so the encoder accepts images up to a **128 MiB raw** frame — comfortably past
every image in the golden corpus. The buffers only allocate if the CMA pool is
at least that big; the stock image defaults to `cma=128M`, which is too small.

**Grow the pool** on the kernel command line (persistent). On the stock PYNQ
SD card, edit the FAT `boot` partition's `uEnv.txt` (or the bootloader's
`bootargs`) to add `cma=320M`, then reboot and confirm:

```sh
grep cma /proc/cmdline
cat /sys/kernel/debug/cma/*/count 2>/dev/null   # pages in the pool
```

The board has **512 MiB** total, so `cma=320M` leaves ~192 MiB for Linux —
tight for the stock Ubuntu userspace. If the system is unstable or the alloc
still fails, stop the services the demo doesn't need (Jupyter, the desktop):

```sh
systemctl disable --now jupyter.service pynq-x11.service lightdm 2>/dev/null || true
free -m    # confirm headroom before raising cma further
```

**Pushing higher.** The ceiling is `DRAM − (Linux working set)`, split ~1 : 1.25
between the tx and rx buffers (the output guard). Each extra 100 MiB of image
needs ~225 MiB more CMA. On a fully slimmed userspace (~80–100 MiB) the board
can reach roughly a **180–190 MiB** image (`cma=448M`, tx 192 / rx 248 MiB).
To change it: edit the three `size` fields in `openjls.dtso`, recompile the
overlay (`dtc -@ -O dtb -o openjls.dtbo openjls.dtso`), and set `cma=` to at
least their sum. Measure the real Linux floor with `free -m` under load first —
over-reserving CMA will OOM the board, not just fail the alloc.

### Undo / reload

```sh
rmdir /sys/kernel/config/device-tree/overlays/openjls   # remove overlay
# reload a new bitstream via fpga0/firmware, then re-apply the overlay
```

# PYNQ-Z2 (Zynq-7020)

Contents:

* `openjls.dtso` — device tree overlay: `generic-uio` nodes for `openjls_axis_regs`
  (0x4000_0000) and the AXI DMA (0x4040_0000), plus the two `u-dma-buf`
  buffers.
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
max 65535x65535) + AXI DMA (Direct Register mode, buffer length register
26 bits, no IRQs — the server polls) sit in the PL on an 80 MHz fabric
clock. See [`../../Software/README.md`](../../Software/README.md) for the
full list of requirements the design satisfies.

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

4. Optional sanity: confirm nothing in the live device tree already claims
   the PL windows (`grep -i 4000 /proc/iomem` should show no entries at
   0x4000_0000/0x4040_0000), and don't have a PYNQ Python overlay (e.g.
   `base.bit`) loaded at the same time.

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
   cat /sys/class/uio/uio*/name    # expect 40000000.openjls and 40400000.dma
   ```

7. **u-dma-buf** (out-of-tree module, needs the kernel headers package):

   ```sh
   git clone https://github.com/ikwzm/udmabuf
   cd udmabuf && make && insmod u-dma-buf.ko
   ls /sys/class/u-dma-buf/        # expect udmabuf-ojls-tx, udmabuf-ojls-rx
   ```

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

### Undo / reload

```sh
rmdir /sys/kernel/config/device-tree/overlays/openjls   # remove overlay
# reload a new bitstream via fpga0/firmware, then re-apply the overlay
```

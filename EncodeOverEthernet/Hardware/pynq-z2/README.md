# PYNQ-Z2 (Zynq-7020)

Contents:

* `openjls.dtso` — device tree overlay: `generic-uio` nodes for `openjls_axi`
  (0x4000_0000) and the AXI DMA (0x4040_0000), plus the two `u-dma-buf`
  buffers.
* `build.tcl` (pending) — regenerates the Vivado project (exported with
  `write_project_tcl`; references the core sources in `ThirdParty/OpenJLS`).

Block design summary: PS7 GEM handles Ethernet; `openjls_axi` (BITNESS 8,
max 65535x65535) + AXI DMA (Direct Register mode, buffer length register
26 bits, no IRQs — the server polls) sit in the PL on an 80 MHz fabric
clock. See [`../../Software/README.md`](../../Software/README.md) for the
full list of requirements the design satisfies.

## Bring-up on the stock PYNQ SD image

### On the development machine

1. **Bitstream** — implement the design, then convert the `.bit` for the
   Linux FPGA manager (bootgen ships with Vivado):

   ```sh
   echo 'all:{ system.bit }' > system.bif
   bootgen -image system.bif -arch zynq -process_bitstream bin -w
   # -> system.bit.bin
   ```

   The `fpga_manager` interface on current kernels rejects raw `.bit` files
   (only the legacy `/dev/xdevcfg` accepted those, and PYNQ's Python class
   converts them in software) — hence the `.bin` conversion.

2. **Overlay** — compile the device tree overlay:

   ```sh
   dtc -@ -O dtb -o openjls.dtbo openjls.dtso
   ```

3. Copy `system.bit.bin`, `openjls.dtbo`, and the `Software/` directory to
   the board (or `git clone --recursive` the repo there directly).

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

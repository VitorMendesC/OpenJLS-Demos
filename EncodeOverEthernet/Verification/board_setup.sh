#!/usr/bin/env bash
# Board-side (PYNQ-Z2, run as root): one-shot bring-up after a power cycle.
#
# Collapses the manual "On the board" sequence from
# ../Hardware/pynq-z2/INTERNALS.md (load PL -> load u-dma-buf -> start server)
# into a single idempotent command. Safe to re-run: it tears down what it owns
# (server, module) and rebuilds it.
#
# The UIO register nodes and the DMA-buffer nodes come from openjls.dtbo,
# which U-Boot applies AT BOOT (installed once per board by
# ../Hardware/pynq-z2/setup_bootargs.sh). The buffers allocate from an
# exclusive reserved-memory carveout, so there is no CMA sizing or
# fragmentation dance here: if the carveout is live, insmod'ing u-dma-buf
# just works — at any uptime, deterministically. If it is missing (first-time
# setup never ran, or its uenvcmd fell back to a stock boot), this script
# stops early and says so rather than fighting the CMA pool.
#
# For swapping precisions on an already-set-up board (u-dma-buf stays loaded,
# only the PL image and server cycle), use board_reload.sh instead — it's the
# lighter, per-bitness path the HIL sweep drives.
#
# Usage (on the board, as root; scripts use $HOME so run under the login user):
#   sudo env HOME=/home/xilinx board_setup.sh [bitness] [server_dir] [fw_dir] [bs_dir]
#
#   bitness      encoder precision to load (8..16, default 8). The server
#                latches this from the CAPS register; any depth works to set up.
#   server_dir   dir holding the built ojls_server    (default $HOME/Software)
#   fw_dir       FPGA-manager firmware dir            (default /lib/firmware)
#   bs_dir       dir holding encode_eth_openjls_b*.bit.bin (default $HOME/bitstreams)
#
# Artifacts expected on the board (put there once by scp or git clone):
#   $bs_dir/encode_eth_openjls_b<bitness>.bit.bin   the PL image
#   $HOME/u-dma-buf.ko                              the u-dma-buf module
#   $server_dir/ojls_server                         the built server
# (openjls.dtbo is NOT used here — setup_bootargs.sh installs it in /boot.)
set -euo pipefail

b="${1:-8}"
server_dir="${2:-$HOME/Software}"
fw_dir="${3:-/lib/firmware}"
bs_dir="${4:-$HOME/bitstreams}"
module="${UDMABUF_KO:-$HOME/u-dma-buf.ko}"

fw="encode_eth_openjls_b${b}.bit.bin"
src="$bs_dir/$fw"
ov=/sys/kernel/config/device-tree/overlays/openjls   # legacy runtime overlay

# --- preflight: fail early and specifically on a missing artifact ------------
[ -f "$src" ]                  || { echo "missing bitstream: $src" >&2; exit 1; }
[ -f "$module" ]              || { echo "missing module: $module" >&2; exit 1; }
[ -x "$server_dir/ojls_server" ] || { echo "missing server: $server_dir/ojls_server" >&2; exit 1; }

echo "=== 1. stop server + unload u-dma-buf (idempotent teardown) ==="
pkill -f '[o]jls_server' 2>/dev/null || true
sleep 0.3
rmmod u-dma-buf 2>/dev/null || true     # so it re-binds cleanly
# A configfs overlay is the pre-carveout flow; its u-dma-buf nodes shadow the
# boot-time ones (and can't reserve memory), so clear any stale one out.
[ -d "$ov" ] && { echo "(removing stale runtime overlay)"; rmdir "$ov" 2>/dev/null || true; }

echo "=== 2. load PL image ($fw) ==="
cp -f "$src" "$fw_dir/$fw"
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo "$fw" > /sys/class/fpga_manager/fpga0/firmware
state="$(cat /sys/class/fpga_manager/fpga0/state)"
echo "fpga state: $state"
[ "$state" = operating ] || { echo "PL not operating after load" >&2; exit 1; }

echo "=== 3. verify the boot-time overlay (UIO + DMA carveout) is live ==="
dt=/proc/device-tree
missing=""
for n in reserved-memory/ojls-tx@10000000 reserved-memory/ojls-rx@18000000 \
         reserved-memory/ojls-desc@ffc0000 udmabuf-ojls-tx udmabuf-ojls-rx \
         udmabuf-ojls-desc openjls@40000000 dma@40400000; do
  [ -d "$dt/$n" ] || missing="$missing $n"
done
if [ -n "$missing" ]; then
  echo "!! boot device tree is missing:$missing" >&2
  echo "   openjls.dtbo was not applied at boot (first-time setup never ran," >&2
  echo "   or its uenvcmd fell back to a stock boot). Run the first-time setup:" >&2
  echo "   Hardware/pynq-z2/setup_bootargs.sh (as root), then reboot — it" >&2
  echo "   installs the uenvcmd that patches the DMA carveout into the FIT" >&2
  echo "   device tree. See Hardware/pynq-z2/INTERNALS.md." >&2
  exit 1
fi
echo "UIO devices: $(cat /sys/class/uio/uio*/name 2>/dev/null | sort -u | tr '\n' ' ')"

echo "=== 4. load u-dma-buf (buffers come from the exclusive carveout) ==="
insmod "$module"; sleep 0.5

echo "=== 5. verify all three buffers allocated ==="
ok=1
for name in tx rx desc; do
  d="/sys/class/u-dma-buf/udmabuf-ojls-$name"
  if [ -d "$d" ]; then
    size=$(cat "$d/size")
    if [ "$size" -ge 1048576 ]; then
      printf "  %-22s %d MiB\n" "udmabuf-ojls-$name" "$(( size / 1048576 ))"
    else
      printf "  %-22s %d KiB\n" "udmabuf-ojls-$name" "$(( size / 1024 ))"
    fi
  else
    echo "  udmabuf-ojls-$name  MISSING"; ok=0
  fi
done
if [ "$ok" != 1 ]; then
  echo "!! a buffer failed to allocate from its carveout — dmesg says:" >&2
  dmesg | grep -i -E 'reserved_mem|dma_alloc|u-dma-buf|udmabuf' | tail -8 >&2
  echo "   the carveout is exclusive, so this is not a memory-pressure race;" >&2
  echo "   check that openjls.dtso sizes match their pools (powers of two) —" >&2
  echo "   see Hardware/pynq-z2/INTERNALS.md ('Large images and the DMA carveout')." >&2
  exit 1
fi

echo "=== 6. start server (detached; confirm it latched BITNESS $b) ==="
cd "$server_dir"
setsid stdbuf -oL -eL ./ojls_server >/tmp/ojls_server.log 2>&1 </dev/null &
for _ in $(seq 1 25); do
  grep -q "BITNESS $b\b" /tmp/ojls_server.log 2>/dev/null && break
  sleep 0.2
done
if grep -q "BITNESS $b\b" /tmp/ojls_server.log 2>/dev/null; then
  echo
  echo "BOARD READY — BITNESS $b, buffers up, server listening on :19020"
else
  echo "server did not report BITNESS $b — log:" >&2
  cat /tmp/ojls_server.log >&2 || true
  exit 1
fi

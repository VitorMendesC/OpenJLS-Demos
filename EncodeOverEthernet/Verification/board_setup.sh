#!/usr/bin/env bash
# Board-side (PYNQ-Z2, run as root): one-shot bring-up after a power cycle.
#
# Collapses the manual "On the board" sequence from
# ../Hardware/pynq-z2/INTERNALS.md (load PL -> apply overlay -> free CMA -> load
# u-dma-buf -> start server) into a single idempotent command. Safe to re-run:
# it tears down what it owns (server, module, overlay) and rebuilds it.
#
# The one ordering that matters and trips people up on a fresh boot: the stock
# image's zocl-drm driver grabs and fragments the CMA pool at boot, so the
# 176 MiB rx buffer fails to allocate if you insmod u-dma-buf first (dmesg:
# "cma_alloc ... ret:-16" then "-12"). This script unbinds zocl-drm BEFORE the
# first insmod, so all three buffers allocate on the first try.
#
# For swapping precisions on an already-set-up board (overlay + u-dma-buf stay
# loaded, only the PL image and server cycle), use board_reload.sh instead —
# it's the lighter, per-bitness path the HIL sweep drives.
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
#   $HOME/openjls.dtbo                              compiled overlay
#   $HOME/u-dma-buf.ko                              the u-dma-buf module
#   $server_dir/ojls_server                         the built server
set -euo pipefail

b="${1:-8}"
server_dir="${2:-$HOME/Software}"
fw_dir="${3:-/lib/firmware}"
bs_dir="${4:-$HOME/bitstreams}"
dtbo="${DTBO:-$HOME/openjls.dtbo}"
module="${UDMABUF_KO:-$HOME/u-dma-buf.ko}"

fw="encode_eth_openjls_b${b}.bit.bin"
src="$bs_dir/$fw"
ov=/sys/kernel/config/device-tree/overlays/openjls
zdev="axi:zyxclmm_drm"          # stock PYNQ zocl-drm framebuffer device

# --- preflight: fail early and specifically on a missing artifact ------------
[ -f "$src" ]                  || { echo "missing bitstream: $src" >&2; exit 1; }
[ -f "$dtbo" ]                 || { echo "missing overlay: $dtbo" >&2; exit 1; }
[ -f "$module" ]              || { echo "missing module: $module" >&2; exit 1; }
[ -x "$server_dir/ojls_server" ] || { echo "missing server: $server_dir/ojls_server" >&2; exit 1; }

echo "=== 1. stop server + unload u-dma-buf (idempotent teardown) ==="
pkill -f '[o]jls_server' 2>/dev/null || true
sleep 0.3
rmmod u-dma-buf 2>/dev/null || true     # so it re-binds cleanly after the overlay

echo "=== 2. load PL image ($fw) ==="
cp -f "$src" "$fw_dir/$fw"
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo "$fw" > /sys/class/fpga_manager/fpga0/firmware
state="$(cat /sys/class/fpga_manager/fpga0/state)"
echo "fpga state: $state"
[ "$state" = operating ] || { echo "PL not operating after load" >&2; exit 1; }

echo "=== 3. apply overlay (UIO + u-dma-buf nodes) ==="
cp -f "$dtbo" "$fw_dir/"
[ -d "$ov" ] && { echo "(overlay present, removing to reapply)"; rmdir "$ov" || true; }
mkdir -p "$ov"
echo "$(basename "$dtbo")" > "$ov/path"
sleep 0.3
echo "UIO devices: $(cat /sys/class/uio/uio*/name 2>/dev/null | sort -u | tr '\n' ' ')"

echo "=== 4. free CMA held by zocl-drm (so the 176 MiB rx buffer can allocate) ==="
# The three buffers (~304 MiB) nearly fill the 320 MiB pool, so they need it
# CONTIGUOUS, not just free by total. zocl-drm's boot framebuffers fragment it;
# unbinding frees them, and compacting migrates movable pages out of the CMA
# region so a single 176 MiB span is available.
systemctl stop jupyter 2>/dev/null || true
free_cma() {
  if [ -e "/sys/bus/platform/drivers/zocl-drm/$zdev" ]; then
    echo "$zdev" > /sys/bus/platform/drivers/zocl-drm/unbind && echo "zocl-drm unbound"
  else
    echo "(zocl-drm not bound)"
  fi
  sync
  echo 3 > /proc/sys/vm/drop_caches
  # Compact movable pages out of the CMA region if the kernel supports it
  # (CONFIG_COMPACTION; absent on some stock images — test before writing so a
  # missing knob doesn't print a redirection error).
  [ -w /proc/sys/vm/compact_memory ] && echo 1 > /proc/sys/vm/compact_memory
  sleep 0.5
  echo "CmaFree: $(awk '/CmaFree/{print $2" "$3}' /proc/meminfo)"
}

buffers_ok() {          # all three nodes present?
  for name in tx rx desc; do
    [ -d "/sys/class/u-dma-buf/udmabuf-ojls-$name" ] || return 1
  done
  return 0
}

echo "=== 5. load u-dma-buf (retrying while the CMA pool settles) ==="
# Right after boot, jupyter shutdown and dirty writeback can leave transiently
# pinned pages in the CMA region (cma_alloc ret -16 / EBUSY) that drop_caches
# can't evict yet. A single quick retry often loses that race; escalating
# waits (1 s, 4 s, 8 s) reliably win it on the stock image.
free_cma
insmod "$module"; sleep 0.5
for wait in 1 4 8; do
  buffers_ok && break
  echo "  (a buffer missed — waiting ${wait}s for pinned pages, then retrying)"
  rmmod u-dma-buf 2>/dev/null || true
  sleep "$wait"
  free_cma
  insmod "$module"; sleep 0.5
done

echo "=== 6. verify all three buffers allocated ==="
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
  echo "!! a buffer failed to allocate — CMA too small or too fragmented:" >&2
  dmesg | grep -i -E 'cma_alloc|dma_alloc_coherent|u-dma-buf' | tail -8 >&2
  echo "   a reboot gives the cleanest pool; if it still fails, grow cma= —" >&2
  echo "   see Hardware/pynq-z2/INTERNALS.md ('Large images and the CMA pool')." >&2
  exit 1
fi

echo "=== 7. start server (detached; confirm it latched BITNESS $b) ==="
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

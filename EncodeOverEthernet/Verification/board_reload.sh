#!/usr/bin/env bash
# Board-side (PYNQ-Z2, run as root): reload the bitstream for a given encoder
# precision and restart the server.
#
# The server reads the hardware BITNESS from the CAPS register ONCE at startup
# and rejects any request whose bitness differs, so after swapping in a
# different-depth bitstream the still-running server would reject the whole new
# bucket — it must be restarted. The device-tree overlay and u-dma-buf are
# precision-independent (register/DMA addresses and the DDR buffers don't move),
# so they stay loaded; only the PL image and the server are cycled.
#
# The host driver (run_hil_sweep.py) copies this script and the needed
# bitstream to the board, then runs it over ssh as root.
#
# Usage (on the board, as root):
#   board_reload.sh <bitness> [server_dir] [firmware_dir] [bitstream_dir]
set -euo pipefail

b="${1:?usage: board_reload.sh <bitness> [server_dir] [fw_dir] [bs_dir]}"
server_dir="${2:-$HOME/Software}"
fw_dir="${3:-/lib/firmware}"
bs_dir="${4:-$HOME/bitstreams}"

fw="encode_eth_openjls_b${b}.bit.bin"
src="$bs_dir/$fw"
[ -f "$src" ] || { echo "missing bitstream: $src" >&2; exit 1; }
[ -x "$server_dir/ojls_server" ] || { echo "missing server: $server_dir/ojls_server" >&2; exit 1; }

# 1. stop any running server (frees /dev/uio*, /dev/udmabuf-*)
pkill -f '[o]jls_server' 2>/dev/null || true
sleep 0.3

# 2. reload the PL
cp -f "$src" "$fw_dir/$fw"
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo "$fw" > /sys/class/fpga_manager/fpga0/firmware
state="$(cat /sys/class/fpga_manager/fpga0/state)"
echo "fpga state: $state"
[ "$state" = operating ] || { echo "fpga not operating after reload" >&2; exit 1; }

# 3. restart the server, fully detached so the launching ssh channel returns —
#    a backgrounded server otherwise holds the channel open and hangs the ssh
#    call (the server starts regardless, but the caller would time out).
#    stdbuf -oL: the server prints its "openjls: ... BITNESS N" banner on
#    stdout, which is block-buffered when redirected to a file — without line
#    buffering that line can sit unflushed for the whole run and the check
#    below would race it. stderr (the axidma line) is already unbuffered.
#    The server opens its three DMA buffers (udmabuf-ojls-{tx,rx,desc}) by
#    name, so no --*-buf flags are needed; pass them only to override the
#    defaults for a differently-named overlay.
cd "$server_dir"
setsid stdbuf -oL -eL ./ojls_server \
  >/tmp/ojls_server.log 2>&1 </dev/null &

# 4. confirm the server latched the intended precision from the CAPS register.
#    Poll a few seconds: the banner appears once the buffer flushes, and the
#    host also probes the TCP port before sending.
for _ in $(seq 1 25); do
  grep -q "BITNESS $b\b" /tmp/ojls_server.log 2>/dev/null && break
  sleep 0.2
done
if grep -q "BITNESS $b\b" /tmp/ojls_server.log 2>/dev/null; then
  echo "server up, BITNESS $b"
else
  echo "server did not report BITNESS $b — log:" >&2
  cat /tmp/ojls_server.log >&2 || true
  exit 1
fi

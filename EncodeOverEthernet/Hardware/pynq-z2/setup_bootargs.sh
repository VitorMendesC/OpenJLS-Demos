#!/bin/sh
# First-boot kernel-command-line + boot-overlay setup for the EncodeOverEthernet
# demo on a PYNQ-Z2 (Xilinx/PYNQ U-Boot image). Run once per board, as root,
# with openjls.dtbo next to this script; then reboot.
#
# It makes three persistent changes:
#
#   1. bootargs (in /boot/uEnv.txt): adds
#        uio_pdrv_genirq.of_id=generic-uio   binds the UIO register nodes
#      and pins `cma=128M` (the stock size). The DMA buffers do NOT come
#      from CMA anymore — they live in an exclusive reserved-memory carveout
#      (see openjls.dtso) — so CMA no longer needs growing; it must actually
#      stay small enough to fit beside the ~256 MiB carveout. Re-runs replace
#      any previous `cma=` (older versions of this script set cma=320M).
#
#   2. Installs openjls.dtbo into /boot so U-Boot can load it.
#
#   3. Caps U-Boot's fdt/initrd relocation (fdt_high= / initrd_high= in
#      /boot/uEnv.txt) at 0x0ffc0000, i.e. below the lowest carveout.
#      Without this U-Boot relocates the patched DTB to the top of DDR —
#      *inside* the ojls-rx carveout (which ends at the 512 MiB top) — and
#      the kernel then refuses to create that reserved-memory region
#      (overlap with the live DTB), so udmabuf-ojls-rx probes with -EINVAL
#      while tx/desc still come up. boot.scr `env import`s uEnv.txt fully,
#      so these land in the U-Boot environment before uenvcmd runs.
#
#   4. Installs a `uenvcmd` line in /boot/uEnv.txt. U-Boot runs it before its
#      normal boot: it loads image.ub, extracts the kernel DTB from it,
#      applies openjls.dtbo in RAM, and boots kernel + patched DTB. This is
#      what makes the overlay's reserved-memory carveout real — the kernel
#      must see it at early boot; a runtime (configfs) overlay is too late
#      and would reserve nothing. If any step of uenvcmd fails (e.g. the
#      dtbo is missing), U-Boot falls through to the stock unpatched boot,
#      so a bad install cannot brick the board — the demo just reports the
#      missing carveout at board_setup.sh time.
#
#      Addresses: FIT staged at 0x10000000 (as stock); extracted DTB at
#      0x08000000 and dtbo at 0x08100000, clear of the kernel's 0x80000
#      load address (uncompressed, ~7 MiB) and of the FIT staging area.
#
# On this image U-Boot imports /boot/uEnv.txt and its `bootargs=` line *fully
# replaces* the kernel command line. So we seed from the running /proc/cmdline
# (keeping root=... and everything else) and add only what is missing.
# Idempotent: a re-run converges to the same file.
#
# Overrides:  UENV=/boot/uEnv.txt  BOOTDIR=/boot  CMA=128M  DTBO=<path>
set -eu

UENV=${UENV:-/boot/uEnv.txt}
BOOTDIR=${BOOTDIR:-/boot}
CMA=${CMA:-128M}
DTBO=${DTBO:-$(dirname "$0")/openjls.dtbo}

if [ "$(id -u)" -ne 0 ]; then
	echo "setup_bootargs.sh: must run as root (writes $UENV)" >&2
	exit 1
fi
if [ ! -f "$DTBO" ]; then
	echo "setup_bootargs.sh: $DTBO not found (copy openjls.dtbo next to this script, or set DTBO=)" >&2
	exit 1
fi

# --- 1. bootargs ------------------------------------------------------------
# Seed from an existing bootargs line if there is one, else the live cmdline.
args=$(sed -n 's/^bootargs=//p' "$UENV" 2>/dev/null || true)
[ -n "$args" ] || args=$(cat /proc/cmdline)

case "$args" in *uio_pdrv_genirq.of_id=*) ;; *) args="$args uio_pdrv_genirq.of_id=generic-uio" ;; esac
case "$args" in
	*cma=*) args=$(printf '%s' "$args" | sed -E "s/cma=[0-9]+[KkMmGg]?/cma=$CMA/") ;;
	*)      args="$args cma=$CMA" ;;
esac

# --- 2. the overlay U-Boot applies at boot ---------------------------------
cp -f "$DTBO" "$BOOTDIR/openjls.dtbo"

# --- 3. keep U-Boot's relocations out of the carveouts ----------------------
# Cap fdt/initrd relocation below the lowest carveout (ojls-desc@ffc0000).
# U-Boot's lmb allocates top-down, so the DTB lands just under 0x0ffc0000,
# clear of the kernel image (~7 MiB at 0x80000) and of all three pools.
fdt_high='fdt_high=0x0ffc0000'
initrd_high='initrd_high=0x0ffc0000'

# --- 4. uenvcmd -------------------------------------------------------------
# Single-quoted: ${devtype} etc. are U-Boot variables, expanded by U-Boot's
# shell when uenvcmd runs (boot.scr sets them before importing uEnv.txt).
uenvcmd='uenvcmd=echo openjls: applying openjls.dtbo to the FIT device tree && fatload ${devtype} ${devnum}:${distro_bootpart} 0x10000000 image.ub && fatload ${devtype} ${devnum}:${distro_bootpart} 0x08100000 openjls.dtbo && imxtract 0x10000000 fdt-0 0x08000000 && fdt addr 0x08000000 && fdt resize 0x10000 && fdt apply 0x08100000 && bootm 0x10000000:kernel-0 - 0x08000000'

# --- rewrite uEnv.txt atomically -------------------------------------------
tmp="$UENV.tmp"
{
	# keep everything that isn't a line we own
	[ -f "$UENV" ] && grep -v -e '^bootargs=' -e '^uenvcmd=' -e '^fdt_high=' -e '^initrd_high=' "$UENV" || true
	echo "bootargs=$args"
	echo "$fdt_high"
	echo "$initrd_high"
	echo "$uenvcmd"
} > "$tmp"
mv -f "$tmp" "$UENV"

echo "setup_bootargs.sh: wrote $UENV"
echo "  bootargs=$args"
echo "  $fdt_high $initrd_high  (keeps U-Boot's relocated DTB out of the carveouts)"
echo "  uenvcmd=(boot-time overlay apply, falls back to stock boot on failure)"
echo "setup_bootargs.sh: installed $BOOTDIR/openjls.dtbo"
echo "setup_bootargs.sh: reboot for the new command line + carveout to take effect."

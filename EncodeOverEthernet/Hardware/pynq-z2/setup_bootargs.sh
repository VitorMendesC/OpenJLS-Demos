#!/bin/sh
# First-boot kernel-command-line setup for the EncodeOverEthernet demo on a
# PYNQ-Z2 (Xilinx/PYNQ U-Boot image). Run once per board, as root, then reboot.
#
# The demo needs two kernel parameters that persist across reboots:
#   uio_pdrv_genirq.of_id=generic-uio   binds the UIO register nodes
#   cma=<size>                          the stock 128 MiB CMA pool is too small
#                                       for the DMA buffers, so bring-up fails
#
# On this image U-Boot imports /boot/uEnv.txt and its `bootargs=` line *fully
# replaces* the kernel command line. So we seed from the running /proc/cmdline
# (keeping root=... and everything else) and add only the parameters that are
# missing. Idempotent: once both are present a re-run changes nothing.
#
# Overrides:  UENV=/boot/uEnv.txt  CMA=320M   (e.g. CMA=448M for larger images)
set -eu

UENV=${UENV:-/boot/uEnv.txt}
CMA=${CMA:-320M}

if [ "$(id -u)" -ne 0 ]; then
	echo "setup_bootargs.sh: must run as root (writes $UENV)" >&2
	exit 1
fi

# Seed from an existing bootargs line if there is one, else the live cmdline.
args=$(sed -n 's/^bootargs=//p' "$UENV" 2>/dev/null || true)
[ -n "$args" ] || args=$(cat /proc/cmdline)

case "$args" in *uio_pdrv_genirq.of_id=*) ;; *) args="$args uio_pdrv_genirq.of_id=generic-uio" ;; esac
case "$args" in *cma=*) ;; *) args="$args cma=$CMA" ;; esac

if grep -q '^bootargs=' "$UENV" 2>/dev/null; then
	sed -i "s|^bootargs=.*|bootargs=$args|" "$UENV"
else
	echo "bootargs=$args" >> "$UENV"
fi

echo "setup_bootargs.sh: wrote $UENV"
echo "  bootargs=$args"
echo "setup_bootargs.sh: reboot for the new kernel command line to take effect."

#!/usr/bin/env bash
# qemu-raspi-boot.sh — boot the Pi kernel from an alpine-pi image under
# qemu-system-arm's raspi1ap machine and capture the serial log.
#
# Usage: qemu-raspi-boot.sh <img> [timeout-seconds] [logfile]
#
# WHAT THIS PROVES, AND WHAT IT CANNOT
# ------------------------------------
# It proves the front of the boot chain: the kernel on the FAT partition
# decompresses and runs, the device tree loads, and early userspace from the
# initramfs executes.
#
# It cannot prove the system actually comes up, because QEMU's raspi
# emulation has two defects against a stock linux-rpi kernel:
#
#   1. bcm2835_power / bcm2835_pm NULL-deref during driver init against
#      QEMU's incomplete mailbox firmware emulation. Worked around below
#      with initcall_blacklist; without it the kernel panics ~2s in.
#   2. bcm2835-dma emits bus addresses above the 0x5fffffff limit, so every
#      SD read fails. mmc0 is detected but /dev/mmcblk0p2 never mounts, and
#      early userspace gives up before OpenRC is ever reached.
#
# Defect 2 has no workaround, so a PASS here means "the kernel and DT are
# sound", not "the image boots". Userspace is covered by scripts/chroot-test.sh
# (T2) and the session by scripts/headless-render-test.sh (T3), both of which
# run the image's armhf binaries under user-mode qemu in a chroot and so never
# touch an SD controller at all.
#
# This is the ONLY test left in this repo that boots a kernel. There used to be
# a second one (qemu-virt-boot.sh, a full OpenRC boot on qemu-system-arm's virt
# machine); it was deleted because it could not be made to finish inside the
# five minute ceiling every test here has to meet. The consequence is written
# down rather than glossed over: NOTHING in CI now proves that OpenRC boots or
# that it orders services correctly. T2 checks that statically - every init
# script parses, every runlevel symlink resolves, every enabled service has an
# executable - but real service ordering is verified on hardware only.
#
# Serial output only appears with -M raspi1ap -cpu arm1176 plus
# earlycon=pl011 and keep_bootcon. The uart8250/mmio32, earlyprintk,
# versatilepb and raspi0 variants that appear in most RPi/QEMU writeups
# produce zero bytes with a 6.x linux-rpi: the PL011 driver only enables the
# console after migrating off the boot console, and without keep_bootcon
# everything emitted in between goes to a console that is never adopted.
set -euo pipefail

IMG="${1:-}"
TIMEOUT="${2:-90}"
LOG="${3:-}"

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "usage: $0 <img> [timeout-seconds] [logfile]" >&2
	exit 2
fi

for tool in qemu-system-arm mcopy mdir timeout sfdisk; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: missing '$tool'. Install: qemu-system-arm mtools util-linux coreutils" >&2
		exit 3
	}
done

WORK="$(mktemp -d -t alpinepi-raspi.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# FAT partition is partition 1; read its start rather than assuming 2048.
OFFSET_SECTORS="$(sfdisk -d "$IMG" 2>/dev/null | awk '/start=/{for(i=1;i<=NF;i++) if($i~/^start=/){gsub(/[start=,]/,"",$i); print $i; exit}}')"
case "$OFFSET_SECTORS" in ''|*[!0-9]*) OFFSET_SECTORS=2048 ;; esac
OFFSET_BYTES=$(( OFFSET_SECTORS * 512 ))
echo "[raspi] FAT offset: sector $OFFSET_SECTORS ($OFFSET_BYTES bytes)"

# mtools' @@offset reads a partition out of a disk image without loop-mounting,
# so this needs no root. NOTE: @@offset is where the FAT *filesystem* starts,
# not an offset to any file - mtools walks the FAT directory and follows the
# cluster chain, so the kernel changing size or becoming fragmented is
# irrelevant here.
#
# Names are discovered rather than hardcoded: a different kernel flavour
# renames vmlinuz-*, initramfs-* and the DTB all at once, and hardcoding them
# would fail with a confusing mcopy error rather than a clear one.
FAT="$(mdir -b -i "${IMG}@@${OFFSET_BYTES}" :: 2>/dev/null)"
[ -n "$FAT" ] || { echo "ERROR: cannot read the FAT partition of $IMG" >&2; exit 4; }

pick() {
	# $1 = human name for the error, rest = patterns in order of preference
	local what="$1"; shift
	local pat
	for pat in "$@"; do
		local hit
		hit="$(printf '%s\n' "$FAT" | grep -iE "$pat" | head -1)"
		[ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
	done
	echo "ERROR: no $what on the boot partition. Contents:" >&2
	printf '%s\n' "$FAT" | sed 's/^/  /' >&2
	return 1
}

K_NAME="$(pick "kernel" '/(vmlinuz|zImage|Image|kernel)[^/]*$')"
I_NAME="$(pick "initramfs" '/(initramfs|initrd)[^/]*$')"
# raspi1ap is a Pi 1 Model A+, so prefer that board's DTB; the Zero W's own
# bcm2835-rpi-zero-w.dtb describes hardware QEMU does not emulate. Fall back
# through the other BCM2835 boards.
D_NAME="$(pick "BCM2835 DTB" '/bcm2835-rpi-a-plus\.dtb$' '/bcm2835-rpi-b(-plus)?\.dtb$' '/bcm2835-rpi-[^/]*\.dtb$')"
echo "[raspi] using $K_NAME, $I_NAME, $D_NAME"

mcopy -n -i "${IMG}@@${OFFSET_BYTES}" "$K_NAME" "$WORK/k"
mcopy -n -i "${IMG}@@${OFFSET_BYTES}" "$I_NAME" "$WORK/i"
mcopy -n -i "${IMG}@@${OFFSET_BYTES}" "$D_NAME" "$WORK/dtb"
ls -lh "$WORK/k" "$WORK/i" "$WORK/dtb"

# QEMU's SD emulation rejects any size that is not a power of two.
IMG_SIZE="$(stat -c %s "$IMG")"
POW2=1; while [ "$POW2" -lt "$IMG_SIZE" ]; do POW2=$(( POW2 * 2 )); done
cp --sparse=always "$IMG" "$WORK/sd.img"
[ "$POW2" = "$IMG_SIZE" ] || { echo "[raspi] padding $IMG_SIZE -> $POW2 for SD emulation"; truncate -s "$POW2" "$WORK/sd.img"; }

set +e
timeout --preserve-status --kill-after=5 "$TIMEOUT" \
	qemu-system-arm \
		-M raspi1ap -cpu arm1176 -m 512 \
		-kernel "$WORK/k" -initrd "$WORK/i" -dtb "$WORK/dtb" \
		-drive file="$WORK/sd.img",format=raw,if=sd \
		-append "console=ttyAMA0,115200 earlycon=pl011,0x20201000 keep_bootcon initcall_blacklist=bcm2835_power_driver_init,bcm2835_pm_driver_init" \
		-nographic -serial mon:stdio -no-reboot \
	< /dev/null 2>&1 | { [ -n "$LOG" ] && tee "$LOG" || cat; }
rc=${PIPESTATUS[0]}
set -e
echo "[raspi] qemu rc=$rc"

#!/usr/bin/env bash
# chroot-test.sh - T2: does the image's armhf userspace actually run?
#
# Usage: chroot-test.sh <img> <headless|sway|xfce4> [outdir]
#
# Loop-mounts the image's rootfs READ-ONLY, puts a throwaway overlay on top,
# and runs scripts/lib/chroot-assert.sh inside it under qemu-arm user-mode
# emulation. Exits non-zero if any assertion failed. Measured wall clock: 6-10
# seconds per variant against a 5 minute ceiling.
#
# WHY THIS REPLACED A FULL-SYSTEM BOOT
# ------------------------------------
# The question "do these armhf binaries run and does the configuration point
# at files that exist" does not need a kernel, a device tree, an SD controller
# or an init system. It needs an ARM instruction translator and a rootfs. That
# is a chroot plus binfmt_misc, which is what pmbootstrap itself uses to BUILD
# these images, and it answers in seconds what the old qemu-system-arm virt
# boot took ten minutes to answer less reliably.
#
# WHAT IS GIVEN UP, HONESTLY
# --------------------------
# A chroot has no kernel of its own, so nothing here proves that OpenRC boots,
# that it orders services correctly, or that a service actually starts. The
# repo used to have a test for that (a full-system boot on qemu-system-arm's
# virt machine) and it has been deleted, because it could not be made to fit
# inside five minutes. What survives of it is static: this test checks that
# every enabled service's binary exists, that every init script parses, and
# that every runlevel symlink resolves - the three ways service startup has
# actually broken here. Real service ORDERING is now verified on hardware
# only. That is a deliberate trade: a ten minute test that nobody waits for
# catches nothing at all.
#
# It also cannot see anything the kernel does: no Wi-Fi association, no
# VideoCore, no SD timing, no CMA pressure. T1 (scripts/qemu-raspi-boot.sh)
# covers the kernel and device tree; the board covers the rest.
set -euo pipefail

IMG="${1:-}"
VARIANT="${2:-}"
OUTDIR="${3:-chroot-test-${VARIANT:-unknown}}"

usage() {
	echo "usage: $0 <img> <headless|sway|xfce4> [outdir]" >&2
	exit 2
}
[ -n "$IMG" ] && [ -f "$IMG" ] || usage
case "$VARIANT" in headless|sway|xfce4) ;; *) usage ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/image-chroot.sh
. "$HERE/lib/image-chroot.sh"

# Five minutes is the ceiling for every test in this repo, and ic_bootstrap
# refuses to be given more. This test runs in under ten seconds, so the budget
# is a tripwire for something hanging - a wedged qemu-arm process, an ext4
# journal replay, a chroot child that never returns - not a target to grow
# into.
ic_bootstrap 300 "$@"

trap ic_teardown EXIT INT TERM HUP

ic_need_tools losetup mount umount mountpoint chroot sfdisk mknod install
ic_binfmt
ic_mount "$IMG"

PAYLOAD="$(ic_install_payload "$HERE/lib/chroot-assert.sh")"
LOG="$IC_ROOT/out/chroot-test.log"

echo "[t2] $(basename "$IMG") as '$VARIANT', rootfs mounted read-only at $IC_ROOT"
echo

START="$SECONDS"
rc=0
set +e
ic_chroot -- /bin/sh "$PAYLOAD" "$VARIANT" 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e
ELAPSED=$(( SECONDS - START ))

ic_collect "$OUTDIR"

echo
echo "[t2] $VARIANT finished in ${ELAPSED}s (budget 300s); log in $OUTDIR/chroot-test.log"
if [ "$rc" -ne 0 ]; then
	# The counts are in the log; repeat the failures here so a CI log is
	# diagnosable without downloading the artifact.
	echo "[t2] FAILED assertions:"
	grep '^FAIL' "$OUTDIR/chroot-test.log" | sed 's/^/       /' || true
	echo "[t2] RESULT: FAIL"
	exit 1
fi
if grep -q '^warn' "$OUTDIR/chroot-test.log"; then
	echo "[t2] warnings (not fatal, but real):"
	grep '^warn' "$OUTDIR/chroot-test.log" | sed 's/^/       /'
fi
echo "[t2] RESULT: PASS"

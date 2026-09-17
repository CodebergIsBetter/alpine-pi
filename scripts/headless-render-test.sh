#!/usr/bin/env bash
# headless-render-test.sh - T3: does the compositor actually put pixels up?
#
# Usage: headless-render-test.sh <img> <headless|sway|xfce4> [outdir]
#
# Starts the image's OWN configured session inside a chroot, against wlroots'
# headless backend, screenshots it with the image's own grim, and hands the
# frame to scripts/analyse-framebuffer.py. A "graphical" verdict is the pass
# condition for sway and xfce4. Measured wall clock: about 20s for sway and
# 40s for xfce4, against a 5 minute ceiling.
#
# WHY A CHROOT CAN DO THIS AT ALL
# -------------------------------
# A compositor does not need a kernel of its own or a GPU; it needs a socket
# directory, a renderer and somewhere to put the pixels. wlroots' HEADLESS
# backend provides the last of those in plain memory, with no DRM device, no
# KMS and no /dev/dri - which is exactly the situation inside a chroot. The
# old version of this test booted a whole emulated machine with a virtio-gpu
# to get the same answer and took up to 30 minutes to do it; this takes half a
# minute, and because there is no kernel involved it also cannot fail for a
# reason that belongs to the emulator's virtio stack rather than to the image.
#
# WHAT A "graphical" VERDICT PROVES, AND WHAT IT DOES NOT
# -------------------------------------------------------
# It proves the chain from the session symlink to painted pixels:
#   /var/lib/tinydm/default-session.desktop -> Exec= -> the tinydm env chain
#   -> XDG_RUNTIME_DIR -> the compositor -> its clients -> a frame with
#   content in it.
# That is the chain that broke when XDG_RUNTIME_DIR went missing and when the
# session symlink pointed at the wrong .desktop: every process stayed alive
# and the screen was black, which no log-scraping test noticed.
#
# It does NOT prove anything about the VideoCore IV. There is no vc4 here, no
# KMS, no HDMI and no 64 MB CMA pool, so a GPU-specific or memory-pressure
# failure is still hardware-only. It says nothing about frame rate either:
# software rendering under emulation is nothing like the real V3D.
#
# It also no longer covers what the full-system framebuffer test covered on
# the way to the compositor - fbcon, tty1, the getty and tinydm's autologin
# are all skipped, because there is no kernel to provide them. Those are now
# checked statically by T2 (chroot-test.sh) and for real only on the board.
set -euo pipefail

IMG="${1:-}"
VARIANT="${2:-}"
OUTDIR="${3:-headless-render-${VARIANT:-unknown}}"

usage() {
	echo "usage: $0 <img> <headless|sway|xfce4> [outdir]" >&2
	exit 2
}
[ -n "$IMG" ] && [ -f "$IMG" ] || usage
case "$VARIANT" in headless|sway|xfce4) ;; *) usage ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
ANALYSE="$HERE/analyse-framebuffer.py"
[ -f "$ANALYSE" ] || { echo "ERROR: $ANALYSE is missing" >&2; exit 3; }

# shellcheck source=scripts/lib/image-chroot.sh
. "$HERE/lib/image-chroot.sh"

# The ceiling for every test in this repo. The deadlines below are set well
# inside it so that a failing run still has time to copy out the frame and the
# session log - a test that is killed by the budget leaves no evidence, which
# is the one thing worse than a failure.
ic_bootstrap 300 "$@"

SOCKET_WAIT=60      # a wayland socket has to appear this fast
RENDER_DEADLINE=180 # ...and a painted frame this fast, measured from launch
CAPTURE_EVERY=3

trap ic_teardown EXIT INT TERM HUP

ic_need_tools losetup mount umount mountpoint chroot sfdisk mknod install python3
ic_binfmt
ic_mount "$IMG"
mkdir -p "$OUTDIR"

# --------------------------------------------------------------------------- #
# headless: there is nothing to render, and that is the assertion
# --------------------------------------------------------------------------- #
# Inventing an expected verdict for an image with no compositor would mean
# testing the getty, and there is no getty in a chroot either. So this variant
# is SKIPPED here - T2 covers its userspace - but the skip is not free: it
# checks that the image really has no session, because a compositor appearing
# in the headless image would mean the variant selection leaked, and the skip
# would then be hiding it.
if [ "$VARIANT" = headless ]; then
	bad=0
	for prog in sway labwc weston wayfire river cage startxfce4 Xorg; do
		for dir in bin sbin usr/bin usr/sbin; do
			if [ -e "$IC_ROOT/$dir/$prog" ]; then
				echo "FAIL: the headless image ships /$dir/$prog"
				bad=1
			fi
		done
	done
	for path in usr/share/wayland-sessions usr/share/xsessions \
			var/lib/tinydm/default-session.desktop; do
		if [ -e "$IC_ROOT/$path" ]; then
			echo "FAIL: the headless image has /$path"
			bad=1
		fi
	done
	if [ "$bad" -ne 0 ]; then
		echo "[t3] RESULT: FAIL - headless is supposed to have no session at all"
		exit 1
	fi
	echo "[t3] headless: no compositor, no session file, nothing to render."
	echo "[t3] RESULT: SKIP (T3 does not apply to this variant)"
	exit 0
fi

# --------------------------------------------------------------------------- #
# Who the session runs as
# --------------------------------------------------------------------------- #
# From the image, never hardcoded: AUTOLOGIN_UID is 10000 on these builds, not
# the 1000 that tinydm defaults to, and an image built with a different --user
# would silently be tested as the wrong account.
AUTO_UID="$(sed -n 's/^[[:space:]]*AUTOLOGIN_UID=["'"'"']*\([0-9]*\).*/\1/p' \
	"$IC_ROOT/etc/conf.d/tinydm" 2>/dev/null | tail -1 || true)"
[ -n "$AUTO_UID" ] ||
	ic_die "no AUTOLOGIN_UID in /etc/conf.d/tinydm - tinydm would refuse to start"
AUTO_GID="$(awk -F: -v u="$AUTO_UID" '$3 == u { print $4 }' "$IC_ROOT/etc/passwd")"
AUTO_USER="$(awk -F: -v u="$AUTO_UID" '$3 == u { print $1 }' "$IC_ROOT/etc/passwd")"
[ -n "$AUTO_GID" ] ||
	ic_die "AUTOLOGIN_UID=$AUTO_UID matches no account in the image's /etc/passwd"

# What /etc/init.d/xdg-runtime-dirs does at boot. Creating it here rather than
# letting the session create it is deliberate: on the real device the session
# does NOT create it either, so a test that did would hide the day that
# service stops being enabled.
RUNTIME_DIR="$IC_ROOT/run/user/$AUTO_UID"
install -d -m 0700 -o "$AUTO_UID" -g "$AUTO_GID" "$RUNTIME_DIR"

PAYLOAD="$(ic_install_payload "$HERE/lib/chroot-session.sh")"
echo "[t3] $(basename "$IMG") as '$VARIANT', session as $AUTO_USER (uid $AUTO_UID)"

# --------------------------------------------------------------------------- #
# Launch
# --------------------------------------------------------------------------- #
START="$SECONDS"
ic_chroot --user "$AUTO_UID:$AUTO_GID" -- /bin/sh "$PAYLOAD" &
SESSION_PID=$!

session_alive() { kill -0 "$SESSION_PID" 2>/dev/null; }
session_log() {
	if [ -s "$IC_WORK/tmp/out/session.log" ]; then
		echo "--- last 30 lines of the session's own log ---"
		tail -n 30 "$IC_WORK/tmp/out/session.log" | sed 's/^/    /'
	else
		echo "--- the session produced no log at all ---"
	fi
}

WAYLAND_SOCKET=""
while [ $(( SECONDS - START )) -lt "$SOCKET_WAIT" ]; do
	for sock in "$RUNTIME_DIR"/wayland-*; do
		case "$sock" in *.lock|*'*') continue ;; esac
		[ -S "$sock" ] && WAYLAND_SOCKET="$(basename "$sock")"
	done
	[ -n "$WAYLAND_SOCKET" ] && break
	if ! session_alive; then break; fi
	sleep 1
done

if [ -z "$WAYLAND_SOCKET" ]; then
	echo "[t3] no wayland socket in $RUNTIME_DIR after $(( SECONDS - START ))s"
	echo "[t3] the compositor never came up, so there is nothing to photograph."
	session_log
	ic_collect "$OUTDIR"
	echo "[t3] RESULT: FAIL"
	exit 1
fi
echo "[t3] compositor listening on $WAYLAND_SOCKET after $(( SECONDS - START ))s"

# --------------------------------------------------------------------------- #
# Capture until the frame has something in it
# --------------------------------------------------------------------------- #
# Not "capture once": the first frame after the socket appears is routinely
# empty, because the compositor is up but its clients - the bar, the panel,
# the wallpaper - have not drawn yet. Measured on these images: sway's first
# frame is already the wallpaper, xfce4's first is black and its second (about
# 10s later) has the panel. Stopping at the first capture would report a
# working desktop as blank.
VERDICT=""
PREV_VERDICT="none"
CAPTURES=0
while [ $(( SECONDS - START )) -lt "$RENDER_DEADLINE" ]; do
	if ! session_alive; then
		echo "[t3] the session exited after $(( SECONDS - START ))s"
		break
	fi
	if ic_chroot --user "$AUTO_UID:$AUTO_GID" -- /usr/bin/env \
			"XDG_RUNTIME_DIR=/run/user/$AUTO_UID" \
			"WAYLAND_DISPLAY=$WAYLAND_SOCKET" \
			grim -t ppm /out/frame.ppm >/dev/null 2>"$IC_WORK/tmp/grim.err" &&
			[ -s "$IC_WORK/tmp/out/frame.ppm" ]; then
		CAPTURES=$(( CAPTURES + 1 ))
		# The analyser exits non-zero for a blank frame, which is the normal
		# first answer, so its status is discarded here and only consulted for
		# the final verdict below.
		VERDICT="$(python3 "$ANALYSE" "$IC_WORK/tmp/out/frame.ppm" 2>/dev/null |
			awk '$1 == "verdict" { print $3 }' || true)"
		echo "[t3] capture $CAPTURES at $(( SECONDS - START ))s: ${VERDICT:-unreadable}"
		# One saved frame per DISTINCT verdict, not one per capture: the
		# progression (blank -> console -> graphical, or blank -> blank) is
		# what a human needs to see when the result surprises them, and a
		# 2.7 MB PPM every three seconds is not.
		if [ "$VERDICT" != "$PREV_VERDICT" ]; then
			cp -f "$IC_WORK/tmp/out/frame.ppm" \
				"$IC_WORK/tmp/out/frame-${CAPTURES}-${VERDICT:-unreadable}.ppm"
			PREV_VERDICT="$VERDICT"
		fi
		[ "$VERDICT" = graphical ] && break
	else
		echo "[t3] grim failed at $(( SECONDS - START ))s: $(tr -d '\n' < "$IC_WORK/tmp/grim.err")"
	fi
	sleep "$CAPTURE_EVERY"
done
ELAPSED=$(( SECONDS - START ))

# Stop the session before judging: it flushes the last of its log, and it keeps
# the shell from printing a bare "Terminated" over the summary when ic_teardown
# kills the whole namespace a moment later.
#
# SIGKILL after a grace period, not SIGTERM and a wait: sway's session is
# exec'd through dbus-run-session, which under user-mode emulation does not
# pass a TERM on to the compositor it is waiting for. An unbounded "wait" here
# hung until the 300s budget killed the run - correct behaviour from the
# budget, useless behaviour from the test.
kill -TERM "$SESSION_PID" 2>/dev/null || true
for _ in 1 2 3; do
	kill -0 "$SESSION_PID" 2>/dev/null || break
	sleep 1
done
kill -KILL "$SESSION_PID" 2>/dev/null || true
wait "$SESSION_PID" 2>/dev/null || true

# --------------------------------------------------------------------------- #
# Verdict
# --------------------------------------------------------------------------- #
ic_collect "$OUTDIR"
rc=0
if [ ! -s "$OUTDIR/frame.ppm" ]; then
	echo "[t3] no frame was ever captured in ${ELAPSED}s"
	session_log
	echo "[t3] RESULT: FAIL"
	exit 1
fi

echo
python3 "$ANALYSE" "$OUTDIR/frame.ppm" --expect graphical |
	tee "$OUTDIR/verdict.txt" || rc=$?
if [ -n "${SUDO_UID:-}" ]; then
	chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUTDIR" 2>/dev/null || true
fi

echo
echo "[t3] $VARIANT: $CAPTURES captures in ${ELAPSED}s (budget 300s), last verdict '${VERDICT:-none}'"
echo "[t3] frame, verdict and session log in $OUTDIR/"
if [ "$rc" -ne 0 ]; then
	# A wrong verdict is only diagnosable from the compositor's own output,
	# and CI should not need the artifact to see it.
	session_log
	echo "[t3] RESULT: FAIL"
	exit 1
fi
echo "[t3] RESULT: PASS"

#!/bin/sh
# shellcheck shell=dash
# chroot-session.sh - the body of T3's compositor launch. Runs INSIDE the
# image's rootfs, as the image's own autologin user, under qemu-arm.
# Copied in by headless-render-test.sh; it is not useful on its own.
#
# The shellcheck dialect is "dash" because this runs under the image's busybox
# ash; shellcheck's strict POSIX sh dialect rejects "local" (SC3043).
#
# WHAT THIS IMITATES
# ------------------
# /usr/bin/tinydm-run-session, step for step, because the point of T3 is to
# find out whether the session the image is ACTUALLY configured to start will
# paint. So the session command is not hardcoded here: it is read out of
# /var/lib/tinydm/default-session.desktop exactly the way tinydm reads it, and
# the same environment snippets are sourced in the same order. A test that ran
# "sway" directly would still pass on an image whose session symlink pointed at
# the wrong .desktop, or whose env snippet had stopped exporting
# XDG_RUNTIME_DIR - both of which this project has shipped.
#
# WHAT IS DELIBERATELY DIFFERENT
# ------------------------------
# Three things, all of them emulator limits rather than image properties, and
# all of them exported AFTER the image's own snippets so they win:
#
#   WLR_BACKENDS=headless       There is no DRM device in a chroot and no
#                               kernel to provide one. wlroots' headless
#                               backend renders into memory instead, which is
#                               all a screenshot needs.
#   WLR_RENDERER_ALLOW_SOFTWARE wlroots refuses to start on a software GL
#                               stack unless told to ("Software rendering
#                               detected, please use the
#                               WLR_RENDERER_ALLOW_SOFTWARE environment
#                               variable to proceed"). The board has a real
#                               VideoCore IV, so this relaxes a check that
#                               only the emulator trips.
#   WLR_HEADLESS_OUTPUTS=1      One 1280x720 output to photograph.
#   WLR_RENDERER=pixman         The image's own env snippet pins
#                               WLR_RENDERER=gles2, because the VideoCore IV
#                               has no Vulkan and probing for one is wasted
#                               time on the board. In a chroot that pin is
#                               fatal rather than helpful: wlroots' GLES2
#                               renderer needs a DRM file descriptor, there is
#                               no /dev/dri here and no kernel to create one,
#                               and the failure is immediate and total -
#                                 drmGetDevices2 failed: No such file or directory
#                                 Cannot create GLES2 renderer: no DRM FD available
#                                 Failed to create renderer
#                               Overriding to pixman, wlroots' CPU renderer,
#                               is what makes a frame exist at all. The cost is
#                               that T3 cannot exercise the GL path; that the
#                               pin is still in place is checked statically by
#                               T2 instead, and the GL stack itself was never
#                               testable off the board anyway.
#
# WLR_LIBINPUT_NO_DEVICES is deliberately NOT set: the headless backend never
# creates a libinput backend, so the zero-input-devices check that the old
# full-system test had to suppress does not fire here at all.
#
# tinydm's own "setpriv --ambient-caps -all" is skipped. It exists to stop
# bwrap choking on inherited capabilities (pmaports#3868); there is no bwrap
# here, and prctl(PR_CAP_AMBIENT) is one of the calls a user-mode emulator is
# entitled not to implement, so running it would risk failing the test for a
# reason that has nothing to do with the image.
set -u

LOG=/out/session.log
# tinydm redirects the session's output to ~/.local/state/tinydm.log, where a
# failure is invisible to CI. Same idea, somewhere the host can read.
exec >"$LOG" 2>&1

# login(1) would set these; chroot --userspec does not.
HOME="$(awk -F: -v u="$(id -u)" '$3 == u { print $6 }' /etc/passwd)"
USER="$(awk -F: -v u="$(id -u)" '$3 == u { print $1 }' /etc/passwd)"
LOGNAME="$USER"
export HOME USER LOGNAME
cd "$HOME" || exit 1

echo "--- chroot-session ---"
echo "uid:      $(id -u) ($USER), home $HOME"

# Alpine's /etc/profile tests $BASH_VERSION and $BB_ASH_VERSION unquoted and
# unset-unsafe, so sourcing it under "set -u" aborts with
#   /etc/profile: line 7: BASH_VERSION: parameter not set
# tinydm-run-session has no "set -u" and therefore does not hit this. Relax it
# for the two sourcing loops only, so the image's own files behave the way they
# do on the device, and restore it afterwards for this script's own code.
set +u

# tinydm-run-session: source_profile
for profile in /etc/profile "$HOME/.profile"; do
	[ -f "$profile" ] || continue
	echo "sourcing $profile"
	# shellcheck disable=SC1090
	. "$profile"
done

# tinydm-run-session: source_session_profiles wayland. /usr/share first, then
# /etc, so a device override beats the package default - the order matters and
# is copied from tinydm rather than guessed.
for file in /usr/share/tinydm/env-wayland.d/* /etc/tinydm.d/env-wayland.d/*; do
	[ -e "$file" ] || continue
	echo "sourcing $file"
	# shellcheck disable=SC1090
	. "$file"
done

set -u

# Emulation-only overrides; see the header.
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_RENDERER_ALLOW_SOFTWARE=1
export WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	echo "FATAL: the tinydm env chain left XDG_RUNTIME_DIR unset."
	echo "       A wlroots compositor exits immediately without it."
	exit 1
fi
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
if [ ! -w "$XDG_RUNTIME_DIR" ]; then
	echo "FATAL: $XDG_RUNTIME_DIR is not writable by $USER."
	ls -ld "$XDG_RUNTIME_DIR"
	exit 1
fi

# tinydm-run-session: run_session
target=/var/lib/tinydm/default-session.desktop
if [ ! -e "$target" ]; then
	echo "FATAL: no session configured ($target is missing)"
	exit 1
fi
resolved="$(realpath "$target")"
desktop="$(basename "$resolved" | sed 's/\.desktop$//')"
XDG_SESSION_DESKTOP="$desktop"
export XDG_SESSION_DESKTOP
names="$(grep '^DesktopNames=' "$resolved" | head -1 | cut -d= -f2- | tr ';' ':' | sed 's/:$//')"
if [ -n "$names" ]; then
	XDG_CURRENT_DESKTOP="$names"
	export XDG_CURRENT_DESKTOP
fi
cmd="$(grep '^Exec=' "$resolved" | head -1 | cut -d= -f2-)"
if [ -z "$cmd" ]; then
	echo "FATAL: $resolved has no Exec= line"
	exit 1
fi

echo "session:  $resolved"
echo "desktop:  $desktop"
echo "exec:     $cmd"
echo "--- session output follows ---"

# Unquoted: Exec is a command line, not a single program name - "Exec=
# dbus-run-session /usr/bin/sway" has to split into two words.
# shellcheck disable=SC2086
exec $cmd

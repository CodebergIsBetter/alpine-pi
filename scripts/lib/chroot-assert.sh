#!/bin/sh
# shellcheck shell=dash
# chroot-assert.sh - the body of T2. Runs INSIDE the image's own rootfs, as
# root, under qemu-arm user-mode emulation. Copied in by chroot-test.sh; it is
# not useful on its own.
#
# Usage: chroot-assert.sh <headless|sway|xfce4>
#
# The shellcheck directive above says "dash" rather than "sh" because this runs
# under the image's busybox ash, which has "local" - shellcheck's strict POSIX
# sh dialect rejects it (SC3043) and would fail the lint job.
#
# WHAT THIS IS FOR
# ----------------
# One thing breaks these images more often than anything else: an armhf binary
# that does not run, or a piece of configuration that names a file which is not
# there. Neither is visible in a build log - apk exits 0 either way - and
# neither needs a kernel to detect. So every check here is either "execute an
# armhf binary and look at what it said" or "follow a reference in the image's
# own configuration and see whether the target exists".
#
# The bug classes below are the ones this project has actually shipped, and
# each has an assertion aimed at it by name:
#
#   * a missing XDG_RUNTIME_DIR, which killed the compositor: the tinydm env
#     chain is sourced for real, as the autologin user, and the value checked;
#   * an eudev sbin/udevadm symlink loop (ELOOP): every symlink under the
#     binary and library directories is resolved;
#   * a tinydm session symlink pointing at the wrong .desktop: the symlink is
#     resolved, the variant checked, and the Exec= program looked up;
#   * an xfce4 image with no icon theme: the theme the image's own xsettings
#     asks for is looked for on disk.
#
# FAIL vs warn
# ------------
# Same split as scripts/assert-boot-log.py, deliberately: FAIL is "this image
# does not work and must not be published", warn is "this is wrong but the
# system still comes up". A warn is printed and counted in the summary so it
# cannot be lost, but it does not gate the release. Promoting one to a FAIL is
# a one-word change.

set -u

VARIANT="${1:-}"
case "$VARIANT" in
	headless|sway|xfce4) ;;
	*) echo "usage: $0 <headless|sway|xfce4>" >&2; exit 2 ;;
esac

PASSES=0
FAILS=0
WARNS=0

pass() { PASSES=$((PASSES + 1)); printf 'pass  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1));  printf 'FAIL  %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1));  printf 'warn  %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

# want_exec <description> <path>
want_exec() {
	if [ -x "$2" ]; then
		pass "$1: $2"
	elif [ -e "$2" ]; then
		fail "$1: $2 exists but is not executable"
	else
		fail "$1: $2 does not exist"
	fi
}

# want_run <label> <expected-extended-regex> <command> [args...]
#
# Runs an armhf binary and matches its own output. The exit status is
# deliberately NOT the assertion: "wpa_supplicant -h" exits 1, "grim -h" exits
# 0, and a binary that cannot resolve a shared library also exits non-zero with
# a completely different message. Matching the text is what distinguishes "it
# ran" from "the loader refused it".
want_run() {
	label="$1"; want="$2"; shift 2
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "$label: $1 is not on PATH inside the image"
		return
	fi
	out="$("$@" 2>&1 | head -3)"
	first="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -1)"
	if printf '%s\n' "$out" | grep -qE "$want"; then
		pass "$label: $first"
	else
		fail "$label: expected /$want/, got: ${first:-<no output>}"
	fi
}

# want_libs <path>
#
# For a GUI client that cannot be asked its version without a display -
# xfdesktop, xfce4-panel, Thunar and xfce4-session all abort with "cannot open
# display" - this is the equivalent proof that the binary is loadable: musl's
# ldd walks the whole DT_NEEDED graph. It is what catches a soname bump in
# Alpine edge that left one package behind, which is the way these images
# usually break.
want_libs() {
	if [ ! -x "$1" ]; then
		fail "shared libraries: $1 does not exist"
		return
	fi
	out="$(ldd "$1" 2>&1)"
	if printf '%s\n' "$out" | grep -qE 'Error (loading|relocating)|not found'; then
		fail "shared libraries: $1 has unresolved dependencies"
		printf '%s\n' "$out" | grep -E 'Error|not found' | sed 's/^/      /'
	else
		pass "shared libraries: $1 resolves ($(printf '%s\n' "$out" | grep -c '=>') objects)"
	fi
}

# ------------------------------------------------------------------------- #
section "the emulated architecture"
# ------------------------------------------------------------------------- #
# If binfmt or the emulator were wrong, nothing below would mean anything, so
# prove first that the binaries being tested really are the image's armhf ones.
want_run "busybox runs" 'BusyBox v' busybox
want_run "apk runs" 'compiled for armhf' apk --version
arch="$(apk --print-arch 2>/dev/null || echo unknown)"
if [ "$arch" = armhf ]; then
	pass "apk --print-arch: armhf"
else
	fail "apk --print-arch: $arch (expected armhf - wrong image or wrong emulator)"
fi
note "alpine-release: $(cat /etc/alpine-release 2>/dev/null || echo unknown)"
note "kernel modules: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"

# ------------------------------------------------------------------------- #
section "core userspace"
# ------------------------------------------------------------------------- #
want_run "openrc" 'OpenRC' openrc --version
want_run "wpa_supplicant" 'wpa_supplicant v' wpa_supplicant -h
want_run "dhcpcd" 'dhcpcd [0-9]' dhcpcd --version
want_run "getty" 'getty|BusyBox' getty --help
# The Wi-Fi radio is the only way into the headless image, and it needs both
# halves: the driver and the 43430 firmware blob. Missing either is silent
# until the board is on a desk with no network.
if find /lib/modules -name 'brcmfmac.ko*' 2>/dev/null | grep -q .; then
	pass "brcmfmac driver present"
else
	fail "brcmfmac driver missing - the board has no other network interface"
fi
if find /lib/firmware/brcm -name 'brcmfmac43430-sdio*.bin*' 2>/dev/null | grep -q .; then
	pass "brcmfmac43430 firmware present"
else
	fail "brcmfmac43430-sdio firmware missing - the radio will not come up"
fi
# depmod has to have run: without modules.dep every modprobe fails by name,
# including the one for the Wi-Fi driver.
for dep in /lib/modules/*/modules.dep; do
	if [ -s "$dep" ]; then
		pass "depmod ran: $dep"
	else
		fail "depmod did not run: $dep is missing or empty"
	fi
done

# ------------------------------------------------------------------------- #
section "the session binaries for the $VARIANT variant"
# ------------------------------------------------------------------------- #
case "$VARIANT" in
	headless)
		# The absence is the assertion here: a compositor in the headless
		# image means the variant selection in build-image.sh leaked.
		for prog in sway labwc weston wayfire river cage startxfce4 Xorg; do
			if command -v "$prog" >/dev/null 2>&1; then
				fail "headless image ships a compositor: $prog"
			fi
		done
		pass "no compositor in the headless image"
		[ -d /usr/share/wayland-sessions ] &&
			fail "headless image has /usr/share/wayland-sessions" ||
			pass "no wayland session directory"
		;;
	sway)
		want_run "sway" 'sway version' sway --version
		want_run "swaymsg" 'swaymsg version' swaymsg --version
		want_run "swaybg" 'swaybg version' swaybg --version
		want_run "foot" 'foot version' foot --version
		# grim is what T3 screenshots with, so T3 cannot report a missing grim
		# as anything but a capture failure. Check it here instead.
		want_run "grim" 'Usage: grim' grim -h
		# sway.desktop's Exec is "dbus-run-session /usr/bin/sway"; without
		# dbus-run-session the session dies before sway is ever exec'd.
		want_run "dbus-run-session" 'dbus-run-session [0-9]' dbus-run-session --version
		;;
	xfce4)
		want_run "labwc" 'labwc [0-9]' labwc --version
		want_run "foot" 'foot version' foot --version
		want_run "xfsettingsd" 'xfsettingsd [0-9]' xfsettingsd --version
		want_run "Xwayland" 'Xwayland Version' Xwayland -version
		want_run "grim" 'Usage: grim' grim -h
		want_run "dbus-run-session" 'dbus-run-session [0-9]' dbus-run-session --version
		# startxfce4 is the session's Exec and it is a shell script, so its
		# failure mode is a syntax error rather than a missing library.
		if sh -n /usr/bin/startxfce4 2>/dev/null; then
			pass "startxfce4 parses"
		else
			fail "startxfce4 has a shell syntax error"
		fi
		# These four abort with "cannot open display" if asked for a version,
		# so the loadable-binary check stands in; T3 then runs them for real
		# under a compositor.
		for prog in /usr/bin/xfdesktop /usr/bin/xfce4-session \
				/usr/bin/xfce4-panel /usr/bin/Thunar; do
			want_libs "$prog"
		done
		;;
esac
# tinydm's own command, and it is PAM-linked: a missing libpam.so.0 means no
# autologin at all, on an image whose only console is a getty.
[ "$VARIANT" = headless ] || want_libs /usr/bin/autologin

# ------------------------------------------------------------------------- #
section "/etc/init.d shell syntax"
# ------------------------------------------------------------------------- #
# OpenRC sources these; a syntax error in one is a service that never starts,
# and nothing in the build catches it. ~70 files, about a second.
syntax_bad=0
for svc in /etc/init.d/*; do
	[ -f "$svc" ] || continue
	sh -n "$svc" 2>/dev/null || { fail "syntax error in $svc"; syntax_bad=1; }
done
[ "$syntax_bad" -eq 0 ] &&
	pass "all $(ls /etc/init.d | wc -l) init scripts parse"

# ------------------------------------------------------------------------- #
section "OpenRC runlevels"
# ------------------------------------------------------------------------- #
# A runlevel entry is a symlink into /etc/init.d. If the target has gone - an
# apk upgrade that dropped a package while the symlink stayed - OpenRC prints
# one line at boot and carries on without the service.
dangling=0
for link in /etc/runlevels/*/*; do
	[ -e "$link" ] || {
		fail "runlevel symlink points at nothing: $link -> $(readlink "$link" 2>/dev/null)"
		dangling=1
		continue
	}
	[ -x "$link" ] || { fail "runlevel entry is not executable: $link"; dangling=1; }
done
[ "$dangling" -eq 0 ] &&
	pass "every runlevel symlink resolves to an executable init script"

# Every "command=" an enabled service supervises has to exist. This is exactly
# the failure that shows up in a boot log as
#   start-stop-daemon: /usr/bin/foo does not exist
# which assert-boot-log.py can only report as a warning after the fact.
missing_cmd=0
for link in /etc/runlevels/*/*; do
	[ -e "$link" ] || continue
	svcname="$(basename "$link")"
	cmd="$(sed -n 's/^[[:space:]]*command=//p' "$link" 2>/dev/null | head -1)"
	[ -n "$cmd" ] || continue
	# Strip quotes, then expand the one variable OpenRC always defines.
	cmd="$(printf '%s' "$cmd" | tr -d '"'"'")"
	cmd="$(printf '%s' "$cmd" | sed -e "s/\${SVCNAME}/$svcname/g" -e "s/\$SVCNAME/$svcname/g")"
	# "${SSHD_BINARY:-/usr/sbin/sshd}" - take the default, which is what runs
	# unless /etc/conf.d overrides it.
	case "$cmd" in
		'${'*':-'*'}') cmd="$(printf '%s' "$cmd" | sed -n 's/^\${[^:]*:-\(.*\)}$/\1/p')" ;;
	esac
	case "$cmd" in
		/*)
			case "$cmd" in
				*'$'*) note "$svcname: command is dynamic ($cmd), not checked" ;;
				*) [ -x "$cmd" ] ||
					{ fail "$svcname is enabled but its command $cmd is missing"; missing_cmd=1; } ;;
			esac
			;;
		*) note "$svcname: command is dynamic ($cmd), not checked" ;;
	esac
done
[ "$missing_cmd" -eq 0 ] &&
	pass "every enabled service's command= exists and is executable"

# ------------------------------------------------------------------------- #
section "/etc/inittab"
# ------------------------------------------------------------------------- #
# busybox init reads this before OpenRC exists. A typo here is an image that
# boots the kernel and then does nothing at all, which is indistinguishable
# from a kernel failure on a board with no serial cable attached.
for want in '^::sysinit:/sbin/openrc sysinit' '^::sysinit:/sbin/openrc boot' \
		'^::wait:/sbin/openrc default' '^::shutdown:/sbin/openrc shutdown'; do
	if grep -qE "$want" /etc/inittab 2>/dev/null; then
		pass "inittab has ${want#^}"
	else
		fail "inittab is missing a line matching /$want/"
	fi
done
if grep -qE '^tty1::respawn:' /etc/inittab; then
	pass "inittab respawns a getty on tty1"
else
	fail "inittab has no respawning tty1 getty - there would be no console"
fi
# Every program inittab names must exist: it is exec'd by PID 1, which has
# nowhere to report an error to.
inittab_bad=0
for prog in $(awk -F: '$4 ~ /^\// { print $4 }' /etc/inittab | awk '{ print $1 }' | sort -u); do
	[ -x "$prog" ] || { fail "inittab runs $prog which is not executable"; inittab_bad=1; }
done
[ "$inittab_bad" -eq 0 ] && pass "every program in inittab exists"

# ------------------------------------------------------------------------- #
section "accounts"
# ------------------------------------------------------------------------- #
# These three files are rewritten by the build, and a malformed line does not
# stop the boot - it stops LOGIN, which on a headless board is the same thing
# as a brick.
check_fields() {
	bad="$(awk -F: -v n="$2" 'NF != n && NF != 0 { print NR": "$0 }' "$1")"
	if [ -n "$bad" ]; then
		fail "$1 has lines without $2 fields:"
		printf '%s\n' "$bad" | sed 's/^/      /'
	else
		pass "$1: every line has $2 colon-separated fields"
	fi
}
check_fields /etc/passwd 7
check_fields /etc/group 4
check_fields /etc/shadow 9

dup="$(cut -d: -f1 /etc/passwd | sort | uniq -d)"
[ -z "$dup" ] && pass "no duplicate usernames" || fail "duplicate usernames: $dup"
dup="$(cut -d: -f3 /etc/passwd | sort | uniq -d)"
[ -z "$dup" ] && pass "no duplicate uids" || fail "duplicate uids: $dup"

shell_bad=0
while IFS=: read -r name _ uid gid _ home shell; do
	# Only accounts that can actually log in have their shell checked. Alpine's
	# baselayout gives the "shutdown", "halt" and "sync" system accounts a
	# COMMAND as their shell field and busybox does not provide /sbin/shutdown,
	# so checking every row reports an upstream quirk as an image defect.
	if [ "$uid" -eq 0 ] || { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; }; then
		[ -x "$shell" ] ||
			{ fail "$name's login shell $shell is not executable"; shell_bad=1; }
	fi
	if ! awk -F: -v g="$gid" '$3 == g { found = 1 } END { exit !found }' /etc/group; then
		fail "$name has primary gid $gid with no /etc/group entry"
		shell_bad=1
	fi
	if ! grep -q "^$name:" /etc/shadow; then
		fail "$name is in /etc/passwd with no /etc/shadow entry"
		shell_bad=1
	fi
	[ -n "$home" ] && [ -d "$home" ] || true
done < /etc/passwd
[ "$shell_bad" -eq 0 ] &&
	pass "every login shell exists and every account has a group and a shadow entry"

orphan="$(cut -d: -f1 /etc/shadow | while read -r s; do
	grep -q "^$s:" /etc/passwd || echo "$s"
done)"
[ -z "$orphan" ] && pass "no /etc/shadow entry without a passwd entry" ||
	fail "shadow entries with no passwd entry: $orphan"

mode="$(stat -c '%a %U %G' /etc/shadow 2>/dev/null)"
case "$mode" in
	"640 root shadow"|"600 root root"|"640 root root")
		pass "/etc/shadow permissions: $mode" ;;
	*) fail "/etc/shadow permissions are $mode (expected 640 root shadow)" ;;
esac

# The interactive account. There is exactly one on these images and everything
# - SSH on headless, autologin on the UI variants - depends on it.
LOGIN_USER=""
LOGIN_UID=""
LOGIN_HOME=""
eval "$(awk -F: '$3 >= 1000 && $3 < 65534 {
	printf "LOGIN_USER=%s LOGIN_UID=%s LOGIN_HOME=%s\n", $1, $3, $6 }' /etc/passwd | head -1)"
if [ -z "$LOGIN_USER" ]; then
	fail "no account with a uid between 1000 and 65533 - nothing can log in"
else
	pass "login account: $LOGIN_USER (uid $LOGIN_UID, home $LOGIN_HOME)"
	if [ -d "$LOGIN_HOME" ]; then
		owner="$(stat -c %u "$LOGIN_HOME")"
		if [ "$owner" = "$LOGIN_UID" ]; then
			pass "$LOGIN_HOME is owned by uid $LOGIN_UID"
		else
			fail "$LOGIN_HOME is owned by uid $owner, not $LOGIN_UID - the session cannot write to it"
		fi
	else
		fail "$LOGIN_HOME does not exist"
	fi
	# A "!" or "*" or empty field is a locked password. The published images
	# have no authorised SSH key, so a locked account means no way in at all.
	hash="$(awk -F: -v u="$LOGIN_USER" '$1 == u { print $2 }' /etc/shadow)"
	case "$hash" in
		'$'*) pass "$LOGIN_USER has a password hash ($(printf '%s' "$hash" | cut -c1-3)...)" ;;
		*) fail "$LOGIN_USER's password field is '$hash' - the account is locked and the image has no SSH key" ;;
	esac
fi

# ------------------------------------------------------------------------- #
section "filesystems"
# ------------------------------------------------------------------------- #
for mp in / /boot; do
	line="$(awk -v m="$mp" '$1 !~ /^#/ && $2 == m { print }' /etc/fstab)"
	if [ -z "$line" ]; then
		fail "/etc/fstab has no entry for $mp"
		continue
	fi
	pass "fstab mounts $mp: $line"
	[ -d "$mp" ] || fail "$mp is in fstab but the mount point does not exist"
	# pmbootstrap writes UUID= for both. A bare /dev/mmcblk0pN would break the
	# moment the card enumerates differently, which is why this is worth
	# noticing even though it still boots today.
	case "$line" in
		UUID=*) ;;
		*) warn "fstab entry for $mp is not UUID= based: $line" ;;
	esac
done

# ------------------------------------------------------------------------- #
section "symlink integrity"
# ------------------------------------------------------------------------- #
# A symlink whose target cannot be reached covers both a dangling link and a
# LOOP: a loop fails with ELOOP, so it shows up here too. That is the eudev
# /sbin/udevadm bug this project shipped, where the link chain pointed back at
# itself and every udev call failed with ELOOP.
#
# Do NOT use "find -xtype l" here. It is a GNU extension, the find in this
# image is busybox, and the error was being swallowed by 2>/dev/null - so the
# assertion silently reported "pass" with a genuinely broken symlink present.
# Caught by deliberately planting /usr/bin/zzz-dangling and watching this
# assertion pass anyway. "-type l ! -exec test -e {} ;" is portable to both
# busybox and GNU find: test -e follows the link, so it is false for a
# dangling target and false for ELOOP.
# "! -exec test -e {} ;" would be the obvious spelling but forks once per
# symlink, and these images have several hundred (every busybox applet is
# one), which measured 3x slower than the whole rest of this script. Read the
# list once and use the shell's builtin [ -e ] instead - no fork per link.
broken="$(
	find /bin /sbin /lib /usr /etc /var -xdev -type l -print 2>/dev/null |
		while IFS= read -r l; do
			[ -e "$l" ] || printf '%s\n' "$l"
		done | head -20
)"
if [ -n "$broken" ]; then
	fail "dangling or looping symlinks:"
	printf '%s\n' "$broken" | while read -r l; do
		note "$l -> $(readlink "$l")"
	done
else
	pass "no dangling or looping symlinks under /bin /sbin /lib /usr /etc /var"
fi

# ------------------------------------------------------------------------- #
section "apk database"
# ------------------------------------------------------------------------- #
# /etc/apk/world is what the build ASKED for. This proves it is also what is
# installed, which is not the same thing: an interrupted apk leaves world
# written and packages missing, and the image still boots - into a system with
# no compositor.
world="$(sed -e 's/[<>=~].*$//' -e '/^[[:space:]]*$/d' /etc/apk/world | tr '\n' ' ')"
# Unquoted on purpose: apk takes one package name per argument, and quoting
# hands it the whole list as a single name, which matches nothing and reports
# every package as absent.
# shellcheck disable=SC2086
installed="$(apk info -e $world 2>/dev/null)"
absent=""
for p in $world; do
	printf '%s\n' "$installed" | grep -qx "$p" || absent="$absent $p"
done
if [ -n "$absent" ]; then
	fail "in /etc/apk/world but not installed:$absent"
else
	pass "all $(printf '%s' "$world" | wc -w) packages in /etc/apk/world are installed"
fi

# ------------------------------------------------------------------------- #
if [ "$VARIANT" = headless ]; then
	section "headless specifics"
	# No tinydm, no session, no leftovers from a UI build.
	for leftover in /etc/conf.d/tinydm /var/lib/tinydm/default-session.desktop \
			/etc/runlevels/default/tinydm; do
		[ -e "$leftover" ] &&
			fail "headless image has $leftover, which only a UI variant should" ||
			pass "no $leftover"
	done
	# sshd is the only way in, so it has to be enabled and present.
	want_exec "sshd" /usr/sbin/sshd
	[ -e /etc/runlevels/default/sshd ] &&
		pass "sshd is in the default runlevel" ||
		fail "sshd is not enabled - the headless image would be unreachable"
	[ -f /etc/ssh/sshd_config ] &&
		pass "sshd_config present" ||
		fail "no /etc/ssh/sshd_config"
else
	section "the autologin session (tinydm)"
	# ------------------------------------------------------------------- #
	want_exec "tinydm-run-session" /usr/bin/tinydm-run-session
	want_exec "autologin" /usr/bin/autologin
	[ -e /etc/runlevels/default/tinydm ] &&
		pass "tinydm is in the default runlevel" ||
		fail "tinydm is not enabled - nothing would start a session"

	# tinydm's own start_pre() does this lookup and REFUSES to start when it
	# fails ("unable to find user with uid N"). The uid is 10000 on these
	# images, not the 1000 the package defaults to, so it is exactly the kind
	# of value that gets out of step with /etc/passwd.
	AUTO_UID="$(sed -n 's/^[[:space:]]*AUTOLOGIN_UID=["'"'"']*\([0-9]*\).*/\1/p' \
		/etc/conf.d/tinydm 2>/dev/null | tail -1)"
	if [ -z "$AUTO_UID" ]; then
		fail "/etc/conf.d/tinydm sets no AUTOLOGIN_UID"
	else
		AUTO_USER="$(awk -F: -v u="$AUTO_UID" '$3 == u { print $1 }' /etc/passwd)"
		if [ -z "$AUTO_USER" ]; then
			fail "AUTOLOGIN_UID=$AUTO_UID matches no account in /etc/passwd - tinydm start_pre would abort"
		elif [ "$AUTO_UID" != "$LOGIN_UID" ]; then
			fail "AUTOLOGIN_UID=$AUTO_UID but the login account is $LOGIN_USER (uid $LOGIN_UID)"
		else
			pass "AUTOLOGIN_UID=$AUTO_UID is $AUTO_USER, the image's login account"
		fi
	fi

	# rc_need names services OpenRC must be able to find in /etc/init.d. A
	# name with no init script makes tinydm fail to start with "needs service
	# X, which does not exist", and the screen stays a text console.
	needs="$(sed -n 's/^[[:space:]]*rc_need=["'"'"']*\([^"'"'"']*\).*/\1/p' \
		/etc/conf.d/tinydm 2>/dev/null | tail -1)"
	for n in $needs; do
		if [ -x "/etc/init.d/$n" ]; then
			if [ -e "/etc/runlevels/default/$n" ] || [ -e "/etc/runlevels/boot/$n" ]; then
				pass "rc_need $n exists and is enabled"
			else
				warn "rc_need $n exists but is in no runlevel (OpenRC will pull it in)"
			fi
		else
			fail "tinydm rc_need names '$n' but /etc/init.d/$n does not exist"
		fi
	done

	# The session symlink. "pointing at the wrong .desktop" is a bug this
	# project shipped, and the wrong one here is not hypothetical: the xfce4
	# image carries BOTH /usr/share/xsessions/xfce.desktop (X11) and
	# /usr/share/wayland-sessions/xfce-wayland.desktop, and the X11 one on
	# this device gives a black screen.
	TARGET_LINK=/var/lib/tinydm/default-session.desktop
	case "$VARIANT" in
		sway)  WANT_SESSION=/usr/share/wayland-sessions/sway.desktop ;;
		xfce4) WANT_SESSION=/usr/share/wayland-sessions/xfce-wayland.desktop ;;
	esac
	if [ ! -L "$TARGET_LINK" ]; then
		fail "$TARGET_LINK is not a symlink - tinydm-run-session exits with 'no session configured'"
	else
		resolved="$(readlink -f "$TARGET_LINK" 2>/dev/null)"
		if [ ! -f "$resolved" ]; then
			fail "$TARGET_LINK -> $(readlink "$TARGET_LINK") which does not exist"
		elif [ "$resolved" != "$WANT_SESSION" ]; then
			fail "$TARGET_LINK -> $resolved, expected $WANT_SESSION for the $VARIANT variant"
		else
			pass "session symlink -> $resolved"
		fi
		# tinydm-run-session decides wayland vs x11 from this prefix and exits
		# with "could not detect session type" for anything else.
		case "$resolved" in
			/usr/share/wayland-sessions/*|/usr/share/xsessions/*)
				pass "session file is in a directory tinydm recognises" ;;
			*) fail "session file $resolved is in neither wayland-sessions nor xsessions" ;;
		esac
		# Exec= is what actually gets run. Resolve the program, and the real
		# program behind a wrapper: sway.desktop is
		# "Exec=dbus-run-session /usr/bin/sway".
		exec_line="$(grep '^Exec=' "$resolved" | head -1 | cut -d= -f2-)"
		if [ -z "$exec_line" ]; then
			fail "$resolved has no Exec= line"
		else
			note "Exec=$exec_line"
			checked=0
			for word in $exec_line; do
				case "$word" in
					-*) continue ;;
				esac
				if command -v "$word" >/dev/null 2>&1; then
					pass "Exec program $word resolves to $(command -v "$word")"
				else
					fail "Exec names $word which is not on PATH in the image"
				fi
				checked=$((checked + 1))
				case "$word" in
					dbus-run-session|dbus-launch|env|setpriv|sh) continue ;;
				esac
				break
			done
			[ "$checked" -gt 0 ] || fail "could not parse a program out of Exec=$exec_line"
		fi
		try="$(grep '^TryExec=' "$resolved" | head -1 | cut -d= -f2-)"
		if [ -n "$try" ]; then
			[ -x "$try" ] && pass "TryExec=$try exists" ||
				fail "TryExec=$try does not exist, so a display manager would hide this session"
		fi
	fi

	# THE XDG_RUNTIME_DIR BUG, tested by doing what tinydm does.
	# tinydm-run-session sources /usr/share/tinydm/env-<type>.d/* and then
	# /etc/tinydm.d/env-<type>.d/* before exec'ing the session. There is no
	# elogind and no pam_rundir in these images, so that chain is the ONLY
	# thing that sets XDG_RUNTIME_DIR, and with it unset sway exits
	# immediately with "XDG_RUNTIME_DIR is not set in the environment" - a
	# black screen with every process alive. Sourcing it as the autologin user
	# also catches a snippet that hardcodes /run/user/1000 while the account
	# is uid 10000.
	if [ -n "${AUTO_USER:-}" ]; then
		got="$(su -s /bin/sh -c '
			for f in /usr/share/tinydm/env-wayland.d/* /etc/tinydm.d/env-wayland.d/*; do
				[ -e "$f" ] || continue
				. "$f"
			done
			printf "%s|%s" "${XDG_RUNTIME_DIR:-}" "${WLR_RENDERER:-}"
		' "$AUTO_USER" 2>/dev/null)"
		rundir="${got%%|*}"
		renderer="${got##*|}"
		if [ "$rundir" = "/run/user/$AUTO_UID" ]; then
			pass "tinydm env chain sets XDG_RUNTIME_DIR=$rundir for $AUTO_USER"
		elif [ -z "$rundir" ]; then
			fail "tinydm env chain leaves XDG_RUNTIME_DIR unset - the compositor would exit at once"
		else
			fail "tinydm env chain sets XDG_RUNTIME_DIR=$rundir, expected /run/user/$AUTO_UID"
		fi
		# VideoCore IV has no Vulkan, so the device package pins the renderer.
		# Losing that pin costs a Vulkan probe on every start and, on some
		# mesa versions, a failed one.
		[ "$renderer" = gles2 ] &&
			pass "tinydm env chain sets WLR_RENDERER=gles2" ||
			warn "tinydm env chain sets WLR_RENDERER='$renderer' (expected gles2 - VideoCore IV has no Vulkan)"
	fi

	# Nothing else creates /run/user/<uid> on these images.
	if [ -e /etc/runlevels/boot/xdg-runtime-dirs ] ||
			[ -e /etc/runlevels/default/xdg-runtime-dirs ]; then
		pass "xdg-runtime-dirs is enabled, so /run/user/$AUTO_UID exists at boot"
	else
		fail "xdg-runtime-dirs is in no runlevel - XDG_RUNTIME_DIR would point at a directory nobody created"
	fi

	# ------------------------------------------------------------------- #
	section "desktop assets"
	# ------------------------------------------------------------------- #
	# A compositor with no font renders a bar with no text in it.
	if find /usr/share/fonts -name '*.ttf' -o -name '*.otf' 2>/dev/null | grep -q .; then
		pass "fonts installed: $(ls /usr/share/fonts | tr '\n' ' ')"
	else
		fail "no fonts in /usr/share/fonts - nothing on screen would have text"
	fi
	# The icon theme the image's own settings ask for. This is the "xfce4
	# image with no icon theme" bug: xfce4-settings ships an xsettings.xml
	# whose IconThemeName is Adwaita, Alpine's xfce4 meta-package does not
	# depend on adwaita-icon-theme, and GTK then falls back to hicolor and
	# draws broken-image placeholders in the panel and in Thunar. A warn
	# rather than a FAIL because the session does still come up - promote it
	# the day adwaita-icon-theme is added to the image.
	xs=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml
	if [ -f "$xs" ]; then
		theme="$(sed -n 's/.*name="IconThemeName"[^>]*value="\([^"]*\)".*/\1/p' "$xs" | head -1)"
		if [ -z "$theme" ]; then
			note "no IconThemeName in $xs"
		elif [ -f "/usr/share/icons/$theme/index.theme" ]; then
			pass "icon theme $theme is installed"
		else
			warn "xsettings asks for icon theme '$theme' but /usr/share/icons/$theme is not installed"
			note "installed themes: $(ls /usr/share/icons 2>/dev/null | tr '\n' ' ')"
			note "GTK falls back to hicolor, so icons render as broken-image placeholders"
		fi
	fi
	other_theme=0
	for d in /usr/share/icons/*; do
		case "$d" in
			/usr/share/icons/hicolor|'/usr/share/icons/*') continue ;;
		esac
		[ -d "$d" ] && other_theme=1
	done
	[ "$other_theme" -eq 1 ] ||
		warn "hicolor is the only icon theme installed"
fi

# ------------------------------------------------------------------------- #
printf '\n== summary\n'
printf 'variant %s: %d passed, %d failed, %d warnings\n' \
	"$VARIANT" "$PASSES" "$FAILS" "$WARNS"
printf '%s\n' "$FAILS" > /out/failures
if [ "$FAILS" -ne 0 ]; then
	printf 'RESULT: FAIL\n'
	exit 1
fi
printf 'RESULT: PASS\n'

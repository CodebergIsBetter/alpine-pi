#!/usr/bin/env bash
# image-chroot.sh - sourced scaffolding for the two chroot tests (T2 and T3).
#
# Not executable: chroot-test.sh and headless-render-test.sh source it.
#
# WHY A CHROOT AND NOT A BOOT
# ---------------------------
# The images are ARMv6 armhf and every runner is x86_64, so they can only run
# under emulation, and there are two kinds of it that differ by three orders of
# magnitude:
#
#   full-system TCG   qemu-system-arm emulates a whole machine - CPU, SD
#                     controller, interrupt controller - and then boots a
#                     kernel. Minutes per test.
#   user-mode qemu    qemu-arm-static plus binfmt_misc translates userspace
#                     instructions only, inside a chroot. No kernel, no device
#                     emulation. Seconds per test.
#
# KVM cannot help (it needs the host CPU to BE an ARM) and neither can GitHub's
# arm64 runners (Graviton/Ampere dropped AArch32 and cannot execute 32-bit
# armhf at all). So everything that is really a userspace question - do the
# binaries run, does the compositor paint - goes through user-mode qemu here,
# and only the kernel and device tree test still boots a machine
# (scripts/qemu-raspi-boot.sh).
#
# THE FIVE MINUTE CEILING IS ENFORCED, NOT DOCUMENTED
# ---------------------------------------------------
# ic_bootstrap re-executes the caller under timeout(1). A test that needs more
# than five minutes is a failed test design, so the budget cannot be raised
# from the command line: a caller asking for more is rejected outright rather
# than quietly granted. An overrun is reported as a FAILURE, not as "expected
# slow".
#
# NOTHING IS EVER WRITTEN TO THE IMAGE
# ------------------------------------
# The rootfs partition is loop-mounted with --read-only (the kernel then
# refuses a write at the block layer, so a bug in this file cannot corrupt a
# reference image) and an overlayfs with a tmpfs upper layer carries every
# write the chroot makes. That is cheaper than the qcow2-overlay or full-copy
# alternatives - no 2.4 GB of I/O per test, which matters when the whole test
# has to fit in five minutes - and it gives the same guarantee.
#
# AND NOTHING IS LEFT BEHIND
# --------------------------
# A leaked loop device has already broken this project's work once, so there
# are three independent safety nets:
#
#   1. an EXIT/INT/TERM/HUP trap unmounts in reverse order and removes the
#      scratch directory;
#   2. the whole privileged part runs in its own mount namespace
#      (unshare --mount), so even SIGKILL - which no trap can catch - takes
#      every mount with it;
#   3. the loop device is detached immediately after it is mounted, which sets
#      the kernel's autoclear flag: the device frees itself when the last
#      reference to it goes away, whatever happens to this process.
#
# unshare also gets --fork --pid --kill-child so that a compositor left
# running inside the chroot cannot outlive the test.

# Populated by ic_mount, read by ic_teardown.
IC_WORK=""
IC_ROOT=""
IC_MOUNTS=()
# Set by ic_binfmt when the handler lacks the "F" flag; see ic_binfmt.
IC_QEMU_INTERP=""

ic_die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 3
}

# --------------------------------------------------------------------------- #
# Privilege, namespace and the time budget
# --------------------------------------------------------------------------- #

# ic_bootstrap <budget-seconds> "$@"
#
# Re-executes the calling script twice, and returns only in the innermost
# invocation:
#
#   1. under sudo, because loop-mounting and chroot need root. GitHub's hosted
#      runners give passwordless sudo, so "./scripts/..." keeps working in
#      build.yml without the workflow having to know this;
#   2. as root, under "timeout ... unshare", which puts the five minute ceiling
#      and the private mount+pid namespace on in one step.
#
# THE ORDER MATTERS AND IS NOT THE OBVIOUS ONE.
# Putting timeout OUTSIDE sudo looks tidier and does not work: timeout then
# runs as the invoking user and cannot signal a root process at all, so the
# budget expires, the banner prints, and the root-side chroot keeps running -
# measured, with a 5s budget and a 120s sleep, the sleep survived the budget
# and held the step's stdout open. With sudo first, timeout is root and its
# SIGKILL lands. unshare --kill-child then sets PR_SET_PDEATHSIG on the pid
# namespace's init, so killing it makes the kernel tear down every process,
# every mount and therefore the loop device too - the one path where no trap
# can run.
ic_bootstrap() {
	local budget="$1"; shift

	case "$budget" in
		''|*[!0-9]*) ic_die "budget must be a number of seconds" ;;
	esac
	# The point of the rule is that it cannot be raised to accommodate a slow
	# test. Refuse rather than clamp, so a caller that tries finds out.
	if [ "$budget" -gt 300 ]; then
		ic_die "budget ${budget}s exceeds the 5 minute ceiling; rework the test, do not raise this"
	fi

	if [ "$(id -u)" -ne 0 ]; then
		command -v sudo >/dev/null 2>&1 ||
			ic_die "must run as root (loop mount + chroot) and sudo is not installed"
		echo "[ic] re-executing under sudo (loop mount and chroot need root)"
		exec sudo -- "$0" "$@"
	fi

	if [ -z "${IC_TIMED:-}" ]; then
		export IC_TIMED=1
		local rc=0
		# --kill-after: bash runs a trap only when the current foreground
		# command returns, so a script blocked in a long child would ignore
		# the SIGTERM. SIGKILL 15s later is the backstop, and the namespace
		# makes it safe.
		timeout --kill-after=15s "$budget" \
			unshare --mount --propagation private --fork --pid --kill-child \
			-- "$0" "$@" || rc=$?
		if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
			echo
			echo "FAIL: $(basename "$0") blew its ${budget}s budget and was killed."
			echo "      Every test in this repo must finish inside five minutes."
			echo "      This is a test FAILURE, not a slow test - find what hung"
			echo "      (the log above stops at the last thing that worked)."
			exit 1
		fi
		exit "$rc"
	fi
}

ic_need_tools() {
	local tool missing=()
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done
	[ "${#missing[@]}" -eq 0 ] ||
		ic_die "missing host tools: ${missing[*]}. Install: qemu-user-static binfmt-support util-linux e2fsprogs coreutils python3"
}

# --------------------------------------------------------------------------- #
# binfmt_misc
# --------------------------------------------------------------------------- #

# Registers the qemu-arm handler if it is missing, or fails with the exact
# command to run. Without it every armhf binary in the chroot dies with
# "Exec format error" - which is what this host looked like before this
# function existed: qemu-arm-static was installed, every other architecture
# was registered, and qemu-arm alone was not.
ic_binfmt() {
	local dir=/proc/sys/fs/binfmt_misc
	local entry="$dir/qemu-arm"

	# binfmt_misc may not be mounted at all (minimal containers). Registering
	# is not namespace-local, so doing it from inside our own mount namespace
	# still reaches the kernel's one global table.
	if [ ! -d "$dir" ] || [ ! -e "$dir/register" ]; then
		mount -t binfmt_misc binfmt_misc "$dir" 2>/dev/null || true
	fi

	if ! { [ -e "$entry" ] && grep -qx enabled "$entry"; }; then
		echo "[ic] binfmt_misc has no enabled qemu-arm handler; registering it"
		# Debian/Ubuntu path first: qemu-user-static ships the definition in
		# /var/lib/binfmts and update-binfmts only has to import it.
		if command -v update-binfmts >/dev/null 2>&1 &&
				[ -f /var/lib/binfmts/qemu-arm ]; then
			update-binfmts --import qemu-arm >/dev/null 2>&1 || true

			# --import above is a no-op when update-binfmts still believes the
			# handler is imported, and that is the normal case here rather
			# than an edge case: "pmbootstrap shutdown" - which runs at the end
			# of every build - unregisters the handler by writing -1 straight
			# to the kernel entry, which never touches update-binfmts' own
			# state in /var/lib/binfmts. The kernel then has no handler while
			# update-binfmts insists there is one, so the image's armhf
			# binaries stop being executable between the build and the tests.
			# Forget it first, then import, so the state and the kernel agree.
			if ! { [ -e "$entry" ] && grep -qx enabled "$entry"; }; then
				update-binfmts --unimport qemu-arm >/dev/null 2>&1 || true
				update-binfmts --import qemu-arm >/dev/null 2>&1 || true
			fi
		fi
		# Container fallback, the pattern taken from the donor project's
		# scripts/chroot-test.sh. "--reset -p yes" clears stale entries (a
		# Docker Desktop install leaves partial ones on WSL2) and re-registers
		# every architecture with the P and F flags.
		if ! { [ -e "$entry" ] && grep -qx enabled "$entry"; }; then
			local runtime
			for runtime in podman docker; do
				command -v "$runtime" >/dev/null 2>&1 || continue
				"$runtime" run --rm --privileged \
					docker.io/multiarch/qemu-user-static --reset -p yes \
					>/dev/null 2>&1 || true
				break
			done
		fi
	fi

	if ! { [ -e "$entry" ] && grep -qx enabled "$entry"; }; then
		cat >&2 <<-'MSG'
			ERROR: binfmt_misc has no enabled qemu-arm handler, so the image's
			       armhf binaries cannot be executed in a chroot and this test
			       cannot run at all. Register it with ONE of:

			         sudo update-binfmts --import qemu-arm
			         sudo apt-get install -y qemu-user-static binfmt-support
			         docker run --privileged --rm tonistiigi/binfmt --install arm
			         podman run --privileged --rm \
			             docker.io/multiarch/qemu-user-static --reset -p yes

			       The first works when qemu-user-static is already installed
			       but its handler was never imported, which is the usual case.
		MSG
		exit 3
	fi

	local flags interp
	flags="$(awk '/^flags:/ { print $2 }' "$entry")"
	interp="$(awk '/^interpreter/ { print $2 }' "$entry")"
	echo "[ic] binfmt qemu-arm: enabled, interpreter $interp, flags ${flags:-none}"

	# The "F" (fix binary) flag makes the kernel open the emulator at
	# REGISTRATION time and reuse that open file for every exec, so it works
	# inside a chroot that has no copy of qemu-arm-static. Without F the
	# kernel resolves the interpreter path INSIDE the chroot, so the emulator
	# has to be copied in - remembered here because the alternative symptom is
	# a bare "No such file or directory" from a binary that plainly exists.
	case "$flags" in
		*F*) IC_QEMU_INTERP="" ;;
		*)   IC_QEMU_INTERP="$interp" ;;
	esac
}

# --------------------------------------------------------------------------- #
# Mounting the image
# --------------------------------------------------------------------------- #

# Echoes "<start-sector> <size-sectors>" for the MBR type 83 (Linux) partition.
# Read from the table rather than hardcoded: partition 1 is the FAT boot
# partition and its size follows ALPINEPI_EXTRA_SPACE and the kernel, so the
# rootfs does not start at a fixed offset.
ic_rootfs_extent() {
	local img="$1" line
	line="$(sfdisk -d "$img" 2>/dev/null | grep -i 'type=83' | head -1)" ||
		true
	[ -n "$line" ] || ic_die "$img has no MBR type 83 partition - is it an alpine-pi image?"
	printf '%s %s\n' \
		"$(printf '%s' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9]*\).*/\1/p')" \
		"$(printf '%s' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9]*\).*/\1/p')"
}

# Echoes "<start-sector> <size-sectors>" for the FAT boot partition, or
# nothing if there is not exactly one. MBR FAT type codes: c = FAT32 LBA,
# b = FAT32, e = FAT16 LBA, 6 = FAT16.
ic_boot_extent() {
	local img="$1" line
	line="$(sfdisk -d "$img" 2>/dev/null | grep -iE 'type=(c|b|e|6)$|type=(c|b|e|6)[,[:space:]]' | head -1)" || true
	[ -n "$line" ] || return 1
	printf '%s %s\n' \
		"$(printf '%s' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9]*\).*/\1/p')" \
		"$(printf '%s' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9]*\).*/\1/p')"
}

ic_mount_track() {
	IC_MOUNTS+=("$1")
}

# ic_mount <img>
# Sets IC_ROOT to a writable view of the image's rootfs, and IC_WORK to the
# scratch directory holding it.
ic_mount() {
	local img="$1" start size loop
	read -r start size < <(ic_rootfs_extent "$img")
	case "$start$size" in ''|*[!0-9]*) ic_die "cannot read the partition table of $img" ;; esac

	# A run killed with SIGKILL - by the budget, or by CI cancelling the job -
	# cannot run its trap, and leaves its (empty, unmounted) scratch directory
	# behind. rmdir only removes empty directories, so this cannot disturb a
	# concurrent run, whose directories are either mounted or populated.
	rmdir /tmp/alpinepi-chroot.*/lower /tmp/alpinepi-chroot.*/tmp \
		/tmp/alpinepi-chroot.*/root /tmp/alpinepi-chroot.* 2>/dev/null || true

	IC_WORK="$(mktemp -d -t alpinepi-chroot.XXXXXX)"
	mkdir -p "$IC_WORK/lower" "$IC_WORK/tmp" "$IC_WORK/root"

	# --read-only is the load-bearing flag: the reference images are read-only
	# inputs and the kernel now enforces that, not this script's good
	# intentions. --sizelimit stops the loop device at the partition end so a
	# stray write cannot reach the next partition either.
	loop="$(losetup --read-only --show --offset "$((start * 512))" \
		--sizelimit "$((size * 512))" --find "$img")" ||
		ic_die "losetup failed on $img"
	echo "[ic] $loop = $(basename "$img") partition at sector $start ($size sectors)"

	# ext4 needs journal recovery if the image was captured from a running
	# system, and recovery is impossible on a read-only device. noload skips
	# the journal, which is safe because nothing here writes to the ext4.
	mount -t ext4 -o ro,noatime "$loop" "$IC_WORK/lower" 2>/dev/null ||
		mount -t ext4 -o ro,noatime,noload "$loop" "$IC_WORK/lower" ||
		ic_die "cannot mount the ext4 rootfs of $img"
	ic_mount_track "$IC_WORK/lower"

	# Detaching now sets the autoclear flag: the kernel frees the device when
	# the mount above goes away, even if this process is SIGKILLed before its
	# trap can run. This is the third safety net from the header comment.
	losetup --detach "$loop" 2>/dev/null || true

	# The upper layer is a tmpfs, not a directory on the host filesystem: the
	# chroot writes a wayland socket, a session log and a few dotfiles, all of
	# which are throwaway, and a tmpfs cannot leave a root-owned mess behind
	# in the workspace if the trap is skipped. 512 MB is far more than the
	# measured worst case (a few MB) and is capped so a runaway log cannot
	# exhaust a runner's RAM.
	mount -t tmpfs -o size=512m,mode=0755 tmpfs "$IC_WORK/tmp"
	ic_mount_track "$IC_WORK/tmp"
	mkdir -p "$IC_WORK/tmp/upper" "$IC_WORK/tmp/work" "$IC_WORK/tmp/out"
	chmod 0777 "$IC_WORK/tmp/out"

	mount -t overlay overlay \
		-o "lowerdir=$IC_WORK/lower,upperdir=$IC_WORK/tmp/upper,workdir=$IC_WORK/tmp/work" \
		"$IC_WORK/root" || ic_die "overlayfs mount failed"
	ic_mount_track "$IC_WORK/root"
	IC_ROOT="$IC_WORK/root"

	ic_mount_boot "$img"

	ic_mount_api
	ic_mount_track "$IC_ROOT/out"

	if [ -n "$IC_QEMU_INTERP" ]; then
		echo "[ic] copying $IC_QEMU_INTERP into the overlay (handler has no F flag)"
		mkdir -p "$IC_ROOT/$(dirname "$IC_QEMU_INTERP")"
		cp -f "$IC_QEMU_INTERP" "$IC_ROOT/$IC_QEMU_INTERP"
	fi
}

# Mount the FAT boot partition at /boot, read-only, so the chroot matches the
# running device.
#
# Without this, /boot is an empty directory and anything pointing into it looks
# broken. That is not hypothetical: the kernel package ships
# /usr/lib/modules/<ver>/vmlinuz -> /boot/vmlinuz-rpi, so the symlink integrity
# assertion reported a dangling link on all three images - a false positive
# that would have failed every build. The links are fine on hardware, where
# fstab mounts this partition there.
#
# Read-only for the same reason the rootfs is: these are reference inputs. A
# missing or unmountable boot partition is a warning rather than fatal, because
# every assertion that needs it says so itself.
ic_mount_boot() {
	local img="$1" start size loop
	if ! read -r start size < <(ic_boot_extent "$img"); then
		echo "[ic] no FAT boot partition found; /boot will be empty"
		return 0
	fi
	case "$start$size" in ''|*[!0-9]*) echo "[ic] unreadable boot extent; /boot will be empty"; return 0 ;; esac
	mkdir -p "$IC_ROOT/boot"
	loop="$(losetup --read-only --show --offset "$((start * 512))" \
		--sizelimit "$((size * 512))" --find "$img")" || {
		echo "[ic] losetup failed for the boot partition; /boot will be empty"
		return 0
	}
	if mount -t vfat -o ro,umask=0077 "$loop" "$IC_ROOT/boot" 2>/dev/null; then
		ic_mount_track "$IC_ROOT/boot"
		echo "[ic] /boot = FAT partition at sector $start"
	else
		echo "[ic] cannot mount the FAT boot partition; /boot will be empty"
	fi
	losetup --detach "$loop" 2>/dev/null || true
}

# /proc, /dev and friends. Built up from scratch rather than bind-mounted from
# the host, for two reasons: a recursive bind of the host's /sys drags in
# cgroup mounts that then refuse to unmount ("target is busy") and pin the loop
# device, and a fresh tmpfs /dev keeps the host's real devices out of reach of
# anything the chroot runs.
ic_mount_api() {
	mount -t proc -o nosuid,nodev,noexec proc "$IC_ROOT/proc"
	ic_mount_track "$IC_ROOT/proc"

	mount -t tmpfs -o mode=0755,nosuid tmpfs "$IC_ROOT/dev"
	ic_mount_track "$IC_ROOT/dev"
	mknod -m 0666 "$IC_ROOT/dev/null" c 1 3
	mknod -m 0666 "$IC_ROOT/dev/zero" c 1 5
	mknod -m 0666 "$IC_ROOT/dev/full" c 1 7
	mknod -m 0666 "$IC_ROOT/dev/random" c 1 8
	mknod -m 0666 "$IC_ROOT/dev/urandom" c 1 9
	mknod -m 0666 "$IC_ROOT/dev/tty" c 5 0
	ln -sf /proc/self/fd "$IC_ROOT/dev/fd"
	ln -sf /proc/self/fd/0 "$IC_ROOT/dev/stdin"
	ln -sf /proc/self/fd/1 "$IC_ROOT/dev/stdout"
	ln -sf /proc/self/fd/2 "$IC_ROOT/dev/stderr"

	mkdir -p "$IC_ROOT/dev/pts" "$IC_ROOT/dev/shm"
	mount -t devpts -o gid=5,mode=0620,ptmxmode=0666 devpts "$IC_ROOT/dev/pts"
	ic_mount_track "$IC_ROOT/dev/pts"
	# Wayland clients that predate memfd_create, and mesa's software renderer,
	# both fall back to POSIX shared memory. Without /dev/shm a compositor
	# starts and then cannot allocate a buffer, which looks like a black
	# screen rather than an error.
	mount -t tmpfs -o size=128m,mode=1777,nosuid,nodev tmpfs "$IC_ROOT/dev/shm"
	ic_mount_track "$IC_ROOT/dev/shm"

	# /out is how a payload hands logs and screenshots back. It is a separate
	# tmpfs so that "rm -rf $IC_WORK" cannot be the thing that deletes the
	# evidence before it is copied out.
	mkdir -p "$IC_ROOT/out"
	mount --bind "$IC_WORK/tmp/out" "$IC_ROOT/out"
}

# Kills everything the chroot started. We are PID 1 of a private pid namespace
# (unshare --fork --pid), so "kill -1" reaches every process in it and nothing
# outside it: a compositor left running would otherwise hold the overlay open,
# turn every umount into a lazy one, and leave the scratch directory behind.
ic_kill_all() {
	[ "$$" -eq 1 ] || return 0
	kill -TERM -1 2>/dev/null || true
	sleep 1
	kill -KILL -1 2>/dev/null || true
}

ic_teardown() {
	local rc=$? m i
	ic_kill_all
	# Reverse order: /dev/shm before /dev, /proc before the overlay.
	for (( i=${#IC_MOUNTS[@]}-1 ; i>=0 ; i-- )); do
		m="${IC_MOUNTS[i]}"
		mountpoint -q "$m" 2>/dev/null || continue
		umount "$m" 2>/dev/null && continue
		# A process the chroot forked may still hold a file open. Lazy
		# unmount detaches it now and the kernel finishes when the last
		# reference goes, which also releases the loop device.
		umount -l "$m" 2>/dev/null || echo "[ic] WARNING: could not unmount $m" >&2
	done
	[ -n "$IC_WORK" ] && rm -rf "$IC_WORK" 2>/dev/null
	return "$rc"
}

# --------------------------------------------------------------------------- #
# Running things inside
# --------------------------------------------------------------------------- #

# ic_chroot [--user <uid>:<gid>] -- <command> [args...]
#
# "env -i" is not cosmetic. This host has WSLg, so DISPLAY and WAYLAND_DISPLAY
# are set in the developer's shell and are NOT set on a CI runner; leaking them
# in makes the chroot behave differently in the two places. Measured: with
# DISPLAY=:0 inherited, startxfce4 decides an X server is already running and
# takes a completely different code path.
ic_chroot() {
	local user="" args=()
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--user) user="$2"; shift 2 ;;
			--) shift; break ;;
			*) break ;;
		esac
	done
	args=("$@")

	# Absolute path: "env -i" clears PATH, so an unqualified "chroot" is not
	# found and the error ("env: 'chroot': No such file or directory") points
	# at the wrong thing entirely.
	local chroot_bin
	chroot_bin="$(command -v chroot)"

	local pre=()
	if [ -n "$user" ]; then
		# Numeric only: GNU chroot resolves a NAME against the host's passwd
		# database, not the image's, so "--userspec=user" would pick up
		# whatever uid a runner happens to have for that name.
		# --groups drops root's supplementary groups, which chroot otherwise
		# keeps and which would hide a permissions bug in the image.
		pre=("$chroot_bin" "--userspec=$user" "--groups=${user#*:}" "$IC_ROOT")
	else
		pre=("$chroot_bin" "$IC_ROOT")
	fi

	env -i "${pre[@]}" /usr/bin/env \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		TERM=dumb LANG=C.UTF-8 \
		"${args[@]}"
}

# Copies a payload script into the overlay and echoes its path inside the
# chroot. The payloads live in scripts/lib/ as real files rather than heredocs
# so that shellcheck and "bash -n" in lint.yml actually see them.
ic_install_payload() {
	local src="$1" name
	name="$(basename "$src")"
	[ -f "$src" ] || ic_die "payload $src is missing"
	install -m 0755 "$src" "$IC_ROOT/$name"
	printf '/%s\n' "$name"
}

# Copies everything a payload left in /out to a host directory, owned by the
# user who invoked us rather than by root - CI does not care, but a developer
# who cannot delete their own out/ directory does.
ic_collect() {
	local dest="$1"
	mkdir -p "$dest"
	cp -a "$IC_WORK/tmp/out/." "$dest/" 2>/dev/null || true
	if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
		chown -R "$SUDO_UID:$SUDO_GID" "$dest" 2>/dev/null || true
	fi
}

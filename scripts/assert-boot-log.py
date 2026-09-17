#!/usr/bin/env python3
"""Judge a QEMU serial log from an alpine-pi boot.

Usage: assert-boot-log.py raspi <logfile>
  tier = raspi   boot chain only: kernel + device tree + early userspace

Exits 0 on pass, 1 on fail, and prints which signals matched so a CI log is
readable without opening the raw serial dump.

"raspi" is the only tier, and the argument is kept rather than dropped because
the FATAL list has to stay keyed by it: what counts as a fatal line depends
entirely on how far the boot was ever expected to get, and a future tier that
gets further must not silently inherit this one's tolerances (see FATAL).

THE TIER THAT USED TO BE HERE, AND WHAT WENT WITH IT
----------------------------------------------------
There was a second tier, "virt": the same rootfs booted on qemu-system-arm's
generic virt machine, which has no bcm2835-dma bug, so OpenRC really ran and
the log could be read for service ordering, fsck, hostname, wpa_supplicant and
the compositor starting or dying. It was deleted along with scripts/
qemu-virt-boot.sh, because a full-system TCG boot of an armhf userspace takes
minutes and every test in this repo has to finish inside five.

Be clear about the cost: NOTHING in CI now proves that OpenRC boots, or that
it orders services correctly. What replaced it is static and runs in seconds
(scripts/chroot-test.sh, in a user-mode qemu chroot): every init script parses,
every runlevel symlink resolves to an executable script, every enabled
service's command exists. Those are the three ways service startup has
actually broken on this project. Real ORDERING - and anything that needs a
running kernel - is verified on hardware only.

That is also why the WARN list below still carries OpenRC and session
vocabulary it can no longer see from a raspi boot: the board is now the only
place a full boot happens, and "assert-boot-log.py raspi board-serial.log" on
a log captured from the real Pi over its UART is the intended way to read one.
"""
import re
import sys

# (regex, human description). Matched case-insensitively against the whole log.
REQUIRED = {
    "raspi": [
        (r"Booting Linux on physical CPU", "kernel entered"),
        (r"Machine model:\s*\S", "device tree loaded"),
        (r"Run /init as init process|Freeing unused kernel", "early userspace reached"),
    ],
}

# Anything here fails the run outright, whatever else matched.
#
# Keyed by tier, and deliberately SHORT, because on raspi1ap the boot is only
# ever expected to reach early userspace. Failing to mount the rootfs and
# dropping to the initramfs emergency shell is the EXPECTED ending here: QEMU's
# bcm2835-dma emulation emits bus addresses past 0x5fffffff, so every SD read
# fails. Adding "Launching initramfs emergency recovery shell" or "on /sysroot
# failed" to this list - which looks like an obvious omission - would fail
# every single run, on every variant, for a defect in the emulator rather than
# in the image. The keying is what keeps that decision attached to the tier it
# is true for instead of to the judge as a whole.
FATAL = {
    "raspi": [
        (r"Kernel panic", "kernel panic"),
        (r"\bOops\b|Internal error: Oops", "kernel oops"),
    ],
}

# Not fatal, but printed so a CI summary shows them without opening the log.
#
# Most of these cannot appear in a raspi1ap run at all - there is no OpenRC and
# no session in it. They are kept because this judge is now also the tool for
# reading a serial log captured from the REAL BOARD, which since the virt tier
# was deleted is the only place a full boot happens; see the module docstring.
WARN = [
    (r"XDG_RUNTIME_DIR is not set", "XDG_RUNTIME_DIR missing - session will not start"),
    (r"Symbolic link loop|ELOOP", "symlink loop (the udevadm bin-merge class of bug)"),
    (r"GL_OUT_OF_MEMORY|Failed to allocate.*FBO", "GPU or CMA allocation failure"),
    (r"failed to (open|create).*(seat|libseat)", "seatd unreachable"),
    (r"No such file or directory.*(sway|labwc|xfdesktop)", "compositor binary missing"),
    # How a half-installed UI actually presents: OpenRC starts the service and
    # start-stop-daemon cannot find the binary it is supposed to supervise.
    # Kept a WARN rather than a FATAL (which is also how the donor harness
    # treats it) because the same message appears for optional services.
    (
        r"start-stop-daemon: .*(not found|does not exist|No such file)",
        "a service's binary is missing",
    ),
    (r"WATCHDOG_DEV is not set", "watchdog cannot start (known gap)"),
    (r"ERROR: \w+ failed to start", "an OpenRC service failed to start"),
    (r"generating new host keys", "sshd generated host keys on this boot (slow on ARM1176)"),
    (r"Some local filesystem failed to mount", "a filesystem in fstab did not mount"),
]


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in REQUIRED:
        print(__doc__)
        return 2
    tier, path = sys.argv[1], sys.argv[2]
    try:
        with open(path, errors="replace") as handle:
            log = handle.read()
    except OSError as e:
        print(f"FAIL: cannot read {path}: {e}")
        return 1

    if not log.strip():
        print(f"FAIL: {path} is empty - QEMU produced no serial output at all")
        return 1

    ok = True
    print(f"== {tier} tier: {path} ({len(log)} bytes) ==")

    for pattern, desc in REQUIRED[tier]:
        if re.search(pattern, log, re.IGNORECASE):
            print(f"  pass  {desc}")
        else:
            print(f"  FAIL  {desc} (no match for /{pattern}/)")
            ok = False

    for pattern, desc in FATAL[tier]:
        if re.search(pattern, log, re.IGNORECASE):
            print(f"  FATAL {desc}")
            ok = False

    for pattern, desc in WARN:
        if re.search(pattern, log, re.IGNORECASE):
            print(f"  warn  {desc}")

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

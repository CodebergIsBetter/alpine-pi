#!/usr/bin/env python3
"""Tests for scripts/assert-boot-log.py, the judge for T1 (the kernel boot).

Run it directly - "python3 tests/test_assert_boot_log.py" - or under pytest.
Either way there are no third-party imports, because the lint workflow must be
able to run this one without fetching a wheel first.

WHY THIS FILE EXISTS
--------------------
Almost everything else in this repo fails CLOSED: a broken REQUIRED pattern
fails a good image, which is loud and obvious. The FATAL list fails OPEN. If
the "Kernel panic" pattern ever stops matching, an image whose kernel died is
reported PASS, the publish job's success() is satisfied, and a broken image is
released - the worst thing this repository can do.

The other direction is pinned just as hard, and is now the easier mistake to
make. T1 runs on QEMU's raspi1ap, where the boot CANNOT reach OpenRC: QEMU's
bcm2835-dma emulation emits bus addresses past 0x5fffffff, so every SD read
fails and the run ends in the initramfs emergency shell. Those lines look like
a catastrophe and are the expected ending. When the "virt" tier still existed
they were fatal THERE and tolerated HERE, and the disagreement made the reason
visible; with virt deleted the only thing keeping someone from "fixing" this
judge by adding "Launching initramfs emergency recovery shell" to FATAL - and
thereby failing every run on every variant forever - is
test_raspi_tolerates_the_initramfs_emergency_shell below.

The fixtures are literal serial-log lines rather than the regexes themselves,
so a typo in a pattern is caught instead of being copied into the test.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

JUDGE = Path(__file__).resolve().parent.parent / "scripts" / "assert-boot-log.py"

# Imported as well as executed: the exit codes are what CI sees, but reading
# FATAL back out of the module is what makes "every fatal pattern is tested"
# checkable at all.
_spec = importlib.util.spec_from_file_location("assert_boot_log", JUDGE)
assert _spec and _spec.loader
judge_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(judge_mod)

# A log that satisfies every REQUIRED pattern of the raspi tier and nothing
# else. This is what a healthy T1 run looks like up to the point where the SD
# controller gives up.
GOOD_RASPI = """\
Booting Linux on physical CPU 0x0
Machine model: Raspberry Pi Zero W Rev 1.1
Freeing unused kernel image (initmem) memory: 1024K
Run /init as init process
"""

# What T1 ALWAYS ends with. Expected, not a failure: see the module docstring.
INITRAMFS_SHELL = """\
mmc0: unrecognised SCR structure version 7
bcm2835-dma 20007000.dma: DMA transfer of 512 bytes past 0x5fffffff
mount: mounting /dev/mmcblk0p2 on /sysroot failed: No such device
Launching initramfs emergency recovery shell...
/ #
"""

# One literal line per entry in FATAL["raspi"]. Each must fail the tier even
# though every REQUIRED pattern matched earlier in the log.
RASPI_FATAL_LINES = [
    "Kernel panic - not syncing: VFS: Unable to mount root fs",
    "Internal error: Oops: 5 [#1] SMP ARM",
]

# Lines that are worth reporting but must never fail a run on their own. They
# come from a FULL boot, which only the real board does now - the judge is also
# used by hand on a serial log captured from the Pi's UART, so the patterns
# stay and so does their "warns, never fails" contract.
WARN_ONLY_LINES = [
    "start-stop-daemon: /usr/bin/sway: not found",
    " * ERROR: wpa_supplicant failed to start",
    "WATCHDOG_DEV is not set",
    "sway: XDG_RUNTIME_DIR is not set in the environment",
]


def run_judge(tier: str, text: str | None) -> tuple[int, str]:
    """Judge a log with this content. text=None means "the file is not there"."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "serial.log"
        if text is not None:
            path.write_text(text)
        done = subprocess.run(
            [sys.executable, str(JUDGE), tier, str(path)],
            capture_output=True,
            text=True,
        )
    return done.returncode, done.stdout


def test_good_raspi_log_passes() -> None:
    rc, out = run_judge("raspi", GOOD_RASPI)
    assert rc == 0, out
    assert "RESULT: PASS" in out


def test_raspi_tolerates_the_initramfs_emergency_shell() -> None:
    """The load-bearing test: this ending is QEMU's fault, not the image's.

    Every real T1 run contains these lines. If this test fails, the judge has
    been "fixed" into failing every build on every variant.
    """
    rc, out = run_judge("raspi", GOOD_RASPI + INITRAMFS_SHELL)
    assert rc == 0, out
    assert "RESULT: PASS" in out


def test_every_raspi_fatal_line_fails_even_with_all_required_present() -> None:
    for line in RASPI_FATAL_LINES:
        rc, out = run_judge("raspi", GOOD_RASPI + line + "\n")
        assert rc == 1, f"{line!r} was not treated as fatal\n{out}"


def test_every_raspi_fatal_pattern_has_a_fixture() -> None:
    """A new FATAL entry with no fixture line above fails here, not in a release."""
    for pattern, desc in judge_mod.FATAL["raspi"]:
        assert any(
            re.search(pattern, line, re.IGNORECASE) for line in RASPI_FATAL_LINES
        ), f"no fixture line matches /{pattern}/ ({desc})"


def test_missing_required_signal_fails() -> None:
    """Drop the device tree line: the kernel ran but never got its DTB."""
    without_dt = "\n".join(
        line for line in GOOD_RASPI.splitlines() if "Machine model" not in line
    )
    rc, out = run_judge("raspi", without_dt + "\n")
    assert rc == 1, out
    assert "device tree loaded" in out


def test_warnings_do_not_fail_a_run() -> None:
    for line in WARN_ONLY_LINES:
        rc, out = run_judge("raspi", GOOD_RASPI + line + "\n")
        assert rc == 0, f"{line!r} should warn, not fail\n{out}"
        assert "warn" in out, f"{line!r} was not reported at all\n{out}"


def test_empty_log_fails() -> None:
    """A QEMU that produced no serial output at all must not pass by default."""
    rc, out = run_judge("raspi", "")
    assert rc == 1, out


def test_missing_log_fails() -> None:
    """The runner wraps the QEMU step in "|| true", so this is reachable."""
    rc, out = run_judge("raspi", None)
    assert rc == 1, out
    assert "cannot read" in out


def test_the_deleted_virt_tier_is_a_usage_error_not_a_pass() -> None:
    """A leftover "assert-boot-log.py virt ..." must be loud.

    The virt tier and the full-system boot behind it were deleted (a TCG boot
    of armhf userspace cannot finish inside the five minute ceiling). If an
    unconverted caller survives somewhere, it has to exit non-zero rather than
    quietly report a pass on a log nothing wrote.
    """
    rc, _ = run_judge("virt", GOOD_RASPI)
    assert rc == 2
    assert "virt" not in judge_mod.REQUIRED
    assert "virt" not in judge_mod.FATAL


def test_unknown_tier_is_a_usage_error() -> None:
    rc, _ = run_judge("framebuffer", GOOD_RASPI)
    assert rc == 2


def main() -> int:
    failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        try:
            fn()
            print(f"  pass  {name}")
        except AssertionError as e:
            print(f"  FAIL  {name}: {e}")
            failed += 1
    print("RESULT:", "PASS" if not failed else f"FAIL ({failed})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

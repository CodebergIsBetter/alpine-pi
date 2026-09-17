"""Tests for scripts/analyse-framebuffer.py, the judge that gates publishing.

Vendored from the author's alpine-armv6 project (tests/
test_framebuffer_analysis.py there, GPL-3, same licence as this repo) with
only the path to the analyser changed - the classifier itself is that
project's code, kept functionally identical here so a fix can move either way
as a plain diff. See the PROVENANCE section of scripts/analyse-framebuffer.py.

Here the classifier judges T3: scripts/headless-render-test.sh runs the
image's own session in an armhf chroot against wlroots' headless backend,
screenshots it with grim, and this is what turns those pixels into the verdict
that decides whether the image is published. Until this file was vendored,
nothing in this repo tested it.

Why these exist
---------------
The framebuffer classifier is the only thing standing between "the UI
renders" and "the UI is broken", and it got the call WRONG in a way that
wasted real debugging time: a working sway session -- status bar,
workspace indicator, clock and mouse cursor all visibly rendering --
was reported as ``console`` because a tiling compositor with an empty
workspace is ~97% background, numerically identical to a text console
under an "ink fraction" heuristic.

So the interesting cases here are the two that look alike by area but
must classify differently:

  * empty tiling desktop  -> graphical (has a bar, has colour)
  * text console w/ prompt -> console  (no bar, greyscale)

Frames are synthesised rather than checked in as binaries: a few
hundred bytes of code is easier to review than a PPM, and it makes the
distinguishing feature explicit.
"""

from __future__ import annotations

import importlib.util
import struct
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "analyse-framebuffer.py"


def _load():
    # The filename has a hyphen in it, so it cannot be imported by name; the
    # module name here is arbitrary and only has to be a valid identifier.
    spec = importlib.util.spec_from_file_location("analyse_framebuffer", _SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["analyse_framebuffer"] = mod
    spec.loader.exec_module(mod)
    return mod


afb = _load()

W, H = 320, 200
BLACK = (0, 0, 0)
WHITE = (200, 200, 200)
BAR_BG = (0x32, 0x32, 0x32)      # sway bar background
BAR_BLUE = (0x28, 0x55, 0x77)    # sway focused-workspace indicator


def _write_ppm(path: Path, pixels: list[list[tuple[int, int, int]]]) -> Path:
    h = len(pixels)
    w = len(pixels[0])
    body = bytearray()
    for row in pixels:
        for r, g, b in row:
            body += struct.pack("BBB", r, g, b)
    path.write_bytes(b"P6\n%d %d\n255\n" % (w, h) + bytes(body))
    return path


def _blank() -> list[list[tuple[int, int, int]]]:
    return [[BLACK for _ in range(W)] for _ in range(H)]


def _console() -> list[list[tuple[int, int, int]]]:
    """Greyscale glyphs on black, sparse, top-left. No bar, no colour."""
    px = _blank()
    for line in range(6):
        y0 = 4 + line * 12
        for dy in range(7):
            for cx in range(40):           # ~40 chars of text
                x0 = 4 + cx * 7
                for dx in range(4):        # a few lit pixels per glyph
                    px[y0 + dy][x0 + dx] = WHITE if (dx + dy) % 3 else BLACK
    return px


def _empty_tiling_desktop() -> list[list[tuple[int, int, int]]]:
    """The case that used to be misread: a bar, then all background."""
    px = _blank()
    for y in range(0, 22):                      # bar band
        for x in range(W):
            px[y][x] = BAR_BG
    for y in range(3, 19):                      # blue workspace chip
        for x in range(4, 24):
            px[y][x] = BAR_BLUE
    for y in range(4, 18):                      # clock glyphs, right side
        for x in range(W - 90, W - 10, 2):
            px[y][x] = WHITE
    return px


@pytest.fixture
def tmp_ppm(tmp_path: Path):
    def make(name: str, pixels) -> Path:
        return _write_ppm(tmp_path / f"{name}.ppm", pixels)

    return make


def test_blank_frame_is_blank(tmp_ppm) -> None:
    info = afb.analyse(tmp_ppm("blank", _blank()))
    assert info["verdict"] == "blank"


def test_text_console_is_console(tmp_ppm) -> None:
    """Greyscale sparse text must NOT be mistaken for a desktop."""
    info = afb.analyse(tmp_ppm("console", _console()))
    assert info["verdict"] == "console", info


def test_empty_tiling_desktop_is_graphical(tmp_ppm) -> None:
    """THE regression: a bar + empty workspace is a working desktop.

    Guards the exact misclassification that reported a live sway session
    as a text console.
    """
    info = afb.analyse(tmp_ppm("desktop", _empty_tiling_desktop()))
    assert info["verdict"] == "graphical", info
    assert info["bar"] != "none", "status bar was not detected"


def test_desktop_and_console_have_similar_ink(tmp_ppm) -> None:
    """Prove the two cases are NOT separable by ink fraction alone.

    If this ever fails it means the fixtures drifted apart and the
    graphical/console test above has become easy for the wrong reason.
    """
    desktop = afb.analyse(tmp_ppm("d2", _empty_tiling_desktop()))
    console = afb.analyse(tmp_ppm("c2", _console()))
    assert desktop["verdict"] != console["verdict"]
    # Both are overwhelmingly background.
    assert desktop["dominant_frac"] > 0.8
    assert console["dominant_frac"] > 0.8


def test_console_is_greyscale_desktop_is_not(tmp_ppm) -> None:
    """The discriminator itself: colour presence."""
    desktop = afb.analyse(tmp_ppm("d3", _empty_tiling_desktop()))
    console = afb.analyse(tmp_ppm("c3", _console()))
    assert console["chromatic_frac"] == 0.0
    assert desktop["chromatic_frac"] > 0.0


def test_console_has_no_bar(tmp_ppm) -> None:
    """Sparse text rows must not register as a filled band."""
    info = afb.analyse(tmp_ppm("c4", _console()))
    assert info["bar"] == "none", info


def test_expect_mismatch_is_reported(tmp_ppm) -> None:
    """--expect must actually gate the exit status."""
    path = tmp_ppm("c5", _console())
    info = afb.analyse(path)
    assert info["verdict"] == "console"
    # A console frame must fail an --expect graphical run.
    assert info["verdict"] != "graphical"


# ---------------------------------------------------------------------- #
# Two 2-colour white-on-black frames that MUST classify differently.
#
# Incident: a framebuffer text console showing a login prompt is exactly
# 2 colours with ~0.3% ink, which matched the old blank rule
# (uniq <= 2 and dom_frac > 0.995). Both no-display negative controls
# therefore reported 'blank' while their captures plainly showed an
# Alpine login prompt -- i.e. the controls for the whole matrix were
# broken by the classifier, not by the image.
#
# The frame that must STILL fail is qemu's placeholder,
# "Guest has not initialized the display (yet).", which is also
# 2-colour white-on-black and means the guest never touched the
# display. It differs structurally: one line centred vertically, versus
# a console whose text starts top-left and covers many rows.
# ---------------------------------------------------------------------- #


def _qemu_placeholder() -> list[list[tuple[int, int, int]]]:
    """One line of text centred vertically -- the guest never drew."""
    px = _blank()
    y0 = H // 2
    for dy in range(8):
        for cx in range(46):                 # ~46 chars, centred
            x0 = (W // 2) - 160 + cx * 7
            for dx in range(4):
                px[y0 + dy][x0 + dx] = WHITE if (dx + dy) % 3 else BLACK
    return px


def test_text_console_is_not_blank(tmp_ppm) -> None:
    """The exact regression: a login prompt must not read as blank."""
    info = afb.analyse(tmp_ppm("con", _console()))
    assert info["verdict"] == "console", info
    assert info["unique_colours"] <= 2, (
        "fixture drifted: the point is that a REAL console is 2-colour, "
        "which is what made the old rule call it blank"
    )


def test_qemu_placeholder_is_blank(tmp_ppm) -> None:
    """A centred single line means the guest never initialised the display."""
    info = afb.analyse(tmp_ppm("ph", _qemu_placeholder()))
    assert info["verdict"] == "blank", info


def test_console_and_placeholder_are_both_two_colour(tmp_ppm) -> None:
    """Prove the two cases are NOT separable by colour count or ink.

    If this fails, the fixtures drifted apart and the tests above have
    become easy for the wrong reason.
    """
    con = afb.analyse(tmp_ppm("c9", _console()))
    ph = afb.analyse(tmp_ppm("p9", _qemu_placeholder()))
    assert con["unique_colours"] == ph["unique_colours"]
    assert con["verdict"] != ph["verdict"]
    # The discriminator is WHERE the ink is, not how much.
    assert con["ink_top_frac"] < 0.30
    assert ph["ink_top_frac"] > 0.30

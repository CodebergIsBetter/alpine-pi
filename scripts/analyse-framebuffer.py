#!/usr/bin/env python3
"""Judge a captured frame: did a UI actually render, or is the screen text?

Usage: analyse-framebuffer.py <shot.ppm> [--expect graphical|console]

Exits 0 if the verdict matches --expect (or, with --expect omitted, if the
frame is not "blank"), 1 otherwise.

WHY THIS EXISTS
---------------
assert-boot-log.py can only prove a compositor PROCESS started. It cannot
prove anything reached the screen. sway can log that it is running on
wayland-1 and still present black - this project has shipped that twice, once
when glamor exhausted the 64 MB CMA pool and once when XDG_RUNTIME_DIR was
unset. scripts/headless-render-test.sh (T3) starts the image's own session
against wlroots' headless backend inside an armhf chroot and screenshots it
with the image's own grim ("grim -t ppm", which is the binary PPM this reads),
and those pixels are the only way to answer "would a person see a desktop"
without the board in front of you.

Stdlib only, no Pillow and no numpy: CI installs nothing for this.

VERDICTS
--------
blank      One flat colour, or QEMU's own "Guest has not initialized the
           display (yet)" placeholder. Nothing rendered. Always a failure.
console    Mostly one dark colour with a little light foreground: the
           signature of a text framebuffer console showing a login prompt.
           No variant expects this any more - T3 skips the headless image
           instead of screenshotting a getty a chroot cannot provide - but
           it is what a UI frame must NOT be, and it is the verdict a serial
           or board capture would land on.
graphical  A status bar, real colour, or a large painted area. A compositor
           put something on screen.

The thresholds are deliberately loose. This is a smoke test for "are there
pixels", not a pixel-perfect regression check, so the PPM is uploaded as a CI
artifact for a human to look at whenever the verdict is surprising.

PROVENANCE
----------
The classifier is vendored from the author's earlier alpine-armv6 project
(scripts/ci/analyse_framebuffer.py there), where the two misreadings
documented in find_bar() and ink_extent() were paid for on real captures.
That project is GPL-3, as are pmbootstrap and pmaports, so this repo is GPL-3
as well - see ./LICENSE. The code below is upstream's: keep any fix
functionally identical in both repos so it can be carried across as a plain
diff, and do not add a non-stdlib import, because CI installs nothing for this
file and must never wait on a numpy wheel build.
"""

from __future__ import annotations

import argparse
import collections
import sys
from pathlib import Path


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    """Parse a binary P6 PPM. Returns (width, height, rgb_bytes)."""
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise ValueError(f"{path}: not a binary P6 PPM (got {data[:2]!r})")

    # Header: P6 <w> <h> <maxval>, whitespace separated, # comments allowed.
    fields: list[bytes] = []
    i = 2
    while len(fields) < 3:
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while i < len(data) and data[i] != 0x0A:
                i += 1
            continue
        start = i
        while i < len(data) and not data[i : i + 1].isspace():
            i += 1
        fields.append(data[start:i])
    i += 1  # the single whitespace byte after maxval

    width, height, maxval = (int(f) for f in fields)
    if maxval != 255:
        raise ValueError(f"{path}: maxval {maxval} unsupported (want 255)")
    return width, height, data[i : i + width * height * 3]


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def chroma(rgb: tuple[int, int, int]) -> int:
    """Colourfulness: brightest channel minus darkest.

    A framebuffer text console is greyscale - white or grey glyphs on black -
    so its chroma is ~0 everywhere. A compositor's bar has real colour; sway's
    focused-workspace indicator is #285577. That makes this a strong
    console-vs-desktop discriminator which, unlike an area measurement, does
    not depend on how much of the screen is painted.
    """
    return max(rgb) - min(rgb)


def ink_extent(
    px: bytes, width: int, height: int, background: tuple[int, int, int]
) -> dict:
    """Where on the screen is the non-background content?

    Needed to tell two 2-colour white-on-black frames apart:

      * a real framebuffer text console - the login prompt starts at the TOP
        LEFT and spans several text rows;
      * QEMU's own "Guest has not initialized the display (yet)." placeholder,
        which is a SINGLE line centred vertically and means the guest never
        touched the display at all.

    Classifying on colour counts alone conflated them: a crisp console is
    exactly 2 colours with ~0.3% ink, which matched the old "blank" rule, so a
    capture that plainly showed a login prompt was reported as blank.
    """
    bg_lum = luminance(background)
    step = max(1, width // 160)
    rows_with_ink: list[int] = []
    min_x = width
    for y in range(height):
        row = y * width * 3
        found = False
        for x in range(0, width, step):
            o = row + x * 3
            if abs(luminance((px[o], px[o + 1], px[o + 2])) - bg_lum) > 40:
                found = True
                if x < min_x:
                    min_x = x
                break
        if found:
            rows_with_ink.append(y)
    if not rows_with_ink:
        return {"rows": 0, "top_frac": None, "bottom_frac": None, "min_x_frac": None}
    return {
        "rows": len(rows_with_ink),
        "top_frac": round(rows_with_ink[0] / height, 3),
        "bottom_frac": round(rows_with_ink[-1] / height, 3),
        "min_x_frac": round(min_x / width, 3),
    }


def find_bar(
    px: bytes, width: int, height: int, background: tuple[int, int, int]
) -> dict | None:
    """Detect a status or title bar: a horizontal band unlike the background.

    Why: a tiling compositor with an empty workspace is ~97% background, which
    by "ink fraction" alone is indistinguishable from a text console. That
    misread reported a working sway desktop - bar, clock and cursor all
    visibly rendering - as "console".

    Structure is the reliable signal. A bar is a contiguous run of rows whose
    own dominant colour differs from the screen background and covers most of
    the row. Console text does not do that: its rows are mostly background
    with sparse glyphs.

    Returns the band's geometry, or None.
    """
    bg_lum = luminance(background)
    rows: list[bool] = []
    for y in range(height):
        row = y * width * 3
        counts: collections.Counter = collections.Counter()
        # Sampling 64 points across a row is plenty to find a fill.
        xs = range(0, width, max(1, width // 64))
        n = 0
        for x in xs:
            o = row + x * 3
            counts[(px[o], px[o + 1], px[o + 2])] += 1
            n += 1
        if not n:
            rows.append(False)
            continue
        colour, hits = counts.most_common(1)[0]
        # A bar row is dominated by a single colour that is NOT the page
        # background - compared by luminance so near-blacks do not count.
        rows.append(hits / n > 0.5 and abs(luminance(colour) - bg_lum) > 12)

    best_start = best_len = 0
    cur_start = cur_len = 0
    for y, is_bar in enumerate(rows):
        if is_bar:
            if cur_len == 0:
                cur_start = y
            cur_len += 1
            if cur_len > best_len:
                best_start, best_len = cur_start, cur_len
        else:
            cur_len = 0

    # Real bars are a handful of rows tall: require 6 so a stray scanline does
    # not count, and cap at 40% of the screen so a solid-colour wallpaper is
    # not mistaken for one.
    if 6 <= best_len <= height * 0.4:
        return {"y": best_start, "height": best_len}
    return None


def analyse(path: Path) -> dict:
    width, height, px = read_ppm(path)
    total = width * height
    if total == 0 or len(px) < total * 3:
        raise ValueError(f"{path}: truncated pixel data")

    # Subsample on a grid for speed; 1024x768 is ~786k pixels and characterising
    # the frame does not need every one of them.
    step = max(1, int((total / 120_000) ** 0.5))
    counts: collections.Counter = collections.Counter()
    sampled = 0
    for y in range(0, height, step):
        row = y * width * 3
        for x in range(0, width, step):
            o = row + x * 3
            counts[(px[o], px[o + 1], px[o + 2])] += 1
            sampled += 1

    dominant, dom_n = counts.most_common(1)[0]
    dom_frac = dom_n / sampled
    uniq = len(counts)

    dom_lum = luminance(dominant)
    # "ink" = pixels far from the dominant colour, i.e. content painted on top
    # of the background.
    ink = sum(n for c, n in counts.items() if abs(luminance(c) - dom_lum) > 40) / sampled

    # Is there colour anywhere? A text console is greyscale.
    chromatic = sum(n for c, n in counts.items() if chroma(c) > 25) / sampled

    bar = find_bar(px, width, height, dominant)
    extent = ink_extent(px, width, height, dominant)

    # "blank" means the guest put NOTHING meaningful on screen. It is NOT
    # simply "few colours": see ink_extent() for why the geometry of the ink,
    # not the colour count, is what separates a login prompt from QEMU's
    # never-initialised-display placeholder.
    no_ink = extent["rows"] == 0 or ink <= 0.0002
    centred_single_line = (
        extent["top_frac"] is not None
        and extent["top_frac"] > 0.30  # nothing in the top third
        and extent["bottom_frac"] < 0.70  # nor in the bottom third
        and extent["rows"] < height * 0.08  # only a sliver of rows
    )
    if uniq <= 1 or no_ink or centred_single_line:
        verdict = "blank"
    elif bar is not None or chromatic > 0.002:
        # A bar and/or real colour means a compositor is painting. This branch
        # is deliberately ahead of the ink-fraction test; see find_bar().
        verdict = "graphical"
    elif dom_lum < 60 and ink < 0.12 and uniq < 400:
        # Dark background, a little bright content, few colours, no bar and no
        # colour: a text console showing a prompt or a log.
        verdict = "console"
    else:
        verdict = "graphical"

    return {
        "path": str(path),
        "resolution": f"{width}x{height}",
        "sampled_px": sampled,
        "unique_colours": uniq,
        "dominant_rgb": dominant,
        "dominant_frac": round(dom_frac, 4),
        "dominant_luminance": round(dom_lum, 1),
        "ink_frac": round(ink, 4),
        "chromatic_frac": round(chromatic, 5),
        "bar": bar or "none",
        "ink_rows": extent["rows"],
        "ink_top_frac": extent["top_frac"],
        "verdict": verdict,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ppm", type=Path)
    ap.add_argument(
        "--expect",
        choices=("graphical", "console"),
        help="required verdict; omit to only reject 'blank'",
    )
    args = ap.parse_args()

    if not args.ppm.is_file():
        print(f"FAIL: no screenshot at {args.ppm} - the capture did not happen")
        return 1

    try:
        info = analyse(args.ppm)
    except ValueError as exc:
        print(f"FAIL: {exc}")
        return 1

    width = max(len(k) for k in info)
    for k, v in info.items():
        print(f"  {k:<{width}} : {v}")

    verdict = info["verdict"]
    if verdict == "blank":
        print("\nFAIL: nothing rendered - the framebuffer holds no content.")
        return 1
    if args.expect and verdict != args.expect:
        print(f"\nFAIL: expected {args.expect!r}, the framebuffer looks {verdict!r}.")
        return 1

    print(f"\nPASS: framebuffer verdict {verdict!r}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

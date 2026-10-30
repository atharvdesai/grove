#!/usr/bin/env python3
"""Draws GroveApp/Resources/Grove.icns: a cream leaf on a deep green squircle,
with a waveform cut through it as the leaf's veins.

    python3 scripts/make-icon.py            # needs Pillow: pip3 install pillow

The leaf is the grove; the bars are the meeting it listens to. Generated rather
than drawn by hand so the icon can be reviewed and adjusted in a diff.

Design constraints, in order:
 - Legible at 16pt: one bold shape, no fine detail that turns to mush.
 - Reads as "listening", not as a document — the notes come downstream.
 - Not the blue every Mac utility defaults to, so it is easy to find in a Dock.
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "GroveApp" / "Resources" / "Grove.icns"
SIZE = 1024
SCALE = 2  # drawn at 2x and scaled down, for clean anti-aliased edges

DEEP = (12, 52, 41)
BRIGHT = (46, 170, 118)
CREAM = (247, 238, 216)


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset, size - inset), radius=radius, fill=255)
    return mask


def background(size):
    """A diagonal deep-to-bright green with a soft light from the top left."""
    gradient = Image.new("RGB", (size, size))
    pixels = gradient.load()
    for y in range(size):
        for x in range(size):
            t = (x + (size - y)) / (2 * size)  # bottom-left 0 → top-right 1
            t = t * t * (3 - 2 * t)
            pixels[x, y] = tuple(int(DEEP[i] + (BRIGHT[i] - DEEP[i]) * t) for i in range(3))
    glow = Image.new("L", (size, size), 0)
    ImageDraw.Draw(glow).ellipse(
        (-size * 0.25, -size * 0.35, size * 0.75, size * 0.55), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    return Image.composite(Image.new("RGB", (size, size), (255, 255, 255)), gradient, glow)


def leaf_polygon(cx, cy, length, width, steps=240):
    """A leaf outline along the x axis: half-width h·sin(πt)^1.3, which closes
    to sharp points at both tips the way a real leaf does, rather than the
    blunt corners two circular arcs make."""
    h = width / 2
    xs = [cx - length / 2 + length * i / steps for i in range(steps + 1)]
    ys = [h * math.sin(math.pi * i / steps) ** 1.3 for i in range(steps + 1)]
    top = [(x, cy - y) for x, y in zip(xs, ys)]
    bottom = [(x, cy + y) for x, y in reversed(list(zip(xs, ys)))]
    return top + bottom


def leaf_layer(size):
    """The leaf, drawn level, with the waveform bars cut out of it."""
    layer = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(layer)
    cx, cy = size / 2, size / 2
    length, width = size * 0.74, size * 0.44
    draw.polygon(leaf_polygon(cx, cy, length, width), fill=255)

    # Waveform: bars across the leaf's axis, tallest in the middle, like a
    # level meter mid-sentence. Cut out, so the green shows through as veins.
    heights = [0.28, 0.52, 0.74, 0.50, 0.62, 0.32]
    bar = size * 0.042
    gap = size * 0.040
    total = len(heights) * bar + (len(heights) - 1) * gap
    x = cx - total / 2
    for h in heights:
        half = width * h / 2
        draw.rounded_rectangle((x, cy - half, x + bar, cy + half), radius=bar / 2, fill=0)
        x += bar + gap

    # A short stem off the left tip, so it reads as a leaf at a glance.
    stem = Image.new("L", (size, size), 0)
    tip = cx - length / 2
    ImageDraw.Draw(stem).line(
        [(tip + size * 0.03, cy), (tip - size * 0.04, cy + size * 0.03)],
        fill=255, width=int(size * 0.03))
    return ImageChops.lighter(layer, stem)


def draw_icon():
    size = SIZE * SCALE
    inset = size * 0.055
    radius = (size - 2 * inset) * 0.2237  # Apple's continuous-corner ratio

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    squircle = squircle_mask(size, inset, radius)
    canvas.paste(background(size), (0, 0), squircle)

    leaf = leaf_layer(size).rotate(32, resample=Image.BICUBIC, center=(size / 2, size / 2))
    leaf = ImageChops.multiply(leaf, squircle)

    shadow = leaf.filter(ImageFilter.GaussianBlur(size * 0.02))
    shadow = ImageChops.offset(shadow, 0, int(size * 0.018))
    shadow = ImageChops.multiply(shadow, squircle)
    canvas = Image.alpha_composite(
        canvas, Image.merge("RGBA", (*Image.new("RGB", (size, size), (0, 25, 15)).split(),
                                     shadow.point(lambda v: int(v * 0.45)))))
    canvas = Image.alpha_composite(
        canvas, Image.merge("RGBA", (*Image.new("RGB", (size, size), CREAM).split(), leaf)))

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    icon = draw_icon()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT, format="ICNS")
    preview = OUT.with_suffix(".png") if "--png" in sys.argv else None
    if preview:
        icon.save(preview)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Regenerate the showcase images in examples/showcase/images/.

Only the Python standard library is used to write the PNG. macOS `sips` converts it
to JPEG and GIF; `cwebp` (Homebrew `webp`) writes WebP. Nothing is downloaded. Run from the repository root:

    python3 scripts/make-showcase-images.py
"""
import math
import pathlib
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "examples" / "showcase" / "images"


def png(path, width, height, pixel):
    rows = b"".join(
        b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height)
    )

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def gradient(x, y):
    # Diagonal blue-to-teal gradient with a soft circle: the PNG demo.
    w, h = 480, 160
    r = int(40 + 60 * x / w)
    g = int(90 + 120 * y / h)
    b = int(200 - 60 * x / w)
    if math.hypot(x - w * 0.8, y - h * 0.5) < 50:
        r, g, b = 250, 200, 80
    return r, g, b


def bars(x, y):
    # A tiny bar chart: the "photo" for the JPEG demo.
    w, h = 320, 180
    heights = [0.35, 0.6, 0.45, 0.85, 0.7]
    slot = w // len(heights)
    i = min(x // slot, len(heights) - 1)
    inside = slot * 0.15 < x % slot < slot * 0.85 and y > h * (1 - heights[i])
    return (60 + 35 * i, 110, 220 - 30 * i) if inside else (245, 245, 240)


def checker(x, y):
    # A checkerboard badge: the GIF demo (GIF is palette-based, so flat colors suit it).
    return (230, 70, 70) if (x // 16 + y // 16) % 2 else (255, 255, 255)


def stripes(x, y):
    # Diagonal stripes: the WebP demo.
    return (120, 70, 200) if ((x + y) // 12) % 2 else (240, 230, 255)


def convert(source, fmt, target):
    if fmt == "webp":
        # sips cannot write WebP; use libwebp's cwebp (`brew install webp`) when present.
        if shutil.which("cwebp") is None:
            print(f"skip {target.name}: cwebp not found (brew install webp); keeping existing file")
            return
        command = ["cwebp", "-quiet", "-lossless", str(source), "-o", str(target)]
    else:
        command = ["sips", "-s", "format", fmt, str(source), "--out", str(target)]
    subprocess.run(command, check=True, capture_output=True, timeout=30)


def main():
    if shutil.which("sips") is None:
        sys.exit("sips not found: this script needs macOS")
    OUT.mkdir(parents=True, exist_ok=True)
    png(OUT / "gradient.png", 480, 160, gradient)
    sources = {"chart": (320, 180, bars, "jpeg", "jpg"),
               "checker": (96, 96, checker, "gif", "gif"),
               "stripes": (200, 120, stripes, "webp", "webp")}
    for name, (w, h, pixel, fmt, ext) in sources.items():
        tmp = OUT / f".{name}.png"
        png(tmp, w, h, pixel)
        try:
            convert(tmp, fmt, OUT / f"{name}.{ext}")
        finally:
            tmp.unlink()
    for item in sorted(OUT.iterdir()):
        print(f"{item.relative_to(ROOT)}  {item.stat().st_size} bytes")


if __name__ == "__main__":
    main()

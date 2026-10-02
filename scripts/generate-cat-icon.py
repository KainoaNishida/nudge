#!/usr/bin/env python3
"""Render the resting pixel-cat sprite as a dependency-free macOS app icon."""

from pathlib import Path
import re
import struct
import sys
import zlib


SOURCE = Path(__file__).resolve().parents[1] / "Sources/MinderApp/PetCompanion.swift"
COLORS = {
    "ink": (51, 46, 59, 255),
    "fur": (237, 145, 79, 255),
    "shade": (181, 92, 64, 255),
    "light": (255, 214, 153, 255),
    "cream": (255, 240, 199, 255),
    "pink": (245, 135, 148, 255),
}


def sprite_blocks():
    source = SOURCE.read_text()
    start = source.index("var result = [", source.index("struct PixelCatSprite"))
    end = source.index("\n        ]", start)
    entries = re.findall(
        r"Block\((\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(ink|fur|shade|light|cream|pink)\)",
        source[start:end],
    )
    if len(entries) < 35:
        raise RuntimeError("Could not read the pixel-cat artwork from PetCompanion.swift")
    blocks = [(int(x), int(y), int(w), int(h), COLORS[color]) for x, y, w, h, color in entries]
    # The icon uses the same open eyes and raised-tail pose as the resting sprite.
    blocks += [(7, 10, 3, 3, COLORS["ink"]), (14, 10, 3, 3, COLORS["ink"]),
               (8, 10, 1, 1, COLORS["cream"]), (15, 10, 1, 1, COLORS["cream"]),
               (21, 14, 2, 2, COLORS["ink"]), (21, 15, 1, 1, COLORS["light"])]
    return blocks


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def render(path, size=1024):
    pixels = bytearray(size * size * 4)

    def fill(x, y, width, height, color):
        for row in range(max(0, y), min(size, y + height)):
            for column in range(max(0, x), min(size, x + width)):
                offset = (row * size + column) * 4
                pixels[offset:offset + 4] = bytes(color)

    # A dark rounded tile leaves the ears and cream face legible in light and dark mode.
    margin = size * 48 // 1024
    radius = size * 205 // 1024
    for y in range(margin, size - margin):
        for x in range(margin, size - margin):
            dx = max(margin + radius - x, 0, x - (size - margin - radius - 1))
            dy = max(margin + radius - y, 0, y - (size - margin - radius - 1))
            if dx * dx + dy * dy <= radius * radius:
                offset = (y * size + x) * 4
                pixels[offset:offset + 4] = bytes((41, 48, 61, 255))

    cell = size * 32 // 1024
    origin = (size - cell * 24) // 2
    for x, y, width, height, color in sprite_blocks():
        fill(origin + x * cell, origin + y * cell, width * cell, height * cell, color)

    scanlines = bytearray()
    for row in range(size):
        scanlines.append(0)
        scanlines.extend(pixels[row * size * 4:(row + 1) * size * 4])
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def pack_iconset(iconset, output):
    entries = [
        (b"icp4", "icon_16x16.png"),
        (b"icp5", "icon_32x32.png"),
        (b"icp6", "icon_32x32@2x.png"),
        (b"ic07", "icon_128x128.png"),
        (b"ic08", "icon_256x256.png"),
        (b"ic09", "icon_512x512.png"),
        (b"ic10", "icon_512x512@2x.png"),
    ]
    records = []
    for kind, filename in entries:
        data = (iconset / filename).read_bytes()
        records.append(kind + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(records)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    if len(sys.argv) == 2:
        render(Path(sys.argv[1]))
    elif len(sys.argv) == 4 and sys.argv[1] == "pack":
        pack_iconset(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise SystemExit("Usage: generate-cat-icon.py OUTPUT.png | pack ICONSET_DIR OUTPUT.icns")

#!/usr/bin/env python3
"""Makes the Windows icon from the macOS one.

The macOS app ships AppIcon.icns; Windows wants an .ico (electron-builder) and the page
wants a PNG (the favicon, the tray). This reads the .icns, takes its PNG entries and writes
both — no image library needed, because the .icns already holds PNGs.

    python3 windows/tools/make-icon.py "Kuvo Code.app/Contents/Resources/AppIcon.icns"

Writes:
    windows/electron/build/icon.ico   the icon of the executable and the window
    windows/app/src/icon.png           the page's favicon and the tray's
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ICO_PATH = os.path.join(ROOT, "windows", "electron", "build", "icon.ico")
PNG_PATH = os.path.join(ROOT, "windows", "app", "src", "icon.png")


def entries(data: bytes):
    """The PNGs inside an .icns, by their size."""
    magic, total = struct.unpack(">4sI", data[:8])
    if magic != b"icns":
        raise SystemExit("that is not an .icns file")
    found = {}
    offset = 8
    while offset + 8 <= min(total, len(data)):
        kind, length = struct.unpack(">4sI", data[offset:offset + 8])
        body = data[offset + 8:offset + length]
        if body[:8] == b"\x89PNG\r\n\x1a\n":
            width = int.from_bytes(body[16:20], "big")
            height = int.from_bytes(body[20:24], "big")
            found[width] = body
        offset += length
    return found


def ico(images: dict) -> bytes:
    """An .ico holding PNG entries — what Windows has read since Vista."""
    sizes = sorted(images)
    header = struct.pack("<HHH", 0, 1, len(sizes))
    directory = b""
    offset = 6 + 16 * len(sizes)
    blobs = b""
    for size in sizes:
        body = images[size]
        directory += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(body), offset)
        blobs += body
        offset += len(body)
    return header + directory + blobs


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    with open(sys.argv[1], "rb") as handle:
        found = entries(handle.read())
    if not found:
        raise SystemExit("no PNG inside that .icns")
    os.makedirs(os.path.dirname(ICO_PATH), exist_ok=True)
    with open(ICO_PATH, "wb") as handle:
        handle.write(ico(found))
    largest = found[max(found)]
    with open(PNG_PATH, "wb") as handle:
        handle.write(largest)
    print(f"icon.ico: {', '.join(str(size) for size in sorted(found))} px")
    print(f"icon.png: {max(found)} px")
    print(ICO_PATH)
    print(PNG_PATH)


if __name__ == "__main__":
    main()

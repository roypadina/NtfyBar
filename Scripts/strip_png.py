#!/usr/bin/env python3
"""Keep only image chunks (IHDR, PLTE, tRNS, IDAT, IEND) in PNGs: no colour profile, EXIF, text or time.
For .icns files the same for every embedded PNG, and iconutil's "info" element is dropped.
Usage: Scripts/strip_png.py FILE..."""
import struct
import sys

KEEP = (b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND")


def png(data):
    out, i = [data[:8]], 8
    while i < len(data):
        size, kind = struct.unpack(">I4s", data[i:i + 8])
        if kind in KEEP:
            out.append(data[i:i + 12 + size])
        i += 12 + size
    return b"".join(out)


def icns(data):
    elements, i = [], 8
    while i < len(data):
        kind, size = struct.unpack(">4sI", data[i:i + 8])
        body = data[i + 8:i + size]
        if kind != b"info":
            body = png(body) if body.startswith(b"\x89PNG") else body
            elements.append(kind + struct.pack(">I", len(body) + 8) + body)
        i += size
    body = b"".join(elements)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


for path in sys.argv[1:]:
    data = open(path, "rb").read()
    data = icns(data) if path.endswith(".icns") else png(data)
    open(path, "wb").write(data)

"""Deterministic geometric app icon, rendered without external image tooling."""
from pathlib import Path
import struct
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def main():
    size = 1024
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            color = (23, 43, 59)
            # Three heater elements denote the three independent load engines.
            for left, top, bottom, accent in [(220, 350, 770, (187, 61, 59)), (442, 220, 770, (56, 120, 173)), (664, 290, 770, (33, 128, 120))]:
                if left <= x < left + 140 and top <= y < bottom:
                    color = accent
            rows.extend(color)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    Path("Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png").write_bytes(data)


if __name__ == "__main__":
    main()


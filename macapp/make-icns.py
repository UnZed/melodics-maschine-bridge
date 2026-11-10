"""Wrap PNG icon representations in the macOS ICNS container."""
from pathlib import Path
import struct
import sys

folder, destination = map(Path, sys.argv[1:])
entries = {
    "icp4": "16x16", "icp5": "32x32", "ic07": "128x128",
    "ic08": "256x256", "ic09": "512x512", "ic10": "512x512@2x",
    "ic11": "16x16@2x", "ic12": "32x32@2x",
    "ic13": "128x128@2x", "ic14": "256x256@2x",
}
chunks = []
for code, size in entries.items():
    png = (folder / f"icon_{size}.png").read_bytes()
    chunks.append(struct.pack(">4sI", code.encode(), len(png) + 8) + png)
body = b"".join(chunks)
destination.write_bytes(struct.pack(">4sI", b"icns", len(body) + 8) + body)

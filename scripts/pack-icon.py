"""Pack standard PNG icon elements into an ICNS container, without external libraries."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[1]
elements = [(b"icp4", "16x16"), (b"icp5", "32x32"), (b"icp6", "32x32@2x"),
            (b"ic07", "128x128"), (b"ic08", "256x256"),
            (b"ic09", "512x512"), (b"ic10", "512x512@2x")]
chunks = []
for kind, filename in elements:
    png = (root / ".build/AppIcon.iconset" / f"icon_{filename}.png").read_bytes()
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
body = b"".join(chunks)
(root / "Design/AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)

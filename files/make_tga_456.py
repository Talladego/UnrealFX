"""Build display-sized (456x256) RLE TGA alts from full-res FX textures.

Writes to files/tga-456/. Does not modify live files/*.tga.
Prefers tga-uncomp/ when present, else files/<name>.tga.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

from PIL import Image

from make_tga_alpha import write_tga_bgra_toplevel

DISP_W = 456
DISP_H = 256


def main() -> int:
    src_dir = Path(__file__).resolve().parent
    out_dir = src_dir / "tga-456"
    out_dir.mkdir(exist_ok=True)

    bak = out_dir / "firstblood.uncomp.bak.tga"
    if bak.is_file():
        bak.unlink()

    live = sorted(p for p in src_dir.glob("*.tga") if p.is_file() and "." not in p.stem)
    print(f"{len(live)} textures -> {out_dir} at {DISP_W}x{DISP_H}")
    total = 0
    for live_path in live:
        name = live_path.stem
        uncomp = src_dir / "tga-uncomp" / f"{name}.tga"
        src = uncomp if uncomp.is_file() else live_path
        im = Image.open(src).convert("RGBA").resize(
            (DISP_W, DISP_H), Image.Resampling.LANCZOS
        )
        dest = out_dir / f"{name}.tga"
        write_tga_bgra_toplevel(dest, im)
        data = dest.read_bytes()
        w, h = struct.unpack_from("<HH", data, 12)
        assert (w, h) == (DISP_W, DISP_H), (name, w, h)
        total += dest.stat().st_size
        print(
            f"  {name}: {w}x{h} type={data[2]} "
            f"{dest.stat().st_size / 1024:.1f} KB <- {src.relative_to(src_dir)}"
        )
    print(f"Total: {total / 1024 / 1024:.2f} MB  ({len(list(out_dir.glob('*.tga')))} files)")
    print("Live files/*.tga untouched.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

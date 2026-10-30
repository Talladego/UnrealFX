"""
Convert comic announcer images to 32-bit TGA with a transparent background.

Keys out the light paper/frame around the art (edge-connected flood fill),
then writes a D3DX-friendly RLE TGA (type 10):
  - 32 bpp BGRA
  - top-left origin
  - 8-bit alpha (descriptor 0x28)

Usage:
  python make_tga_alpha.py fontvibe-bloodbath.tga
  python make_tga_alpha.py *.tga
  python make_tga_alpha.py fontvibe-*.png --force
  python make_tga_alpha.py art.jpeg -o art.tga

Requires: Pillow  (pip install pillow)
"""
from __future__ import annotations

import argparse
import struct
import sys
from collections import deque
from pathlib import Path

from PIL import Image

BACKUP_SUFFIXES = (".24bit.bak", ".prealpha.bak")


def lum(c: tuple[int, int, int]) -> float:
    r, g, b = c
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def sat(c: tuple[int, int, int]) -> float:
    mx, mn = max(c), min(c)
    return ((mx - mn) / mx) if mx else 0.0


def dist(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5


def tga_header_bpp(path: Path) -> int | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if len(raw) < 18 or path.suffix.lower() != ".tga" and not any(
        path.name.endswith(s) for s in BACKUP_SUFFIXES
    ):
        # Still try if content looks like TGA
        if len(raw) < 18:
            return None
    return raw[16]


def count_zero_alpha(path: Path, limit_pixels: int = 200_000) -> tuple[int, int] | None:
    """Return (zero_alpha, sampled) for a 32-bit TGA, or None."""
    raw = path.read_bytes()
    if len(raw) < 18 or raw[16] != 32:
        return None
    w = struct.unpack_from("<H", raw, 12)[0]
    h = struct.unpack_from("<H", raw, 14)[0]
    total = w * h
    step = max(1, total // limit_pixels)
    zero = 0
    sampled = 0
    for i in range(0, total, step):
        a = raw[18 + i * 4 + 3]
        sampled += 1
        if a == 0:
            zero += 1
    return zero, sampled


def looks_already_keyed(path: Path) -> bool:
    stats = count_zero_alpha(path)
    if not stats:
        return False
    zero, sampled = stats
    return sampled > 0 and (zero / sampled) >= 0.05


def find_source_image(src: Path) -> tuple[Path, str]:
    """Pick the best unkeyed source: prefer *.24bit.bak / *.prealpha.bak over keyed TGA."""
    for suffix in BACKUP_SUFFIXES:
        bak = src.with_name(src.name + suffix)
        if bak.exists():
            return bak, f"backup ({bak.name})"

    # Also accept stem.tga.24bit.bak style already used once
    alt = src.with_suffix(src.suffix + ".24bit.bak")
    if alt.exists():
        return alt, f"backup ({alt.name})"

    return src, "file"


def ensure_backup(src: Path) -> Path | None:
    """Save a pre-alpha backup if the source is not already keyed."""
    existing = []
    for suffix in BACKUP_SUFFIXES:
        p = src.with_name(src.name + suffix)
        if p.exists():
            existing.append(p)
    alt = src.with_suffix(src.suffix + ".24bit.bak")
    if alt.exists():
        existing.append(alt)
    if existing:
        return existing[0]

    if looks_already_keyed(src):
        print(f"  WARN: {src.name} already has alpha and no .24bit.bak — refusing to clobber")
        return None

    bak = src.with_name(src.name + ".24bit.bak")
    bak.write_bytes(src.read_bytes())
    print(f"  backup -> {bak.name}")
    return bak


def _encode_tga_rle_row(row: bytes, pxsize: int = 4) -> bytes:
    """Pack one scanline as TGA RLE (packet max length 128)."""
    n = len(row) // pxsize
    out = bytearray()
    i = 0
    while i < n:
        run = 1
        pix = row[i * pxsize : (i + 1) * pxsize]
        while (
            i + run < n
            and run < 128
            and row[(i + run) * pxsize : (i + run + 1) * pxsize] == pix
        ):
            run += 1
        if run >= 2:
            out.append(0x80 | (run - 1))
            out.extend(pix)
            i += run
            continue
        j = i
        while j < n and (j - i) < 128:
            if j + 1 < n and row[j * pxsize : (j + 1) * pxsize] == row[
                (j + 1) * pxsize : (j + 2) * pxsize
            ]:
                run2 = 2
                while (
                    j + run2 < n
                    and run2 < 128
                    and row[j * pxsize : (j + 1) * pxsize]
                    == row[(j + run2) * pxsize : (j + run2 + 1) * pxsize]
                ):
                    run2 += 1
                if run2 >= 2:
                    break
            j += 1
        if j == i:
            j = i + 1
        out.append(j - i - 1)
        out.extend(row[i * pxsize : j * pxsize])
        i = j
    return bytes(out)


def write_tga_bgra_toplevel(path: Path, im: Image.Image) -> None:
    """Write RLE 32-bit TGA (type 10), top-left origin, 8-bit alpha.

    RoR's UI client accepts RLE truecolor TGA; typically ~35–45% smaller than
    uncompressed type-2 dumps of these announcer overlays.
    """
    rgba = im.convert("RGBA")
    w, h = rgba.size
    header = bytearray(18)
    header[2] = 10  # RLE truecolor
    header[12:14] = struct.pack("<H", w)
    header[14:16] = struct.pack("<H", h)
    header[16] = 32
    header[17] = 0x28

    src = rgba.tobytes()
    pixels = bytearray(w * h * 4)
    for i in range(w * h):
        r, g, b, a = src[i * 4 : (i + 1) * 4]
        o = i * 4
        pixels[o : o + 4] = bytes((b, g, r, a))

    body = bytearray()
    row_bytes = w * 4
    for y in range(h):
        body.extend(_encode_tga_rle_row(bytes(pixels[y * row_bytes : (y + 1) * row_bytes])))

    path.write_bytes(bytes(header) + bytes(body))


def key_background(im: Image.Image) -> tuple[Image.Image, dict]:
    rgba = im.convert("RGBA")
    w, h = rgba.size
    px = rgba.load()

    samples: list[tuple[int, int, int]] = []
    step_x = max(1, w // 128)
    step_y = max(1, h // 128)
    for x in range(0, w, step_x):
        for y in (0, 1, 2, h - 1, h - 2, h - 3):
            samples.append(px[x, y][:3])
    for y in range(0, h, step_y):
        for x in (0, 1, 2, w - 1, w - 2, w - 3):
            samples.append(px[x, y][:3])

    bg_cands = [c for c in samples if lum(c) >= 120 and sat(c) <= 0.22]
    if not bg_cands:
        bg_cands = samples
    br = sum(c[0] for c in bg_cands) / len(bg_cands)
    bg = sum(c[1] for c in bg_cands) / len(bg_cands)
    bb = sum(c[2] for c in bg_cands) / len(bg_cands)
    bg_mean = (br, bg, bb)

    def is_background(c) -> bool:
        rgb = c[:3]
        if lum(rgb) >= 155 and sat(rgb) <= 0.20:
            return True
        if lum(rgb) >= 130 and sat(rgb) <= 0.25 and dist(rgb, bg_mean) <= 70:
            return True
        return False

    candidate = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            if is_background(px[x, y]):
                candidate[y * w + x] = 1

    visited = bytearray(w * h)
    q: deque[tuple[int, int]] = deque()

    def seed(x: int, y: int) -> None:
        i = y * w + x
        if candidate[i] and not visited[i]:
            visited[i] = 1
            q.append((x, y))

    for x in range(w):
        seed(x, 0)
        seed(x, h - 1)
    for y in range(h):
        seed(0, y)
        seed(w - 1, y)

    margin = max(16, min(w, h) // 40)
    step = max(4, margin // 3)
    for y in range(0, h, step):
        for x in range(0, w, step):
            if x < margin or y < margin or x >= w - margin or y >= h - margin:
                seed(x, y)

    while q:
        x, y = q.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if nx < 0 or ny < 0 or nx >= w or ny >= h:
                continue
            i = ny * w + nx
            if visited[i] or not candidate[i]:
                continue
            visited[i] = 1
            q.append((nx, ny))

    out = Image.new("RGBA", (w, h))
    out_px = out.load()
    transparent = 0
    soft = 0
    for y in range(h):
        for x in range(w):
            r, g, b, _a = px[x, y]
            if visited[y * w + x]:
                edge = False
                for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                    if 0 <= nx < w and 0 <= ny < h and not visited[ny * w + nx]:
                        edge = True
                        break
                if edge:
                    out_px[x, y] = (r, g, b, 48)
                    soft += 1
                else:
                    out_px[x, y] = (0, 0, 0, 0)
                    transparent += 1
            else:
                out_px[x, y] = (r, g, b, 255)

    stats = {
        "size": (w, h),
        "bg_mean": bg_mean,
        "bg_samples": len(bg_cands),
        "transparent": transparent,
        "soft_edge": soft,
        "pct": 100.0 * transparent / (w * h),
    }
    return out, stats


def resolve_inputs(patterns: list[str]) -> list[Path]:
    files: list[Path] = []
    seen: set[Path] = set()
    for pattern in patterns:
        p = Path(pattern)
        matches = sorted(p.parent.glob(p.name)) if any(ch in p.name for ch in "*?[") else [p]
        if not matches and p.exists():
            matches = [p]
        for m in matches:
            m = m.resolve()
            if not m.is_file():
                continue
            name_l = m.name.lower()
            if name_l.endswith(".24bit.bak") or name_l.endswith(".prealpha.bak"):
                continue
            if m.suffix.lower() not in {".tga", ".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}:
                continue
            if m.stem.startswith("make_tga_alpha") or m.stem.startswith("_make_tga_alpha"):
                continue
            if m in seen:
                continue
            seen.add(m)
            files.append(m)
    return files


def convert_one(src: Path, dest: Path | None, force: bool) -> int:
    dest = (dest or src.with_suffix(".tga")).resolve()
    src = src.resolve()

    read_path, via = find_source_image(src)

    # In-place TGA convert: ensure we have an unkeyed backup first.
    if dest == src and src.suffix.lower() == ".tga":
        bak = ensure_backup(src)
        if bak is None and via == "file" and looks_already_keyed(src):
            return 1
        read_path, via = find_source_image(src)

    if dest.exists() and dest != src and not force:
        print(f"  skip (exists): {dest.name}  (use --force)")
        return 0

    print(f"  source: {read_path.name} ({via})")
    im = Image.open(read_path)
    keyed, stats = key_background(im)

    if stats["pct"] < 1.0:
        print(
            f"  WARN: only {stats['pct']:.1f}% cleared — source may already be keyed "
            f"or background is not light grey"
        )

    write_tga_bgra_toplevel(dest, keyed)
    br, bg, bb = stats["bg_mean"]
    print(
        f"  {src.name} -> {dest.name}  "
        f"{stats['size'][0]}x{stats['size'][1]}  "
        f"bg=({br:.0f},{bg:.0f},{bb:.0f})  "
        f"clear={stats['pct']:.1f}%"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Key out light backgrounds and write 32-bit alpha TGAs for RoR UI."
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Image paths or globs (*.tga, fontvibe-*.png, …)",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Output .tga path (only valid with a single input)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing non-in-place outputs",
    )
    args = parser.parse_args(argv)

    files = resolve_inputs(args.inputs)
    if not files:
        print("No matching image files.", file=sys.stderr)
        return 1

    if args.output and len(files) != 1:
        print("-o/--output requires exactly one input file.", file=sys.stderr)
        return 1

    print(f"Converting {len(files)} file(s)…")
    rc = 0
    for src in files:
        try:
            out = Path(args.output).resolve() if args.output else None
            if convert_one(src, out, force=args.force) != 0:
                rc = 1
        except Exception as exc:  # noqa: BLE001
            print(f"  ERROR {src.name}: {exc}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())

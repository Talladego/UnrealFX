"""
Convert PNG (or JPEG) images to 32-bit TGA for the RoR UI client.

Writes RLE-compressed BGRA TGA (type 10) with top-left origin and 8-bit alpha
(the same layout UnrealFX FX textures use).

By default, light paper/frame backgrounds are keyed to transparent
(same flood-fill as make_tga_alpha.py). If the PNG already has a real
alpha channel, it is preserved unless you pass --key.

Usage:
  python png_to_tga.py fontvibe-annihilation-93623.png   # → annihilation.tga
  python png_to_tga.py *.png
  python png_to_tga.py art.png -o godlike.tga
  python png_to_tga.py art.png --no-key          # keep pixels as-is (opaque if no alpha)
  python png_to_tga.py art.png --key             # force background keying

Requires: Pillow  (pip install pillow)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image

# Reuse the proven keying + TGA writer from the sibling script.
from make_tga_alpha import key_background, write_tga_bgra_toplevel

INPUT_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"}


def effect_tga_name(src: Path) -> Path:
    """Map fontvibe-<effect>[-id].png → <effect>.tga (matches .wav naming)."""
    stem = src.stem.lower()
    if stem.startswith("fontvibe-"):
        stem = stem[len("fontvibe-") :]
    stem = stem.rstrip("!")
    stem = re.sub(r"-\d+$", "", stem).strip("-_")
    if stem and re.fullmatch(r"[a-z][a-z0-9_]*", stem):
        return src.with_name(stem + ".tga")
    return src.with_suffix(".tga")


def has_useful_alpha(im: Image.Image, sample_step: int = 8) -> bool:
    """True if the image already has a non-trivial alpha channel."""
    if im.mode in ("RGB", "L", "P") and "transparency" not in im.info:
        return False
    rgba = im.convert("RGBA")
    w, h = rgba.size
    px = rgba.load()
    transparentish = 0
    sampled = 0
    for y in range(0, h, sample_step):
        for x in range(0, w, sample_step):
            sampled += 1
            if px[x, y][3] < 250:
                transparentish += 1
    return sampled > 0 and (transparentish / sampled) >= 0.05


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
            if m.suffix.lower() not in INPUT_SUFFIXES:
                continue
            if m in seen:
                continue
            seen.add(m)
            files.append(m)
    return files


def convert_one(src: Path, dest: Path, *, force_key: bool, no_key: bool, force: bool) -> int:
    natural = effect_tga_name(src)
    if (
        dest.exists()
        and not force
        and dest.resolve() != src.resolve()
        and dest.resolve() != natural.resolve()
    ):
        print(f"  skip (exists): {dest.name}  (use --force)")
        return 0

    im = Image.open(src)
    use_key = force_key or (not no_key and not has_useful_alpha(im))

    if use_key:
        out, stats = key_background(im)
        br, bg, bb = stats["bg_mean"]
        note = f"keyed clear={stats['pct']:.1f}% bg=({br:.0f},{bg:.0f},{bb:.0f})"
    else:
        out = im.convert("RGBA")
        w, h = out.size
        note = "preserved alpha" if has_useful_alpha(im) else "opaque (no key)"
        stats = {"size": (w, h)}

    write_tga_bgra_toplevel(dest, out)
    w, h = stats["size"] if "size" in stats else out.size
    print(f"  {src.name} -> {dest.name}  {w}x{h}  {note}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert PNG/JPEG to 32-bit alpha TGA for RoR addons."
    )
    parser.add_argument("inputs", nargs="+", help="PNG/JPEG paths or globs")
    parser.add_argument(
        "-o",
        "--output",
        help="Output .tga path (single input only). Default: <effect>.tga for fontvibe-* inputs",
    )
    parser.add_argument(
        "--key",
        action="store_true",
        help="Force light-background keying even if the PNG has alpha",
    )
    parser.add_argument(
        "--no-key",
        action="store_true",
        help="Never key; write pixels as-is (RGB becomes opaque)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing output that is not the natural sibling .tga",
    )
    args = parser.parse_args(argv)

    if args.key and args.no_key:
        print("Use only one of --key / --no-key.", file=sys.stderr)
        return 1

    files = resolve_inputs(args.inputs)
    if not files:
        print("No matching PNG/JPEG files.", file=sys.stderr)
        return 1

    if args.output and len(files) != 1:
        print("-o/--output requires exactly one input file.", file=sys.stderr)
        return 1

    print(f"Converting {len(files)} file(s) to 32-bit TGA…")
    rc = 0
    for src in files:
        dest = Path(args.output).resolve() if args.output else effect_tga_name(src)
        if dest.suffix.lower() != ".tga":
            dest = dest.with_suffix(".tga")
        try:
            if convert_one(
                src,
                dest,
                force_key=args.key,
                no_key=args.no_key,
                force=args.force,
            ) != 0:
                rc = 1
        except Exception as exc:  # noqa: BLE001
            print(f"  ERROR {src.name}: {exc}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())

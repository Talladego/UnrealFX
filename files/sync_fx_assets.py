"""
Scan files/<effect>.tga and regenerate FX texture registrations in
UnrealFX.xml + UnrealFX.lua.

Preferred naming (matches .wav keywords):
  annihilation.tga
  bloodbath.tga
  monsterkill.tga

Legacy fontvibe-* names are still detected and can be renamed with --rename.

Keyword maps to sound file files/<keyword>.wav. Extra aliases:
  monsterkill → monsterkill, monsterkill1, monsterkill2

Usage:
  python sync_fx_assets.py
  python sync_fx_assets.py --rename   # fontvibe-*.tga → <effect>.tga
  python sync_fx_assets.py --dry-run

Typical pipeline for a new visual:
  python png_to_tga.py fontvibe-godlike-123.png -o godlike.tga
  python sync_fx_assets.py
  # then /reload in-game
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FILES_DIR = Path(__file__).resolve().parent
ADDON_DIR = FILES_DIR.parent
XML_PATH = ADDON_DIR / "UnrealFX.xml"
LUA_PATH = ADDON_DIR / "UnrealFX.lua"

# keyword -> extra sound keywords that should use the same art
SOUND_ALIASES: dict[str, list[str]] = {
    "monsterkill": ["monsterkill", "monsterkill1", "monsterkill2"],
}

# TGA stems that are not FX overlays (helpers / junk)
SKIP_STEMS = {
    "make_tga_alpha",
    "png_to_tga",
    "sync_fx_assets",
    "make_tga_456",
}

MARKER_XML_BEGIN = "<!-- BEGIN FX_ASSETS (sync_fx_assets.py) -->"
MARKER_XML_END = "<!-- END FX_ASSETS -->"
MARKER_LUA_BEGIN = "-- BEGIN FX_TEXTURES (sync_fx_assets.py)"
MARKER_LUA_END = "-- END FX_TEXTURES"


def keyword_from_stem(stem: str) -> str | None:
    """annihilation / fontvibe-annihilation-93623 → annihilation"""
    name = stem.lower()
    if name in SKIP_STEMS:
        return None
    if name.startswith("fontvibe-"):
        name = name[len("fontvibe-") :]
    name = name.rstrip("!")
    # Drop trailing numeric id: -93623
    name = re.sub(r"-\d+$", "", name)
    name = name.strip("-_")
    if not name or not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        return None
    return name


def rename_legacy_fontvibe(dry_run: bool) -> list[tuple[Path, Path]]:
    """Rename fontvibe-*.tga → <effect>.tga. Returns list of (src, dest)."""
    planned: list[tuple[Path, Path]] = []
    for path in sorted(FILES_DIR.glob("fontvibe-*.tga")):
        key = keyword_from_stem(path.stem)
        if not key:
            print(f"  skip rename (bad name): {path.name}", file=sys.stderr)
            continue
        dest = FILES_DIR / f"{key}.tga"
        if dest.resolve() == path.resolve():
            continue
        planned.append((path, dest))

    for src, dest in planned:
        if dest.exists() and dest.resolve() != src.resolve():
            print(f"  replace existing {dest.name} with {src.name}")
            if not dry_run:
                dest.unlink()
        print(f"  rename {src.name} -> {dest.name}")
        if not dry_run:
            src.replace(dest)

    return planned


def discover_assets() -> list[dict]:
    found: dict[str, Path] = {}

    # Prefer simple <effect>.tga; also accept legacy fontvibe-*.tga.
    candidates = list(FILES_DIR.glob("*.tga"))
    for path in sorted(candidates, key=lambda p: (0 if not p.name.startswith("fontvibe-") else 1, len(p.name), p.name)):
        if path.name.endswith(".24bit.bak") or path.name.endswith(".prealpha.bak"):
            continue
        key = keyword_from_stem(path.stem)
        if not key:
            continue
        # Prefer non-fontvibe / shorter names when duplicates exist.
        prev = found.get(key)
        if prev is None:
            found[key] = path
            continue
        prev_legacy = prev.name.startswith("fontvibe-")
        cur_legacy = path.name.startswith("fontvibe-")
        if prev_legacy and not cur_legacy:
            found[key] = path
        elif prev_legacy == cur_legacy and len(path.name) < len(prev.name):
            found[key] = path

    assets = []
    for key in sorted(found.keys()):
        path = found[key]
        sounds = SOUND_ALIASES.get(key)
        if not sounds:
            sounds = [key]
        assets.append(
            {
                "key": key,
                "file": f"files/{path.name}",
                "texture": f"UnrealFX_{key}",
                "sounds": sounds,
            }
        )
    return assets


def render_xml_assets(assets: list[dict]) -> str:
    lines = [f"        {MARKER_XML_BEGIN}"]
    for a in assets:
        lines.append(
            f'        <Texture name="{a["texture"]}" file="{a["file"]}" />'
        )
    lines.append(f"        {MARKER_XML_END}")
    return "\n".join(lines)


def render_lua_table(assets: list[dict]) -> str:
    lines = [
        MARKER_LUA_BEGIN,
        "UnrealFX.FX_TEXTURES = {",
    ]
    for a in assets:
        sounds = ", ".join(f'"{s}"' for s in a["sounds"])
        lines.append("    {")
        lines.append(f'        key = "{a["key"]}",')
        lines.append(f'        texture = "{a["texture"]}",')
        lines.append(f'        label = "{a["key"]}",')
        lines.append(f"        sounds = {{ {sounds} }},")
        lines.append("    },")
    lines.append("}")
    lines.append(MARKER_LUA_END)
    return "\n".join(lines)


def replace_marked_block(text: str, begin: str, end: str, replacement: str) -> str:
    start = text.find(begin)
    stop = text.find(end)
    if start < 0 or stop < 0 or stop < start:
        raise RuntimeError(f"Missing markers {begin!r} .. {end!r}")
    stop_end = stop + len(end)
    return text[:start] + replacement + text[stop_end:]


def ensure_xml_markers(text: str) -> str:
    if MARKER_XML_BEGIN in text and MARKER_XML_END in text:
        return text
    m = re.search(
        r"(<Assets>\s*)(.*?)(\s*</Assets>)",
        text,
        flags=re.DOTALL,
    )
    if not m:
        raise RuntimeError("Could not find <Assets> in XML")
    placeholder = (
        f"{m.group(1)}{MARKER_XML_BEGIN}\n"
        f"        {MARKER_XML_END}{m.group(3)}"
    )
    return text[: m.start()] + placeholder + text[m.end() :]


def ensure_lua_markers(text: str) -> str:
    if MARKER_LUA_BEGIN in text and MARKER_LUA_END in text:
        return text
    m = re.search(
        r"UnrealFX\.FX_TEXTURES\s*=\s*\{.*?\n\}",
        text,
        flags=re.DOTALL,
    )
    if not m:
        raise RuntimeError("Could not find UnrealFX.FX_TEXTURES in Lua")
    placeholder = f"{MARKER_LUA_BEGIN}\nUnrealFX.FX_TEXTURES = {{}}\n{MARKER_LUA_END}"
    return text[: m.start()] + placeholder + text[m.end() :]


def patch_default_dynamic_image(text: str, first_texture: str) -> str:
    return re.sub(
        r'(<DynamicImage name="\$parentImage" texture=")UnrealFX_[^"]+(")',
        rf"\1{first_texture}\2",
        text,
        count=1,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Sync <effect>.tga FX assets into addon XML/Lua tables."
    )
    parser.add_argument(
        "--rename",
        action="store_true",
        help="Rename fontvibe-*.tga to <effect>.tga before syncing",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print plan only")
    args = parser.parse_args(argv)

    if args.rename:
        print("Renaming legacy fontvibe-*.tga → <effect>.tga …")
        rename_legacy_fontvibe(dry_run=args.dry_run)

    assets = discover_assets()
    if not assets:
        print("No FX .tga files found.", file=sys.stderr)
        return 1

    print(f"Found {len(assets)} FX asset(s):")
    for a in assets:
        print(f"  {a['key']:16} <- {a['file']}  sounds={a['sounds']}")

    xml_block = render_xml_assets(assets)
    lua_block = render_lua_table(assets)

    xml_text = ensure_xml_markers(XML_PATH.read_text(encoding="utf-8"))
    lua_text = ensure_lua_markers(LUA_PATH.read_text(encoding="utf-8"))

    xml_text = replace_marked_block(xml_text, MARKER_XML_BEGIN, MARKER_XML_END, xml_block)
    xml_text = patch_default_dynamic_image(xml_text, assets[0]["texture"])
    lua_text = replace_marked_block(lua_text, MARKER_LUA_BEGIN, MARKER_LUA_END, lua_block)

    if args.dry_run:
        print("\n--dry-run: no registry files written")
        print("\nXML assets:\n" + xml_block)
        print("\nLua table:\n" + lua_block)
        return 0

    XML_PATH.write_text(xml_text, encoding="utf-8", newline="\n")
    LUA_PATH.write_text(lua_text, encoding="utf-8", newline="\n")
    print(f"\nUpdated {XML_PATH.name} and {LUA_PATH.name}")
    print("Reload UI in-game to pick up new textures.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

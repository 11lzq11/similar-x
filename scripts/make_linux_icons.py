#!/usr/bin/env python3
"""Generate the Linux launcher icons for Similar-X.

flutter_launcher_icons does not support Linux, so this script generates
the freedesktop hicolor icon set from the 1024x1024 source artwork plus
a .desktop entry, which is the standard way a Linux app ships its icon:

    linux/icons/hicolor/<size>x<size>/apps/similar-x.png
    linux/similar-x.desktop

Run from the app root:  python3 scripts/make_linux_icons.py
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "icon" / "similar-x-icon.png"
SIZES = (16, 32, 48, 64, 128, 256, 512)


def main() -> int:
    if not SOURCE.exists():
        print(f"missing source icon: {SOURCE}", file=sys.stderr)
        return 1
    im = Image.open(SOURCE)
    if im.size != (1024, 1024):
        print(f"unexpected source size {im.size}, expected 1024x1024",
              file=sys.stderr)
        return 1
    for size in SIZES:
        out = (ROOT / "linux" / "icons" / "hicolor"
               / f"{size}x{size}" / "apps" / "similar-x.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        im.resize((size, size), Image.LANCZOS).save(out, "PNG")
        print(f"wrote {out.relative_to(ROOT)}")

    desktop = ROOT / "linux" / "similar-x.desktop"
    desktop.write_text(
        "[Desktop Entry]\n"
        "Name=Similar-X\n"
        "Comment=One app for every social network\n"
        "Exec=similar_x\n"
        "Icon=similar-x\n"
        "Terminal=false\n"
        "Type=Application\n"
        "Categories=Network;InstantMessaging;Social;\n"
        "StartupWMClass=similar_x\n",
        encoding="utf-8",
    )
    print(f"wrote {desktop.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

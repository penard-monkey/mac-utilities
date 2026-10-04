# Icon family

SVG sources for the Mac Utilities icons (1024 px app tiles, 18 pt menu bar glyphs).
Shared style: ink tile `#16181D`, cream `#F4F1EA` strokes, one accent per utility.

| Icon | Source | Used by |
|---|---|---|
| Mac Utilities | `mac-utilities.svg` | `utilities-manager/Resources/AppIcon.icns` |
| Git & SSH | `git-ssh.svg` | `git-settings/Resources/AppIcon.icns` |
| GIF Stickers | `gif-stickers.svg` | `gif-stickers/Resources/AppIcon.icns` |
| Transcribe | `transcribe.svg` | `transcribe/Resources/AppIcon.icns` |
| QR Reader | `qr-reader.svg` | not built yet; the utility does not exist |
| Memory | `memory-glyph-{mono,color}.svg` | not wired; the plugin keeps its pressure-tinted SF Symbol |
| Tools | `tools-glyph-{mono,color}.svg` | embedded as a template image in `swiftbar/tools/tools.1m.py` |

Regenerate an app icon (the tile is scaled to 824 pt inside a 1024 pt canvas, as macOS expects):

    swift scripts/icons/render.swift app docs/icons/<name>.svg /tmp/<name>.iconset
    iconutil -c icns /tmp/<name>.iconset -o <utility>/Resources/AppIcon.icns

Glyph PNG (36 px = 18 pt @2x):

    swift scripts/icons/render.swift glyph docs/icons/<name>.svg out.png 36

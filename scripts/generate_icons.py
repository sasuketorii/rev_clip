#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw


APP_ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]
STATUS_BAR_SIZES = [18, 36]


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def assets_root() -> Path:
    return repo_root() / "src/Revclip/Revclip/Resources/Assets.xcassets"


def load_app_icon_master() -> Image.Image:
    # Keep the square Figma export as the sole application icon source.
    return Image.open(repo_root() / "revclip_icon_square.png").convert("RGB")


def generate_app_icons(appicon_dir: Path) -> None:
    appicon_dir.mkdir(parents=True, exist_ok=True)
    for path in appicon_dir.glob("icon_*.png"):
        path.unlink()

    base_icon = load_app_icon_master()
    if base_icon.size != (1024, 1024):
        base_icon = base_icon.resize((1024, 1024), resample=Image.Resampling.LANCZOS)

    resampling = Image.Resampling.LANCZOS
    for size in APP_ICON_SIZES:
        output = appicon_dir / f"icon_{size}.png"
        icon = base_icon if size == 1024 else base_icon.resize((size, size), resample=resampling)
        icon.save(output, format="PNG", optimize=True)

    contents = {
        "images": [
            {"filename": "icon_16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
            {"filename": "icon_32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
            {"filename": "icon_32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
            {"filename": "icon_64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
            {"filename": "icon_128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
            {"filename": "icon_256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
            {"filename": "icon_256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
            {"filename": "icon_512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
            {"filename": "icon_512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
            {"filename": "icon_1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (appicon_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def create_status_bar_icon(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    stroke = max(2, int(round(size * 0.11)))
    body_rect = (
        int(size * 0.20),
        int(size * 0.32),
        int(size * 0.80),
        int(size * 0.88),
    )
    clip_rect = (
        int(size * 0.37),
        int(size * 0.12),
        int(size * 0.63),
        int(size * 0.34),
    )

    draw.rounded_rectangle(body_rect, radius=int(size * 0.12), outline=(0, 0, 0, 255), width=stroke)
    draw.rounded_rectangle(clip_rect, radius=int(size * 0.07), outline=(0, 0, 0, 255), width=stroke)

    return image


def generate_status_bar_icons(status_dir: Path) -> None:
    status_dir.mkdir(parents=True, exist_ok=True)
    for path in status_dir.glob("statusbar_*.png"):
        path.unlink()

    for size in STATUS_BAR_SIZES:
        output = status_dir / f"statusbar_{size}.png"
        create_status_bar_icon(size).save(output, format="PNG")

    contents = {
        "images": [
            {"filename": "statusbar_18.png", "idiom": "mac", "scale": "1x"},
            {"filename": "statusbar_36.png", "idiom": "mac", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    (status_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    root = assets_root()
    generate_app_icons(root / "AppIcon.appiconset")
    generate_status_bar_icons(root / "StatusBarIcon.imageset")
    print("Generated AppIcon and StatusBarIcon assets.")


if __name__ == "__main__":
    main()

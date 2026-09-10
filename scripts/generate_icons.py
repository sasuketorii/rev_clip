#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw


APP_ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]
STATUS_BAR_SIZES = [18, 36]

GRADIENT_TOP = (0x4A, 0x90, 0xD9)
GRADIENT_BOTTOM = (0x35, 0x7A, 0xBD)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def assets_root() -> Path:
    return repo_root() / "src/Revclip/Revclip/Resources/Assets.xcassets"


def lerp_color(start: tuple[int, int, int], end: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(start[i] + (end[i] - start[i]) * t)) for i in range(3))


def create_gradient_background(size: int) -> Image.Image:
    gradient = Image.new("RGBA", (size, size))
    pixels = gradient.load()

    denominator = max(1, size - 1)
    for y in range(size):
        t = y / denominator
        r, g, b = lerp_color(GRADIENT_TOP, GRADIENT_BOTTOM, t)
        for x in range(size):
            pixels[x, y] = (r, g, b, 255)

    rounded_mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(rounded_mask)
    corner_radius = int(size * 0.225)
    mask_draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=corner_radius, fill=255)

    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(gradient, (0, 0), rounded_mask)
    return icon


def draw_clipboard_silhouette(target: Image.Image) -> None:
    size = target.size[0]
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)

    body_rect = (
        int(size * 0.24),
        int(size * 0.30),
        int(size * 0.76),
        int(size * 0.83),
    )
    draw.rounded_rectangle(body_rect, radius=int(size * 0.08), fill=255)

    # Create the upper notch of the clipboard body.
    notch_rect = (
        int(size * 0.40),
        int(size * 0.30),
        int(size * 0.60),
        int(size * 0.40),
    )
    draw.rounded_rectangle(notch_rect, radius=int(size * 0.03), fill=0)

    clip_rect = (
        int(size * 0.35),
        int(size * 0.17),
        int(size * 0.65),
        int(size * 0.36),
    )
    draw.rounded_rectangle(clip_rect, radius=int(size * 0.07), fill=255)

    white_layer = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    target.paste(white_layer, (0, 0), mask)


def app_icon_master_path() -> Path:
    return repo_root() / "scripts/icon-source/revclip_icon.png"


def load_app_icon_master() -> Image.Image:
    master_path = app_icon_master_path()
    if master_path.is_file():
        return Image.open(master_path).convert("RGB")

    base_icon = create_gradient_background(1024)
    draw_clipboard_silhouette(base_icon)
    return base_icon.convert("RGB")


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

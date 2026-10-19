#!/usr/bin/env python3
"""Compose the marketplace image from a real, synthetic-content code preview."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

repo = Path(__file__).resolve().parent.parent
shots = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "screenshots"
wallpaper = Path("/usr/share/omarchy/themes/ristretto/backgrounds/0-launch.png")
W, H = 2560, 1600
# Fit the full overlay, including its preview pane, inside the marketplace card.


def cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - width) // 2, (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def scaled(path):
    image = Image.open(path).convert("RGBA")
    return image.resize((2280, round(image.height * 2280 / image.width)), Image.LANCZOS)


# The wallpaper, softened and dimmed so the cards read first.
back = cover(Image.open(wallpaper).convert("RGB"), W, H).filter(ImageFilter.GaussianBlur(18))
card = ImageEnhance.Brightness(back).enhance(0.5).convert("RGBA")


def place(image, x, y):
    global card
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 24, x + image.width, y + image.height + 24), 30, fill=(0, 0, 0, 180))
    card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(28)))
    card.alpha_composite(image, (x, y))


place(scaled(shots / "code.png"), 140, 250)

card.convert("RGB").save(repo / "preview.png", optimize=True)
print("wrote", repo / "preview.png", card.size)

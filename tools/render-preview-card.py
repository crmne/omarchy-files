#!/usr/bin/env python3
"""Composes preview.png, the marketplace card, from the overlay captures.

Run tools/render-preview, which captures the overlay and calls this with the
folder holding search.png and actions.png, both three times the on-screen
size. The card is the plugin itself rather than words about it: the results
for "invoice" and the actions panel for the first one, over Omarchy's
ristretto wallpaper.

The marketplace card shows only a strip from the middle, about 2.7 times as
wide as it is tall, and the websites crop to 16:9. So the cards are shown
large and run off the edges, with the query, the first results and the first
actions in the middle, where every crop keeps them."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

repo = Path(__file__).resolve().parent.parent
shots = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "screenshots"
wallpaper = Path("/usr/share/omarchy/themes/ristretto/backgrounds/0-launch.png")
W, H = 2560, 1600
# Of the three-times captures: the cards show at 2.25 times their on-screen
# size, about 1.1 times a HiDPI screen's own pixels.
SCALE = 0.75


def cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - width) // 2, (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def scaled(path):
    image = Image.open(path).convert("RGBA")
    return image.resize((round(image.width * SCALE), round(image.height * SCALE)), Image.LANCZOS)


# The wallpaper, softened and dimmed so the cards read first.
back = cover(Image.open(wallpaper).convert("RGB"), W, H).filter(ImageFilter.GaussianBlur(18))
card = ImageEnhance.Brightness(back).enhance(0.5).convert("RGBA")


def place(image, x, y):
    global card
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 24, x + image.width, y + image.height + 24), 30, fill=(0, 0, 0, 180))
    card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(28)))
    card.alpha_composite(image, (x, y))


place(scaled(shots / "search.png"), 110, 300)
place(scaled(shots / "actions.png"), 1420, 440)

card.convert("RGB").save(repo / "preview.png", optimize=True)
print("wrote", repo / "preview.png", card.size)

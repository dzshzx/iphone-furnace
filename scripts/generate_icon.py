"""Deterministic geometric app icon rendered with Pillow."""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
BACKGROUND = (23, 43, 59)
# Three heater elements denote the three independent load engines.
HEATERS = [
    (220, 350, 770, (187, 61, 59)),
    (442, 220, 770, (56, 120, 173)),
    (664, 290, 770, (33, 128, 120)),
]
OUTPUT = Path("Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")


def render():
    image = Image.new("RGB", (SIZE, SIZE), BACKGROUND)
    draw = ImageDraw.Draw(image)
    for left, top, bottom, accent in HEATERS:
        # rectangle() bounds are inclusive; the heater spans [left, left + 140).
        draw.rectangle((left, top, left + 139, bottom - 1), fill=accent)
    return image


def main():
    # No metadata chunks and fixed compression keep the bytes reproducible.
    render().save(OUTPUT, format="PNG", optimize=False, compress_level=9)


if __name__ == "__main__":
    main()

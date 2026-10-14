"""Draws the app icon (the Android launcher vector: a TV outline with a play mark) at 1024 px.

    python tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
S = 1024 / 108  # the Android vector is 108 x 108


def box(x0, y0, x1, y1):
    return [round(x0 * S), round(y0 * S), round(x1 * S), round(y1 * S)]


img = Image.new("RGB", (1024, 1024), "#0B5394")
d = ImageDraw.Draw(img)
d.rounded_rectangle(box(20, 32, 88, 74), radius=round(4 * S), fill="#FFFFFF")
d.rectangle(box(26, 38, 82, 68), fill="#0B5394")
d.polygon([(round(48 * S), round(44 * S)), (round(62 * S), round(53 * S)), (round(48 * S), round(62 * S))], fill="#FFB300")
d.rectangle(box(40, 78, 68, 82), fill="#FFFFFF")
for out in [ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png", ROOT / "docs" / "icon.png"]:
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(out)

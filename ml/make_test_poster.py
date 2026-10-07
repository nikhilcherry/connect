"""Builds the emulator's virtual-camera poster for testing the live plate view.

The Android emulator's virtual scene shows a room with a poster wall. Replacing
`poster.png` (and moving the poster in front of the camera in
`Toren1BD.posters`: position 0.3 0.1 -2.2, rotation 0 0 0) puts a plate in the
live preview. This composites a SYNTHETIC Indian-format plate ("KA 13 LV 3970",
the number registered in the demo account) onto a real motorbike photo from the
test split, so the whole chain can be tried without a phone:
live frame → our detector → tap → still photo → crop → ML Kit → lookup.

    python3 make_test_poster.py <test-photo.jpg> <out poster.png>
"""
import glob
import sys

from PIL import Image, ImageDraw, ImageFont

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
crop = im.crop((110, 30, 430, 270)).resize((1024, 768), Image.LANCZOS)
d = ImageDraw.Draw(crop)
x0, y0, x1, y1 = [int(v) for v in ((233 - 110) * 3.2, (106 - 30) * 3.2, (331 - 110) * 3.2, (193 - 30) * 3.2)]
d.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=(248, 248, 244), outline=(20, 20, 20), width=5)
font = glob.glob("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf")[0]
pw, ph = x1 - x0, y1 - y0


def fit(text, maxw, start):
    s = start
    while ImageFont.truetype(font, s).getlength(text) > maxw:
        s -= 2
    return ImageFont.truetype(font, s)


d.text(((x0 + x1) // 2, y0 + ph * 0.30), "KA 13 LV", fill=(15, 15, 15), font=fit("KA 13 LV", pw * 0.8, int(ph * 0.4)), anchor="mm")
d.text(((x0 + x1) // 2, y0 + ph * 0.72), "3970", fill=(15, 15, 15), font=fit("3970", pw * 0.8, int(ph * 0.45)), anchor="mm")
sq = Image.new("RGB", (1024, 1024), (255, 255, 255))
sq.paste(crop, (0, 128))
sq.save(out)

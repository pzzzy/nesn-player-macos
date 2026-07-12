#!/usr/bin/env python3
"""Generate the original NESN Player app icon without third-party assets."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Assets" / "AppIcon.png"
SIZE = 1024
im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Soft macOS-style rounded square and shadow.
shadow = Image.new("RGBA", im.size, (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle((78, 92, 946, 960), radius=205, fill=(0, 0, 0, 115))
shadow = shadow.filter(ImageFilter.GaussianBlur(30))
im.alpha_composite(shadow)

mask = Image.new("L", im.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((72, 64, 952, 944), radius=210, fill=255)
# Deep navy-to-electric-blue vertical gradient.
grad = Image.new("RGBA", im.size)
pix = grad.load()
for y in range(SIZE):
    t = max(0, min(1, (y - 64) / 880))
    for x in range(SIZE):
        glow = max(0, 1 - (((x - 350) / 700) ** 2 + ((y - 250) / 650) ** 2))
        pix[x, y] = (int(8 + 5*glow), int(24 + 45*glow), int(55 + 105*glow), 255)
im.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(im)
# Border and subtle stadium arcs.
d.rounded_rectangle((76, 68, 948, 940), radius=206, outline=(105, 190, 255, 120), width=8)
for inset, alpha in [(145, 32), (205, 24), (265, 18)]:
    d.arc((inset, inset-30, SIZE-inset, SIZE-inset+30), 195, 345, fill=(120, 205, 255, alpha), width=8)
# Baseball seam motif behind the player control.
d.ellipse((230, 230, 794, 794), fill=(247, 250, 255, 245), outline=(255,255,255,255), width=8)
d.arc((212, 290, 605, 735), 285, 75, fill=(210, 30, 52, 255), width=18)
d.arc((419, 290, 812, 735), 105, 255, fill=(210, 30, 52, 255), width=18)
# Stitch marks.
for y, x1, x2, tilt in [(340,350,675,1),(390,327,698,1),(440,312,712,1),(584,312,712,-1),(634,327,698,-1),(684,350,675,-1)]:
    if y < 512: x = x1
    else: x = x2
    d.line((x-14, y-12*tilt, x+14, y+12*tilt), fill=(210,30,52,255), width=9)
    d.line((1024-x-14, y+12*tilt, 1024-x+14, y-12*tilt), fill=(210,30,52,255), width=9)
# Play button with depth.
d.ellipse((335, 335, 689, 689), fill=(5, 24, 58, 235), outline=(74, 166, 255, 255), width=13)
d.polygon([(463, 417), (463, 607), (620, 512)], fill=(255,255,255,255))
# Tiny live accent, generic and non-trademarked.
d.ellipse((776, 156, 854, 234), fill=(230, 37, 58, 255), outline=(255,130,140,255), width=5)
OUT.parent.mkdir(parents=True, exist_ok=True)
im.save(OUT)
print(OUT)

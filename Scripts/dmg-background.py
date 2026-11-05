# Draws the DMG window background: warm paper, the wordmark, a hand-drawn-feeling arrow. Run with: python3 -I Scripts/dmg-background.py
from PIL import Image, ImageDraw, ImageFont
W, H, S = 640, 420, 2  # draw at 2x for Retina
paper, ink, clay, faint = (245, 240, 228), (36, 32, 26), (217, 120, 86), (138, 127, 108)
img = Image.new("RGB", (W * S, H * S), paper)
d = ImageDraw.Draw(img)
serif = "android/app/src/main/res/font/source_serif.ttf"
big = ImageFont.truetype(serif, 34 * S); small = ImageFont.truetype(serif, 15 * S)
# Wordmark, centred, with the clay full stop.
w1 = d.textlength("everyday", font=big); w2 = d.textlength(".", font=big)
x = (W * S - w1 - w2) / 2
d.text((x, 38 * S), "everyday", font=big, fill=ink); d.text((x + w1, 38 * S), ".", font=big, fill=clay)
# Arrow from the app to Applications (icons sit at x=170 and x=470, y=215).
y = 215 * S
d.line([(250 * S, y), (390 * S, y)], fill=clay, width=3 * S)
d.polygon([(392 * S, y), (378 * S, y - 9 * S), (378 * S, y + 9 * S)], fill=clay)
cap = "Drag into Applications to install"
d.text(((W * S - d.textlength(cap, font=small)) / 2, 330 * S), cap, font=small, fill=faint)
# Faint paper grain line along the bottom, flat.
d.line([(40 * S, 372 * S), ((W - 40) * S, 372 * S)], fill=(227, 218, 202), width=1 * S)
img.save("Resources/dmg/background@2x.png"); img.resize((W, H), Image.LANCZOS).save("Resources/dmg/background.png")
print("ok")

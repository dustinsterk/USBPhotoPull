"""Draws the USBPhotoPull app icon: Icon/AppIcon-1024.png and Icon/AppIcon.iconset/. Needs Pillow (pip install pillow)."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersampling for smooth edges
W = S * SS

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def vgradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", size)
    px = g.load()
    for y in range(h):
        c = lerp(top, bottom, y / (h - 1))
        for x in range(w):
            px[x, y] = c
    return g

def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

def s(v):  # scale design units (1024 grid) to supersampled pixels
    return int(v * SS)

canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))

# --- Base tile (macOS grid: 824 px tile, 100 px margin) with soft drop shadow
tile_box = (s(100), s(100), s(924), s(924))
radius = s(185)
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(
    (tile_box[0], tile_box[1] + s(14), tile_box[2], tile_box[3] + s(14)), radius=radius, fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(s(18)))
canvas.alpha_composite(shadow)

bg = vgradient((W, W), (32, 44, 92, 255), (18, 120, 160, 255))
canvas.paste(bg, (0, 0), rounded_mask((W, W), tile_box, radius))

d = ImageDraw.Draw(canvas)

# --- USB-C cable rising from the bottom edge, plugged into the photo card (clipped to the tile)
cab = Image.new("RGBA", (W, W), (0, 0, 0, 0))
cd = ImageDraw.Draw(cab)
cable_x = s(470)
cd.rounded_rectangle((cable_x - s(24), s(680), cable_x + s(24), s(960)), radius=s(10), fill=(226, 233, 243, 255))
cd.rounded_rectangle((cable_x - s(62), s(585), cable_x + s(62), s(700)), radius=s(26), fill=(245, 248, 252, 255))
cd.rounded_rectangle((cable_x - s(36), s(645), cable_x + s(36), s(668)), radius=s(11), fill=(40, 60, 100, 255))
tile_clip = rounded_mask((W, W), tile_box, radius)
canvas.paste(cab, (0, 0), Image.composite(cab.getchannel("A"), Image.new("L", (W, W), 0), tile_clip))
d = ImageDraw.Draw(canvas)

# --- Back photo card (tilted feel via offset, lighter)
back = (s(250), s(205), s(700), s(555))
d.rounded_rectangle(back, radius=s(36), fill=(255, 255, 255, 60))

# --- Front photo card with shadow
card = (s(300), s(255), s(760), s(615))
cs = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(cs).rounded_rectangle(
    (card[0], card[1] + s(10), card[2], card[3] + s(10)), radius=s(40), fill=(0, 0, 0, 90))
canvas.alpha_composite(cs.filter(ImageFilter.GaussianBlur(s(14))))
d = ImageDraw.Draw(canvas)
d.rounded_rectangle(card, radius=s(40), fill=(255, 255, 255, 255))

# photo inside the card
inner = (s(326), s(281), s(734), s(589))
photo = vgradient((inner[2] - inner[0], inner[3] - inner[1]), (120, 196, 255, 255), (190, 232, 255, 255))
pm = rounded_mask(photo.size, (0, 0, photo.size[0], photo.size[1]), s(22))
canvas.paste(photo, (inner[0], inner[1]), pm)

pd = ImageDraw.Draw(canvas)
# sun
pd.ellipse((s(628), s(318), s(690), s(380)), fill=(255, 205, 64, 255))
# mountains (clipped to the photo area)
mtn = Image.new("RGBA", (W, W), (0, 0, 0, 0))
md = ImageDraw.Draw(mtn)
md.polygon([(s(326), s(589)), (s(470), s(400)), (s(600), s(589))], fill=(46, 140, 96, 255))
md.polygon([(s(500), s(589)), (s(620), s(450)), (s(734), s(560)), (s(734), s(589))], fill=(30, 110, 78, 255))
clip = Image.new("L", (W, W), 0)
ImageDraw.Draw(clip).rounded_rectangle(inner, radius=s(22), fill=255)
canvas.paste(mtn, (0, 0), Image.composite(mtn.getchannel("A"), Image.new("L", (W, W), 0), clip))

# --- "pull" arrow badge (orange) bottom-right
bc = (s(735), s(700))
br = s(118)
bsh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(bsh).ellipse((bc[0] - br, bc[1] - br + s(10), bc[0] + br, bc[1] + br + s(10)), fill=(0, 0, 0, 100))
canvas.alpha_composite(bsh.filter(ImageFilter.GaussianBlur(s(12))))
d = ImageDraw.Draw(canvas)
d.ellipse((bc[0] - br, bc[1] - br, bc[0] + br, bc[1] + br), fill=(255, 149, 0, 255))
d.ellipse((bc[0] - br + s(6), bc[1] - br + s(6), bc[0] + br - s(6), bc[1] + br - s(6)), outline=(255, 190, 90, 255), width=s(4))
# down arrow
aw = s(26)
d.rounded_rectangle((bc[0] - aw, bc[1] - s(70), bc[0] + aw, bc[1] + s(20)), radius=s(10), fill=(255, 255, 255, 255))
d.polygon([(bc[0] - s(66), bc[1] + s(4)), (bc[0] + s(66), bc[1] + s(4)), (bc[0], bc[1] + s(76))], fill=(255, 255, 255, 255))

master = canvas.resize((S, S), Image.LANCZOS)

out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
iconset = os.path.join(out_dir, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
master.save(os.path.join(out_dir, "AppIcon-1024.png"))
for size in (16, 32, 128, 256, 512):
    master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    master.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
print("ok")
